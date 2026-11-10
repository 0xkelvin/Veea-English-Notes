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
import 'package:veea_english_app/data/local/sqlite_vocabulary_repository.dart';
import 'package:veea_english_app/data/remote/api_client.dart';
import 'package:veea_english_app/data/remote/auth_api.dart';
import 'package:veea_english_app/data/remote/vocabulary_api.dart';
import 'package:veea_english_app/models/vocabulary_word.dart';
import 'package:veea_english_app/providers/auth_provider.dart';
import 'package:veea_english_app/providers/vocabulary_provider.dart';
import 'package:veea_english_app/screens/phone_account_screen.dart';
import 'package:veea_english_app/services/sync_service.dart';
import '../support/fake_token_store.dart';

const accountA = '11111111-1111-1111-1111-111111111111';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  late SqliteVocabularyRepository repo;
  late VocabularyProvider vocabulary;
  late AuthProvider auth;
  late SyncService sync;
  late FakeTokenStore tokens;
  final paths = <String>[];

  http.Response ok(Object data) =>
      http.Response(jsonEncode({'data': data}), 200);
  Map<String, Object?> challenge(String id) => {
    'challenge_id': id,
    'expires_in': 600,
    'retry_after': 60,
  };

  Future<void> build({
    required bool signedIn,
    String baseUrl = 'https://veea.test',
  }) async {
    SharedPreferences.setMockInitialValues({});
    AppConfig.overrideBaseUrl(baseUrl);
    paths.clear();
    var profilePhone = '+84901234567';
    repo = await SqliteVocabularyRepository.open(path: inMemoryDatabasePath);
    tokens = FakeTokenStore();
    if (signedIn) {
      await repo.activateNotebook(accountA);
      await repo.insert(
        VocabularyWord.create(
          id: 'a-word',
          word: 'resilient',
          meaning: 'kiên cường',
          date: '2026-11-10',
          now: DateTime(2026, 11, 10),
        ),
      );
      tokens
        ..accessToken = 'access'
        ..refreshToken = 'refresh'
        ..identifier = '+84901234567'
        ..accountId = accountA
        ..authMethod = 'phone_otp';
    }
    vocabulary = VocabularyProvider(repo);
    await vocabulary.init();
    final client = ApiClient(
      tokenStore: tokens,
      baseUrl: '$baseUrl/api/v1',
      httpClient: MockClient((r) async {
        final p = r.url.path;
        paths.add(p);
        if (p.endsWith('/config')) return ok({'phone_otp_available': true});
        if (p.endsWith('/current-code')) return ok(challenge('current'));
        if (p.endsWith('/current-verify')) {
          return ok({'proof_id': 'proof', 'expires_in': 900});
        }
        if (p.endsWith('/new-code')) return ok(challenge('new'));
        if (p.endsWith('/phone-change/confirm')) {
          profilePhone = '+84987654321';
          return ok({
            'user_id': accountA,
            'identifier': '+84987654321',
            'auth_method': 'phone_otp',
            'tokens': {'access_token': 'a2', 'refresh_token': 'r2'},
          });
        }
        if (p.endsWith('/delete-otp') && r.method == 'POST') {
          return ok(challenge('delete'));
        }
        if (p.endsWith('/delete-otp') && r.method == 'DELETE') {
          return http.Response('', 204);
        }
        if (p.endsWith('/users/me')) {
          return ok({
            'id': accountA,
            'phone': profilePhone,
            'auth_method': 'phone_otp',
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
    await auth.restore();
  }

  tearDown(() async {
    AppConfig.overrideBaseUrl(null);
    auth.dispose();
    sync.dispose();
    vocabulary.dispose();
    await repo.close();
  });

  Widget wrap({double scale = 1, bool dark = false}) => MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: vocabulary),
      ChangeNotifierProvider.value(value: auth),
      ChangeNotifierProvider.value(value: sync),
    ],
    child: MaterialApp(
      theme: dark ? PixelTheme.dark() : PixelTheme.light(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: const AccountScreen(),
    ),
  );

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, Finder finder) async {
    if (finder.evaluate().isEmpty) {
      await tester.scrollUntilVisible(
        finder,
        200,
        scrollable: find.byType(Scrollable).last,
      );
    }
    await tester.ensureVisible(finder);
    await tester.runAsync(() async {
      await tester.tap(finder);
      await Future<void>.delayed(const Duration(milliseconds: 150));
    });
    await settle(tester);
  }

  testWidgets(
    'with no API configured: coming soon, no form, no backup promise',
    (tester) async {
      await tester.runAsync(() => build(signedIn: false, baseUrl: ''));
      await tester.pumpWidget(wrap());
      await settle(tester);
      expect(find.textContaining('coming soon'), findsOneWidget);
      expect(find.byKey(const Key('account_phone')), findsNothing);
      expect(find.textContaining('notebooks stay separate'), findsNothing);
      expect(paths, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'signed-out form shows steps and the backup note when available',
    (tester) async {
      await tester.runAsync(() => build(signedIn: false));
      await tester.pumpWidget(wrap());
      await settle(tester);
      expect(find.text('Step 1 of 2 · Your phone number'), findsOneWidget);
      expect(find.textContaining('notebooks stay separate'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('signed in: retention copy and change-phone 3-step flow', (
    tester,
  ) async {
    await tester.runAsync(() => build(signedIn: true));
    await tester.pumpWidget(wrap());
    await settle(tester);
    expect(
      find.textContaining(
        'Words you add while signed out stay in this notebook',
      ),
      findsOneWidget,
    );
    await tap(tester, find.byKey(const Key('change_phone_entry')));
    expect(find.text('Step 1 of 3'), findsOneWidget);
    expect(find.textContaining('contact Veea support'), findsOneWidget);
    await tap(tester, find.byKey(const Key('change_current_send')));
    await tester.enterText(
      find.byKey(const Key('change_current_code')),
      '111111',
    );
    await tap(tester, find.byKey(const Key('change_current_verify')));
    expect(find.text('Step 2 of 3'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('change_new_phone')),
      '0987654321',
    );
    await tap(tester, find.byKey(const Key('change_new_send')));
    expect(find.text('Step 3 of 3'), findsOneWidget);
    expect(find.textContaining('+84987654321'), findsWidgets);
    await tester.enterText(find.byKey(const Key('change_new_code')), '222222');
    await tap(tester, find.byKey(const Key('change_new_confirm')));
    expect(find.text('Number changed'), findsOneWidget);
    expect(auth.accountId, accountA);
    expect(tokens.refreshToken, 'r2');
    await tap(tester, find.byKey(const Key('change_done')));
    await tester.drag(find.byType(Scrollable).first, const Offset(0, 1200));
    await settle(tester);
    expect(find.text('+84987654321'), findsOneWidget);
    expect(vocabulary.stats.totalWords, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'delete: fresh code, explicit final confirmation, guest afterwards',
    (tester) async {
      await tester.runAsync(() => build(signedIn: true));
      await tester.pumpWidget(wrap());
      await settle(tester);
      await tap(tester, find.byKey(const Key('delete_account_entry')));
      expect(find.textContaining('Feedback you already sent'), findsOneWidget);
      await tap(tester, find.byKey(const Key('delete_continue')));
      expect(paths.where((p) => p.endsWith('/delete-otp')), hasLength(1));
      await tester.enterText(find.byKey(const Key('delete_code')), '123456');
      await tap(tester, find.byKey(const Key('delete_confirm')));
      expect(find.text('Delete permanently?'), findsOneWidget);
      // Cancelling the final confirmation deletes nothing.
      await tap(tester, find.text('Cancel'));
      expect(auth.isSignedIn, isTrue);
      await tap(tester, find.byKey(const Key('delete_confirm')));
      await tap(tester, find.byKey(const Key('delete_final')));
      expect(auth.isSignedIn, isFalse);
      expect(vocabulary.stats.totalWords, 0);
      expect(find.textContaining('were deleted'), findsOneWidget);
      expect(find.byKey(const Key('account_phone')), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'phone change remains usable on a small screen with large text and keyboard',
    (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      tester.view.viewInsets = const FakeViewPadding(bottom: 200);
      addTearDown(tester.view.reset);
      await tester.runAsync(() => build(signedIn: true));
      await tester.pumpWidget(wrap(scale: 2, dark: true));
      await settle(tester);
      await tap(tester, find.byKey(const Key('change_phone_entry')));
      await tap(tester, find.byKey(const Key('change_current_send')));
      await tester.enterText(
        find.byKey(const Key('change_current_code')),
        '111111',
      );
      await tap(tester, find.byKey(const Key('change_current_verify')));
      await tester.enterText(
        find.byKey(const Key('change_new_phone')),
        '0987654321',
      );
      await tap(tester, find.byKey(const Key('change_new_send')));
      expect(find.text('Step 3 of 3'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
