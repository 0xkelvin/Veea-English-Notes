import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

class FeedbackService {
  const FeedbackService._();

  static const String supportEmail = 'support@veea.app';
  static const String appVersion = '1.0.1';

  /// Generates the diagnostics report string.
  static String generateReport({
    required int totalWords,
    required int streakDays,
  }) {
    String osInfo = 'Unknown OS';
    try {
      osInfo = '${Platform.operatingSystem} ${Platform.operatingSystemVersion}';
    } catch (_) {
      if (kIsWeb) osInfo = 'Web';
    }

    return '''
Hi Veea Team,

[Please describe your feedback, feature request, or bug here]

--- DIAGNOSTICS ---
App: Veea English v$appVersion
OS: $osInfo
Total Words: $totalWords
Streak: $streakDays days
Timestamp: ${DateTime.now().toUtc().toIso8601String()}
-------------------
''';
  }

  /// Attempts to open system email client with prefilled metadata.
  ///
  /// Returns `true` if mail client launched successfully, `false` otherwise.
  static Future<bool> openFeedbackMail({
    required int totalWords,
    required int streakDays,
  }) async {
    final body = generateReport(totalWords: totalWords, streakDays: streakDays);

    final emailUri = Uri(
      scheme: 'mailto',
      path: supportEmail,
      queryParameters: {
        'subject': '[Veea English v$appVersion] Feedback / Bug Report',
        'body': body,
      },
    );

    try {
      final launched = await launchUrl(
        emailUri,
        mode: LaunchMode.externalApplication,
      );
      return launched;
    } catch (e) {
      debugPrint('Could not launch email client: $e');
      return false;
    }
  }
}
