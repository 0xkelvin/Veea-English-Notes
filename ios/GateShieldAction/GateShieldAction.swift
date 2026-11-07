import Foundation
import ManagedSettings
import FamilyControls
import OSLog

final class GateShieldAction: ShieldActionDelegate {
  override func handle(action: ShieldAction, for application: ApplicationToken,
                       completionHandler: @escaping (ShieldActionResponse) -> Void) {
    guard action == .primaryButtonPressed else { completionHandler(.close); return }
    guard #available(iOS 16.0, *) else { completionHandler(.close); return }
    do {
      let queued = try NativeGateStore.shared().update({ state -> Bool in
        state.reconcile(at: Date())
        guard let app = state.applications.first(where: { NativeGateShielding.token(for: $0) == application }),
              state.shieldedApplicationIDs(at: Date()).contains(app.id) else { return false }
        state.pendingChallenge = NativeGatePendingChallenge(applicationID: app.id, createdAt: Date())
        return true
      }, apply: { NativeGateShielding.apply($0) })
      guard queued else { completionHandler(.none); return }
      if #available(iOS 26.5, *) { completionHandler(.openParentalControlsApp) }
      else { completionHandler(.close) }
    } catch {
      Logger(subsystem: "com.nintran.veeaEnglishApp", category: "ScreenTime").error("Challenge handoff failed: \(error.localizedDescription, privacy: .public)")
      completionHandler(.close)
    }
  }

  override func handle(action: ShieldAction, for category: ActivityCategoryToken,
                       completionHandler: @escaping (ShieldActionResponse) -> Void) {
    completionHandler(.close)
  }

  override func handle(action: ShieldAction, for webDomain: WebDomainToken,
                       completionHandler: @escaping (ShieldActionResponse) -> Void) {
    completionHandler(.close)
  }
}
