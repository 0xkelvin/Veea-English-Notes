// Run from the project root:
// swiftc -swift-version 6 ios/Runner/GateAccessState.swift test/native/gate_access_state/main.swift -o /tmp/veea-gate-tests
import Foundation

@MainActor
func runTests() {
  let suite = "veea.gate.tests.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defer { defaults.removePersistentDomain(forName: suite) }
  let state = GateAccessState(defaults: defaults, migrateLegacy: false)
  let now = Date(timeIntervalSince1970: 1000)
  defaults.set(true, forKey: "gate_enabled")
  defaults.set(["X", "YouTube"], forKey: "gated_apps")

  precondition(state.needsChallenge(for: "X", now: now))
  state.grantPass(for: " X ", minutes: 0, now: now)
  precondition(!state.needsChallenge(for: "x", now: now.addingTimeInterval(1)))
  precondition(state.needsChallenge(for: "X", now: now.addingTimeInterval(2)))

  state.grantPass(for: "X", minutes: 5, now: now)
  precondition(!state.needsChallenge(for: "X", now: now.addingTimeInterval(1)))
  precondition(!state.needsChallenge(for: "X", now: now.addingTimeInterval(299)))
  precondition(state.needsChallenge(for: "X", now: now.addingTimeInterval(300)))
  precondition(state.needsChallenge(for: "YouTube", now: now))

  state.grantPass(for: "X", minutes: 0, now: now)
  precondition(state.needsChallenge(for: "X", now: now.addingTimeInterval(30)))
  state.grantPass(for: "X", minutes: 5, now: now)
  let reloaded = GateAccessState(defaults: defaults, migrateLegacy: false)
  precondition(!reloaded.needsChallenge(for: "X", now: now.addingTimeInterval(60)))
  reloaded.revokePass(for: "X")
  precondition(reloaded.needsChallenge(for: "X", now: now.addingTimeInterval(61)))

  defaults.set(false, forKey: "gate_enabled")
  precondition(!state.needsChallenge(for: "X", now: now))
  defaults.set(true, forKey: "gate_enabled")
  precondition(!state.needsChallenge(for: "WhatsApp", now: now))
  defaults.set(true, forKey: "native_gate_enabled")
  precondition(!state.needsChallenge(for: "X", now: now))
  defaults.set(false, forKey: "native_gate_enabled")
  precondition(state.needsChallenge(for: "X", now: now))
  print("14 gate access checks passed")
}

runTests()
