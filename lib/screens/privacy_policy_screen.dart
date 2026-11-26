import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/config/app_config.dart';
import '../core/theme/pixel_metrics.dart';
import '../services/feedback_service.dart';
import '../widgets/pixel/pixel_box.dart';

/// Offline-readable privacy notice describing on-device behavior and optional
/// online services used by Veea English.
class PrivacyPolicyScreen extends StatelessWidget {
  const PrivacyPolicyScreen({super.key});

  Future<void> _openExternalPolicy(BuildContext context, Uri uri) async {
    final opened = await FeedbackService.openTrustedUrl(uri);
    if (!opened && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Could not open the privacy policy link. You can read the offline summary above.',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final policyUri = AppConfig.privacyPolicyUri;
    final supportEmail = AppConfig.supportEmail;

    return Scaffold(
      appBar: AppBar(title: const Text('Privacy policy')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(PixelMetrics.space4),
          children: [
            Text(
              'How Veea handles your data',
              style: theme.textTheme.headlineSmall,
            ),
            const SizedBox(height: PixelMetrics.space2),
            Text(
              'You can read this notice offline at any time. It explains how '
              'the app handles data on this device and when you choose to use '
              'optional online features.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: PixelMetrics.space4),
            const _PolicySection(
              icon: Icons.book_outlined,
              title: 'Your words stay on this device',
              paragraphs: [
                'Your saved words, meanings, pronunciation notes, examples, '
                    'tags, and practice history stay stored on this device.',
                'Your notebook remains on this device across sign-in, '
                    'sign-out, account changes, and account deletion.',
              ],
            ),
            const _PolicySection(
              icon: Icons.save_alt_outlined,
              title: 'Manual backups (JSON and CSV)',
              paragraphs: [
                'Exporting a JSON or CSV backup is controlled by you and '
                    'happens only when you choose to copy or share it.',
                'Local export is not automatic cloud backup or cloud sync.',
              ],
            ),
            const _PolicySection(
              icon: Icons.translate_outlined,
              title: 'Optional online word lookup',
              paragraphs: [
                'Typing a word or copying text to your clipboard does not '
                    'automatically send words to external services.',
                'The bundled English–Vietnamese dictionary works offline. '
                    'Successful online lookup results are saved on this phone '
                    'for later offline use. They stay outside account sync. '
                    'You can clear them in Settings → Offline dictionary '
                    'without deleting your notebook.',
                'Only when you explicitly choose to look up a word online does '
                    'Veea send the word or phrase you entered to a third-party translation or '
                    'dictionary service (such as Google Translate or MyMemory) '
                    'to fetch a suggested meaning. These services also receive '
                    'the network information needed to respond, including your IP address.',
              ],
            ),
            const _PolicySection(
              icon: Icons.account_circle_outlined,
              title: 'Accounts and purchases',
              paragraphs: [
                'Veea works offline without an account. When you choose to '
                    'sign up or sign in, Veea uses the configured Veea account '
                    'service with your email address and verification codes '
                    '(and an optional password).',
                'The account service also receives network information such as '
                    'your IP address and a device/platform label, and keeps '
                    'session records so you can view and revoke signed-in sessions.',
                'Inside Account settings, you can manage active sessions, '
                    'sign out, or request deletion of your online account. '
                    'For other account-data requests, use the support contact '
                    'in the app or its App Store listing.',
                'This release is free. If you previously purchased Veea Pro, '
                    'those purchases were processed by Apple through '
                    'the App Store. Veea does not receive your payment card '
                    'details. When purchase verification is enabled, Apple '
                    'purchase records are verified with the configured Veea '
                    'service to keep your access accurate.',
              ],
            ),
            const _PolicySection(
              icon: Icons.lock_outline,
              title: 'App locks and Screen Time',
              paragraphs: [
                'On iOS, apps you select in Apple’s Screen Time picker are '
                    'stored as private system tokens that stay on this device.',
                'Veea cannot read your messages or browsing history, and '
                    'Screen Time selections are never used for advertising or '
                    'marketing.',
              ],
            ),
            const _PolicySection(
              icon: Icons.tune_outlined,
              title: 'Device permissions',
              paragraphs: [
                'Permissions are requested only when you choose to use a '
                    'feature:',
                '• Notifications: used only if you turn on daily practice '
                    'reminders.',
                '• Camera: used only when you open the scanner to capture '
                    'text.',
                '• Photos: used only when you pick a photo to scan or attach '
                    'a screenshot to feedback.',
              ],
            ),
            const _PolicySection(
              icon: Icons.feedback_outlined,
              title: 'Help and feedback',
              paragraphs: [
                'Feedback is optional and does not require an account.',
                'Your feedback message, optional reply contact, optional app '
                    'details (app version, platform, and screen name), and any '
                    'screenshot you pick are shared only when you choose to '
                    'share or send them.',
                'Saved vocabulary words, account IDs, and sign-in credentials '
                    'are not added automatically to feedback drafts.',
              ],
            ),
            PixelBox(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Service details and full online policy',
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: PixelMetrics.space2),
                  Text(
                    'This in-app notice describes how the app handles data on '
                    'your device and during optional requests. Additional '
                    'service-side terms, data retention details, and operator '
                    'information are governed by the published policy provided '
                    'by the service operator.',
                    style: theme.textTheme.bodyMedium,
                  ),
                  if (policyUri != null) ...[
                    const SizedBox(height: PixelMetrics.space3),
                    OutlinedButton.icon(
                      key: const Key('open_external_privacy_policy'),
                      onPressed: () => _openExternalPolicy(context, policyUri),
                      icon: const Icon(Icons.open_in_new),
                      label: const Text('Open full privacy policy'),
                    ),
                    const SizedBox(height: PixelMetrics.space1),
                    Text(
                      policyUri.toString(),
                      style: theme.textTheme.bodySmall,
                    ),
                  ] else ...[
                    const SizedBox(height: PixelMetrics.space2),
                    Text(
                      'Check the App Store listing for the full online privacy policy.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                  if (supportEmail != null) ...[
                    const SizedBox(height: PixelMetrics.space3),
                    Text('Support contact', style: theme.textTheme.titleSmall),
                    const SizedBox(height: PixelMetrics.space1),
                    Wrap(
                      spacing: PixelMetrics.space2,
                      runSpacing: PixelMetrics.space1,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(supportEmail, style: theme.textTheme.bodyMedium),
                        TextButton.icon(
                          key: const Key('copy_privacy_support_email'),
                          onPressed: () async {
                            await Clipboard.setData(
                              ClipboardData(text: supportEmail),
                            );
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Support email copied'),
                                ),
                              );
                            }
                          },
                          icon: const Icon(Icons.copy, size: 18),
                          label: const Text('Copy'),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PolicySection extends StatelessWidget {
  const _PolicySection({
    required this.icon,
    required this.title,
    required this.paragraphs,
  });

  final IconData icon;
  final String title;
  final List<String> paragraphs;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: PixelMetrics.space3),
      child: PixelBox(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Icon(icon, size: 20),
                ),
                const SizedBox(width: PixelMetrics.space2),
                Expanded(
                  child: Text(title, style: theme.textTheme.titleMedium),
                ),
              ],
            ),
            const SizedBox(height: PixelMetrics.space2),
            for (var i = 0; i < paragraphs.length; i++) ...[
              Text(paragraphs[i], style: theme.textTheme.bodyMedium),
              if (i + 1 < paragraphs.length)
                const SizedBox(height: PixelMetrics.space2),
            ],
          ],
        ),
      ),
    );
  }
}
