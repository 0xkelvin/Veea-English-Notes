import Foundation
import StoreKit
import Flutter

/// Apple-verified, account-bound entitlements. No notebook content enters StoreKit.
@available(iOS 16.0, *)
@MainActor
final class ProPurchaseManager {
  static let shared = ProPurchaseManager()
  private var owner: UUID?
  private var productID = ""
  private var product: Product?
  private var transactions: [String: Transaction] = [:]
  private var ownedTransactions: [String: Transaction] = [:]
  private var pendingTransactions: [String: Transaction] = [:]
  private var deniedKey: String? { owner.map { "pro.revoked.\($0.uuidString.lowercased()).\(productID)" } }
  private var deniedIDs: Set<String> { Set(deniedKey.flatMap { defaults.stringArray(forKey:$0) } ?? []) }
  private var listener: Task<Void, Never>?
  private var generation = 0
  private(set) var isReady = false
  private var outcome: String?
  var onChange: (() -> Void)?
  private let defaults = UserDefaults.standard
  private var lifetimeKey: String? { leaseKey.map { $0 + ".lifetime" } }
  private var leaseKey: String? { owner.map { "pro.server.lease.\($0.uuidString.lowercased())" } }
  var isPro: Bool {
    guard owner != nil else { return false }
    if !transactions.isEmpty { return true }
    return leaseKey.map { defaults.double(forKey: $0) > Date().timeIntervalSince1970 } ?? false
  }
  private var hasLifetime: Bool {
    !transactions.isEmpty || (isPro && lifetimeKey.map { defaults.bool(forKey:$0) } == true)
  }
  private func state() -> [String: Any] {
    ["hasPro": isPro, "hasLifetime":hasLifetime, "pendingTransactions":Array(pendingTransactions.keys), "price": product?.displayPrice as Any? ?? NSNull(),
     "transactions": Array(Set(ownedTransactions.keys).union(pendingTransactions.keys)).sorted(), "outcome": outcome as Any? ?? NSNull()]
  }
  func configure(_ args: [String: Any]) async throws -> [String: Any] {
    let nextOwner = (args["accountID"] as? String).flatMap(UUID.init(uuidString:))
    let nextProduct = args["productID"] as? String ?? ""
    if nextOwner != owner || nextProduct != productID {
      generation += 1
      isReady = false
      transactions = [:]
      ownedTransactions = [:]
      pendingTransactions = [:]
      outcome = nil
      product = nil
      owner = nextOwner
      productID = nextProduct
    }
    if let key = leaseKey {
      if args["clearServer"] as? Bool == true { defaults.removeObject(forKey: key); if let lifetimeKey { defaults.removeObject(forKey:lifetimeKey) } }
      if let until = args["serverUntil"] as? Double {
        if let lifetimeKey, let lifetime = args["serverLifetime"] as? Bool { defaults.set(lifetime,forKey:lifetimeKey) }
        defaults.set(min(until, Date().timeIntervalSince1970 + 86400), forKey: key)
      }
    }
    if listener == nil {
      listener = Task { [weak self] in
        for await result in Transaction.updates {
          guard let self else { return }
          // An update is deliberately left unfinished until Go durably records it.
          if case .verified(let tx) = result, tx.productID == self.productID {
            if tx.revocationDate != nil { self.rememberRevocation(tx) }
            if tx.appAccountToken == self.owner { self.pendingTransactions[String(tx.id)] = tx }
            await self.refreshEntitlements()
            self.onChange?()
          }
        }
      }
    }
    if outcome == "pending" || outcome == "cancelled" { outcome = nil }
    let epoch = generation
    for await verification in Transaction.unfinished {
      guard epoch == generation else { throw changedAccount() }
      if case .verified(let tx) = verification, tx.productID == productID {
        if tx.revocationDate != nil { rememberRevocation(tx) }
        if tx.appAccountToken == owner { pendingTransactions[String(tx.id)] = tx }
      }
    }
    await refreshEntitlements()
    guard epoch == generation else { throw changedAccount() }
    isReady = true
    if args["loadProduct"] as? Bool != false && !productID.isEmpty && product == nil {
      let products = (try? await Product.products(for: [productID])) ?? []
      guard epoch == generation else { throw changedAccount() }
      product = products.first { $0.id == productID && $0.type == .nonConsumable }
    }
    return state()
  }
  private func refreshEntitlements() async {
    let epoch = generation, expectedOwner = owner, expectedProduct = productID
    var found: [String: Transaction] = [:]
    var raw: [String: Transaction] = [:]
    var mismatch = false
    for await verification in Transaction.currentEntitlements {
      guard case .verified(let tx) = verification,
            tx.productID == expectedProduct, tx.productType == .nonConsumable,
            tx.revocationDate == nil, !tx.isUpgraded else { continue }
      guard tx.appAccountToken == expectedOwner, expectedOwner != nil else {
        mismatch = expectedOwner != nil; continue
      }
      raw[String(tx.id)] = tx
      if !deniedIDs.contains(String(tx.id)) { found[String(tx.id)] = tx }
    }
    guard epoch == generation else { return }
    for (id,tx) in pendingTransactions where tx.appAccountToken == expectedOwner && tx.productID == expectedProduct {
      if tx.revocationDate != nil || deniedIDs.contains(id) { found.removeValue(forKey:id) }
      else { found[id]=tx;raw[id]=tx }
    }
    transactions = found
    ownedTransactions = raw
    // Device-verified lifetime access needs no redundant server lifetime lease.
    // A local refund can then remove it immediately even while offline; manual
    // grants retain their separate bounded server lease.
    if !found.isEmpty, let key=leaseKey, let lifetimeKey, defaults.bool(forKey:lifetimeKey) {
      defaults.removeObject(forKey:key);defaults.removeObject(forKey:lifetimeKey)
    }
    if mismatch && found.isEmpty { outcome = "account_mismatch" }
    else if outcome == "account_mismatch" { outcome = nil }
  }
  func purchase() async throws -> [String: Any] {
    guard let owner, let product else {
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
    let epoch = generation
    outcome = nil
    try await AppStore.sync()
    guard epoch == generation else { throw changedAccount() }
    await refreshEntitlements()
    return state()
  }
  private func rememberRevocation(_ tx: Transaction) {
    guard let account=tx.appAccountToken else { return }
    let key="pro.revoked.\(account.uuidString.lowercased()).\(tx.productID)"
    var ids=Set(defaults.stringArray(forKey:key) ?? []);ids.insert(String(tx.id))
    defaults.set(Array(ids),forKey:key)
    if owner==account, ownedTransactions[String(tx.id)] != nil, let leaseKey, let lifetimeKey, defaults.bool(forKey:lifetimeKey) {
      defaults.removeObject(forKey:leaseKey);defaults.removeObject(forKey:lifetimeKey)
    }
  }
  func recordVerification(_ id: String, revoked: Bool) async {
    guard let key = deniedKey, let tx = ownedTransactions[id] ?? pendingTransactions[id], tx.appAccountToken == owner else { return }
    var ids = deniedIDs
    if revoked { ids.insert(id) } else { ids.remove(id) }
    defaults.set(Array(ids),forKey:key)
    await refreshEntitlements()
  }
  func finish(_ id: String) async {
    guard let tx = ownedTransactions[id] ?? pendingTransactions[id], tx.appAccountToken == owner else { return }
    await tx.finish()
    pendingTransactions.removeValue(forKey:id)
  }
  private func changedAccount() -> NSError {
    NSError(domain: "VeeaPro", code: 4, userInfo: [NSLocalizedDescriptionKey: "Your account changed. Open Pro again to continue."])
  }
}
