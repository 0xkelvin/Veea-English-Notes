import Flutter
import SwiftUI
import UIKit
import Vision
#if canImport(FamilyControls) && canImport(ManagedSettings) && canImport(DeviceActivity)
import FamilyControls
import ManagedSettings
import DeviceActivity
#endif

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var appGateChannel: FlutterMethodChannel?
  private static let appGroupSuite = "group.app.veea.english"
  private var relockTimer: Timer?

  /// Known iOS app URL schemes used to scan which apps are installed on the
  /// user's iPhone and to launch the target app after unlocking the gate.
  private static let knownAppSchemes: [(name: String, schemes: [String])] = [
    ("Instagram", ["instagram://"]),
    ("X", ["twitter://"]),
    ("YouTube", ["youtube://"]),
    ("TikTok", ["snssdk1233://", "snssdk1180://", "tiktok://", "musically://"]),
    ("Threads", ["barcelona://"]),
    ("Reddit", ["reddit://"]),
    ("Facebook", ["fb://"]),
    ("Messenger", ["fb-messenger://"]),
    ("WhatsApp", ["whatsapp://"]),
    ("Telegram", ["tg://"]),
    ("Discord", ["discord://"]),
    ("Snapchat", ["snapchat://"]),
    ("Netflix", ["nflx://"]),
    ("Twitch", ["twitch://"]),
    ("Spotify", ["spotify://"]),
    ("Pinterest", ["pinterest://"]),
    ("LinkedIn", ["linkedin://"]),
    ("Zalo", ["zalo://"]),
    ("Shopee", ["shopeevn://"]),
    ("Lazada", ["lazada://"]),
    ("Grab", ["grab://"]),
    ("Chrome", ["googlechrome://"]),
    ("Gmail", ["googlegmail://"]),
    ("Google Maps", ["comgooglemaps://"]),
    ("Duolingo", ["duolingo://"]),
    ("Notion", ["notion://"]),
    ("Slack", ["slack://"]),
    ("ChatGPT", ["chatgpt://"]),
    ("CapCut", ["capcut://"])
  ]

  private var ocrChannelRegistered = false

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    if let controller = window?.rootViewController as? FlutterViewController {
      registerOcrChannel(messenger: controller.binaryMessenger)
      registerAppGateChannel(messenger: controller.binaryMessenger)
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func applicationDidBecomeActive(_ application: UIApplication) {
    super.applicationDidBecomeActive(application)
    checkPendingGateTargetFromAppGroup()
  }

  override func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    if handleIncomingUrl(url) {
      return true
    }
    return super.application(app, open: url, options: options)
  }

  func handleIncomingUrl(_ url: URL) -> Bool {
    if url.scheme == "veea" && url.host == "gate" {
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
      let targetApp = components?.queryItems?.first(where: { $0.name == "app" })?.value
        ?? sharedDefaults()?.string(forKey: "pending_gate_target_app")
        ?? "Instagram"
      sharedDefaults()?.removeObject(forKey: "pending_gate_target_app")

      // If the user already has an active pass for this app, open it directly.
      let unlockKey = "unlocked_until_\(targetApp.lowercased())"
      let unlockedUntil = sharedDefaults()?.double(forKey: unlockKey) ?? 0
      if unlockedUntil > Date().timeIntervalSince1970 {
        _ = launchTargetApp(named: targetApp)
        return true
      }

      appGateChannel?.invokeMethod("onGateTriggered", arguments: ["targetApp": targetApp])
      return true
    }
    return false
  }

  private func sharedDefaults() -> UserDefaults? {
    return UserDefaults(suiteName: Self.appGroupSuite) ?? UserDefaults.standard
  }

  func checkPendingGateTargetFromAppGroup() {
    guard let defaults = sharedDefaults(),
          let pendingTarget = defaults.string(forKey: "pending_gate_target_app"),
          !pendingTarget.isEmpty else {
      return
    }
    defaults.removeObject(forKey: "pending_gate_target_app")
    appGateChannel?.invokeMethod("onGateTriggered", arguments: ["targetApp": pendingTarget])
  }

  /// Scans the device for installed apps using `UIApplication.shared.canOpenURL`.
  private func scanInstalledAppsOnDevice() -> [String] {
    var installed: [String] = []
    for entry in Self.knownAppSchemes {
      let isInstalled = entry.schemes.contains { scheme in
        guard let url = URL(string: scheme) else { return false }
        return UIApplication.shared.canOpenURL(url)
      }
      if isInstalled {
        installed.append(entry.name)
      }
    }
    return installed
  }

  /// Opens the target app via its registered URL scheme if installed.
  private func launchTargetApp(named appName: String) -> Bool {
    let normalized = appName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    for entry in Self.knownAppSchemes where entry.name.lowercased() == normalized {
      for scheme in entry.schemes {
        if let url = URL(string: scheme), UIApplication.shared.canOpenURL(url) {
          UIApplication.shared.open(url, options: [:], completionHandler: nil)
          return true
        }
      }
    }
    if normalized.contains("://"), let url = URL(string: normalized), UIApplication.shared.canOpenURL(url) {
      UIApplication.shared.open(url, options: [:], completionHandler: nil)
      return true
    }
    return false
  }

  private func registerAppGateChannel(messenger: FlutterBinaryMessenger) {
    guard self.appGateChannel == nil else { return }
    let channel = FlutterMethodChannel(
      name: "app.veea.english/app_gate",
      binaryMessenger: messenger
    )
    self.appGateChannel = channel

    channel.setMethodCallHandler { [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) in
      guard let self = self else {
        result(nil)
        return
      }

      switch call.method {
      case "requestPermissions":
        self.handleRequestGatePermissions(result: result)

      case "getInstalledApps":
        DispatchQueue.main.async {
          let installed = self.scanInstalledAppsOnDevice()
          result(installed)
        }

      case "pickAppsToGate":
        self.handlePickAppsToGate(result: result)

      case "setGateEnabled":
        let args = call.arguments as? [String: Any] ?? [:]
        let enabled = args["enabled"] as? Bool ?? false
        let passMinutes = args["passMinutes"] as? Int ?? 15
        let gatedApps = args["gatedApps"] as? [String] ?? []
        let defaults = self.sharedDefaults()
        defaults?.set(enabled, forKey: "gate_enabled")
        defaults?.set(passMinutes, forKey: "pass_minutes")
        if !gatedApps.isEmpty {
          defaults?.set(gatedApps, forKey: "gated_apps")
        }
        self.applyManagedSettingsShield(enabled: enabled)
        result(nil)

      case "grantPass":
        let args = call.arguments as? [String: Any] ?? [:]
        let targetApp = args["targetApp"] as? String ?? ""
        let durationMinutes = args["durationMinutes"] as? Int ?? 15
        let effectiveMinutes = max(durationMinutes, 1)
        let unlockUntil = Date().timeIntervalSince1970 + Double(effectiveMinutes * 60)
        self.sharedDefaults()?.set(unlockUntil, forKey: "unlocked_until_\(targetApp.lowercased())")
        self.temporarilyLiftShield(durationMinutes: effectiveMinutes)
        result(nil)

      case "launchApp":
        let args = call.arguments as? [String: Any] ?? [:]
        let targetApp = args["targetApp"] as? String ?? ""
        DispatchQueue.main.async {
          let ok = self.launchTargetApp(named: targetApp)
          result(ok)
        }

      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func handleRequestGatePermissions(result: @escaping FlutterResult) {
    #if canImport(FamilyControls) && !targetEnvironment(simulator)
    if #available(iOS 16.0, *) {
      Task {
        do {
          try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
          DispatchQueue.main.async {
            self.sharedDefaults()?.set(true, forKey: "family_controls_authorized")
            result(true)
          }
        } catch {
          DispatchQueue.main.async {
            self.sharedDefaults()?.set(false, forKey: "family_controls_authorized")
            // Still allow enabling the gate via URL-scheme / Shortcut mode when
            // signed with a Personal Team profile that lacks FamilyControls.
            result(true)
          }
        }
      }
      return
    }
    #endif
    result(true)
  }

  private func activeRootViewController() -> UIViewController? {
    if let root = self.window?.rootViewController {
      return root
    }
    return UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
      .first(where: { $0.isKeyWindow })?.rootViewController
  }

  private func handlePickAppsToGate(result: @escaping FlutterResult) {
    #if canImport(FamilyControls) && !targetEnvironment(simulator)
    if #available(iOS 16.0, *),
       AuthorizationCenter.shared.authorizationStatus == .approved,
       let rootVC = self.activeRootViewController() {
      DispatchQueue.main.async {
        let pickerView = FamilyActivityPickerWrapperView { selection in
          ScreenTimeSelectionStore.shared.selection = selection
          let enabled = self.sharedDefaults()?.bool(forKey: "gate_enabled") ?? false
          self.applyManagedSettingsShield(enabled: enabled)
          let count = selection.applicationTokens.count + selection.categoryTokens.count
          if count > 0 {
            result(["Screen Time (\(count) selected)"])
          } else {
            result(nil)
          }
        }
        let hostingVC = UIHostingController(rootView: pickerView)
        rootVC.present(hostingVC, animated: true)
      }
      return
    }
    #endif
    // When FamilyControls system picker is not active, return nil so Flutter
    // displays the installed-apps checklist scanned from this device.
    result(nil)
  }

  private func applyManagedSettingsShield(enabled: Bool) {
    #if canImport(FamilyControls) && canImport(ManagedSettings) && !targetEnvironment(simulator)
    if #available(iOS 16.0, *),
       AuthorizationCenter.shared.authorizationStatus == .approved {
      let store = ManagedSettingsStore()
      if enabled {
        let selection = ScreenTimeSelectionStore.shared.selection
        store.shield.applications = selection.applicationTokens.isEmpty ? nil : selection.applicationTokens
        store.shield.applicationCategories = selection.categoryTokens.isEmpty
          ? nil
          : .specific(selection.categoryTokens)
      } else {
        store.shield.applications = nil
        store.shield.applicationCategories = nil
      }
    }
    #endif
  }

  private func temporarilyLiftShield(durationMinutes: Int) {
    #if canImport(FamilyControls) && canImport(ManagedSettings) && !targetEnvironment(simulator)
    if #available(iOS 16.0, *),
       AuthorizationCenter.shared.authorizationStatus == .approved {
      let store = ManagedSettingsStore()
      store.shield.applications = nil
      store.shield.applicationCategories = nil

      relockTimer?.invalidate()
      relockTimer = Timer.scheduledTimer(
        withTimeInterval: TimeInterval(durationMinutes * 60),
        repeats: false
      ) { [weak self] _ in
        guard let self = self else { return }
        let stillEnabled = self.sharedDefaults()?.bool(forKey: "gate_enabled") ?? false
        self.applyManagedSettingsShield(enabled: stillEnabled)
      }
    }
    #endif
  }

  private func registerOcrChannel(messenger: FlutterBinaryMessenger) {
    guard !ocrChannelRegistered else { return }
    ocrChannelRegistered = true
    let channel = FlutterMethodChannel(name: "com.veea.english/ocr", binaryMessenger: messenger)

    channel.setMethodCallHandler { (call: FlutterMethodCall, result: @escaping FlutterResult) in
      if call.method == "recognizeText" {
        guard let args = call.arguments as? [String: Any],
              let filePath = args["path"] as? String else {
          result(FlutterError(code: "INVALID_ARGUMENT", message: "Path is required", details: nil))
          return
        }

        let fileURL = URL(fileURLWithPath: filePath)
        guard FileManager.default.fileExists(atPath: filePath) else {
          result("")
          return
        }

        DispatchQueue.global(qos: .userInitiated).async {
          let requestHandler = VNImageRequestHandler(url: fileURL, options: [:])
          let request = VNRecognizeTextRequest { (request, error) in
            if let error = error {
              DispatchQueue.main.async {
                result(FlutterError(code: "OCR_FAILED", message: error.localizedDescription, details: nil))
              }
              return
            }

            guard let observations = request.results as? [VNRecognizedTextObservation] else {
              DispatchQueue.main.async {
                result("")
              }
              return
            }

            let text = observations.compactMap { observation in
              observation.topCandidates(1).first?.string
            }.joined(separator: "\n")

            DispatchQueue.main.async {
              result(text)
            }
          }

          request.recognitionLevel = .accurate
          request.usesLanguageCorrection = true

          do {
            try requestHandler.perform([request])
          } catch {
            DispatchQueue.main.async {
              result(FlutterError(code: "OCR_ERROR", message: error.localizedDescription, details: nil))
            }
          }
        }
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let messenger = engineBridge.applicationRegistrar.messenger()
    registerOcrChannel(messenger: messenger)
    registerAppGateChannel(messenger: messenger)
  }
}

class SceneDelegate: FlutterSceneDelegate {
  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    super.scene(scene, willConnectTo: session, options: connectionOptions)
    for urlContext in connectionOptions.urlContexts {
      _ = (UIApplication.shared.delegate as? AppDelegate)?.handleIncomingUrl(urlContext.url)
    }
  }

  override func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    super.scene(scene, openURLContexts: URLContexts)
    for urlContext in URLContexts {
      _ = (UIApplication.shared.delegate as? AppDelegate)?.handleIncomingUrl(urlContext.url)
    }
  }

  override func sceneDidBecomeActive(_ scene: UIScene) {
    super.sceneDidBecomeActive(scene)
    (UIApplication.shared.delegate as? AppDelegate)?.checkPendingGateTargetFromAppGroup()
  }
}

#if canImport(FamilyControls) && !targetEnvironment(simulator)
@available(iOS 16.0, *)
final class ScreenTimeSelectionStore {
  static let shared = ScreenTimeSelectionStore()
  private let key = "veea_family_activity_selection"

  var selection: FamilyActivitySelection {
    get {
      guard let data = UserDefaults.standard.data(forKey: key),
            let decoded = try? JSONDecoder().decode(FamilyActivitySelection.self, from: data) else {
        return FamilyActivitySelection()
      }
      return decoded
    }
    set {
      if let encoded = try? JSONEncoder().encode(newValue) {
        UserDefaults.standard.set(encoded, forKey: key)
      }
    }
  }
}

@available(iOS 16.0, *)
struct FamilyActivityPickerWrapperView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var selection: FamilyActivitySelection = ScreenTimeSelectionStore.shared.selection
  let onSave: (FamilyActivitySelection) -> Void

  var body: some View {
    NavigationView {
      FamilyActivityPicker(selection: $selection)
        .navigationTitle("Select Apps to Gate")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") {
              dismiss()
            }
          }
          ToolbarItem(placement: .confirmationAction) {
            Button("Done") {
              onSave(selection)
              dismiss()
            }
          }
        }
    }
  }
}
#endif
