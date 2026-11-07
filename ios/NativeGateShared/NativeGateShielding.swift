import Foundation
import FamilyControls
import ManagedSettings
import DeviceActivity

@available(iOS 16.0, *)
enum NativeGateShielding {
  static let storeName = ManagedSettingsStore.Name("veea-native-gate")

  static func token(for application: NativeGateApplication) -> ApplicationToken? {
    try? JSONDecoder().decode(ApplicationToken.self, from: application.token)
  }

  static func apply(_ state: NativeGateState, now: Date = Date()) {
    let ids = state.shieldedApplicationIDs(at: now)
    let tokens = Set(state.applications.filter { ids.contains($0.id) }.compactMap(token))
    let settings = ManagedSettingsStore(named: storeName)
    settings.shield.applications = tokens.isEmpty ? nil : tokens
    // Categories would prevent individual apps from being unlocked separately.
    settings.shield.applicationCategories = nil
    settings.shield.webDomains = nil
    settings.shield.webDomainCategories = nil
  }

  static func reconcile() throws {
    try NativeGateStore.shared().update({ $0.reconcile(at: Date()) }, apply: { apply($0) })
  }

  static func stopMonitors() {
    let center = DeviceActivityCenter()
    let activities = center.activities.filter { $0.rawValue.hasPrefix("veea.native.") }
    // An empty argument means stop all activities, including unrelated features.
    if !activities.isEmpty { center.stopMonitoring(activities) }
  }

  static func stopExpiredMonitors(now: Date = Date()) {
    let center = DeviceActivityCenter()
    let expired = center.activities.filter { activity in
      guard activity.rawValue.hasPrefix("veea.native.") else { return false }
      return (center.schedule(for: activity)?.nextInterval?.end ?? .distantPast) <= now
    }
    if !expired.isEmpty { center.stopMonitoring(expired) }
  }
}
