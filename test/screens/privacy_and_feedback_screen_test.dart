import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:veea_english_app/core/config/app_config.dart';
import 'package:veea_english_app/core/theme/pixel_theme.dart';
import 'package:veea_english_app/data/feedback_repository.dart';
import 'package:veea_english_app/data/local/sqlite_vocabulary_repository.dart';
import 'package:veea_english_app/data/remote/api_client.dart';
import 'package:veea_english_app/models/vocabulary_word.dart';
import 'package:veea_english_app/providers/feedback_provider.dart';
import 'package:veea_english_app/screens/feedback_screen.dart';
import 'package:veea_english_app/screens/privacy_policy_screen.dart';
import 'package:veea_english_app/services/feedback_service.dart';
import '../support/fake_token_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late SqliteVocabularyRepository repo;
  late FakeTokenStore tokens;
  late List<Uri> httpRequests;
  late FeedbackProvider feedback;

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

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    AppConfig.overrideBaseUrl(null);
    AppConfig.overrideFeedbackDelivery(null);
    AppConfig.overridePrivacyPolicyUrl(null);
    AppConfig.overrideSupportEmail(null);
    AppConfig.overrideZaloCommunityUrl(null);
    FeedbackService.overrideHandlers();

    repo = await SqliteVocabularyRepository.open(path: inMemoryDatabasePath);
    await repo.insert(
      VocabularyWord.create(
        id: 'secret-word-1',
        word: 'serendipity',
        meaning: 'sự tình cờ may mắn',
        date: '2026-11-24',
        now: DateTime.utc(2026, 11, 24),
      ),
    );
    tokens = FakeTokenStore()
      ..accessToken = 'secret-access-token'
      ..refreshToken = 'secret-refresh-token'
      ..accountId = 'acct-uuid-9999'
      ..identifier = 'learner@example.test';
    httpRequests = [];
    final client = ApiClient(
      tokenStore: tokens,
      baseUrl: 'https://account.example.test/api/v1',
      httpClient: MockClient((r) async {
        httpRequests.add(r.url);
        return http.Response(jsonEncode({'data': {}}), 200);
      }),
    );
    feedback = FeedbackProvider(FeedbackRepository(repo.database, client));
    await feedback.activate('acct-uuid-9999');
  });

  tearDown(() async {
    AppConfig.overrideBaseUrl(null);
    AppConfig.overrideFeedbackDelivery(null);
    AppConfig.overridePrivacyPolicyUrl(null);
    AppConfig.overrideSupportEmail(null);
    AppConfig.overrideZaloCommunityUrl(null);
    FeedbackService.overrideHandlers();
    feedback.dispose();
    await repo.close();
  });

  Widget wrap(Widget child, {double scale = 1.0, bool dark = false}) =>
      ChangeNotifierProvider.value(
        value: feedback,
        child: MaterialApp(
          theme: dark ? PixelTheme.dark() : PixelTheme.light(),
          builder: (context, widget) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: widget!,
          ),
          home: child,
        ),
      );

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
  }

  group('PrivacyPolicyScreen', () {
    testWidgets(
      'renders complete offline policy without invented external links or mailbox',
      (tester) async {
        tester.view.physicalSize = const Size(600, 3200);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(wrap(const PrivacyPolicyScreen()));
        await tester.pumpAndSettle();

        expect(find.text('Privacy policy'), findsOneWidget);
        expect(find.text('Your words stay on this device'), findsOneWidget);
        expect(
          find.textContaining(
            'across sign-in, sign-out, account changes, and account deletion',
          ),
          findsOneWidget,
        );
        expect(find.text('Manual backups (JSON and CSV)'), findsOneWidget);
        expect(
          find.textContaining('not automatic cloud backup or cloud sync'),
          findsOneWidget,
        );
        expect(find.text('Optional online word lookup'), findsOneWidget);
        expect(
          find.textContaining('Google Translate or MyMemory'),
          findsOneWidget,
        );
        expect(find.textContaining('clipboard'), findsOneWidget);
        expect(find.text('Accounts and purchases'), findsOneWidget);
        expect(
          find.textContaining('Apple through the App Store'),
          findsOneWidget,
        );
        expect(find.text('App locks and Screen Time'), findsOneWidget);
        expect(find.textContaining('private system tokens'), findsOneWidget);
        expect(
          find.textContaining('never used for advertising or marketing'),
          findsOneWidget,
        );
        expect(find.text('Device permissions'), findsOneWidget);
        expect(find.textContaining('Notifications:'), findsOneWidget);
        expect(find.textContaining('Camera:'), findsOneWidget);
        expect(find.textContaining('Photos:'), findsOneWidget);
        expect(find.text('Help and feedback'), findsOneWidget);
        expect(
          find.text('Service details and full online policy'),
          findsOneWidget,
        );

        // No unconfigured external link or invented mailbox.
        expect(
          find.byKey(const Key('open_external_privacy_policy')),
          findsNothing,
        );
        expect(
          find.byKey(const Key('copy_privacy_support_email')),
          findsNothing,
        );
        expect(find.textContaining('support@veea.app'), findsNothing);
      },
    );

    testWidgets(
      'validates external privacy policy URL and support email before exposing actions',
      (tester) async {
        tester.view.physicalSize = const Size(600, 3200);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        // Unsafe URL & email must remain hidden.
        AppConfig.overridePrivacyPolicyUrl(
          'https://user:pass@example.test/privacy',
        );
        AppConfig.overrideSupportEmail('bad@example.test?cc=evil@example.test');
        await tester.pumpWidget(wrap(const PrivacyPolicyScreen()));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('open_external_privacy_policy')),
          findsNothing,
        );
        expect(
          find.byKey(const Key('copy_privacy_support_email')),
          findsNothing,
        );

        // Valid HTTPS URL & email are shown and launch safely.
        Uri? openedUri;
        var shouldLaunchSucceed = true;
        FeedbackService.overrideHandlers(
          launch: (uri, {required mode}) async {
            openedUri = uri;
            return shouldLaunchSucceed;
          },
        );
        AppConfig.overridePrivacyPolicyUrl('https://example.test/privacy');
        AppConfig.overrideSupportEmail('support@example.test');

        await tester.pumpWidget(wrap(const PrivacyPolicyScreen()));
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('open_external_privacy_policy')),
          findsOneWidget,
        );
        expect(find.text('support@example.test'), findsOneWidget);

        await tester.tap(find.byKey(const Key('open_external_privacy_policy')));
        await tester.pumpAndSettle();
        expect(openedUri?.toString(), 'https://example.test/privacy');

        shouldLaunchSucceed = false;
        await tester.tap(find.byKey(const Key('open_external_privacy_policy')));
        await tester.pumpAndSettle();
        expect(
          find.textContaining('Could not open the privacy policy link'),
          findsOneWidget,
        );
      },
    );
  });

  group('FeedbackScreen against account-only Go build', () {
    testWidgets(
      'makes zero legacy HTTP requests, preserves reports, respects diagnostics/screenshot, and never marks sent',
      (tester) async {
        // Simulate Go account build: cloud base URL set, feedback delivery left at default OFF.
        AppConfig.overrideBaseUrl('https://account.example.test');
        expect(AppConfig.isCloudEnabled, isTrue);
        expect(AppConfig.isFeedbackDeliveryEnabled, isFalse);

        // Seed an existing report with diagnostics OFF and a PNG screenshot.
        await tester.runAsync(
          () => feedback.submit(
            kind: 'bug',
            message: 'Existing local draft with screenshot.',
            diagnostics: false,
            screenshot: samplePng,
          ),
        );
        final savedId = feedback.reports.single.id;

        // Use iPad-sized viewport to verify valid sharePositionOrigin.
        tester.view.physicalSize = const Size(1024, 1400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        ShareParams? capturedShare;
        var shareStatus = ShareResultStatus.success;
        FeedbackService.overrideHandlers(
          share: (params) async {
            capturedShare = params;
            return ShareResult('activity', shareStatus);
          },
        );

        await tester.pumpWidget(wrap(const FeedbackScreen()));
        await settle(tester);

        // No legacy /client/config or /feedback calls were made!
        expect(httpRequests, isEmpty);
        expect(
          find.text('Existing local draft with screenshot.'),
          findsOneWidget,
        );
        expect(find.text('Saved on this device · Not sent'), findsOneWidget);
        expect(find.text('Includes screenshot'), findsOneWidget);
        expect(find.byKey(const Key('email_support_draft')), findsNothing);
        expect(find.byKey(const Key('feedback_zalo_community')), findsNothing);

        // Share saved report -> includes PNG attachment, valid non-zero iPad origin,
        // omits diagnostics and never leaks account UUID/email/tokens/words.
        final shareBtn = find.byKey(ValueKey('share_report_$savedId'));
        await tester.ensureVisible(shareBtn);
        await tester.tap(shareBtn);
        await settle(tester);

        expect(httpRequests, isEmpty);
        expect(capturedShare, isNotNull);
        expect(capturedShare!.sharePositionOrigin, isNotNull);
        expect(capturedShare!.sharePositionOrigin!.width, greaterThan(0));
        expect(capturedShare!.sharePositionOrigin!.height, greaterThan(0));
        expect(capturedShare!.files, hasLength(1));
        expect(
          capturedShare!.text,
          contains('Existing local draft with screenshot.'),
        );
        expect(capturedShare!.text, isNot(contains('App details:')));
        expect(capturedShare!.text, isNot(contains('acct-uuid-9999')));
        expect(capturedShare!.text, isNot(contains('learner@example.test')));
        expect(capturedShare!.text, isNot(contains('secret-access-token')));
        expect(capturedShare!.text, isNot(contains('serendipity')));

        // Must NEVER mark report received/sent after share sheet completes.
        expect(feedback.reports.single.queued, isTrue);
        expect(find.text('Saved on this device · Not sent'), findsOneWidget);
        expect(find.text('Received'), findsNothing);

        // Cancelled share shows clear error message.
        shareStatus = ShareResultStatus.dismissed;
        await tester.tap(shareBtn);
        await settle(tester);
        expect(find.textContaining('Sharing was cancelled'), findsOneWidget);

        // Unavailable share shows clear error message.
        shareStatus = ShareResultStatus.unavailable;
        await tester.tap(shareBtn);
        await settle(tester);
        expect(find.textContaining('Sharing is not available'), findsOneWidget);
      },
    );

    testWidgets(
      'opt-in diagnostics appear in share draft and Email support appears only with valid config',
      (tester) async {
        AppConfig.overrideBaseUrl('https://account.example.test');
        AppConfig.overrideSupportEmail('help@example.test');
        AppConfig.overrideZaloCommunityUrl('https://zalo.me/g/learners123');
        await tester.runAsync(feedback.refresh);

        tester.view.physicalSize = const Size(600, 1800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        ShareParams? capturedShare;
        Uri? capturedMailUri;
        var launchOk = true;
        FeedbackService.overrideHandlers(
          share: (params) async {
            capturedShare = params;
            return const ShareResult('ok', ShareResultStatus.success);
          },
          launch: (uri, {required mode}) async {
            expect(mode, LaunchMode.externalApplication);
            capturedMailUri = uri;
            return launchOk;
          },
        );

        await tester.pumpWidget(wrap(const FeedbackScreen()));
        await settle(tester);

        expect(httpRequests, isEmpty);
        expect(find.byKey(const Key('email_support_draft')), findsOneWidget);
        expect(
          find.byKey(const Key('feedback_zalo_community')),
          findsOneWidget,
        );

        await tester.enterText(
          find.byKey(const Key('feedback_message')),
          'Please improve dark mode contrast on cards.',
        );
        await tester.tap(find.byKey(const Key('feedback_optional_details')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('feedback_include_diagnostics')));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('share_feedback_draft')));
        await settle(tester);
        expect(capturedShare?.text, contains('App details:'));
        expect(capturedShare?.text, contains('App version:'));
        expect(capturedShare?.text, contains('Platform:'));
        expect(capturedShare?.text, isNot(contains('acct-uuid-9999')));
        expect(capturedShare?.text, isNot(contains('serendipity')));

        await tester.tap(find.byKey(const Key('email_support_draft')));
        await settle(tester);
        expect(capturedMailUri?.scheme, 'mailto');
        expect(capturedMailUri?.path, 'help@example.test');
        expect(
          capturedMailUri?.queryParameters['body'],
          contains('Please improve dark mode contrast on cards.'),
        );
        expect(
          capturedMailUri?.queryParameters['body'],
          contains('App details:'),
        );

        // Mail app unavailable surfaces a clear message.
        launchOk = false;
        await tester.tap(find.byKey(const Key('email_support_draft')));
        await settle(tester);
        expect(
          find.textContaining('No email app is available'),
          findsOneWidget,
        );
      },
    );
  });

  group('Responsive layout and dark mode', () {
    final variants = [
      (name: 'phone', size: const Size(390, 844), scale: 1.0, dark: false),
      (name: 'large_text', size: const Size(320, 568), scale: 2.0, dark: false),
      (name: 'landscape', size: const Size(740, 360), scale: 1.0, dark: false),
      (name: 'dark', size: const Size(390, 844), scale: 1.0, dark: true),
    ];

    for (final v in variants) {
      testWidgets('PrivacyPolicyScreen fits ${v.name}', (tester) async {
        tester.view.physicalSize = v.size;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        AppConfig.overridePrivacyPolicyUrl('https://example.test/privacy');
        AppConfig.overrideSupportEmail('help@example.test');
        await tester.pumpWidget(
          wrap(const PrivacyPolicyScreen(), scale: v.scale, dark: v.dark),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });

      testWidgets('FeedbackScreen fits ${v.name}', (tester) async {
        tester.view.physicalSize = v.size;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        AppConfig.overrideSupportEmail('help@example.test');
        await tester.runAsync(
          () => feedback.submit(
            kind: 'bug',
            message: 'Saved report to check responsive card layout.',
            diagnostics: true,
          ),
        );
        await tester.pumpWidget(
          wrap(const FeedbackScreen(), scale: v.scale, dark: v.dark),
        );
        await settle(tester);
        expect(tester.takeException(), isNull);
      });
    }
  });
}
