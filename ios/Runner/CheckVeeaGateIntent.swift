import AppIntents

/// Compatibility only for pre-launch testers. Never requests a challenge.
@available(iOS 16.0, *)
struct CheckVeeaGateIntent: AppIntent {
  static var title: LocalizedStringResource = "Check Veea Gate"
  static var description = IntentDescription("This older action is inactive. Use Screen Time protection in Veea.")
  static var openAppWhenRun: Bool = false
  static var isDiscoverable: Bool = false
  @Parameter(title: "App", default: "X")
  var targetApp: String
  func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
    .result(value: false)
  }
}

// No AppShortcutsProvider: first launch exposes no Shortcut setup or actions.
