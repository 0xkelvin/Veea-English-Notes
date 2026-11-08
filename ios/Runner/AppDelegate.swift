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
  private var pendingColdStartTarget: String?

  /// Known iOS app URL schemes used to scan which apps are installed on the
  /// user's iPhone and to launch the target app after unlocking the gate.
  private static let knownAppSchemes: [(name: String, schemes: [String])] = [
    ("Facebook", ["fb://"]),
    ("Instagram", ["instagram://"]),
    ("TikTok", ["snssdk1233://", "snssdk1180://", "tiktok://", "musically://"]),
    ("YouTube", ["youtube://"]),
    ("Threads", ["barcelona://"]),
    ("X", ["twitter://"]),
    ("Reddit", ["reddit://"]),
    ("Messenger", ["fb-messenger://"]),
    ("WhatsApp", ["whatsapp://"]),
    ("Telegram", ["tg://"]),
    ("Zalo", ["zalo://"]),
    ("Discord", ["discord://"]),
    ("Snapchat", ["snapchat://"]),
    ("Netflix", ["nflx://"]),
    ("Spotify", ["spotify://"]),
    ("Twitch", ["twitch://"]),
    ("Pinterest", ["pinterest://"]),
    ("LinkedIn", ["linkedin://"]),
    ("Shopee", ["shopeevn://"]),
    ("Lazada", ["lazada://"]),
    ("Tiki", ["tiki://"]),
    ("Grab", ["grab://"]),
    ("Be", ["be://"]),
    ("MoMo", ["momo://"]),
    ("Chrome", ["googlechrome://"]),
    ("Gmail", ["googlegmail://"]),
    ("Google Maps", ["comgooglemaps://"]),
    ("ChatGPT", ["chatgpt://"]),
    ("CapCut", ["capcut://"]),
    ("Canva", ["canva://"]),
    ("Notion", ["notion://"]),
    ("Slack", ["slack://"]),
    ("Zoom", ["zoomus://"]),
    ("Teams", ["msteams://"]),
    ("Duolingo", ["duolingo://"]),
    ("Roblox", ["robloxmobile://"]),
    ("LINE", ["line://"]),
    ("Viber", ["viber://"]),
    ("KakaoTalk", ["kakaotalk://"]),
    ("WeChat", ["wechat://"])
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

    if let url = launchOptions?[.url] as? URL {
      _ = handleIncomingUrl(url)
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
    let schemes = (Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? [])
      .flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
    if schemes.contains(url.scheme ?? "") && url.host == "gate" {
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
      if let request = components?.queryItems?.first(where: { $0.name == "request" })?.value {
        let callback = components?.queryItems?.first(where: { $0.name == "x-success" })?.value ?? ""
        let cancel = components?.queryItems?.first(where: { $0.name == "x-cancel" })?.value
        guard let target = GateAccessState.shared.acceptUniversalRequest(id: request, callback: callback, cancel: cancel) else {
          sharedDefaults()?.set("Could not start this challenge. Update the Veea shortcut and try again.", forKey: "universal_gate_error")
          // Only the callback shape is retained for troubleshooting; never its tokens.
          if let parts = URLComponents(string: callback) {
            sharedDefaults()?.set("\(parts.scheme ?? "")://\(parts.host ?? "")\(parts.path)", forKey: "universal_callback_kind")
          }
          return true
        }
        sharedDefaults()?.removeObject(forKey: "universal_gate_error")
        let apps = sharedDefaults()?.dictionary(forKey: "universal_gate_apps") as? [String: String] ?? [:]
        pendingColdStartTarget = target
        appGateChannel?.invokeMethod("onGateTriggered", arguments: ["targetApp": target, "appName": apps[GateAccessState.shared.universalSession?.appKey ?? ""] ?? "Protected app"])
        return true
      }
      let targetApp = components?.queryItems?.first(where: { $0.name == "app" })?.value
        ?? sharedDefaults()?.string(forKey: "pending_gate_target_app")
        ?? "Facebook"
      sharedDefaults()?.removeObject(forKey: "pending_gate_target_app")

      let defaults = sharedDefaults()
      let normalizedTarget = targetApp.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      let now = Date().timeIntervalSince1970

      // A URL already foregrounds Veea. Never launch the target from here:
      // an unconditional App Open shortcut would just open this URL again.
      // Check Veea Gate must evaluate access in the background before Open URLs.
      let gateEnabled = defaults?.bool(forKey: "gate_enabled") ?? false
      if !gateEnabled { return true }
      let selected = defaults?.stringArray(forKey: "gated_apps") ?? []
      if !selected.contains(where: { GateAccessState.normalized($0) == normalizedTarget }) {
        return true
      }
      let unlockedUntil = defaults?.double(forKey: "unlocked_until_\(normalizedTarget)") ?? 0
      if unlockedUntil > now { return true }

      pendingColdStartTarget = targetApp
      appGateChannel?.invokeMethod("onGateTriggered", arguments: ["targetApp": targetApp])
      return true
    }
    return false
  }

  private func sharedDefaults() -> UserDefaults? {
    return GateAccessState.shared.defaults
  }

  func checkPendingGateTargetFromAppGroup() {
    if #available(iOS 16.0, *) {
      NativeScreenTimeManager.shared.reconcile()
      if let target = NativeScreenTimeManager.shared.consumePendingChallenge() {
        pendingColdStartTarget = target
        appGateChannel?.invokeMethod("onGateTriggered", arguments: ["targetApp": target])
        return
      }
    }
    guard let defaults = sharedDefaults(),
          let pendingTarget = defaults.string(forKey: "pending_gate_target_app"),
          !pendingTarget.isEmpty else {
      return
    }
    defaults.removeObject(forKey: "pending_gate_target_app")
    pendingColdStartTarget = pendingTarget
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
      case "consumePendingGate":
        var target = self.pendingColdStartTarget
        self.pendingColdStartTarget = nil
        if target == nil, #available(iOS 16.0, *) {
          target = NativeScreenTimeManager.shared.consumePendingChallenge()
        }
        result(target)

      case "requestPermissions":
        // Shortcut mode needs no Screen Time authorization. Native setup uses
        // its own explicit authorization request and propagates any failure.
        result(true)

      case "getInstalledApps":
        DispatchQueue.main.async {
          let installed = self.scanInstalledAppsOnDevice()
          result(installed)
        }

      case "pickAppsToGate":
        result(nil)

      case "setGateEnabled":
        let args = call.arguments as? [String: Any] ?? [:]
        let enabled = args["enabled"] as? Bool ?? false
        let passMinutes = args["passMinutes"] as? Int ?? 15
        let gatedApps = args["gatedApps"] as? [String] ?? []
        let defaults = self.sharedDefaults()
        defaults?.set(enabled, forKey: "gate_enabled")
        defaults?.set(passMinutes, forKey: "pass_minutes")
        defaults?.set(gatedApps, forKey: "gated_apps")
        if !enabled { GateAccessState.shared.setUniversalEnabled(false) }
        result(nil)

      case "grantPass":
        let args = call.arguments as? [String: Any] ?? [:]
        let targetApp = (args["targetApp"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let durationMinutes = args["durationMinutes"] as? Int ?? 15
        var nativeStatus: [String: Any]?
        if targetApp.hasPrefix("native:") {
          do {
            guard #available(iOS 16.0, *) else { throw NativeGateError.unavailable }
            try NativeScreenTimeManager.shared.grantPass(target: targetApp)
            nativeStatus = NativeScreenTimeManager.shared.status()
          } catch { result(self.screenTimeError(error)); return }
        } else if targetApp.hasPrefix("shortcut:") {
          guard GateAccessState.shared.earnUniversalPass(for: targetApp) else {
            result(FlutterError(code: "RETURN_EXPIRED", message: "This app opening has expired. Open the app again to continue.", details: nil)); return
          }
        } else {
          GateAccessState.shared.grantPass(for: targetApp, minutes: durationMinutes)
        }
        // A successfully completed gate must not be replayed on the next resume.
        self.pendingColdStartTarget = nil
        self.sharedDefaults()?.removeObject(forKey: "pending_gate_target_app")
        result(nativeStatus)

      case "revokePass":
        let args = call.arguments as? [String: Any] ?? [:]
        let targetApp = (args["targetApp"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if targetApp.hasPrefix("native:") {
          do {
            guard #available(iOS 16.0, *) else { throw NativeGateError.unavailable }
            try NativeScreenTimeManager.shared.revokePass(target: targetApp)
          } catch { result(self.screenTimeError(error)); return }
        } else {
          GateAccessState.shared.revokePass(for: targetApp)
        }
        result(nil)

      case "getScreenTimeStatus":
        if #available(iOS 16.0, *) { result(NativeScreenTimeManager.shared.status()) }
        else { result(["supported": false, "available": false]) }

      case "requestScreenTimeAuthorization":
        guard #available(iOS 16.0, *) else { result(self.screenTimeError(NativeGateError.unavailable)); return }
        Task { @MainActor in
          do {
            try await NativeScreenTimeManager.shared.requestAuthorization()
            result(NativeScreenTimeManager.shared.status())
          } catch { result(self.screenTimeError(error)) }
        }

      case "chooseScreenTimeApplications":
        guard #available(iOS 16.0, *), let root = self.activeRootViewController() else {
          result(self.screenTimeError(NativeGateError.unavailable)); return
        }
        do {
          try NativeScreenTimeManager.shared.chooseApplications(from: root) { selection in
            switch selection {
            case .success(let saved): result(saved)
            case .failure(let error): result(self.screenTimeError(error))
            }
          }
        } catch { result(self.screenTimeError(error)) }

      case "setScreenTimeEnabled":
        let args = call.arguments as? [String: Any] ?? [:]
        do {
          guard #available(iOS 16.0, *) else { throw NativeGateError.unavailable }
          try NativeScreenTimeManager.shared.setEnabled(args["enabled"] as? Bool ?? false,
                                                       minutes: args["passMinutes"] as? Int ?? 15)
          result(NativeScreenTimeManager.shared.status())
        } catch { result(self.screenTimeError(error)) }

      case "setScreenTimeDuration":
        let args = call.arguments as? [String: Any] ?? [:]
        do {
          guard #available(iOS 16.0, *) else { throw NativeGateError.unavailable }
          try NativeScreenTimeManager.shared.setDuration(args["passMinutes"] as? Int ?? 15)
          result(NativeScreenTimeManager.shared.status())
        } catch { result(self.screenTimeError(error)) }

      case "manageScreenTimeApplications":
        guard #available(iOS 16.0, *), let root = self.activeRootViewController() else {
          result(self.screenTimeError(NativeGateError.unavailable)); return
        }
        do {
          try NativeScreenTimeManager.shared.manageApplications(from: root) { result($0) }
        } catch { result(self.screenTimeError(error)) }

      case "getShortcutSetupStatus":
        let supportsImport: Bool
        if #available(iOS 27.0, *) { supportsImport = true } else { supportsImport = false }
        result(["supportsImport": supportsImport,
                "tested": GateAccessState.shared.testedShortcuts()])

      case "beginShortcutSetupTest":
        let args = call.arguments as? [String: Any] ?? [:]
        let app = (args["targetApp"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !app.isEmpty else {
          result(FlutterError(code: "INVALID_APP", message: "Choose an app to test.", details: nil)); return
        }
        GateAccessState.shared.beginSetupTest(for: app)
        result(nil)

      case "launchApp":
        let args = call.arguments as? [String: Any] ?? [:]
        let targetApp = args["targetApp"] as? String ?? ""
        if targetApp.hasPrefix("shortcut:") {
          guard let url = GateAccessState.shared.takeUniversalReturn(for: targetApp) else {
            result(false); return
          }
          UIApplication.shared.open(url, options: [:]) { opened in
            if !opened { GateAccessState.shared.universalReturnFailed(for: targetApp) }
            result(opened)
          }
        } else {
          DispatchQueue.main.async { result(self.launchTargetApp(named: targetApp)) }
        }

      case "getUniversalGateStatus":
        var status = GateAccessState.shared.universalStatus()
        status["error"] = self.sharedDefaults()?.string(forKey: "universal_gate_error")
        #if DEBUG
        status["callbackKind"] = self.sharedDefaults()?.string(forKey: "universal_callback_kind")
        #endif
        result(status)

      case "setUniversalGateEnabled":
        let enabled = (call.arguments as? [String: Any])?["enabled"] as? Bool ?? false
        GateAccessState.shared.setUniversalEnabled(enabled)
        result(nil)

      case "cancelUniversalGate":
        let target = (call.arguments as? [String: Any])?["targetApp"] as? String ?? ""
        if let url = GateAccessState.shared.cancelUniversalChallenge(for: target) {
          UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
        result(nil)

      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func screenTimeError(_ error: Error) -> FlutterError {
    FlutterError(code: "SCREEN_TIME_ERROR", message: error.localizedDescription, details: nil)
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
