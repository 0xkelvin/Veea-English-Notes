import Foundation

/// Purchase environments are distinct ownership and cache namespaces. Unknown
/// environments (including Xcode simulation) cannot unlock a release build.
enum ProPurchasePolicy {
  static func supports(_ environment: String?) -> Bool {
    environment == "Production" || environment == "Sandbox"
  }

  static func allowsInstallation(_ environment: String?) -> Bool {
    environment == nil || supports(environment)
  }

  static func planReady(owner: UUID?, installation: String?, hasOwnership: Bool, hasLease: Bool, serverPlanKnown: Bool) -> Bool {
    if owner == nil || !allowsInstallation(installation) { return true }
    return hasOwnership || hasLease || serverPlanKnown
  }

  static func canCommitOwnershipScan(startedIn: String?, currentInstallation: String?) -> Bool {
    // Resolving nil to a supported app-download environment does not change
    // which signed IAPs StoreKit admits. A known unsupported install stays closed.
    allowsInstallation(startedIn) && allowsInstallation(currentInstallation)
  }

  static func hasLifetime(owned: Bool, memory: ProServerLease, diskExpiresAt: TimeInterval?, diskLifetime: Bool, now: TimeInterval) -> Bool {
    if owned || (memory.isActive(at: now) && memory.lifetime) { return true }
    guard diskLifetime, let diskExpiresAt, diskExpiresAt.isFinite, now.isFinite else { return false }
    return now < diskExpiresAt
  }

  static func replacesServerLease(clearServer: Bool, until: TimeInterval?, lifetime: Bool?) -> Bool {
    if clearServer { return true }
    return until?.isFinite == true && lifetime != nil
  }

  static func accepts(installation: String?, transaction: String?) -> Bool {
    // StoreKit scopes its transaction sequences to this installation. The app
    // download and its IAP can have different signing environments in review;
    // AppTransaction is a cache namespace, never an IAP environment router.
    // Missing app information must not erase independently signed offline Pro.
    supports(transaction) && allowsInstallation(installation)
  }

  static func namespace(environment: String?, owner: UUID?, productID: String, apiOrigin: String) -> String? {
    guard supports(environment), let environment, let owner, !productID.isEmpty, !apiOrigin.isEmpty else { return nil }
    let origin = Data(apiOrigin.utf8).base64EncodedString()
    return "v2.\(origin).\(environment).\(owner.uuidString.lowercased()).\(productID)"
  }

  static func clearServerLeases(in defaults: UserDefaults, owner: UUID?, productID: String, apiOrigin: String, lifetimeOnly: Bool = false) {
    // Removing an authoritative account grant does not need an app-download
    // environment. Clear both possible namespaces before a late lookup can
    // reveal an obsolete cached lease, retaining other accounts and services.
    for environment in ["Production", "Sandbox"] {
      guard let namespace = namespace(environment: environment, owner: owner, productID: productID, apiOrigin: apiOrigin) else { continue }
      let key = "pro.server.lease.\(namespace)"
      if lifetimeOnly && !defaults.bool(forKey: key + ".lifetime") { continue }
      defaults.removeObject(forKey: key)
      defaults.removeObject(forKey: key + ".lifetime")
    }
  }
}

/// A freshly authenticated server plan may be used immediately if Apple cannot
/// resolve the app download offline. This fallback is process-local; persistence
/// still requires a verified installation namespace.
struct ProServerLease {
  private(set) var expiresAt: TimeInterval?
  private(set) var lifetime = false

  mutating func grant(until: TimeInterval, lifetime: Bool?, now: TimeInterval) {
    guard until.isFinite, now.isFinite else { clear(); return }
    let retainedLifetime = isActive(at: now) && self.lifetime
    expiresAt = min(until, now + 86400)
    self.lifetime = lifetime ?? retainedLifetime
  }

  func isActive(at now: TimeInterval) -> Bool {
    guard now.isFinite, let expiresAt else { return false }
    return now < expiresAt
  }

  mutating func clear() {
    expiresAt = nil
    lifetime = false
  }

  mutating func clearLifetime() {
    if lifetime { clear() }
  }
}
