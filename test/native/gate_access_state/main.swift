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

  // Installer links, old checks and the wrong app must not confirm setup.
  precondition(state.testedShortcuts().isEmpty)
  state.recordShortcutCheck(for: "X", now: now)
  precondition(state.testedShortcuts().isEmpty)
  state.beginSetupTest(for: "X", now: now)
  state.recordShortcutCheck(for: "YouTube", now: now.addingTimeInterval(1))
  precondition(state.testedShortcuts().isEmpty)
  state.recordShortcutCheck(for: " x ", now: now.addingTimeInterval(2))
  precondition(state.testedShortcuts()["x"] == 1002)
  state.beginSetupTest(for: "X", now: now.addingTimeInterval(3))
  precondition(state.testedShortcuts().isEmpty)
  state.recordShortcutCheck(for: "X", now: now.addingTimeInterval(304))
  precondition(state.testedShortcuts().isEmpty)
  state.beginSetupTest(for: "X", now: now)
  defaults.set(true, forKey: "native_gate_enabled")
  state.recordShortcutCheck(for: "X", now: now.addingTimeInterval(1))
  precondition(state.testedShortcuts().isEmpty)
  defaults.set(false, forKey: "native_gate_enabled")
  defaults.set(false, forKey: "gate_enabled")
  state.recordShortcutCheck(for: "X", now: now.addingTimeInterval(1))
  precondition(state.testedShortcuts().isEmpty)
  print("Shortcut setup proof, retry, expiry, app isolation and disabled-mode checks passed")
  defaults.set(true, forKey: "gate_enabled")
  state.setUniversalEnabled(true)
  let a = "shortcut:name:safari:request:100-200"
  let b = "shortcut:name:whatsapp:request:103-203"
  let callbackA = "shortcuts://callback/a?token=test-a"
  let callbackB = "shortcuts://callback/b?token=test-b"
  func check(_ id: String, _ name: String, _ when: Date = now) -> Bool {
    state.prepareUniversalCheck("veea-universal\n\(id)\n\(name)", now: when)
  }
  precondition(!check("1-2", "Shortcuts"))
  precondition(!check("1-2", "Veea English"))
  precondition(!check("bad-token", "Safari"))
  precondition(check("100-200", "Safari"))
  precondition(state.acceptUniversalRequest(id: "different", callback: callbackA, now: now) == nil)
  for invalid in ["https://example.com", "shortcuts://run-shortcut?name=Other", "shortcuts://x-callback-url/run-shortcut?name=Other"] {
    precondition(state.acceptUniversalRequest(id: "100-200", callback: invalid, now: now) == nil)
  }
  precondition(state.takeUniversalReturn(for: a, now: now) == nil)
  precondition(!state.earnUniversalPass(for: b, now: now))
  precondition(state.acceptUniversalRequest(id: "100-200", callback: callbackA, now: now) == a)
  precondition(state.acceptUniversalRequest(id: "100-200", callback: callbackB, now: now) == nil)
  precondition(state.earnUniversalPass(for: a, now: now))
  precondition(state.takeUniversalReturn(for: b, now: now) == nil)
  precondition(state.takeUniversalReturn(for: a, now: now)?.absoluteString == callbackA)
  precondition(state.takeUniversalReturn(for: a, now: now) == nil)
  precondition(!check("101-201", "Safari", now.addingTimeInterval(1)))
  precondition(check("102-202", "Safari", now.addingTimeInterval(2)))
  precondition(check("103-203", "WhatsApp", now.addingTimeInterval(3)))
  precondition(state.acceptUniversalRequest(id: "102-202", callback: callbackA, now: now.addingTimeInterval(4)) == nil)
  precondition(state.acceptUniversalRequest(id: "103-203", callback: callbackB, now: now.addingTimeInterval(4)) == b)
  precondition(!state.earnUniversalPass(for: a, now: now.addingTimeInterval(4)))
  precondition(state.earnUniversalPass(for: b, now: now.addingTimeInterval(4)))
  precondition(state.takeUniversalReturn(for: b, now: now.addingTimeInterval(4))?.absoluteString == callbackB)
  state.universalReturnFailed(for: b)
  precondition(defaults.double(forKey: "gate_handoff_until_shortcut:name:whatsapp") == 0)
  precondition(state.takeUniversalReturn(for: b, now: now.addingTimeInterval(5))?.absoluteString == callbackB)
  state.cancelUniversalChallenge(for: a)
  precondition(state.universalSession?.target == b)
  state.cancelUniversalChallenge(for: b)
  precondition(state.universalSession == nil)
  precondition(check("104-204", "Safari"))
  precondition(state.acceptUniversalRequest(id: "104-204", callback: callbackA, now: now.addingTimeInterval(601)) == nil)
  precondition(check("105-205", "Safari"))
  let cancelTarget = state.universalSession!.target
  precondition(state.acceptUniversalRequest(id: "105-205", callback: callbackA, cancel: callbackB, now: now) == cancelTarget)
  precondition(state.cancelUniversalChallenge(for: cancelTarget)?.absoluteString == callbackB)
  precondition(check("106-206", "Safari"))
  let priorTarget = state.universalSession!.target
  precondition(check("107-207", "Safari"))
  let currentTarget = state.universalSession!.target
  precondition(priorTarget != currentTarget)
  precondition(state.acceptUniversalRequest(id: "107-207", callback: callbackB, now: now) == currentTarget)
  precondition(!state.earnUniversalPass(for: priorTarget, now: now))
  precondition(state.cancelUniversalChallenge(for: priorTarget) == nil)
  precondition(state.universalSession?.target == currentTarget)
  precondition(state.acceptUniversalRequest(id: "106-206", callback: callbackA, now: now) == nil)
  state.setUniversalEnabled(false)
  precondition(!check("108-208", "Safari"))
  precondition(state.universalSession == nil)
  print("Universal callback, multi-app isolation, earned return, replay, failure, cancellation and expiry checks passed")

}

runTests()
