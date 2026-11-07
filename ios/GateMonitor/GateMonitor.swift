import Foundation
import DeviceActivity
import OSLog

final class GateMonitor: DeviceActivityMonitor {
  private func reconcile() {
    if #available(iOS 16.0, *) {
      do { try NativeGateShielding.reconcile() }
      catch { Logger(subsystem: "com.veea.veeaRewind", category: "ScreenTime").error("Relock failed: \(error.localizedDescription, privacy: .public)") }
    }
  }

  override func intervalDidStart(for activity: DeviceActivityName) {
    super.intervalDidStart(for: activity)
    reconcile()
  }

  override func intervalDidEnd(for activity: DeviceActivityName) {
    super.intervalDidEnd(for: activity)
    // Recompute from current expiry. An old callback cannot revoke a newer pass.
    reconcile()
  }
}
