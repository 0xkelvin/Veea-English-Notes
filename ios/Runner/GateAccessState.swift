import Foundation

/// Persistent access state shared by the app and its in-app background intent.
/// The intent must check this BEFORE a Shortcut opens Veea's URL.
@MainActor
final class GateAccessState {
  static let shared = GateAccessState(defaults: .standard)
  let defaults: UserDefaults

  init(defaults: UserDefaults, migrateLegacy: Bool = true) {
    self.defaults = defaults
    if migrateLegacy && !defaults.bool(forKey: "gate_state_migrated_v1") {
      if let legacy = UserDefaults(suiteName: "group.app.veea.english") {
        for (key, value) in legacy.dictionaryRepresentation()
          where Self.isGateKey(key) && defaults.object(forKey: key) == nil {
          defaults.set(value, forKey: key)
        }
      }
      defaults.set(true, forKey: "gate_state_migrated_v1")
    }
  }

  static func normalized(_ app: String) -> String {
    app.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  private static func isGateKey(_ key: String) -> Bool {
    ["gate_enabled", "gated_apps", "pass_minutes"].contains(key)
      || key.hasPrefix("unlocked_until_")
  }

  /// Consumes only the earned return-to-app token, never a general cooldown.
  func needsChallenge(for app: String, now: Date = Date()) -> Bool {
    if defaults.bool(forKey: "native_gate_enabled") { return false }
    let key = Self.normalized(app)
    let selected = defaults.stringArray(forKey: "gated_apps") ?? []
    guard defaults.bool(forKey: "gate_enabled"),
          selected.contains(where: { Self.normalized($0) == key }) else {
      return false
    }
    let handoffKey = "gate_handoff_until_\(key)"
    let handoffUntil = defaults.double(forKey: handoffKey)
    defaults.removeObject(forKey: handoffKey)
    if handoffUntil > now.timeIntervalSince1970 { return false }
    return defaults.double(forKey: "unlocked_until_\(key)") <= now.timeIntervalSince1970
  }

  func grantPass(for app: String, minutes: Int, now: Date = Date()) {
    let key = Self.normalized(app)
    // Every Open grants exactly the earned handoff, rather than a minute pass.
    if minutes > 0 {
      defaults.set(now.addingTimeInterval(Double(minutes) * 60).timeIntervalSince1970,
                   forKey: "unlocked_until_\(key)")
    } else {
      defaults.removeObject(forKey: "unlocked_until_\(key)")
    }
    defaults.set(now.addingTimeInterval(30).timeIntervalSince1970,
                 forKey: "gate_handoff_until_\(key)")
  }

  func revokePass(for app: String) {
    let key = Self.normalized(app)
    defaults.removeObject(forKey: "unlocked_until_\(key)")
    defaults.removeObject(forKey: "gate_handoff_until_\(key)")
  }

  // A fresh setup test is confirmed only by the installed background intent.
  // Launching Shortcuts, returning to Veea or a user tapping Next is not proof.
  func beginSetupTest(for app: String, now: Date = Date()) {
    let key = Self.normalized(app)
    defaults.set(UUID().uuidString, forKey: "setup_test_nonce_\(key)")
    defaults.set(now.timeIntervalSince1970, forKey: "setup_test_started_\(key)")
    defaults.removeObject(forKey: "setup_checked_nonce_\(key)")
    defaults.removeObject(forKey: "setup_checked_at_\(key)")
  }

  func recordShortcutCheck(for app: String, now: Date = Date()) {
    let key = Self.normalized(app)
    let started = defaults.double(forKey: "setup_test_started_\(key)")
    guard defaults.bool(forKey: "gate_enabled"),
          !defaults.bool(forKey: "native_gate_enabled"),
          (defaults.stringArray(forKey: "gated_apps") ?? []).contains(where: { Self.normalized($0) == key }),
          let nonce = defaults.string(forKey: "setup_test_nonce_\(key)"),
          started > 0, now.timeIntervalSince1970 >= started,
          now.timeIntervalSince1970 - started <= 300 else { return }
    defaults.set(nonce, forKey: "setup_checked_nonce_\(key)")
    defaults.set(now.timeIntervalSince1970, forKey: "setup_checked_at_\(key)")
  }

  func testedShortcuts() -> [String: Double] {
    var result: [String: Double] = [:]
    for (name, _) in defaults.dictionaryRepresentation() where name.hasPrefix("setup_test_nonce_") {
      let key = String(name.dropFirst("setup_test_nonce_".count))
      if let nonce = defaults.string(forKey: name),
         defaults.string(forKey: "setup_checked_nonce_\(key)") == nonce {
        result[key] = defaults.double(forKey: "setup_checked_at_\(key)")
      }
    }
    return result
  }
}
