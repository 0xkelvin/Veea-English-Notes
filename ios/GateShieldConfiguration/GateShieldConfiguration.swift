import ManagedSettings
import ManagedSettingsUI
import UIKit

final class GateShieldConfiguration: ShieldConfigurationDataSource {
  override func configuration(shielding application: Application) -> ShieldConfiguration {
    let name = application.localizedDisplayName ?? "this app"
    let subtitle: String
    if #available(iOS 26.5, *) {
      subtitle = "Complete your vocabulary challenge in Veea to earn time in \(name)."
    } else {
      subtitle = "Open Veea English and complete a vocabulary challenge to earn access to \(name)."
    }
    return ShieldConfiguration(
      backgroundBlurStyle: .systemMaterial,
      backgroundColor: .systemBackground,
      icon: UIImage(systemName: "book.closed.fill"),
      title: .init(text: "Earn your screen time", color: .label),
      subtitle: .init(text: subtitle, color: .secondaryLabel),
      primaryButtonLabel: .init(text: "Learn in Veea", color: .white),
      primaryButtonBackgroundColor: .systemBlue,
      secondaryButtonLabel: .init(text: "Not now", color: .secondaryLabel)
    )
  }
}
