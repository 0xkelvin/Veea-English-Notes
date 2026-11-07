import UIKit
import SwiftUI
import FamilyControls
import ManagedSettings
import DeviceActivity

@available(iOS 16.0, *)
@MainActor
final class NativeScreenTimeManager {
  static let shared = NativeScreenTimeManager()
  private var presentedController: UIViewController?

  var isSupported: Bool {
    #if targetEnvironment(simulator)
    return false
    #else
    return true
    #endif
  }

  func status() -> [String: Any] {
    let approved = AuthorizationCenter.shared.authorizationStatus == .approved
    let store = try? NativeGateStore.shared()
    let loadedState = try? store?.read()
    let storageError = store != nil && loadedState == nil
    let state = loadedState ?? NativeGateState()
    let configured = storageError
      ? GateAccessState.shared.defaults.bool(forKey: "native_gate_enabled") : state.enabled
    let active = configured && approved && isSupported && store != nil
    GateAccessState.shared.defaults.set(active, forKey: "native_gate_enabled")
    return [
      "supported": isSupported,
      "available": isSupported && store != nil,
      "authorized": approved,
      "enabled": active,
      "configured": configured,
      "error": storageError ? "Protection settings could not be read. Turn protection off to reset them." : "",
      "passMinutes": state.passMinutes,
      "applications": state.applications.enumerated().map { index, app in
        ["id": "native:\(app.id)", "label": "Protected app \(index + 1)",
         "unlockedUntil": state.passes[app.id]?.expiresAt.timeIntervalSince1970 ?? 0] as [String: Any]
      }
    ]
  }

  func requestAuthorization() async throws {
    guard isSupported else { throw NativeGateError.unavailable }
    _ = try NativeGateStore.shared()
    try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
    guard AuthorizationCenter.shared.authorizationStatus == .approved else {
      throw NativeGateError.authorizationRequired
    }
  }

  func setEnabled(_ enabled: Bool, minutes: Int) throws {
    let store = try NativeGateStore.shared()
    if enabled {
      try requireAuthorization()
      guard NativeGatePolicy.supportedPassMinutes.contains(minutes) else {
        throw NativeGateError.invalidDuration
      }
      try store.update({ state in
        try NativeGatePolicy.validateApplicationCount(state.applications.count)
        guard !state.applications.isEmpty else { throw NativeGateError.unknownApplication }
        state.enabled = true
        state.passMinutes = minutes
        state.reconcile(at: Date())
      }, apply: { NativeGateShielding.apply($0) })
      // Retire settings created by the old, unnamed-store implementation.
      ManagedSettingsStore().clearAllSettings()
    } else {
      try store.disable(apply: { NativeGateShielding.apply($0) })
      NativeGateShielding.stopMonitors()
      ManagedSettingsStore().clearAllSettings()
    }
    GateAccessState.shared.defaults.set(enabled, forKey: "native_gate_enabled")
  }

  func setDuration(_ minutes: Int) throws {
    guard NativeGatePolicy.supportedPassMinutes.contains(minutes) else {
      throw NativeGateError.invalidDuration
    }
    // Already earned passes retain their original expiry.
    try NativeGateStore.shared().update { $0.passMinutes = minutes }
  }

  func grantPass(target: String) throws {
    try requireAuthorization()
    NativeGateShielding.stopExpiredMonitors()
    guard let id = NativeGatePolicy.applicationID(from: target) else {
      throw NativeGateError.unknownApplication
    }
    let store = try NativeGateStore.shared()
    let minutes = try store.read().passMinutes
    let center = DeviceActivityCenter()
    _ = try NativeGateGrantCoordinator(store: store).grant(
      applicationID: id, minutes: minutes,
      startMonitoring: { name, start, expiry in
        let calendar = Calendar.current
        let components: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute, .second]
        let schedule = DeviceActivitySchedule(
          intervalStart: calendar.dateComponents(components, from: start),
          intervalEnd: calendar.dateComponents(components, from: expiry), repeats: false
        )
        try center.startMonitoring(DeviceActivityName(name), during: schedule)
      },
      stopMonitoring: { center.stopMonitoring([DeviceActivityName($0)]) },
      apply: { NativeGateShielding.apply($0) }
    )
  }

  func revokePass(target: String) throws {
    guard let id = NativeGatePolicy.applicationID(from: target) else {
      throw NativeGateError.unknownApplication
    }
    let activity = try NativeGateStore.shared().update({ state -> String? in
      state.passes.removeValue(forKey: id)?.activityName
    }, apply: { NativeGateShielding.apply($0) })
    if let activity { DeviceActivityCenter().stopMonitoring([DeviceActivityName(activity)]) }
  }

  func consumePendingChallenge() -> String? {
    try? NativeGateStore.shared().update { $0.consumeChallenge(at: Date()) }
  }

  func reconcile() {
    guard AuthorizationCenter.shared.authorizationStatus == .approved else {
      GateAccessState.shared.defaults.set(false, forKey: "native_gate_enabled")
      return
    }
    try? NativeGateShielding.reconcile()
    // Clean up completed, nonrepeating monitors outside extension callbacks.
    NativeGateShielding.stopExpiredMonitors()
  }

  func chooseApplications(from root: UIViewController, completion: @escaping (Result<Bool, Error>) -> Void) throws {
    try requireAuthorization()
    let state = try NativeGateStore.shared().read()
    let selection = FamilyActivitySelection()
    var initial = selection
    initial.applicationTokens = Set(state.applications.compactMap(NativeGateShielding.token))
    let view = NativeGatePicker(initialSelection: initial, onSave: { [weak self] tokens in
      do {
        try self?.saveSelection(tokens)
        self?.dismissPresentation { completion(.success(true)) }
      } catch { self?.dismissPresentation { completion(.failure(error)) } }
    }, onCancel: { [weak self] in
      self?.dismissPresentation { completion(.success(false)) }
    })
    try present(UIHostingController(rootView: view), from: root)
  }

  func manageApplications(from root: UIViewController, completion: @escaping (String?) -> Void) throws {
    try requireAuthorization()
    let state = try NativeGateStore.shared().read()
    let view = NativeGateApplicationsView(state: state, onSelect: { [weak self] id in
      self?.dismissPresentation { completion("native:\(id)") }
    }, onClose: { [weak self] in self?.dismissPresentation { completion(nil) } })
    try present(UIHostingController(rootView: view), from: root)
  }

  private func requireAuthorization() throws {
    guard isSupported else { throw NativeGateError.unavailable }
    guard AuthorizationCenter.shared.authorizationStatus == .approved else {
      throw NativeGateError.authorizationRequired
    }
  }

  private func saveSelection(_ tokens: Set<ApplicationToken>) throws {
    try NativeGatePolicy.validateApplicationCount(tokens.count)
    let removedActivities = try NativeGateStore.shared().update({ state -> [String] in
      let old = state.applications
      state.applications = try tokens.map { token in
        if let existing = old.first(where: { NativeGateShielding.token(for: $0) == token }) { return existing }
        return NativeGateApplication(id: UUID().uuidString, token: try JSONEncoder().encode(token))
      }.sorted { $0.id < $1.id }
      let selected = Set(state.applications.map(\.id))
      let removed = state.passes.filter { !selected.contains($0.key) }.map { $0.value.activityName }
      state.reconcile(at: Date())
      if tokens.isEmpty { state.enabled = false; state.pendingChallenge = nil }
      return removed
    }, apply: { NativeGateShielding.apply($0) })
    if !removedActivities.isEmpty {
      DeviceActivityCenter().stopMonitoring(removedActivities.map { DeviceActivityName($0) })
    }
    _ = status()
  }

  private func present(_ controller: UIViewController, from root: UIViewController) throws {
    guard presentedController == nil, root.presentedViewController == nil else {
      throw NativeGateError.unavailable
    }
    controller.isModalInPresentation = true
    presentedController = controller
    root.present(controller, animated: true)
  }

  private func dismissPresentation(completion: @escaping () -> Void) {
    guard let controller = presentedController else { completion(); return }
    presentedController = nil
    controller.dismiss(animated: true, completion: completion)
  }
}

@available(iOS 16.0, *)
private struct NativeGatePicker: View {
  @State var selection: FamilyActivitySelection
  let onSave: (Set<ApplicationToken>) -> Void
  let onCancel: () -> Void

  init(initialSelection: FamilyActivitySelection, onSave: @escaping (Set<ApplicationToken>) -> Void,
       onCancel: @escaping () -> Void) {
    _selection = State(initialValue: initialSelection)
    self.onSave = onSave
    self.onCancel = onCancel
  }

  var hasCategoriesOrWebsites: Bool { !selection.categoryTokens.isEmpty || !selection.webDomainTokens.isEmpty }
  var tooManyApplications: Bool { selection.applicationTokens.count > NativeGatePolicy.maximumApplications }
  var invalidSelection: Bool { hasCategoriesOrWebsites || tooManyApplications }

  var body: some View {
    NavigationStack {
      VStack {
        Text(tooManyApplications ? "Choose up to 50 individual apps." : hasCategoriesOrWebsites ? "Choose individual apps, not entire categories or websites." : "Select the individual apps you want to protect.")
          .font(.callout).padding().foregroundStyle(invalidSelection ? Color.red : Color.secondary)
        FamilyActivityPicker(selection: $selection)
      }
      .navigationTitle("Protect your apps")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") { onSave(selection.applicationTokens) }.disabled(invalidSelection)
        }
      }
    }.interactiveDismissDisabled()
  }
}

@available(iOS 16.0, *)
private struct NativeGateApplicationsView: View {
  let state: NativeGateState
  let onSelect: (String) -> Void
  let onClose: () -> Void

  var body: some View {
    NavigationStack {
      List(state.applications) { app in
        if let token = NativeGateShielding.token(for: app) {
          VStack(alignment: .leading, spacing: 12) {
            Label(token).labelStyle(.titleAndIcon)
            if let pass = state.passes[app.id], pass.expiresAt > Date() {
              Text("Unlocked until \(pass.expiresAt.formatted(date: .omitted, time: .shortened))")
                .font(.callout).foregroundStyle(.secondary)
            } else {
              Button("Learn to unlock") { onSelect(app.id) }.disabled(!state.enabled)
            }
          }.padding(.vertical, 6)
        }
      }
      .navigationTitle("Protected apps")
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done", action: onClose) } }
    }.interactiveDismissDisabled()
  }
}
