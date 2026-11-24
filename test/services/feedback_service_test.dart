import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:veea_english_app/core/config/app_config.dart';
import 'package:veea_english_app/services/feedback_service.dart';

void main() {
  tearDown(() {
    AppConfig.overrideBaseUrl(null);
    AppConfig.overrideFeedbackDelivery(null);
    AppConfig.overridePrivacyPolicyUrl(null);
    AppConfig.overrideSupportEmail(null);
    AppConfig.overrideZaloCommunityUrl(null);
    FeedbackService.overrideHandlers();
  });

  group('Support and privacy build config validation', () {
    test('defaults keep external URLs, support email, and legacy feedback off', () {
      expect(AppConfig.privacyPolicyUri, isNull);
      expect(AppConfig.privacyPolicyUrl, isNull);
      expect(AppConfig.supportEmail, isNull);
      expect(AppConfig.isFeedbackDeliveryEnabled, isFalse);

      // Enabling the Go account service alone must NOT enable legacy feedback delivery.
      AppConfig.overrideBaseUrl('https://account.example.test');
      expect(AppConfig.isCloudEnabled, isTrue);
      expect(AppConfig.isFeedbackDeliveryEnabled, isFalse);

      // Delivery requires both cloud base URL and the explicit delivery flag.
      AppConfig.overrideFeedbackDelivery(true);
      expect(AppConfig.isFeedbackDeliveryEnabled, isTrue);

      AppConfig.overrideBaseUrl('');
      expect(AppConfig.isFeedbackDeliveryEnabled, isFalse);
    });

    test('parseTrustedHttpsUrl accepts safe HTTPS URLs and rejects unsafe inputs', () {
      expect(
        AppConfig.parseTrustedHttpsUrl('https://example.test/privacy')?.toString(),
        'https://example.test/privacy',
      );
      expect(
        AppConfig.parseTrustedHttpsUrl(
          '  https://docs.example.test/legal/privacy?lang=en#words  ',
        )?.toString(),
        'https://docs.example.test/legal/privacy?lang=en#words',
      );

      for (final unsafe in [
        null,
        '',
        '   ',
        'http://example.test/privacy',
        'javascript:alert(1)',
        'mailto:help@example.test',
        'file:///etc/passwd',
        'data:text/html,hi',
        'https://user:pass@example.test/privacy',
        'https://user@example.test/privacy',
        'https://@example.test/privacy',
        'https://example.test:8443/privacy',
        'https://localhost/privacy',
        'https://127.0.0.1/privacy',
        'https://[::1]/privacy',
        'https://intranet/privacy',
        'https://example.test/a/../secret',
        'https://example.test/%2e%2e/secret',
        'https://example.test/privacy\nInjected: 1',
        'https://example.test/privacy with spaces',
        'https://example.test\\privacy',
      ]) {
        expect(
          AppConfig.parseTrustedHttpsUrl(unsafe),
          isNull,
          reason: 'Expected rejection for: $unsafe',
        );
      }
    });

    test('parseSupportEmail accepts valid addresses and rejects unsafe inputs', () {
      expect(
        AppConfig.parseSupportEmail('help@example.test'),
        'help@example.test',
      );
      expect(
        AppConfig.parseSupportEmail('  Support.Team+app@Sub.Example.Test  '),
        'Support.Team+app@sub.example.test',
      );

      for (final unsafe in [
        null,
        '',
        '   ',
        'not-an-email',
        'help@localhost',
        'help@127.0.0.1',
        'help@example.test?cc=evil@example.test',
        'help@example.test,evil@example.test',
        'help@example.test\nBcc:evil@example.test',
        '.help@example.test',
        'help.@example.test',
        'he..lp@example.test',
        'help@bad_domain.test',
        'help@example.123',
        '<help@example.test>',
      ]) {
        expect(
          AppConfig.parseSupportEmail(unsafe),
          isNull,
          reason: 'Expected rejection for: $unsafe',
        );
      }
    });
  });

  group('FeedbackService formatting and handoffs', () {
    final samplePng = Uint8List.fromList([
      137,
      80,
      78,
      71,
      13,
      10,
      26,
      10,
      0,
      0,
      0,
      0,
    ]);

    test('formatDraft omits diagnostics unless opted in and never leaks account/notebook data', () {
      const draft = FeedbackDraft(
        kind: 'bug',
        message: 'Audio stops when switching tabs.',
        includeDiagnostics: false,
      );

      final body = FeedbackService.formatDraft(draft);
      expect(body, contains('Problem report'));
      expect(body, contains('Audio stops when switching tabs.'));
      expect(body, isNot(contains('App details')));
      expect(body, isNot(contains('App version')));
      expect(body, isNot(contains('Platform')));
      expect(body, isNot(contains('Total Words')));
      expect(body, isNot(contains('support@veea.app')));
    });

    test('formatDraft includes only safe app details when diagnostics are opted in', () {
      const draft = FeedbackDraft(
        kind: 'feature',
        message: 'Add keyboard shortcuts for flashcard review.',
        contact: 'reader@example.test',
        includeDiagnostics: true,
        diagnostics: {
          'app_version': '1.0.2',
          'platform': 'iOS',
          'screen': 'feedback',
        },
      );

      final body = FeedbackService.formatDraft(draft);
      expect(body, contains('Feature request'));
      expect(body, contains('Reply contact: reader@example.test'));
      expect(body, contains('App details:'));
      expect(body, contains('- App version: 1.0.2'));
      expect(body, contains('- Platform: iOS'));
      expect(body, contains('- Screen: feedback'));
      expect(body, isNot(contains('Attachment note:')));
    });

    test('formatDraft explicitly notes when a screenshot is not attached', () {
      final draft = FeedbackDraft(
        kind: 'bug',
        message: 'Button text clips on small screen.',
        screenshotBytes: samplePng,
      );

      final withoutAttachment = FeedbackService.formatDraft(
        draft,
        screenshotAttached: false,
      );
      expect(withoutAttachment, contains('Attachment note:'));
      expect(withoutAttachment, contains('not attached automatically'));

      final withAttachment = FeedbackService.formatDraft(
        draft,
        screenshotAttached: true,
      );
      expect(withAttachment, isNot(contains('Attachment note:')));
    });

    test('shareDraft attaches screenshot, normalizes iPad anchor, and handles results', () async {
      ShareParams? captured;
      FeedbackService.overrideHandlers(
        share: (params) async {
          captured = params;
          return const ShareResult('com.apple.UIKit.activity.Mail', ShareResultStatus.success);
        },
      );

      final result = await FeedbackService.shareDraft(
        FeedbackDraft(
          kind: 'bug',
          message: 'Layout overlap on landscape.',
          screenshotBytes: samplePng,
        ),
        sharePositionOrigin: Rect.zero,
      );

      expect(result.status, FeedbackHandoffStatus.handedOff);
      expect(result.attachmentIncluded, isTrue);
      expect(result.message, contains('does not send feedback automatically'));
      expect(captured, isNotNull);
      expect(captured!.sharePositionOrigin, isNotNull);
      expect(captured!.sharePositionOrigin!.width, greaterThan(0));
      expect(captured!.sharePositionOrigin!.height, greaterThan(0));
      expect(captured!.files, hasLength(1));
      expect(captured!.fileNameOverrides, ['veea_feedback_screenshot.png']);
      expect(captured!.text, isNot(contains('Attachment note:')));
    });

    test('shareDraft reports cancelled, unavailable, and thrown errors clearly', () async {
      const draft = FeedbackDraft(
        kind: 'other',
        message: 'Checking share error states.',
      );

      FeedbackService.overrideHandlers(
        share: (_) async => const ShareResult('', ShareResultStatus.dismissed),
      );
      final cancelled = await FeedbackService.shareDraft(draft);
      expect(cancelled.status, FeedbackHandoffStatus.cancelled);
      expect(cancelled.message, contains('cancelled'));

      FeedbackService.overrideHandlers(
        share: (_) async => ShareResult.unavailable,
      );
      final unavailable = await FeedbackService.shareDraft(draft);
      expect(unavailable.status, FeedbackHandoffStatus.unavailable);
      expect(unavailable.message, contains('not available'));

      FeedbackService.overrideHandlers(
        share: (_) async => throw StateError('platform share failure'),
      );
      final failed = await FeedbackService.shareDraft(draft);
      expect(failed.status, FeedbackHandoffStatus.failed);
      expect(failed.message, contains('Could not open the share sheet'));
    });

    test('openEmailDraft fails closed without configured support email and encodes mailto safely', () async {
      var launched = false;
      FeedbackService.overrideHandlers(
        launch: (uri, {required mode}) async {
          launched = true;
          return true;
        },
      );

      final unconfigured = await FeedbackService.openEmailDraft(
        const FeedbackDraft(kind: 'bug', message: 'No mailbox configured.'),
      );
      expect(unconfigured.status, FeedbackHandoffStatus.unavailable);
      expect(launched, isFalse);

      Uri? launchedUri;
      LaunchMode? launchedMode;
      AppConfig.overrideSupportEmail('help@example.test');
      FeedbackService.overrideHandlers(
        launch: (uri, {required mode}) async {
          launchedUri = uri;
          launchedMode = mode;
          return true;
        },
      );

      final opened = await FeedbackService.openEmailDraft(
        FeedbackDraft(
          kind: 'bug',
          message: 'Crash after tapping button.',
          screenshotBytes: samplePng,
        ),
      );
      expect(opened.status, FeedbackHandoffStatus.handedOff);
      expect(opened.attachmentIncluded, isFalse);
      expect(opened.message, contains('screenshot is not attached'));
      expect(launchedMode, LaunchMode.externalApplication);
      expect(launchedUri, isNotNull);
      expect(launchedUri!.scheme, 'mailto');
      expect(launchedUri!.path, 'help@example.test');
      // Percent-encoded spaces (%20) instead of '+' so iOS Mail renders cleanly.
      expect(launchedUri!.query, isNot(contains('+')));
      expect(launchedUri!.queryParameters['body'], contains('not attached automatically'));
    });

    test('openTrustedUrl refuses non-HTTPS URLs before calling launcher', () async {
      var called = false;
      FeedbackService.overrideHandlers(
        launch: (uri, {required mode}) async {
          called = true;
          return true;
        },
      );

      expect(
        await FeedbackService.openTrustedUrl(
          Uri.parse('http://example.test/privacy'),
        ),
        isFalse,
      );
      expect(called, isFalse);

      expect(
        await FeedbackService.openTrustedUrl(
          Uri.parse('https://example.test/privacy'),
        ),
        isTrue,
      );
      expect(called, isTrue);
    });
  });
}
