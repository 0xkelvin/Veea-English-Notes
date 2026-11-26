import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
  if !condition() { fatalError(message) }
}

// Apple's app-download signing environment is not an IAP router. In review an
// otherwise Production app must accept a fresh verified Sandbox purchase.
let environments: [String?] = ["Sandbox", "Production", "Xcode", "", "Future", nil]
for app in environments {
  for transaction in environments {
    let shouldAccept = (transaction == "Sandbox" || transaction == "Production") &&
      (app == nil || app == "Sandbox" || app == "Production")
    expect(ProPurchasePolicy.accepts(installation: app, transaction: transaction) == shouldAccept,
           "Unexpected purchase environment admission: \(String(describing: app))/\(String(describing: transaction))")
  }
}
expect(ProPurchasePolicy.accepts(installation: "Production", transaction: "Sandbox"), "App Review Sandbox IAP was rejected by app-download environment")
expect(ProPurchasePolicy.canCommitOwnershipScan(startedIn: nil, currentInstallation: "Production"), "Late Production app lookup discarded a completed offline ownership scan")
expect(ProPurchasePolicy.canCommitOwnershipScan(startedIn: nil, currentInstallation: "Sandbox"), "Late Sandbox app lookup discarded a completed restore or purchase scan")
expect(!ProPurchasePolicy.canCommitOwnershipScan(startedIn: nil, currentInstallation: "Xcode"), "Late Xcode app lookup admitted release ownership")
expect(!ProPurchasePolicy.canCommitOwnershipScan(startedIn: nil, currentInstallation: "Unsupported"), "Unknown app lookup admitted release ownership")

let owner = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
let otherOwner = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
expect(!ProPurchasePolicy.planReady(owner: owner, installation: nil, hasOwnership: false, hasLease: false, serverPlanKnown: false), "Initial unresolved account paused paid locks as Free")
expect(!ProPurchasePolicy.planReady(owner: owner, installation: "Production", hasOwnership: false, hasLease: false, serverPlanKnown: false), "Verified app download was mistaken for a verified account plan")
expect(ProPurchasePolicy.planReady(owner: owner, installation: nil, hasOwnership: true, hasLease: false, serverPlanKnown: false), "Offline StoreKit owner could not reconcile its plan")
expect(ProPurchasePolicy.planReady(owner: owner, installation: nil, hasOwnership: false, hasLease: true, serverPlanKnown: false), "Fresh server-only Pro grant could not reconcile its plan")
expect(ProPurchasePolicy.planReady(owner: owner, installation: nil, hasOwnership: false, hasLease: false, serverPlanKnown: true), "Authoritative Free reply could not pause extra locks")
expect(ProPurchasePolicy.planReady(owner: nil, installation: nil, hasOwnership: false, hasLease: false, serverPlanKnown: false), "Signed-out Free plan never settled")
expect(ProPurchasePolicy.planReady(owner: owner, installation: "Xcode", hasOwnership: false, hasLease: false, serverPlanKnown: false), "Unsupported release installation never settled")
let sandbox = ProPurchasePolicy.namespace(environment: "Sandbox", owner: owner, productID: "app.veea.pro", apiOrigin: "https://accounts.example.test")!
let production = ProPurchasePolicy.namespace(environment: "Production", owner: owner, productID: "app.veea.pro", apiOrigin: "https://accounts.example.test")!
expect(sandbox != production, "Sandbox cache leaked into Production")
expect(production != ProPurchasePolicy.namespace(environment: "Production", owner: otherOwner, productID: "app.veea.pro", apiOrigin: "https://accounts.example.test"), "Owner caches collided")
expect(production != ProPurchasePolicy.namespace(environment: "Production", owner: owner, productID: "app.veea.other", apiOrigin: "https://accounts.example.test"), "Product caches collided")
expect(production == ProPurchasePolicy.namespace(environment: "Production", owner: owner, productID: "app.veea.pro", apiOrigin: "https://accounts.example.test"), "Offline cache namespace changed for the same verified installation")
expect(ProPurchasePolicy.namespace(environment: nil, owner: owner, productID: "app.veea.pro", apiOrigin: "https://accounts.example.test") == nil, "Unknown installation read a cache")
expect(ProPurchasePolicy.namespace(environment: "Xcode", owner: owner, productID: "app.veea.pro", apiOrigin: "https://accounts.example.test") == nil, "Xcode simulation read a release ownership cache")
expect(ProPurchasePolicy.namespace(environment: "Production", owner: nil, productID: "app.veea.pro", apiOrigin: "https://accounts.example.test") == nil, "Signed-out account read a cache")
expect(ProPurchasePolicy.namespace(environment: "Production", owner: owner, productID: "", apiOrigin: "https://accounts.example.test") == nil, "Unconfigured product read a cache")

expect(production != ProPurchasePolicy.namespace(environment: "Production", owner: owner, productID: "app.veea.pro", apiOrigin: "https://staging.example.test"), "Different account service reused a server lease")
expect(ProPurchasePolicy.namespace(environment: "Production", owner: owner, productID: "app.veea.pro", apiOrigin: "") == nil, "Unconfigured service reused a server lease")

// Existing unsuffixed leases had no trusted environment and cannot be migrated.
let defaults = UserDefaults(suiteName: "veea.purchase-policy.\(UUID().uuidString)")!
let legacyKey = "pro.server.lease.\(owner.uuidString.lowercased())"
defaults.set(Date().timeIntervalSince1970 + 86400, forKey: legacyKey)
defaults.set(Date().timeIntervalSince1970 + 86400, forKey: "pro.server.lease.\(sandbox)")
expect(defaults.double(forKey: "pro.server.lease.\(production)") == 0, "Legacy or Sandbox grant became Production Pro")
defaults.removeObject(forKey: legacyKey)
defaults.removeObject(forKey: "pro.server.lease.\(sandbox)")

// A Free reply can arrive before the asynchronous app-download environment.
// Neither possible disk lease may reappear when that lookup eventually resolves.
let sandboxLeaseKey = "pro.server.lease.\(sandbox)"
let productionLeaseKey = "pro.server.lease.\(production)"
let otherServiceNamespace = ProPurchasePolicy.namespace(environment: "Production", owner: owner, productID: "app.veea.pro", apiOrigin: "https://staging.example.test")!
let otherOwnerNamespace = ProPurchasePolicy.namespace(environment: "Production", owner: otherOwner, productID: "app.veea.pro", apiOrigin: "https://accounts.example.test")!
let otherProductNamespace = ProPurchasePolicy.namespace(environment: "Production", owner: owner, productID: "app.veea.other", apiOrigin: "https://accounts.example.test")!
let protectedKeys = ["pro.server.lease.\(otherServiceNamespace)", "pro.server.lease.\(otherOwnerNamespace)", "pro.server.lease.\(otherProductNamespace)", "pro.revoked.\(production)"]
for key in [sandboxLeaseKey, productionLeaseKey] + protectedKeys { defaults.set(12345, forKey: key) }
defaults.set(true, forKey: productionLeaseKey + ".lifetime")
defaults.set(false, forKey: sandboxLeaseKey + ".lifetime")
ProPurchasePolicy.clearServerLeases(in: defaults, owner: owner, productID: "app.veea.pro", apiOrigin: "https://accounts.example.test")
expect(defaults.object(forKey: sandboxLeaseKey) == nil && defaults.object(forKey: productionLeaseKey) == nil, "Free-before-app-environment-resolution resurrected a cached paid lease")
expect(defaults.object(forKey: sandboxLeaseKey + ".lifetime") == nil && defaults.object(forKey: productionLeaseKey + ".lifetime") == nil, "Free reply retained lifetime metadata")
for key in protectedKeys { expect(defaults.integer(forKey: key) == 12345, "Free reply touched a different owner, product, service or revocation list") }

// A cold-start signed refund also arrives before the environment lookup; only
// lifetime leases are removed, retaining an independent finite manual grant.
defaults.set(12345, forKey: productionLeaseKey)
defaults.set(true, forKey: productionLeaseKey + ".lifetime")
defaults.set(12345, forKey: sandboxLeaseKey)
defaults.set(false, forKey: sandboxLeaseKey + ".lifetime")
ProPurchasePolicy.clearServerLeases(in: defaults, owner: owner, productID: "app.veea.pro", apiOrigin: "https://accounts.example.test", lifetimeOnly: true)
expect(defaults.object(forKey: productionLeaseKey) == nil, "Cold-start refund retained a lifetime disk lease")
expect(defaults.integer(forKey: sandboxLeaseKey) == 12345, "Lifetime refund removed a finite manual disk grant")

// A definite shorter finite Pro reply supersedes an active old lifetime lease,
// even before the app environment is known. Uncertain nil metadata keeps its
// prior bounded lease instead of pretending that its plan has been resolved.
defaults.set(99999, forKey: productionLeaseKey)
defaults.set(true, forKey: productionLeaseKey + ".lifetime")
expect(ProPurchasePolicy.replacesServerLease(clearServer: false, until: 60, lifetime: false), "Definite finite plan did not replace a stale paid cache")
expect(!ProPurchasePolicy.replacesServerLease(clearServer: false, until: 60, lifetime: nil), "Uncertain plan destroyed an active same-source lease")
expect(!ProPurchasePolicy.replacesServerLease(clearServer: false, until: .infinity, lifetime: true), "Invalid plan replaced a valid lease")
ProPurchasePolicy.clearServerLeases(in: defaults, owner: owner, productID: "app.veea.pro", apiOrigin: "https://accounts.example.test")
var replacement = ProServerLease()
replacement.grant(until: 60, lifetime: false, now: 0)
expect(defaults.object(forKey: productionLeaseKey) == nil, "Late environment lookup recovered an obsolete active lifetime lease")
expect(!ProPurchasePolicy.hasLifetime(owned: false, memory: replacement, diskExpiresAt: defaults.double(forKey: productionLeaseKey), diskLifetime: defaults.bool(forKey: productionLeaseKey + ".lifetime"), now: 1), "Shorter finite replacement retained old lifetime metadata")
expect(!replacement.isActive(at: 60), "An older paid cache extended the shorter new grant")
for key in [sandboxLeaseKey, productionLeaseKey] + protectedKeys {
  defaults.removeObject(forKey: key)
  defaults.removeObject(forKey: key + ".lifetime")
}

// A fresh server-only Pro grant must work even when AppTransaction lookup fails
// offline. This in-memory proof is bounded and never copied to a shared cache.
var lease = ProServerLease()
let now: TimeInterval = 1_000_000
expect(!lease.isActive(at: now), "Fresh process inherited a volatile grant")
lease.grant(until: now + 7 * 86400, lifetime: true, now: now)
expect(lease.expiresAt == now + 86400, "Volatile grant exceeded the 24-hour maximum")
expect(lease.isActive(at: now + 86399), "Fresh authenticated server grant was lost before expiry")
expect(!lease.isActive(at: now + 86400), "Volatile grant survived its expiry boundary")
expect(lease.lifetime, "Lifetime metadata was lost")
expect(ProPurchasePolicy.allowsInstallation(nil), "Missing app-download lookup disabled a fresh online grant")
expect(!ProPurchasePolicy.allowsInstallation("Xcode"), "Known Xcode app used a release server grant")
expect(!ProPurchasePolicy.allowsInstallation("Unsupported"), "Unknown signed app environment used a server grant")

// The same clear is used on owner/product/API changes and a Free server reply.
lease.clear()
expect(!lease.isActive(at: now) && !lease.lifetime, "Account change or Free reply retained paid memory")
lease.grant(until: now + 60, lifetime: false, now: now)
expect(lease.isActive(at: now + 59) && !lease.lifetime, "Finite manual grant was treated as lifetime")
expect(!ProPurchasePolicy.hasLifetime(owned: false, memory: lease, diskExpiresAt: now - 1, diskLifetime: true, now: now), "Expired lifetime disk metadata overrode a fresh finite manual grant")
expect(ProPurchasePolicy.hasLifetime(owned: false, memory: lease, diskExpiresAt: now + 60, diskLifetime: true, now: now), "Active lifetime disk proof was ignored")
expect(!ProPurchasePolicy.hasLifetime(owned: false, memory: lease, diskExpiresAt: nil, diskLifetime: true, now: now), "Missing disk proof was treated as lifetime")
lease.clearLifetime()
expect(lease.isActive(at: now + 59), "Apple lifetime revocation removed an independent manual grant")
expect(!lease.isActive(at: now + 60), "Manual grant survived its own expiry")
lease.grant(until: now + 120, lifetime: true, now: now)
lease.clearLifetime()
expect(!lease.isActive(at: now), "Lifetime refund retained a volatile paid grant")
lease.grant(until: .infinity, lifetime: true, now: now)
expect(!lease.isActive(at: now) && !lease.lifetime, "Non-finite proof created an unbounded grant")
lease.grant(until: now + 10, lifetime: true, now: now)
lease.grant(until: now + 20, lifetime: nil, now: now + 5)
expect(lease.lifetime, "Uncertain refresh discarded an active same-source lifetime lease")
lease.grant(until: now + 60, lifetime: nil, now: now + 21)
expect(!lease.lifetime, "Unspecified metadata resurrected an expired lifetime proof")

print("Pro purchase environment matrix, cache isolation and volatile server lease checks passed")
