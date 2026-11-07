import AppIntents

@available(iOS 16.0, *)
struct CheckVeeaGateIntent: AppIntent {
  static var title: LocalizedStringResource = "Check Veea Gate"
  static var description = IntentDescription(
    "Returns true when this app needs a vocabulary challenge. Use If to open the Veea gate link only when true."
  )
  static var openAppWhenRun: Bool = false

  @available(iOS 26.0, *)
  static var supportedModes: IntentModes { .background }

  @Parameter(title: "App", default: "X")
  var targetApp: String

  static var parameterSummary: some ParameterSummary {
    Summary("Check Veea Gate for \(\.$targetApp)")
  }

  @MainActor
  func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
    .result(value: GateAccessState.shared.needsChallenge(for: targetApp))
  }
}

@available(iOS 16.0, *)
struct VeeaGateShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: CheckVeeaGateIntent(),
      phrases: ["Check a gate in \(.applicationName)"],
      shortTitle: "Check Veea Gate",
      systemImageName: "lock.shield"
    )
  }
}
