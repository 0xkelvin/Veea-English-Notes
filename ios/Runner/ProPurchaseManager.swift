import Foundation
import StoreKit
import Flutter

/// Apple-verified, account-bound entitlements. No notebook content enters StoreKit.
@available(iOS 16.0, *)
@MainActor
final class ProPurchaseManager {
  static let shared = ProPurchaseManager()
  private var owner: UUID?
  // Set only from Apple's verified app transaction, never a Dart flag or filename.
  private var environment: String?
  private var environmentLookupStarted = false
  private var environmentTask: Task<Void, Never>?
  private var apiOrigin = ""
  private var volatileLease = ProServerLease()
  private var serverPlanKnown = false
  private var productID = ""
  private var product: Product?
  private var transactions: [String: Transaction] = [:]
  private var ownedTransactions: [String: Transaction] = [:]
  private var pendingTransactions: [String: Transaction] = [:]
  private var namespace: String? { ProPurchasePolicy.namespace(environment: environment, owner: owner, productID: productID, apiOrigin: apiOrigin) }
  private var listener: Task<Void, Never>?
  private var generation = 0
  private(set) var isReady = false
  private var outcome: String?
  var onChange: (() -> Void)?
  private let defaults = UserDefaults.standard
  private var lifetimeKey: String? { leaseKey.map { $0 + ".lifetime" } }
  private var leaseKey: String? { namespace.map { "pro.server.lease.\($0)" } }
  private var hasActiveServerLease: Bool {
    volatileLease.isActive(at: Date().timeIntervalSince1970) ||
      leaseKey.map { defaults.double(forKey: $0) > Date().timeIntervalSince1970 } == true
  }
  var isPro: Bool {
    guard owner != nil, ProPurchasePolicy.allowsInstallation(environment) else { return false }
    if !transactions.isEmpty { return true }
    return hasActiveServerLease
  }
  private var hasLifetime: Bool {
    guard isPro else { return false }
    return ProPurchasePolicy.hasLifetime(owned: !transactions.isEmpty, memory: volatileLease,
      diskExpiresAt: leaseKey.map { defaults.double(forKey: $0) },
      diskLifetime: lifetimeKey.map { defaults.bool(forKey: $0) } == true,
      now: Date().timeIntervalSince1970)
  }
  private func state() -> [String: Any] {
    ["hasPro": isPro, "hasLifetime":hasLifetime, "pendingTransactions":Array(pendingTransactions.keys), "price": product?.displayPrice as Any? ?? NSNull(),
     "transactions": Array(Set(ownedTransactions.keys).union(pendingTransactions.keys)).sorted(), "outcome": outcome as Any? ?? NSNull()]
  }
  func configure(_ args: [String: Any]) async throws -> [String: Any] {
    let nextOwner = (args["accountID"] as? String).flatMap(UUID.init(uuidString:))
    let nextProduct = args["productID"] as? String ?? ""
    let nextOrigin = args["apiOrigin"] as? String ?? ""
    if nextOwner != owner || nextProduct != productID || nextOrigin != apiOrigin {
      generation += 1
      isReady = false
      transactions = [:]
      ownedTransactions = [:]
      pendingTransactions = [:]
      volatileLease.clear()
      serverPlanKnown = false
      outcome = nil
      product = nil
      owner = nextOwner
      productID = nextProduct
      apiOrigin = nextOrigin
    }
    startEnvironmentLookupIfNeeded()
    if args["clearServer"] as? Bool == true {
      serverPlanKnown = true
      volatileLease.clear()
    }
    if ProPurchasePolicy.replacesServerLease(clearServer: args["clearServer"] as? Bool == true,
      until: args["serverUntil"] as? Double, lifetime: args["serverLifetime"] as? Bool) {
      ProPurchasePolicy.clearServerLeases(in: defaults, owner: owner, productID: productID, apiOrigin: apiOrigin)
    }
    if let until = args["serverUntil"] as? Double {
      volatileLease.grant(until: until, lifetime: args["serverLifetime"] as? Bool, now: Date().timeIntervalSince1970)
      if until.isFinite { serverPlanKnown = true }
    }
    if let key = leaseKey {
      if let until = args["serverUntil"] as? Double, until.isFinite {
        if let lifetimeKey {
          if let lifetime = args["serverLifetime"] as? Bool { defaults.set(lifetime,forKey:lifetimeKey) }
          else if defaults.double(forKey: key) <= Date().timeIntervalSince1970 { defaults.set(false, forKey: lifetimeKey) }
        }
        defaults.set(min(until, Date().timeIntervalSince1970 + 86400), forKey: key)
      }
    }
    if listener == nil {
      listener = Task { [weak self] in
        for await result in Transaction.updates {
          guard let self else { return }
          // An update remains unfinished until Go verifies and acknowledges it.
          if case .verified(let tx) = result, self.accepts(tx) {
            let epoch = self.generation
            if tx.appAccountToken == self.owner { self.pendingTransactions[String(tx.id)] = tx }
            if tx.revocationDate != nil { self.rememberRevocation(tx) }
            await self.refreshEntitlements()
            guard epoch == self.generation else { continue }
            self.onChange?()
          }
        }
      }
    }
    if outcome == "pending" || outcome == "cancelled" { outcome = nil }
    let epoch = generation
    for await verification in Transaction.unfinished {
      guard epoch == generation else { throw changedAccount() }
      if case .verified(let tx) = verification, accepts(tx) {
        if tx.appAccountToken == owner { pendingTransactions[String(tx.id)] = tx }
        if tx.revocationDate != nil { rememberRevocation(tx) }
      }
    }
    await refreshEntitlements()
    guard epoch == generation else { throw changedAccount() }
    updatePlanReadiness()
    if ProPurchasePolicy.allowsInstallation(environment) && !NativeGateReleasePolicy.isFreeLaunch && args["loadProduct"] as? Bool != false && !productID.isEmpty && product == nil {
      let products = (try? await Product.products(for: [productID])) ?? []
      guard epoch == generation else { throw changedAccount() }
      product = ProPurchasePolicy.allowsInstallation(environment) ? products.first { $0.id == productID && $0.type == .nonConsumable } : nil
    }
    return state()
  }
  private func refreshEntitlements() async {
    let epoch = generation, expectedOwner = owner, expectedProduct = productID, expectedEnvironment = environment
    var found: [String: Transaction] = [:]
    var raw: [String: Transaction] = [:]
    var mismatch = false
    for await verification in Transaction.currentEntitlements {
      guard case .verified(let tx) = verification,
            ProPurchasePolicy.accepts(installation: expectedEnvironment, transaction: environmentName(tx.environment)),
            tx.productID == expectedProduct, tx.productType == .nonConsumable,
            tx.revocationDate == nil, !tx.isUpgraded else { continue }
      guard tx.appAccountToken == expectedOwner, expectedOwner != nil else {
        mismatch = expectedOwner != nil; continue
      }
      raw[String(tx.id)] = tx
      if !deniedIDs(for: tx).contains(String(tx.id)) { found[String(tx.id)] = tx }
    }
    guard epoch == generation else { return }
    guard ProPurchasePolicy.canCommitOwnershipScan(startedIn: expectedEnvironment, currentInstallation: environment) else {
      transactions = [:]
      ownedTransactions = [:]
      updatePlanReadiness()
      return
    }
    for (id,tx) in pendingTransactions where tx.appAccountToken == expectedOwner && accepts(tx) {
      if tx.revocationDate != nil || deniedIDs(for: tx).contains(id) { found.removeValue(forKey:id) }
      else { found[id]=tx;raw[id]=tx }
    }
    transactions = found
    ownedTransactions = raw
    // Device-verified lifetime access needs no redundant server lifetime lease.
    // A local refund can then remove it immediately even while offline; manual
    // grants retain their separate bounded server lease.
    if !found.isEmpty { clearLifetimeLease() }
    if mismatch && found.isEmpty { outcome = "account_mismatch" }
    else if outcome == "account_mismatch" { outcome = nil }
    updatePlanReadiness()
  }
  func purchase() async throws -> [String: Any] {
    guard !NativeGateReleasePolicy.isFreeLaunch else {
      throw NSError(domain: "VeeaPro", code: 5, userInfo: [NSLocalizedDescriptionKey: "This release is free. No purchase is needed."])
    }
    guard ProPurchasePolicy.allowsInstallation(environment), let owner, let product else {
      throw NSError(domain: "VeeaPro", code: 1, userInfo: [NSLocalizedDescriptionKey: "Sign in and connect to the App Store before purchasing."])
    }
    let epoch = generation
    outcome = nil
    switch try await product.purchase(options: [.appAccountToken(owner)]) {
    case .success(let verification):
      guard case .verified(let tx) = verification else {
        throw NSError(domain: "VeeaPro", code: 2, userInfo: [NSLocalizedDescriptionKey: "Apple could not verify the purchase. Please try restoring purchases."])
      }
      guard epoch == generation else { throw changedAccount() }
      guard accepts(tx) else { throw incompatibleEnvironment() }
      guard tx.appAccountToken == owner else { outcome = "account_mismatch"; return state() }
      pendingTransactions[String(tx.id)] = tx
      await refreshEntitlements()
    case .pending: outcome = "pending"
    case .userCancelled: outcome = "cancelled"
    @unknown default: throw NSError(domain: "VeeaPro", code: 3, userInfo: [NSLocalizedDescriptionKey: "Apple returned an unknown payment result. Try restoring purchases."])
    }
    guard epoch == generation else { throw changedAccount() }
    return state()
  }
  func restore() async throws -> [String: Any] {
    guard owner != nil else { throw changedAccount() }
    guard ProPurchasePolicy.allowsInstallation(environment) else { throw incompatibleEnvironment() }
    let epoch = generation
    outcome = nil
    try await AppStore.sync()
    guard epoch == generation else { throw changedAccount() }
    await refreshEntitlements()
    guard epoch == generation else { throw changedAccount() }
    return state()
  }
  private func rememberRevocation(_ tx: Transaction) {
    guard accepts(tx), let key = deniedKey(for: tx) else { return }
    let account = tx.appAccountToken
    var ids=Set(defaults.stringArray(forKey:key) ?? []);ids.insert(String(tx.id))
    defaults.set(Array(ids),forKey:key)
    if owner==account {
      clearLifetimeLease()
    }
  }
  func recordVerification(_ id: String, revoked: Bool) async {
    guard let tx = ownedTransactions[id] ?? pendingTransactions[id], tx.appAccountToken == owner, accepts(tx), let key = deniedKey(for: tx) else { return }
    var ids = deniedIDs(for: tx)
    if revoked { ids.insert(id) } else { ids.remove(id) }
    defaults.set(Array(ids),forKey:key)
    if revoked { clearLifetimeLease() }
    await refreshEntitlements()
  }
  func finish(_ id: String) async {
    guard let tx = ownedTransactions[id] ?? pendingTransactions[id], tx.appAccountToken == owner, accepts(tx) else { return }
    let epoch = generation
    await tx.finish()
    guard epoch == generation else { return }
    pendingTransactions.removeValue(forKey:id)
  }
  private func accepts(_ tx: Transaction) -> Bool {
    tx.productID == productID && tx.productType == .nonConsumable && !tx.isUpgraded &&
      ProPurchasePolicy.accepts(installation: environment, transaction: environmentName(tx.environment))
  }
  private func clearLifetimeLease() {
    volatileLease.clearLifetime()
    ProPurchasePolicy.clearServerLeases(in: defaults, owner: owner, productID: productID, apiOrigin: apiOrigin, lifetimeOnly: true)
  }
  private func updatePlanReadiness() {
    // An unavailable account check is unknown, not a confirmed Free downgrade.
    // StoreKit checkout availability remains separate from lock reconciliation.
    isReady = ProPurchasePolicy.planReady(owner: owner, installation: environment, hasOwnership: !transactions.isEmpty, hasLease: hasActiveServerLease, serverPlanKnown: serverPlanKnown)
  }
  private func startEnvironmentLookupIfNeeded() {
    guard !environmentLookupStarted, owner != nil, !productID.isEmpty else { return }
    environmentLookupStarted = true
    // shared may use the network. Resolve once in the background, never hold up
    // offline ownership, free startup or checkout, and never call refresh().
    environmentTask = Task { [weak self] in
      let resolved = try? await AppTransaction.shared
      guard let self, case .verified(let app) = resolved,
            app.bundleID == Bundle.main.bundleIdentifier else { return }
      self.environment = self.environmentName(app.environment)
      self.updatePlanReadiness()
      let epoch = self.generation
      await self.refreshEntitlements()
      guard epoch == self.generation else { return }
      // The provider can now refresh a safely namespaced server lease. This is
      // an app-download fact, so it must not cancel an in-flight Apple purchase.
      self.onChange?()
    }
  }
  private func deniedKey(for tx: Transaction) -> String? {
    ProPurchasePolicy.namespace(environment: environmentName(tx.environment), owner: tx.appAccountToken, productID: tx.productID, apiOrigin: apiOrigin).map { "pro.revoked.\($0)" }
  }
  private func deniedIDs(for tx: Transaction) -> Set<String> {
    Set(deniedKey(for: tx).flatMap { defaults.stringArray(forKey: $0) } ?? [])
  }
  private func environmentName(_ value: AppStore.Environment) -> String {
    if value == .production { return "Production" }
    if value == .sandbox { return "Sandbox" }
    if value == .xcode { return "Xcode" }
    return "Unsupported"
  }
  private func incompatibleEnvironment() -> NSError {
    NSError(domain: "VeeaPro", code: 6, userInfo: [NSLocalizedDescriptionKey: "The App Store could not verify this installation. Please try again or restore purchases."])
  }
  private func changedAccount() -> NSError {
    NSError(domain: "VeeaPro", code: 4, userInfo: [NSLocalizedDescriptionKey: "Your account changed. Open Pro again to continue."])
  }
}
