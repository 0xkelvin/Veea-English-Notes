import Foundation
import Darwin

enum TestFailure: Error { case schedule, mutation }

if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "increment" {
  let store = try NativeGateStore(directory: URL(fileURLWithPath: CommandLine.arguments[2]))
  for _ in 0..<30 { try store.update { $0.passMinutes += 1 } }
  exit(0)
}

let directory = FileManager.default.temporaryDirectory.appendingPathComponent("veea-native-tests-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: directory) }
let store = try NativeGateStore(directory: directory)
try NativeGatePolicy.validateApplicationCount(50)
do {
  try NativeGatePolicy.validateApplicationCount(51)
  preconditionFailure("More than 50 apps must not be accepted")
} catch NativeGateError.tooManyApplications {}
// A suspended process must not make the main app or an extension wait forever.
let lock = open(directory.appendingPathComponent("state.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
precondition(lock >= 0 && flock(lock, LOCK_EX | LOCK_NB) == 0)
let waitStarted = Date()
do {
  _ = try store.read()
  preconditionFailure("Expected bounded lock failure")
} catch NativeGateError.storage {}
precondition(Date().timeIntervalSince(waitStarted) < 3)
flock(lock, LOCK_UN)
close(lock)
let now = Date(timeIntervalSince1970: 1000.4)
let appA = NativeGateApplication(id: UUID().uuidString, token: Data([1]))
let appB = NativeGateApplication(id: UUID().uuidString, token: Data([2]))
try store.update { $0.enabled = true; $0.applications = [appA, appB] }
precondition(try! store.read().shieldedApplicationIDs(at: now) == [appA.id, appB.id])

// Launch duration policy: every whole minute from 5 minutes to 24 hours.
for minutes in [5, 6, 14, 15, 16, 59, 60, 90, 1439, 1440] {
  precondition(NativeGatePolicy.supportedPassMinutes.contains(minutes))
}
for minutes in [-1, 0, 4, 1441, 10080] {
  do {
    _ = try coordinatorForBounds(store).grant(applicationID: appB.id, minutes: minutes, now: now,
      startMonitoring: { _, _, _ in preconditionFailure("Invalid duration must not schedule") },
      stopMonitoring: { _ in }, apply: { _ in preconditionFailure("Invalid duration must not unshield") })
    preconditionFailure("Expected duration rejection")
  } catch NativeGateError.invalidDuration {}
}
func coordinatorForBounds(_ store: NativeGateStore) -> NativeGateGrantCoordinator {
  NativeGateGrantCoordinator(store: store)
}
// Cross-midnight 24-hour grant has an exact persisted schedule end and survives reload.
let lateNight = ISO8601DateFormatter().date(from: "2026-11-10T23:59:30Z")!
let dayPass = try coordinatorForBounds(store).grant(applicationID: appB.id, minutes: 1440, now: lateNight,
  startMonitoring: { _, start, end in precondition(end.timeIntervalSince(start) == 86400) },
  stopMonitoring: { _ in }, apply: { _ in })
precondition(dayPass.expiresAt.timeIntervalSince(lateNight) == 86400)
precondition(try! store.read().passes[appB.id] == dayPass)
try store.update { $0.passMinutes = 30 }
precondition(try! store.read().passes[appB.id] == dayPass) // Settings changes don't shorten earned access.
try store.update { $0.passes = [:] }

// Short elapsed-time passes still schedule >=15-minute ongoing intervals.
for minutes in [5, 6, 10, 14] {
  let shortPass = try coordinatorForBounds(store).grant(applicationID: appB.id, minutes: minutes, now: now,
    startMonitoring: { _, start, end in
      precondition(start < now)
      precondition(end.timeIntervalSince(start) == 900)
      precondition(end.timeIntervalSince(now) >= Double(minutes * 60))
      precondition(end.timeIntervalSince(now) < Double(minutes * 60 + 1))
      // An immediate intervalDidStart callback reconciles before the grant saves.
      try store.update { $0.reconcile(at: now) }
    }, stopMonitoring: { _ in }, apply: { _ in })
  try store.update { $0.reconcile(at: now) } // Or the start callback arrives after save.
  precondition(try! store.read().passes[appB.id] == shortPass)
  precondition(try! store.read().shieldedApplicationIDs(at: now) == [appA.id])
  try store.update { $0.reconcile(at: shortPass.expiresAt) } // End-callback policy.
  precondition(try! store.read().passes[appB.id] == nil)
  precondition(try! store.read().shieldedApplicationIDs(at: shortPass.expiresAt).contains(appB.id))
}
try store.update { $0.passes = [:] }

// A calendar/timezone is explicit and round-trips instants in DST's repeated hour.
for iso in ["2026-11-01T08:30:00Z", "2026-11-01T09:30:00Z", "2026-03-08T10:30:00Z"] {
  let instant = ISO8601DateFormatter().date(from: iso)!
  let components = NativeGatePolicy.scheduleComponents(for: instant)
  precondition(components.timeZone?.secondsFromGMT() == 0)
  precondition(components.calendar?.date(from: components) == instant)
}
var oldState = NativeGateState()
oldState.passMinutes = 0
oldState.reconcile(at: now)
precondition(oldState.passMinutes == 5)
oldState.passMinutes = 10080
oldState.reconcile(at: now)
precondition(oldState.passMinutes == 1440)

var scheduled = false
var applied = false
let coordinator = NativeGateGrantCoordinator(store: store)
let pass = try coordinator.grant(applicationID: appA.id, minutes: 15, now: now,
  startMonitoring: { _, start, expiry in
    precondition(expiry.timeIntervalSince(start) >= 900)
    precondition(expiry.timeIntervalSince1970.rounded() == expiry.timeIntervalSince1970)
    precondition(try! store.read().passes[appA.id] == nil)
    scheduled = true
  }, stopMonitoring: { _ in }, apply: { state in
    precondition(scheduled)
    precondition(state.shieldedApplicationIDs(at: now) == [appB.id])
    applied = true
  })
precondition(applied)
precondition(try! store.read().shieldedApplicationIDs(at: pass.expiresAt) == [appA.id, appB.id])
let reloaded = try NativeGateStore(directory: directory)
precondition(try! reloaded.read().passes[appA.id] == pass)

let beforeFailure = try store.read()
do {
  _ = try coordinator.grant(applicationID: appB.id, minutes: 15, now: now,
    startMonitoring: { _, _, _ in throw TestFailure.schedule },
    stopMonitoring: { _ in preconditionFailure("No monitor started") },
    apply: { _ in preconditionFailure("Failed scheduling must keep shields") })
  preconditionFailure("Expected schedule failure")
} catch TestFailure.schedule {}
precondition(try! store.read() == beforeFailure)
do {
  _ = try coordinator.grant(applicationID: appB.id, minutes: 0, now: now,
    startMonitoring: { _, _, _ in preconditionFailure("Zero duration cannot schedule") },
    stopMonitoring: { _ in }, apply: { _ in })
  preconditionFailure("Expected duration failure")
} catch NativeGateError.invalidDuration {}

var stoppedNewMonitor = false
do {
  _ = try coordinator.grant(applicationID: appB.id, minutes: 15, now: now,
    startMonitoring: { _, _, _ in try store.update { $0.enabled = false } },
    stopMonitoring: { _ in stoppedNewMonitor = true }, apply: { _ in
      preconditionFailure("A disabled gate must not grant a pass")
    })
  preconditionFailure("Expected stale-selection failure")
} catch NativeGateError.unknownApplication {}
precondition(stoppedNewMonitor)
try store.update { $0.enabled = true }

let renewed = try coordinator.grant(applicationID: appA.id, minutes: 30,
  now: now.addingTimeInterval(600), startMonitoring: { _, _, _ in },
  stopMonitoring: { old in precondition(old == pass.activityName) }, apply: { _ in })
try store.update { $0.reconcile(at: pass.expiresAt) }
precondition(try! store.read().passes[appA.id] == renewed)
precondition(try! store.read().shieldedApplicationIDs(at: pass.expiresAt) == [appB.id])

try store.update { $0.pendingChallenge = .init(applicationID: appB.id, createdAt: now) }
let pending = try store.update { $0.consumeChallenge(at: now.addingTimeInterval(10)) }
precondition(pending == "native:\(appB.id)")
precondition(try! store.update { $0.consumeChallenge(at: now.addingTimeInterval(11)) } == nil)
try store.update { $0.pendingChallenge = .init(applicationID: appB.id, createdAt: now) }
precondition(try! store.update { $0.consumeChallenge(at: now.addingTimeInterval(121)) } == nil)
try store.update { $0.pendingChallenge = .init(applicationID: appA.id, createdAt: now) }
precondition(try! store.update { $0.consumeChallenge(at: now.addingTimeInterval(1)) } == nil)

try store.update { $0.applications = [appB]; $0.reconcile(at: now) }
precondition(try! store.read().passes.isEmpty)
do {
  try store.update { state in state.enabled = false; throw TestFailure.mutation }
  preconditionFailure("Expected aborted transaction")
} catch TestFailure.mutation {}
precondition(try! store.read().enabled)

// Per-app rules migrate existing JSON and drive independent production grants.
let rulesDirectory = directory.appendingPathComponent("rules")
let rules = try NativeGateStore(directory: rulesDirectory)
try rules.update { state in
  state.enabled = true; state.applications = [appA, appB]; state.passMinutes = 15
}
let rulesFile = rulesDirectory.appendingPathComponent("state.json")
var legacyJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: rulesFile)) as! [String: Any]
legacyJSON.removeValue(forKey: "applicationMinutes")
legacyJSON.removeValue(forKey: "disabledApplicationIDs")
try JSONSerialization.data(withJSONObject: legacyJSON).write(to: rulesFile)
precondition(try! rules.read().applicationMinutes.isEmpty)
precondition(try! rules.read().unlockMinutes(for: appA.id) == 15)
try rules.update { try $0.setApplicationDuration(5, for: appA.id) }
let rulesCoordinator = NativeGateGrantCoordinator(store: rules)
let rulesA = try rulesCoordinator.grant(applicationID: appA.id, now: now,
  startMonitoring: { _, start, end in precondition(end.timeIntervalSince(start) >= 900) },
  stopMonitoring: { _ in }, apply: { _ in })
let rulesB = try rulesCoordinator.grant(applicationID: appB.id, now: now,
  startMonitoring: { _, _, _ in }, stopMonitoring: { _ in }, apply: { _ in })
precondition(rulesA.expiresAt == Date(timeIntervalSince1970: 1301))
precondition(rulesB.expiresAt == Date(timeIntervalSince1970: 1901))
try rules.update { $0.passMinutes = 60 }
precondition(try! rules.read().unlockMinutes(for: appA.id) == 5)
precondition(try! rules.read().unlockMinutes(for: appB.id) == 60)
precondition(try! rules.read().passes[appB.id] == rulesB)
try rules.update { $0.reconcile(at: rulesA.expiresAt) }
precondition(try! rules.read().shieldedApplicationIDs(at: rulesA.expiresAt) == [appA.id])
precondition(try! rules.read().passes[appB.id] == rulesB)
// Explicitly choosing the same value as the default remains a custom rule.
try rules.update { try $0.setApplicationDuration(60, for: appA.id); $0.passMinutes = 30 }
precondition(try! rules.read().unlockMinutes(for: appA.id) == 60)
try rules.update { try $0.setApplicationDuration(nil, for: appA.id) }
precondition(try! rules.read().unlockMinutes(for: appA.id) == 30)
let validRules = try rules.read()
for invalid in [0, 4, 1441] {
  do { try rules.update { try $0.setApplicationDuration(invalid, for: appA.id) }; preconditionFailure("Invalid override accepted") }
  catch NativeGateError.invalidDuration {}
}
do { try rules.update { try $0.setApplicationDuration(15, for: UUID().uuidString) }; preconditionFailure("Unknown app accepted") }
catch NativeGateError.unknownApplication {}
precondition(try! rules.read() == validRules)
try rules.update { state in
  try state.setApplicationDuration(5, for: appA.id)
  state.pendingChallenge = .init(applicationID: appA.id, createdAt: now)
  _ = try state.removeApplication(appA.id)
}
precondition(try! rules.read().pendingChallenge == nil)
precondition(try! rules.read().applicationMinutes[appA.id] == nil)
precondition(try! rules.read().enabled)
precondition(try! rules.read().passes[appB.id] == rulesB)
let removedMonitor = try rules.update { try $0.removeApplication(appB.id) }
precondition(removedMonitor == rulesB.activityName)
precondition(try! rules.read().enabled == false)
precondition(try! rules.read().passes.isEmpty)
// Picker changes prune removed app overrides without changing retained app timers.
try rules.update { state in
  state.applications = [appA]
  state.applicationMinutes = [appA.id: 15, appB.id: 30]
  state.reconcile(at: now)
}
precondition(try! rules.read().applicationMinutes == [appA.id: 15])
print("Per-app migration, inheritance, overrides, independent expiry and removal checks passed")

// Settings switches retain app/time choices while pausing only that app.
let toggles = try NativeGateStore(directory: directory.appendingPathComponent("toggles"))
try toggles.update { state in
  state.enabled = true; state.applications = [appA, appB]
  try state.setApplicationDuration(30, for: appA.id)
}
let toggleCoordinator = NativeGateGrantCoordinator(store: toggles)
let toggleA = try toggleCoordinator.grant(applicationID: appA.id, now: now,
  startMonitoring: { _, _, _ in }, stopMonitoring: { _ in }, apply: { _ in })
let toggleB = try toggleCoordinator.grant(applicationID: appB.id, now: now,
  startMonitoring: { _, _, _ in }, stopMonitoring: { _ in }, apply: { _ in })
try toggles.update { $0.pendingChallenge = .init(applicationID: appA.id, createdAt: now) }
let pausedMonitor = try toggles.update { try $0.setApplicationLockEnabled(false, for: appA.id) }
precondition(pausedMonitor == toggleA.activityName)
precondition(try! toggles.read().applications == [appA, appB])
precondition(try! toggles.read().applicationMinutes[appA.id] == 30)
precondition(try! toggles.read().passes[appA.id] == nil)
precondition(try! toggles.read().pendingChallenge == nil)
precondition(try! toggles.read().passes[appB.id] == toggleB)
precondition(try! toggles.read().isApplicationLockEnabled(appA.id) == false)
try toggles.update { $0.reconcile(at: toggleA.expiresAt) }
precondition(try! toggles.read().shieldedApplicationIDs(at: toggleA.expiresAt) == [appB.id])
do {
  _ = try toggleCoordinator.grant(applicationID: appA.id, now: now,
    startMonitoring: { _, _, _ in preconditionFailure("Paused apps cannot earn passes") }, stopMonitoring: { _ in }, apply: { _ in })
  preconditionFailure("Expected paused app rejection")
} catch NativeGateError.unknownApplication {}
try toggles.update { _ = try $0.setApplicationLockEnabled(true, for: appA.id) }
precondition(try! toggles.read().shieldedApplicationIDs(at: now).contains(appA.id))
// Repeating an unchanged ON must preserve an existing earned pass.
let enabledPass = try toggleCoordinator.grant(applicationID: appA.id, now: now,
  startMonitoring: { _, _, _ in }, stopMonitoring: { _ in }, apply: { _ in })
try toggles.update { _ = try $0.setApplicationLockEnabled(true, for: appA.id) }
precondition(try! toggles.read().passes[appA.id] == enabledPass)
// A switch turning OFF between scheduling and persistence must stop the new monitor.
var stoppedPausedMonitor = false
try toggles.update { _ = try $0.setApplicationLockEnabled(false, for: appB.id) }
try toggles.update { _ = try $0.setApplicationLockEnabled(true, for: appB.id) }
do {
  _ = try toggleCoordinator.grant(applicationID: appB.id, now: now,
    startMonitoring: { _, _, _ in try toggles.update { _ = try $0.setApplicationLockEnabled(false, for: appB.id) } },
    stopMonitoring: { _ in stoppedPausedMonitor = true }, apply: { _ in preconditionFailure("Paused race cannot unshield with a new pass") })
  preconditionFailure("Expected paused-app race rejection")
} catch NativeGateError.unknownApplication {}
precondition(stoppedPausedMonitor)
try toggles.disable { _ in }
precondition(try! toggles.read().applications.count == 2)
precondition(try! toggles.read().disabledApplicationIDs == [appB.id])
precondition(try! toggles.read().applicationMinutes[appA.id] == 30)
try toggles.update { $0.enabled = true; $0.reconcile(at: now) }
precondition(try! toggles.read().shieldedApplicationIDs(at: now) == [appA.id])
try toggles.update { _ = try $0.removeApplication(appB.id) }
precondition(try! toggles.read().disabledApplicationIDs.isEmpty)
print("App-lock switch migration, persistence, independent pausing, resume and grant-race checks passed")

// Verify that callbacks and the main app cannot lose each other's writes.
try store.update { $0.passMinutes = 0 }
let children = try (0..<4).map { _ -> Process in
  let process = Process()
  process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
  process.arguments = ["increment", directory.path]
  try process.run()
  return process
}
for process in children { process.waitUntilExit(); precondition(process.terminationStatus == 0) }
precondition(try! store.read().passMinutes == 120)

try Data("invalid state".utf8).write(to: directory.appendingPathComponent("state.json"))
do { _ = try store.read(); preconditionFailure("Corrupt state must not pretend to be a clean install") }
catch is DecodingError {}
try store.disable { state in precondition(state.shieldedApplicationIDs(at: now).isEmpty) }
precondition(try! store.read().enabled == false)
precondition(NativeGatePolicy.applicationID(from: "native:\(appA.id)") == appA.id)
precondition(NativeGatePolicy.applicationID(from: "native:bad-id") == nil)
print("Native gate policy, persistence, handoff, scheduling-failure, stale-callback, and cross-process lock tests passed")
