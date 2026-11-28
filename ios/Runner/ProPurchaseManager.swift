import Foundation
import StoreKit

/// StoreKit owns local access. Matching account proofs are claimed separately.
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
  private var productID = ""
  private var product: Product?
  private var transactions: [String: Transaction] = [:]
  private var ownedTransactions: [String: Transaction] = [:]
  private var pendingTransactions: [String: Transaction] = [:]
  private var namespace: String? { ProPurchasePolicy.namespace(environment: environment, owner: owner, productID: productID, apiOrigin: apiOrigin) }
  private var listener: Task<Void, Never>?
  private var generation = 0
  private var outcome: String?
  var onChange: (() -> Void)?
  private let defaults = UserDefaults.standard
  private var lifetimeKey: String? { leaseKey.map { $0 + ".lifetime" } }
  private var leaseKey: String? { namespace.map { "pro.server.lease.\($0)" } }
  private var hasActiveServerLease: Bool {
    volatileLease.isActive(at: Date().timeIntervalSince1970) ||
      leaseKey.map { defaults.double(forKey: $0) > Date().timeIntervalSince1970 } == true
  }
  private var serverLifetime: Bool {
    hasActiveServerLease && ProPurchasePolicy.hasLifetime(owned: false, memory: volatileLease,
      diskExpiresAt: leaseKey.map { defaults.double(forKey: $0) },
      diskLifetime: lifetimeKey.map { defaults.bool(forKey: $0) } == true,
      now: Date().timeIntervalSince1970)
  }
  private func state() -> [String: Any] {
    let local = transactions.values.contains { accepts($0) && $0.environment == .production }
    let sandbox = transactions.values.contains { accepts($0) && $0.environment == .sandbox }
    let account = owner != nil && ProPurchasePolicy.allowsInstallation(environment) && hasActiveServerLease
    let lifetime = account && serverLifetime
    let localFinishes = pendingTransactions.values.filter {
      accepts($0) && !ProPurchasePolicy.canClaim(owner: owner, token: $0.appAccountToken) &&
        ($0.revocationDate != nil || transactions[String($0.id)] != nil)
    }.map { String($0.id) }.sorted()
    let pendingClaims = pendingTransactions.values.filter {
      accepts($0) && ProPurchasePolicy.canClaim(owner: owner, token: $0.appAccountToken)
    }.map { String($0.id) }.sorted()
    return ["hasPro": local || sandbox || account, "hasLifetime": local || sandbox || lifetime,
      "localApple": local, "localSandbox": sandbox, "serverApple": lifetime, "manualPremium": account && !lifetime,
      "localFinishTransactions": localFinishes, "pendingTransactions": pendingClaims,
      "price": product?.displayPrice as Any? ?? NSNull(),
      "transactions": Array(Set(ownedTransactions.values.filter(accepts).map { String($0.id) }).union(pendingClaims)).sorted(),
      "outcome": outcome as Any? ?? NSNull()]
  }
  func configure(_ args: [String: Any]) async throws -> [String: Any] {
    let nextOwner = (args["accountID"] as? String).flatMap(UUID.init(uuidString:))
    let requestedProduct = args["productID"] as? String
    let nextProduct = requestedProduct == ProPurchasePolicy.productID ? ProPurchasePolicy.productID : ""
    let nextOrigin = args["apiOrigin"] as? String ?? ""
    if nextOwner != owner || nextProduct != productID || nextOrigin != apiOrigin {
      if nextOwner != owner {
        ProPurchasePolicy.clearServerLeases(in: defaults, owner: owner, productID: productID, apiOrigin: apiOrigin)
      }
      generation += 1
      transactions = [:]
      ownedTransactions = [:]
      pendingTransactions = [:]
      volatileLease.clear()
      outcome = nil
      product = nil
      owner = nextOwner
      productID = nextProduct
      apiOrigin = nextOrigin
    }
    startEnvironmentLookupIfNeeded()
    if args["clearServer"] as? Bool == true {
      volatileLease.clear()
    }
    if ProPurchasePolicy.replacesServerLease(clearServer: args["clearServer"] as? Bool == true,
      until: args["serverUntil"] as? Double, lifetime: args["serverLifetime"] as? Bool) {
      ProPurchasePolicy.clearServerLeases(in: defaults, owner: owner, productID: productID, apiOrigin: apiOrigin)
    }
    if let until = args["serverUntil"] as? Double {
      volatileLease.grant(until: until, lifetime: args["serverLifetime"] as? Bool, now: Date().timeIntervalSince1970)
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
          if case .verified(let tx) = result, self.accepts(tx) {
            let epoch = self.generation
            self.receive(tx)
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
      guard epoch == generation else { throw ProPurchaseError.accountChanged }
      if case .verified(let tx) = verification, accepts(tx) {
        receive(tx)
      }
    }
    await refreshEntitlements()
    guard epoch == generation else { throw ProPurchaseError.accountChanged }
    if ProPurchasePolicy.allowsInstallation(environment) && args["loadProduct"] as? Bool != false && !productID.isEmpty && product == nil {
      let products = (try? await Product.products(for: [productID])) ?? []
      guard epoch == generation else { throw ProPurchaseError.accountChanged }
      product = ProPurchasePolicy.allowsInstallation(environment) ? products.first { $0.id == productID && $0.type == .nonConsumable } : nil
    }
    return state()
  }
  private func receive(_ tx: Transaction) {
    let id = String(tx.id)
    if let current = pendingTransactions[id], current.signedDate > tx.signedDate { return }
    pendingTransactions[id] = tx
    if tx.revocationDate != nil {
      rememberRevocation(tx, at: tx.signedDate)
      if tx.environment == .production && ProPurchasePolicy.canClaim(owner: owner, token: tx.appAccountToken) { clearLifetimeLease() }
    }
  }

  private func refreshEntitlements() async {
    let epoch = generation, expectedEnvironment = environment
    var current: [String: Transaction] = [:]
    for await verification in Transaction.currentEntitlements {
      guard epoch == generation else { return }
      if case .verified(let tx) = verification, accepts(tx), tx.revocationDate == nil {
        current[String(tx.id)] = tx
      }
    }
    guard epoch == generation else { return }
    guard ProPurchasePolicy.canCommitOwnershipScan(startedIn: expectedEnvironment, currentInstallation: environment) else {
      transactions = [:]
      ownedTransactions = [:]
      return
    }
    for (id, tx) in pendingTransactions where accepts(tx) {
      if let existing = current[id], existing.signedDate > tx.signedDate { continue }
      current[id] = tx
    }
    ownedTransactions = current.filter { ProPurchasePolicy.canClaim(owner: owner, token: $0.value.appAccountToken) }
    transactions = current.filter { _, tx in
      ProPurchasePolicy.isActive(revoked: tx.revocationDate != nil, signedAt: tx.signedDate, deniedAt: deniedAt(for: tx))
    }
    if transactions.isEmpty, current.values.contains(where: { $0.revocationDate != nil }) {
      outcome = "revoked"
    } else if !transactions.isEmpty && outcome == "revoked" {
      outcome = nil
    }
    // A matching Production purchase needs no duplicate account lease. A
    // Sandbox or differently bound proof must not erase an independent lease.
    if transactions.values.contains(where: {
      $0.environment == .production && ProPurchasePolicy.canClaim(owner: owner, token: $0.appAccountToken)
    }) { clearLifetimeLease() }
  }
  func purchase() async throws -> [String: Any] {
    guard ProPurchasePolicy.allowsInstallation(environment), let product else {
      throw ProPurchaseError.storeUnavailable
    }
    let epoch = generation
    let options: Set<Product.PurchaseOption> = owner.map { [.appAccountToken($0)] } ?? []
    outcome = nil
    switch try await product.purchase(options: options) {
    case .success(let verification):
      guard case .verified(let tx) = verification else {
        throw ProPurchaseError.unverifiedPurchase
      }
      guard epoch == generation else { throw ProPurchaseError.accountChanged }
      guard accepts(tx) else { throw ProPurchaseError.incompatibleInstallation }
      receive(tx)
      await refreshEntitlements()
    case .pending: outcome = "pending"
    case .userCancelled: outcome = "cancelled"
    @unknown default: throw ProPurchaseError.unknownPaymentResult
    }
    guard epoch == generation else { throw ProPurchaseError.accountChanged }
    return state()
  }
  func restore() async throws -> [String: Any] {
    guard ProPurchasePolicy.allowsInstallation(environment) else { throw ProPurchaseError.incompatibleInstallation }
    let epoch = generation
    outcome = nil
    try await AppStore.sync()
    guard epoch == generation else { throw ProPurchaseError.accountChanged }
    await refreshEntitlements()
    guard epoch == generation else { throw ProPurchaseError.accountChanged }
    if transactions.isEmpty, !productID.isEmpty,
       case .verified(let tx)? = await Transaction.latest(for: productID),
       epoch == generation, accepts(tx), tx.revocationDate != nil {
      receive(tx)
      await refreshEntitlements()
    }
    guard epoch == generation else { throw ProPurchaseError.accountChanged }
    return state()
  }
  private func rememberRevocation(_ tx: Transaction, at date: Date) {
    let key = revokedKey(for: tx)
    var dates = defaults.dictionary(forKey: key) as? [String: Double] ?? [:]
    let id = String(tx.id)
    dates[id] = max(dates[id] ?? 0, date.timeIntervalSince1970)
    defaults.set(dates, forKey: key)
  }
  func recordVerification(_ id: String, revoked: Bool, recorded: Bool) async {
    guard let tx = ownedTransactions[id] ?? pendingTransactions[id],
          ProPurchasePolicy.canClaim(owner: owner, token: tx.appAccountToken), accepts(tx) else { return }
    if revoked {
      rememberRevocation(tx, at: tx.signedDate)
      if recorded { clearLifetimeLease() }
    }
    // Only a newer verified StoreKit proof can supersede a device revocation.
    await refreshEntitlements()
  }
  func finish(_ id: String, locally: Bool = false) async {
    guard let tx = pendingTransactions[id] ?? ownedTransactions[id], accepts(tx) else { return }
    let canClaim = ProPurchasePolicy.canClaim(owner: owner, token: tx.appAccountToken)
    if locally {
      guard !canClaim, pendingTransactions[id] != nil,
            tx.revocationDate != nil || transactions[id] != nil else { return }
    } else {
      guard canClaim else { return }
    }
    let epoch = generation
    await tx.finish()
    guard epoch == generation, pendingTransactions[id]?.signedDate == tx.signedDate else { return }
    pendingTransactions.removeValue(forKey: id)
  }
  private func accepts(_ tx: Transaction) -> Bool {
    ProPurchasePolicy.acceptsProduct(verified: true, productID: tx.productID,
      configuredProductID: productID, nonConsumable: tx.productType == .nonConsumable,
      purchased: tx.ownershipType == .purchased, upgraded: tx.isUpgraded,
      installation: environment, transaction: environmentName(tx.environment))
  }
  private func clearLifetimeLease() {
    volatileLease.clearLifetime()
    ProPurchasePolicy.clearServerLeases(in: defaults, owner: owner, productID: productID, apiOrigin: apiOrigin, lifetimeOnly: true)
  }
  private func startEnvironmentLookupIfNeeded() {
    guard !environmentLookupStarted, !productID.isEmpty else { return }
    environmentLookupStarted = true
    // shared may use the network. Resolve once in the background, never hold up
    // offline ownership, free startup or checkout, and never call refresh().
    environmentTask = Task { [weak self] in
      let resolved = try? await AppTransaction.shared
      guard let self, case .verified(let app) = resolved,
            app.bundleID == Bundle.main.bundleIdentifier else { return }
      self.environment = self.environmentName(app.environment)
      let epoch = self.generation
      await self.refreshEntitlements()
      guard epoch == self.generation else { return }
      // The provider can now refresh a safely namespaced server lease. This is
      // an app-download fact, so it must not cancel an in-flight Apple purchase.
      self.onChange?()
    }
  }
  private func revokedKey(for tx: Transaction) -> String {
    "pro.revoked.v3.\(environmentName(tx.environment)).\(tx.productID)"
  }
  private func deniedAt(for tx: Transaction) -> Date? {
    let id = String(tx.id)
    let dates = defaults.dictionary(forKey: revokedKey(for: tx)) as? [String: Double]
    if let date = dates?[id] { return Date(timeIntervalSince1970: date) }
    guard let legacy = ProPurchasePolicy.namespace(environment: environmentName(tx.environment),
      owner: tx.appAccountToken, productID: tx.productID, apiOrigin: apiOrigin),
      defaults.stringArray(forKey: "pro.revoked.\(legacy)")?.contains(id) == true else { return nil }
    rememberRevocation(tx, at: tx.signedDate)
    return tx.signedDate
  }
  private func environmentName(_ value: AppStore.Environment) -> String {
    if value == .production { return "Production" }
    if value == .sandbox { return "Sandbox" }
    if value == .xcode { return "Xcode" }
    return "Unsupported"
  }
}

enum ProPurchaseError: String, Error {
  case storeUnavailable = "STORE_UNAVAILABLE"
  case unverifiedPurchase = "UNVERIFIED_PURCHASE"
  case unknownPaymentResult = "UNKNOWN_PAYMENT_RESULT"
  case accountChanged = "ACCOUNT_CHANGED"
  case incompatibleInstallation = "INCOMPATIBLE_INSTALLATION"
}
