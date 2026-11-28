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
try store.update { try $0.setAllApplicationLocks(true) }
// All-off revoked the original pass. Earn a new one before testing renewal.
let restoredPass = try coordinator.grant(applicationID: appA.id, minutes: 15, now: now,
  startMonitoring: { _, _, _ in }, stopMonitoring: { _ in }, apply: { _ in })

let renewed = try coordinator.grant(applicationID: appA.id, minutes: 30,
  now: now.addingTimeInterval(600), startMonitoring: { _, _, _ in },
  stopMonitoring: { old in precondition(old == restoredPass.activityName) }, apply: { _ in })
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
precondition(try! toggles.read().disabledApplicationIDs == [appA.id, appB.id])
precondition(try! toggles.read().applicationMinutes[appA.id] == 30)
try toggles.update { try $0.setAllApplicationLocks(true); $0.reconcile(at: now) }
precondition(try! toggles.read().shieldedApplicationIDs(at: now) == [appA.id, appB.id])
try toggles.update { _ = try $0.removeApplication(appB.id) }
precondition(try! toggles.read().disabledApplicationIDs.isEmpty)
print("App-lock switch migration, persistence, independent pausing, resume and grant-race checks passed")

// Aggregate control is all-on/all-off; per-app changes keep the engine active
// whenever at least one selected app remains on, across persisted reloads.
try toggles.update { try $0.setAllApplicationLocks(false) }
precondition(try! toggles.read().enabled == false)
try toggles.update { _ = try $0.setApplicationLockEnabled(true, for: appA.id) }
precondition(try! toggles.read().enabled)
let aggregatePass = try toggleCoordinator.grant(applicationID: appA.id, now: now,
  startMonitoring: { _, _, _ in }, stopMonitoring: { _ in }, apply: { _ in })
try toggles.update { $0.applications.append(appB); $0.disabledApplicationIDs.insert(appB.id) }
precondition(try! toggles.read().shieldedApplicationIDs(at: now).isEmpty)
try toggles.update { try $0.setAllApplicationLocks(true); $0.reconcile(at: now) }
precondition(try! toggles.read().shieldedApplicationIDs(at: now) == [appB.id])
precondition(try! toggles.read().passes[appA.id] == aggregatePass)
try toggles.update { try $0.setAllApplicationLocks(true) }
precondition(try! toggles.read().passes[appA.id] == aggregatePass)
try toggles.update { _ = try $0.setApplicationLockEnabled(false, for: appA.id) }
precondition(try! toggles.read().enabled)
precondition(try! toggles.read().disabledApplicationIDs == [appA.id])
try toggles.update { _ = try $0.setApplicationLockEnabled(false, for: appB.id) }
precondition(try! toggles.read().enabled == false)
precondition(try! toggles.read().disabledApplicationIDs == [appA.id, appB.id])
try toggles.update { _ = try $0.setApplicationLockEnabled(true, for: appB.id) }
precondition(try! toggles.read().shieldedApplicationIDs(at: now) == [appB.id])
try toggles.update { _ = try $0.removeApplication(appB.id) }
precondition(try! toggles.read().enabled == false) // Remaining app A stays off.

// Legacy master-OFF must migrate to all OFF without resurrecting saved choices.
var legacyOff = NativeGateState()
legacyOff.applications = [appA, appB]
legacyOff.applicationMinutes = [appA.id: 30]
legacyOff.disabledApplicationIDs = [appB.id]
legacyOff.passes = [appA.id: aggregatePass]
legacyOff.pendingChallenge = .init(applicationID: appA.id, createdAt: now)
let migratedOff = try JSONDecoder().decode(NativeGateState.self, from: JSONEncoder().encode(legacyOff))
precondition(!migratedOff.enabled)
precondition(migratedOff.disabledApplicationIDs == [appA.id, appB.id])
precondition(migratedOff.applicationMinutes == [appA.id: 30])
precondition(migratedOff.passes.isEmpty && migratedOff.pendingChallenge == nil)
precondition(!migratedOff.isApplicationLockEnabled(appA.id))
var emptySelection = NativeGateState()
do {
  try emptySelection.setAllApplicationLocks(true)
  preconditionFailure("No selected apps cannot be enabled")
} catch NativeGateError.unknownApplication {}
print("Aggregate all-on/all-off, partial-state reload, last-active removal and legacy-OFF migration checks passed")

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

// Plan enforcement is native, independent of paywall widgets.
// Free means one app; full access requires a verified purchase.
precondition(!NativeGateReleasePolicy.isFreeLaunch)
precondition(!NativeGateReleasePolicy.permitsAllLockControls(purchasedPro: false))
precondition(NativeGateReleasePolicy.permitsAllLockControls(purchasedPro: true))
for minutes in [5, 7, 47, 1440] {
  try NativeGatePlanPolicy.requireDuration(minutes, pro: false)
  precondition(NativeGatePlanPolicy.duration(minutes, pro: false) == minutes)
}
for minutes in [0, 4, 1441] {
  do { try NativeGatePlanPolicy.requireDuration(minutes, pro: false); preconditionFailure("Reject unsupported duration") }
  catch NativeGateError.invalidDuration {}
}
print("Free includes one app; all supported default and per-app times remain free")

// Count enforcement and downgrade preserve personal configuration.
try NativeGatePlanPolicy.requireAppCount(1, pro: false)
do { try NativeGatePlanPolicy.requireAppCount(2, pro: false); preconditionFailure("Free must refuse a second app") }
catch NativeGatePlanError.proRequired {}
try NativeGatePlanPolicy.requireAppCount(50, pro: true)
for minutes in [5, 15, 30] { try NativeGatePlanPolicy.requireDuration(minutes, pro: false) }
try NativeGatePlanPolicy.requireDuration(7, pro: false)
precondition(NativeGatePlanPolicy.duration(7, pro: false) == 7)
precondition(NativeGatePlanPolicy.duration(7, pro: true) == 7)
var downgrade = NativeGateState()
downgrade.applications = [appA, appB]
try downgrade.setAllApplicationLocks(true)
downgrade.applicationMinutes = [appB.id: 7]
downgrade.passes[appB.id] = aggregatePass
let stoppedByPlan = NativeGatePlanPolicy.applyFreePlan(to: &downgrade)
precondition(stoppedByPlan == [aggregatePass.activityName])
precondition(downgrade.isApplicationLockEnabled(appA.id))
precondition(!downgrade.isApplicationLockEnabled(appB.id))
precondition(downgrade.applications == [appA, appB])
precondition(downgrade.applicationMinutes[appB.id] == 7)
precondition(NativeGatePlanPolicy.applyFreePlan(to: &downgrade).isEmpty)
// OFF and removal always remain possible after a downgrade.
_ = try downgrade.setApplicationLockEnabled(false, for: appA.id)
_ = try downgrade.removeApplication(appB.id)
precondition(!downgrade.enabled)
print("Free/Pro native limits, retained selections, safe downgrade, and unconditional removal checks passed")

var preferredFree = NativeGateState()
preferredFree.applications = [appA,appB]
try preferredFree.setAllApplicationLocks(true)
_ = NativeGatePlanPolicy.applyFreePlan(to:&preferredFree,preferredApplicationID:appB.id)
precondition(preferredFree.isApplicationLockEnabled(appB.id))
precondition(!preferredFree.isApplicationLockEnabled(appA.id))
print("Free downgrade keeps the current challenge app when available")

var earnedFree = NativeGateState()
earnedFree.applications = [appA, appB]
try earnedFree.setAllApplicationLocks(true)
earnedFree.passes[appB.id] = aggregatePass
_ = NativeGatePlanPolicy.applyFreePlan(to: &earnedFree, at: now)
precondition(earnedFree.isApplicationLockEnabled(appB.id))
precondition(earnedFree.passes[appB.id] == aggregatePass)
precondition(!earnedFree.isApplicationLockEnabled(appA.id))
precondition(earnedFree.shieldedApplicationIDs(at: now).isEmpty)
print("Free downgrade preserves the earned pass when no challenge app is pending")

// Safety limit is independent of the plan.
for count in [1, 2, 50] { try NativeGatePolicy.validateApplicationCount(count) }
do { try NativeGatePolicy.validateApplicationCount(51); preconditionFailure("Reject selections over the safety limit") }
catch NativeGateError.tooManyApplications {}

// Readiness: unknown is never a confirmed downgrade and never grants Pro.
typealias R = NativeGatePlanReadiness
precondition(!R.isReady(scanComplete: false, signedIn: false, installationSupported: true, hasPro: false, serverPlanKnown: false))
precondition(!R.isReady(scanComplete: false, signedIn: true, installationSupported: true, hasPro: true, serverPlanKnown: true))
// Guest: verified StoreKit scan alone decides (offline guest purchases count).
precondition(R.isReady(scanComplete: true, signedIn: false, installationSupported: true, hasPro: false, serverPlanKnown: false))
precondition(R.isReady(scanComplete: true, signedIn: false, installationSupported: true, hasPro: true, serverPlanKnown: false))
// Signed in with unreachable/unknown account plan: wait, do not pause extras.
precondition(!R.isReady(scanComplete: true, signedIn: true, installationSupported: true, hasPro: false, serverPlanKnown: false))
precondition(R.isReady(scanComplete: true, signedIn: true, installationSupported: true, hasPro: true, serverPlanKnown: false))
precondition(R.isReady(scanComplete: true, signedIn: true, installationSupported: true, hasPro: false, serverPlanKnown: true))
precondition(R.isReady(scanComplete: true, signedIn: true, installationSupported: false, hasPro: false, serverPlanKnown: false))
// Unknown status still permits one free app; only more apps need Pro.
try NativeGatePlanPolicy.requireAppCount(0, pro: false)
try NativeGatePlanPolicy.requireAppCount(1, pro: false)
print("Plan readiness waits for ownership and account status without blocking the free app")

// Picker save: a Free picker over a retained (migrated/downgraded) list edits
// the one active app and never deletes the paused apps, times or passes.
typealias S = NativeGateSelectionPolicy
let freeCheck: (Int) throws -> Void = { try NativeGatePlanPolicy.requireAppCount($0, pro: false) }
let proCheck: (Int) throws -> Void = { try NativeGatePlanPolicy.requireAppCount($0, pro: true) }
let appC = NativeGateApplication(id: UUID().uuidString, token: Data([3]))
let appNew = NativeGateApplication(id: UUID().uuidString, token: Data([4]))
let pickerPass = NativeGatePass(expiresAt: now.addingTimeInterval(600), activityName: "picker-pass")
func activeIDs(_ state: NativeGateState) -> Set<String> {
  Set(state.applications.map(\.id).filter { state.isApplicationLockEnabled($0) })
}
func retainedFreeState() throws -> NativeGateState {
  var state = NativeGateState()
  state.applications = [appA, appB, appC].sorted { $0.id < $1.id }
  try state.setAllApplicationLocks(true)
  state.applicationMinutes = [appA.id: 30, appB.id: 7, appC.id: 90]
  state.passes[appA.id] = pickerPass
  _ = NativeGatePlanPolicy.applyFreePlan(to: &state, preferredApplicationID: appA.id, at: now)
  precondition(activeIDs(state) == [appA.id])
  return state
}

// Unchanged: saving the active app keeps every app, time and the earned pass.
var unchanged = try retainedFreeState()
let unchangedBefore = unchanged
let unchangedStops = try S.apply(chosen: [appA], freePicker: true, proNow: false, to: &unchanged, at: now, requireAppCount: freeCheck)
precondition(unchangedStops.isEmpty)
precondition(unchanged == unchangedBefore)

// Switch to an existing paused app: it becomes the only active app with its
// saved time; the old app pauses (its pass ends) but stays saved.
var switched = try retainedFreeState()
let switchedStops = try S.apply(chosen: [appB], freePicker: true, proNow: false, to: &switched, at: now, requireAppCount: freeCheck)
precondition(switchedStops == ["picker-pass"])
precondition(Set(switched.applications.map(\.id)) == [appA.id, appB.id, appC.id])
precondition(activeIDs(switched) == [appB.id])
precondition(switched.applicationMinutes == [appA.id: 30, appB.id: 7, appC.id: 90])
precondition(switched.unlockMinutes(for: appB.id) == 7)

// Switch to a new app: added, sole active, nothing removed.
var added = try retainedFreeState()
_ = try S.apply(chosen: [appNew], freePicker: true, proNow: false, to: &added, at: now, requireAppCount: freeCheck)
precondition(added.applications.count == 4 && added.applications.contains(appNew))
precondition(activeIDs(added) == [appNew.id])
precondition(added.applicationMinutes == [appA.id: 30, appB.id: 7, appC.id: 90])

// Several apps active (Free confirmed after a downgrade, not yet reconciled):
// an unchanged save leaves exactly one active and deletes nothing.
var multiActive = NativeGateState()
multiActive.applications = [appA, appB, appC].sorted { $0.id < $1.id }
try multiActive.setAllApplicationLocks(true)
multiActive.passes[appA.id] = pickerPass
_ = try S.apply(chosen: [appA], freePicker: true, proNow: false, to: &multiActive, at: now, requireAppCount: freeCheck)
precondition(activeIDs(multiActive) == [appA.id] && multiActive.passes[appA.id] == pickerPass)
precondition(multiActive.applications.count == 3)

// All locks off: choosing keeps every lock off and keeps the list.
var allOff = try retainedFreeState()
try allOff.setAllApplicationLocks(false)
_ = try S.apply(chosen: [appB], freePicker: true, proNow: false, to: &allOff, at: now, requireAppCount: freeCheck)
precondition(activeIDs(allOff).isEmpty && !allOff.enabled && allOff.applications.count == 3)
_ = try S.apply(chosen: [appNew], freePicker: true, proNow: false, to: &allOff, at: now, requireAppCount: freeCheck)
precondition(activeIDs(allOff).isEmpty && !allOff.enabled && allOff.applications.count == 4)
precondition(allOff.applicationMinutes == [appA.id: 30, appB.id: 7, appC.id: 90])

// Empty defensive Free save on a retained list turns all off, keeps the list.
var emptied = try retainedFreeState()
let emptiedStops = try S.apply(chosen: [], freePicker: true, proNow: false, to: &emptied, at: now, requireAppCount: freeCheck)
precondition(emptiedStops == ["picker-pass"])
precondition(!emptied.enabled && emptied.applications.count == 3 && emptied.passes.isEmpty)
precondition(emptied.applicationMinutes == [appA.id: 30, appB.id: 7, appC.id: 90])

// More than one chosen app is refused on a Free picker even with Pro now.
for pro in [false, true] {
  var refused = try retainedFreeState()
  let before = refused
  do {
    _ = try S.apply(chosen: [appA, appB], freePicker: true, proNow: pro, to: &refused, at: now, requireAppCount: pro ? proCheck : freeCheck)
    preconditionFailure("Free picker must refuse two apps")
  } catch NativeGatePlanError.proRequired {}
  precondition(refused == before)
}

// Adding a new app respects the 50-app safety limit; existing apps still switch.
var full50 = NativeGateState()
full50.applications = (0..<50).map { NativeGateApplication(id: UUID().uuidString, token: Data([UInt8($0)])) }
try full50.setAllApplicationLocks(true)
_ = NativeGatePlanPolicy.applyFreePlan(to: &full50, at: now)
do {
  _ = try S.apply(chosen: [appNew], freePicker: true, proNow: false, to: &full50, at: now, requireAppCount: freeCheck)
  preconditionFailure("51st app must be refused")
} catch NativeGateError.tooManyApplications {}
_ = try S.apply(chosen: [full50.applications[7]], freePicker: true, proNow: false, to: &full50, at: now, requireAppCount: freeCheck)
precondition(full50.applications.count == 50 && activeIDs(full50) == [full50.applications[7].id])

// Pro verified while a Free-mode picker was open: hidden paused apps are kept
// and none are newly paused; the chosen app is switched on.
var upgraded = try retainedFreeState()
_ = try S.apply(chosen: [appB], freePicker: true, proNow: true, to: &upgraded, at: now, requireAppCount: proCheck)
precondition(upgraded.applications.count == 3 && activeIDs(upgraded) == [appA.id, appB.id])
precondition(upgraded.passes[appA.id] == pickerPass)
// Plan unknown at save (not Pro) still only allows one active app.
var unknownSave = try retainedFreeState()
let unknownCheck: (Int) throws -> Void = { if $0 > 1 { throw NativeGatePlanError.checkingPro } }
_ = try S.apply(chosen: [appC], freePicker: true, proNow: false, to: &unknownSave, at: now, requireAppCount: unknownCheck)
precondition(activeIDs(unknownSave) == [appC.id] && unknownSave.applications.count == 3)

// Ordinary Free (one saved app) keeps deliberate replacement.
var single = NativeGateState()
single.applications = [appA]
try single.setAllApplicationLocks(true)
single.applicationMinutes = [appA.id: 30]
single.passes[appA.id] = pickerPass
let singleKeep = single
let singleStops = try S.apply(chosen: [appA], freePicker: true, proNow: false, to: &single, at: now, requireAppCount: freeCheck)
precondition(singleStops.isEmpty)
precondition(single == singleKeep) // Same app keeps id, custom time and pass.
let replacedStops = try S.apply(chosen: [appB], freePicker: true, proNow: false, to: &single, at: now, requireAppCount: freeCheck)
precondition(replacedStops == ["picker-pass"] && single.applications == [appB] && single.applicationMinutes.isEmpty)
precondition(activeIDs(single) == [appB.id])

// Full (Pro) picker replaces deliberately; the current-plan check still applies.
var proReplace = try retainedFreeState()
_ = try S.apply(chosen: [appB, appNew], freePicker: false, proNow: true, to: &proReplace, at: now, requireAppCount: proCheck)
precondition(Set(proReplace.applications.map(\.id)) == [appB.id, appNew.id])
precondition(proReplace.applicationMinutes == [appB.id: 7])
var lostPro = try retainedFreeState()
let lostBefore = lostPro
do {
  _ = try S.apply(chosen: [appB, appNew], freePicker: false, proNow: false, to: &lostPro, at: now, requireAppCount: freeCheck)
  preconditionFailure("Pro lost mid-picker must refuse several apps")
} catch NativeGatePlanError.proRequired {}
precondition(lostPro == lostBefore)

// Through the locked store: a refused save leaves the persisted state intact.
let pickerStore = try NativeGateStore(directory: directory.appendingPathComponent("picker"))
let persistedRetained = try retainedFreeState()
try pickerStore.update { $0 = persistedRetained }
do {
  try pickerStore.update { state in
    _ = try S.apply(chosen: [appB, appNew], freePicker: false, proNow: false, to: &state, at: now, requireAppCount: freeCheck)
  }
  preconditionFailure("Expected refusal")
} catch NativeGatePlanError.proRequired {}
precondition(try! pickerStore.read() == persistedRetained)
try pickerStore.update { state in
  _ = try S.apply(chosen: [appC], freePicker: true, proNow: false, to: &state, at: now, requireAppCount: freeCheck)
}
let persistedSwitch = try pickerStore.read()
precondition(activeIDs(persistedSwitch) == [appC.id] && persistedSwitch.applications.count == 3)
print("Free picker keeps paused apps, times and passes; switches, all-off, empty, max, upgrade and Pro replacement checks passed")

// Server plan freshness: a Premium lease is known only until it ends; an
// explicit Free reply stays known. Clock is injected.
typealias F = NativeGateServerPlanFreshness
let t0: TimeInterval = 1_800_000_000
var fresh = F()
precondition(!fresh.isKnown(at: t0))
fresh.recordLease(until: t0 + 3600, now: t0)
precondition(fresh.isKnown(at: t0) && fresh.isKnown(at: t0 + 3599))
precondition(!fresh.isKnown(at: t0 + 3600))
// Bounded like the lease itself: never more than 24 hours.
fresh.recordLease(until: t0 + 10 * 86400, now: t0)
precondition(fresh.knownUntil == t0 + 86400)
precondition(fresh.isKnown(at: t0 + 86399) && !fresh.isKnown(at: t0 + 86400))
// A later fresh reply (Free) supersedes and stays known.
fresh.recordFree()
precondition(fresh.isKnown(at: t0 + 30 * 86400))
// A later Premium reply replaces Free knowledge with a bounded window.
fresh.recordLease(until: t0 + 60, now: t0)
precondition(!fresh.confirmedFree && !fresh.isKnown(at: t0 + 61))
// Non-finite input is ignored rather than becoming unbounded knowledge.
var nonFinite = F()
nonFinite.recordLease(until: .infinity, now: t0)
precondition(!nonFinite.isKnown(at: t0))
nonFinite.recordFree()
nonFinite.recordLease(until: .nan, now: t0)
precondition(nonFinite.isKnown(at: t0))
// Already-expired lease is unknown.
var expired = F()
expired.recordLease(until: t0 - 1, now: t0)
precondition(!expired.isKnown(at: t0))
// Reset (account/product/origin change) forgets everything.
var resetPlan = F()
resetPlan.recordFree()
resetPlan.reset()
precondition(!resetPlan.isKnown(at: t0))

// Readiness: offline after a server-only lease ends -> not ready (no pause);
// fresh Free -> ready; guests are unaffected; freshness never grants Pro.
var leased = F()
leased.recordLease(until: t0 + 86400, now: t0)
precondition(R.isReady(scanComplete: true, signedIn: true, installationSupported: true, hasPro: true, serverPlan: leased, now: t0 + 100))
precondition(!R.isReady(scanComplete: true, signedIn: true, installationSupported: true, hasPro: false, serverPlan: leased, now: t0 + 86400 + 1))
// A refund observed while the lease answer is fresh is a confirmed Free state.
precondition(R.isReady(scanComplete: true, signedIn: true, installationSupported: true, hasPro: false, serverPlan: leased, now: t0 + 100))
var freeReply = F()
freeReply.recordFree()
precondition(R.isReady(scanComplete: true, signedIn: true, installationSupported: true, hasPro: false, serverPlan: freeReply, now: t0 + 30 * 86400))
precondition(!R.isReady(scanComplete: false, signedIn: true, installationSupported: true, hasPro: false, serverPlan: freeReply, now: t0))
precondition(R.isReady(scanComplete: true, signedIn: false, installationSupported: true, hasPro: false, serverPlan: F(), now: t0))
precondition(!R.isReady(scanComplete: true, signedIn: true, installationSupported: true, hasPro: false, serverPlan: F(), now: t0))
print("Server plan freshness: expired account leases are unknown, Free replies stay known, guests unaffected")
