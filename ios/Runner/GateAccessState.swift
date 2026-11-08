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

/// One pending callback belongs to one app and one challenge. No app URLs or
/// guessed launch schemes are needed: Shortcuts retains the original App value.
struct UniversalGateSession: Codable {
  let id: String
  let target: String
  let appKey: String
  let issuedAt: Double
  var callback: String?
  var cancelCallback: String?
  var earned = false
  var returnSent = false
}

extension GateAccessState {
  var universalEnabled: Bool {
    defaults.bool(forKey: "universal_gate_enabled")
      && defaults.bool(forKey: "gate_enabled")
      && !defaults.bool(forKey: "native_gate_enabled")
  }

  var universalSession: UniversalGateSession? {
    get {
      guard let data = defaults.data(forKey: "universal_gate_session") else { return nil }
      return try? JSONDecoder().decode(UniversalGateSession.self, from: data)
    }
    set {
      if let value = newValue, let data = try? JSONEncoder().encode(value) {
        defaults.set(data, forKey: "universal_gate_session")
      } else { defaults.removeObject(forKey: "universal_gate_session") }
    }
  }

  func setUniversalEnabled(_ enabled: Bool) {
    defaults.set(enabled, forKey: "universal_gate_enabled")
    defaults.removeObject(forKey: "universal_gate_error")
    if !enabled {
      if let session = universalSession { revokePass(for: session.appKey) }
      universalSession = nil
    }
  }

  private func beginUniversalChallenge(appKey: String, label: String, requestID: String, now: Date) -> Bool {
    var apps = defaults.dictionary(forKey: "universal_gate_apps") as? [String: String] ?? [:]
    apps[appKey] = label
    defaults.set(apps, forKey: "universal_gate_apps")
    let handoffKey = "gate_handoff_until_\(appKey)"
    let handoff = defaults.double(forKey: handoffKey)
    defaults.removeObject(forKey: handoffKey)
    if handoff > now.timeIntervalSince1970,
       let session = universalSession, session.appKey == appKey, session.earned, session.returnSent {
      defaults.set(now.timeIntervalSince1970, forKey: "universal_verified_\(appKey)")
      universalSession = nil
      return false
    }
    // Each opening supersedes the earlier callback, including another opening
    // of an app with the same name. Flutter keeps progress under the stable app key.
    if let prior = universalSession { revokePass(for: prior.appKey) }
    universalSession = UniversalGateSession(id: requestID, target: "\(appKey):request:\(requestID)", appKey: appKey,
                                            issuedAt: now.timeIntervalSince1970)
    return true
  }

  func prepareUniversalCheck(_ input: String, now: Date = Date()) -> Bool {
    let parts = input.split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
    guard universalEnabled, parts.count == 3, parts[0] == "veea-universal",
          parts[1].range(of: "^[0-9]{1,10}-[0-9]{1,10}$", options: .regularExpression) != nil else { return false }
    let label = parts[2].trimmingCharacters(in: .whitespacesAndNewlines)
    guard !label.isEmpty, label.count <= 100,
          !["shortcuts", "home screen", "veea english", "veeaenglish", "veea gate test"].contains(Self.normalized(label)) else { return false }
    // Shortcuts keeps the actual App object. Only its label is used for progress;
    // the per-invocation token correlates the callback with this exact opening.
    return beginUniversalChallenge(appKey: "shortcut:name:\(Self.normalized(label))",
                                   label: label, requestID: parts[1], now: now)
  }

  func acceptUniversalRequest(id: String, callback: String, cancel: String? = nil,
                              now: Date = Date()) -> String? {
    guard universalEnabled, var session = universalSession, session.id == id,
          !session.earned, !session.returnSent,
          session.issuedAt <= now.timeIntervalSince1970,
          now.timeIntervalSince1970 - session.issuedAt <= 600,
          Self.isShortcutCallback(callback),
          session.callback == nil || session.callback == callback else { return nil }
    session.callback = callback
    if let cancel, Self.isShortcutCallback(cancel) { session.cancelCallback = cancel }
    universalSession = session
    return session.target
  }

  /// Accept only the callback supplied by Shortcuts, never an arbitrary URL to
  /// another app, website, or a named shortcut chosen in an incoming deep link.
  static func isShortcutCallback(_ value: String) -> Bool {
    guard let url = URLComponents(string: value),
          ["shortcuts", "shortcuts-production"].contains(url.scheme?.lowercased() ?? ""),
          url.user == nil, url.password == nil, url.fragment == nil else { return false }
    let host = url.host?.lowercased() ?? ""
    return host == "callback" || (host == "x-callback-url" &&
      ["/callback", "/resume", "/complete"].contains(url.path.lowercased()))
  }

  func earnUniversalPass(for target: String, now: Date = Date()) -> Bool {
    guard universalEnabled, var session = universalSession, session.target == target,
          session.callback != nil, !session.returnSent,
          session.issuedAt <= now.timeIntervalSince1970,
          now.timeIntervalSince1970 - session.issuedAt <= 600 else { return false }
    session.earned = true
    universalSession = session
    return true
  }

  func takeUniversalReturn(for target: String, now: Date = Date()) -> URL? {
    guard universalEnabled, var session = universalSession, session.target == target,
          session.earned, !session.returnSent, let callback = session.callback,
          Self.isShortcutCallback(callback), now.timeIntervalSince1970 >= session.issuedAt,
          now.timeIntervalSince1970 - session.issuedAt <= 600,
          let url = URL(string: callback) else { return nil }
    session.returnSent = true
    universalSession = session
    grantPass(for: session.appKey, minutes: 0, now: now)
    return url
  }

  func universalReturnFailed(for target: String) {
    guard var session = universalSession, session.target == target else { return }
    session.returnSent = false
    universalSession = session
    revokePass(for: session.appKey)
  }

  @discardableResult
  func cancelUniversalChallenge(for target: String) -> URL? {
    guard let session = universalSession, session.target == target else { return nil }
    revokePass(for: session.appKey)
    universalSession = nil
    guard !session.earned, let callback = session.cancelCallback,
          Self.isShortcutCallback(callback) else { return nil }
    return URL(string: callback)
  }

  func universalStatus() -> [String: Any] {
    let apps = defaults.dictionary(forKey: "universal_gate_apps") as? [String: String] ?? [:]
    var result: [String: Any] = ["enabled": universalEnabled, "apps": apps.keys.sorted().map { key in
      ["id": key, "name": apps[key] ?? "Protected app",
       "verifiedAt": defaults.double(forKey: "universal_verified_\(key)")] as [String: Any]
    }]
    if let session = universalSession {
      result["pendingTarget"] = session.target
      result["pendingAppName"] = apps[session.appKey] ?? "Protected app"
    }
    return result
  }
}
