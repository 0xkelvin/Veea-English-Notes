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

  private var applicationLabelsRegistered = false
  private var ocrChannelRegistered = false

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    if let controller = window?.rootViewController as? FlutterViewController {
      registerOcrChannel(messenger: controller.binaryMessenger)
      registerAppGateChannel(messenger: controller.binaryMessenger)
      if #available(iOS 16.0, *), !applicationLabelsRegistered,
         let registrar = registrar(forPlugin: "VeeaApplicationLabel") {
        registerApplicationLabels(registrar)
      }
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

  // Consume retired gate links without starting a challenge or invoking callbacks.
  // Native Screen Time challenges arrive through the app-group handoff instead.
  func handleIncomingUrl(_ url: URL) -> Bool {
    let schemes = (Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? [])
      .flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
    return schemes.contains(url.scheme ?? "") && url.host == "gate"
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
    sharedDefaults()?.removeObject(forKey: "pending_gate_target_app")
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
        result(false)
      case "getInstalledApps":
        result([])
      case "pickAppsToGate":
        result(nil)
      case "setGateEnabled":
        self.sharedDefaults()?.set(false, forKey: "gate_enabled")
        self.sharedDefaults()?.removeObject(forKey: "pending_gate_target_app")
        GateAccessState.shared.setUniversalEnabled(false)
        result(nil)

      case "grantPass":
        let args = call.arguments as? [String: Any] ?? [:]
        let targetApp = (args["targetApp"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var nativeStatus: [String: Any]?
        if targetApp.hasPrefix("native:") {
          do {
            guard #available(iOS 16.0, *) else { throw NativeGateError.unavailable }
            try NativeScreenTimeManager.shared.grantPass(target: targetApp)
            nativeStatus = NativeScreenTimeManager.shared.status()
          } catch { result(self.screenTimeError(error)); return }
        } else {
          result(FlutterError(code: "UNSUPPORTED_GATE", message: "Use Screen Time protection in Veea.", details: nil)); return
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

      case "setScreenTimeApplicationDuration", "removeScreenTimeApplication":
        let args = call.arguments as? [String: Any] ?? [:]
        do {
          guard #available(iOS 16.0, *), let target = args["targetApp"] as? String else {
            throw NativeGateError.unknownApplication
          }
          if call.method == "removeScreenTimeApplication" {
            try NativeScreenTimeManager.shared.removeApplication(target: target)
          } else {
            // Null explicitly restores inheritance; malformed values must not reset a rule.
            guard args["passMinutes"] == nil || args["passMinutes"] is NSNull || args["passMinutes"] is Int else {
              throw NativeGateError.invalidDuration
            }
            try NativeScreenTimeManager.shared.setApplicationDuration(target: target, minutes: args["passMinutes"] as? Int)
          }
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
        result(["supportsImport": false, "tested": [:]])
      case "beginShortcutSetupTest", "setUniversalGateEnabled", "cancelUniversalGate":
        result(FlutterError(code: "UNSUPPORTED_GATE", message: "Use Screen Time protection in Veea.", details: nil))
      case "launchApp":
        result(false)
      case "getUniversalGateStatus":
        result(["enabled": false, "apps": []])

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

  @available(iOS 16.0, *)
  private func registerApplicationLabels(_ registrar: FlutterPluginRegistrar) {
    guard !applicationLabelsRegistered else { return }
    registrar.register(NativeApplicationLabelFactory(), withId: "app.veea.english/application_label")
    applicationLabelsRegistered = true
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let messenger = engineBridge.applicationRegistrar.messenger()
    registerOcrChannel(messenger: messenger)
    registerAppGateChannel(messenger: messenger)
    if #available(iOS 16.0, *), !applicationLabelsRegistered,
       let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "VeeaApplicationLabel") {
      registerApplicationLabels(registrar)
    }
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
