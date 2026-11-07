import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:veea_english_app/core/config/app_config.dart';
import 'package:veea_english_app/core/theme/pixel_theme.dart';
import 'package:veea_english_app/data/feedback_repository.dart';
import 'package:veea_english_app/data/local/sqlite_vocabulary_repository.dart';
import 'package:veea_english_app/data/remote/api_client.dart';
import 'package:veea_english_app/data/remote/auth_api.dart';
import 'package:veea_english_app/data/remote/vocabulary_api.dart';
import 'package:veea_english_app/providers/auth_provider.dart';
import 'package:veea_english_app/providers/feedback_provider.dart';
import 'package:veea_english_app/providers/vocabulary_provider.dart';
import 'package:veea_english_app/screens/phone_account_screen.dart';
import 'package:veea_english_app/screens/feedback_screen.dart';
import 'package:veea_english_app/services/sync_service.dart';
import '../support/fake_token_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  late SqliteVocabularyRepository repo;
  late VocabularyProvider vocabulary;
  late AuthProvider auth;
  late SyncService sync;
  late FeedbackProvider feedback;
  late FakeTokenStore tokens;
  http.Response ok(Object data) =>
      http.Response(jsonEncode({'data': data}), 200);
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    AppConfig.overrideBaseUrl('https://veea.test');
    repo = await SqliteVocabularyRepository.open(path: inMemoryDatabasePath);
    vocabulary = VocabularyProvider(repo);
    await vocabulary.init();
    tokens = FakeTokenStore();
    final client = ApiClient(
      tokenStore: tokens,
      baseUrl: 'https://veea.test/api/v1',
      httpClient: MockClient((r) async {
        if (r.url.path.endsWith('/config')) {
          return ok({'phone_otp_available': true});
        }
        if (r.url.path.endsWith('/request')) {
          return ok({
            'challenge_id': 'challenge',
            'expires_in': 600,
            'retry_after': 60,
          });
        }
        if (r.url.path.endsWith('/verify')) {
          if ((jsonDecode(r.body) as Map)['code'] != '123456') {
            return http.Response(
              jsonEncode({
                'error': {'message': 'That code is incorrect or expired'},
              }),
              400,
            );
          }
          return ok({
            'user_id': 'account-A',
            'identifier': '+84901234567',
            'tokens': {'access_token': 'access', 'refresh_token': 'refresh'},
          });
        }
        if (r.url.path.endsWith('/sync')) {
          return ok({
            'accepted': [],
            'changes': [],
            'cursor': '0',
            'serverTime': DateTime.now().toUtc().toIso8601String(),
            'hasMore': false,
          });
        }
        return http.Response('{}', 204);
      }),
    );
    sync = SyncService(repository: repo, api: VocabularyApi(client));
    auth = AuthProvider(
      authApi: AuthApi(client: client, tokens: tokens),
      tokens: tokens,
      client: client,
      repository: repo,
      sync: sync,
    );
    feedback = FeedbackProvider(FeedbackRepository(repo.database, client));
  });
  tearDown(() async {
    AppConfig.overrideBaseUrl(null);
    auth.dispose();
    sync.dispose();
    feedback.dispose();
    vocabulary.dispose();
    await repo.close();
  });
  Widget wrap(Widget screen) => MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: vocabulary),
      ChangeNotifierProvider.value(value: auth),
      ChangeNotifierProvider.value(value: sync),
      ChangeNotifierProvider.value(value: feedback),
    ],
    child: MaterialApp(theme: PixelTheme.light(), home: screen),
  );
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
  }

  Future<void> send(WidgetTester tester) async {
    await tester.enterText(
      find.byKey(const Key('account_phone')),
      '0901234567',
    );
    await tester.ensureVisible(find.byKey(const Key('send_account_otp')));
    await tester.tap(find.byKey(const Key('send_account_otp')));
    await settle(tester);
  }

  testWidgets(
    'phone sign in validates, supports OTP autofill, errors and changing number',
    (tester) async {
      await tester.pumpWidget(wrap(const AccountScreen()));
      await settle(tester);
      await tester.tap(find.byKey(const Key('send_account_otp')));
      await settle(tester);
      expect(find.textContaining('Enter a Vietnamese'), findsOneWidget);
      await send(tester);
      expect(find.byKey(const Key('account_otp')), findsOneWidget);
      expect(find.textContaining('Resend in'), findsOneWidget);
      final otp = tester.widget<TextField>(
        find.byKey(const Key('account_otp')),
      );
      expect(otp.autofillHints, contains(AutofillHints.oneTimeCode));
      await tester.enterText(find.byKey(const Key('account_otp')), '111111');
      await tester.ensureVisible(find.byKey(const Key('verify_account_otp')));
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('verify_account_otp')));
        await Future<void>.delayed(const Duration(milliseconds: 150));
      });
      await settle(tester);
      expect(find.textContaining('incorrect or expired'), findsOneWidget);
      expect(auth.isSignedIn, false);
      await tester.ensureVisible(find.text('Use another number'));
      await tester.tap(find.text('Use another number'));
      await settle(tester);
      expect(find.byKey(const Key('account_phone')), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'successful verification opens account and signout resets consumed code',
    (tester) async {
      await tester.pumpWidget(wrap(const AccountScreen()));
      await settle(tester);
      await send(tester);
      await tester.enterText(find.byKey(const Key('account_otp')), '123456');
      await tester.ensureVisible(find.byKey(const Key('verify_account_otp')));
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('verify_account_otp')));
        await Future<void>.delayed(const Duration(milliseconds: 150));
      });
      await settle(tester);
      expect(auth.isSignedIn, true);
      expect(find.text('Phone verified'), findsOneWidget);
      expect(await tokens.readAccountId(), 'account-A');
      await tester.ensureVisible(find.text('Sign out'));
      await tester.tap(find.text('Sign out'));
      await settle(tester);
      expect(auth.isSignedIn, false);
      expect(find.byKey(const Key('account_phone')), findsOneWidget);
      expect(find.byKey(const Key('account_otp')), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'feedback saves locally without signing in and exposes a queued receipt',
    (tester) async {
      AppConfig.overrideBaseUrl('');
      await tester.pumpWidget(wrap(const FeedbackScreen()));
      await settle(tester);
      await tester.enterText(
        find.byKey(const Key('feedback_message')),
        'Please let me study with a desktop app.',
      );
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('submit_feedback')));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('submit_feedback')));
        await Future<void>.delayed(const Duration(milliseconds: 150));
      });
      await settle(tester);
      expect(feedback.reports, hasLength(1));
      expect(feedback.reports.single.queued, true);
      expect(auth.isSignedIn, false);
      await tester.ensureVisible(find.text('Waiting to send'));
      expect(find.text('Waiting to send'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
