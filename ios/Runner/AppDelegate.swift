import Flutter
import UIKit
import Vision

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let controller = window?.rootViewController as! FlutterViewController
    let channel = FlutterMethodChannel(name: "com.veea.english/ocr", binaryMessenger: controller.binaryMessenger)

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

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}
