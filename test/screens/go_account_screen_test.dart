import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:veea_english_app/core/config/app_config.dart';
import 'package:veea_english_app/data/local/sqlite_vocabulary_repository.dart';
import 'package:veea_english_app/providers/auth_provider.dart';
import 'package:veea_english_app/providers/vocabulary_provider.dart';
import 'package:veea_english_app/services/sync_service.dart';
import 'package:veea_english_app/screens/phone_account_screen.dart';
import 'package:veea_english_app/screens/go_account_screen.dart';
import '../data/go_session_test.dart' show tokens, userA;
import '../support/go_account_stack.dart';
import '../support/secure_storage.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  late GoAccountStack app;
  late VocabularyProvider vocabulary;
  late List<String> paths;
  late List<Map<String, dynamic>> requestBodies;
  late DateTime resendAfter;
  late DateTime expiresAt;
  setUp(() async {
    AppConfig.overrideBaseUrl('http://localhost');
    paths = [];
    requestBodies = [];
    resendAfter = DateTime.now().toUtc().subtract(const Duration(seconds: 1));
    expiresAt = DateTime.now().toUtc().add(const Duration(minutes: 10));
    app = GoAccountStack(
      await SqliteVocabularyRepository.open(path: inMemoryDatabasePath),
      TestSecureStorage(),
      'http://localhost',
      network: MockClient((request) async {
        paths.add(request.url.path);
        if (request.body.isNotEmpty) {
          requestBodies.add(jsonDecode(request.body) as Map<String, dynamic>);
        }
        if (request.url.path.endsWith('/password/login')) {
          return http.Response(jsonEncode(tokens()), 200);
        }
        if (request.url.path.endsWith('/start')) {
          return http.Response(
            jsonEncode({
              'challenge_token': 'vct_${'c' * 43}',
              'expires_at': expiresAt.toIso8601String(),
              'resend_after': resendAfter.toIso8601String(),
            }),
            202,
          );
        }
        return http.Response('{"code":"sync_unavailable"}', 503);
      }),
    );
    await app.auth.restore();
    vocabulary = VocabularyProvider(app.repo);
    await vocabulary.init();
  });
  tearDown(() async {
    await app.close();
    vocabulary.dispose();
    AppConfig.overrideBaseUrl(null);
  });
  Widget build({DateTime Function()? now}) => MultiProvider(
    providers: [
      ChangeNotifierProvider<AuthProvider>.value(value: app.auth),
      ChangeNotifierProvider<SyncService>.value(value: app.sync),
      ChangeNotifierProvider<VocabularyProvider>.value(value: vocabulary),
    ],
    child: MaterialApp(
      home: now == null ? const AccountScreen() : GoAccountScreen(now: now),
    ),
  );
  testWidgets(
    'production account entry selects email Go UI without phone configuration requests',
    (tester) async {
      await tester.pumpWidget(build());
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('go_email')), findsOneWidget);
      expect(find.text('Sign in with email'), findsOneWidget);
      expect(paths, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'email signup waits for Go verification instead of selecting an account',
    (tester) async {
      await tester.pumpWidget(build());
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('go_email')),
        'synthetic@example.test',
      );
      await tester.tap(find.text('Create an account'));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('go_signin')));
        await Future<void>.delayed(const Duration(milliseconds: 60));
      });
      await tester.pumpAndSettle();
      expect(paths, ['/v1/auth/signup/otp/start']);
      expect(find.byKey(const Key('go_verify')), findsOneWidget);
      expect(app.auth.isSignedIn, isFalse);
      expect(await tester.runAsync(app.store.readSession), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'email code cooldown unlocks without typing or leaving the screen',
    (tester) async {
      var now = DateTime.utc(2026, 11, 24);
      resendAfter = now.add(const Duration(seconds: 2));
      expiresAt = now.add(const Duration(minutes: 10));
      await tester.pumpWidget(build(now: () => now));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('go_email')),
        'synthetic@example.test',
      );
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('go_signin')));
        await Future<void>.delayed(const Duration(milliseconds: 60));
      });
      await tester.pumpAndSettle();
      expect(find.text('Resend code in 2s'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byKey(const Key('go_email'))).enabled,
        isFalse,
      );
      now = now.add(const Duration(seconds: 2));
      await tester.pump(const Duration(seconds: 2));
      final resend = find.widgetWithText(TextButton, 'Resend code');
      expect(tester.widget<TextButton>(resend).onPressed, isNotNull);
      expect(paths, ['/v1/auth/otp/start']);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'password signup resend retains its password and changing email clears it',
    (tester) async {
      await tester.pumpWidget(build());
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('go_email')),
        'synthetic@example.test',
      );
      await tester.tap(find.text('Create an account'));
      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('go_password')),
        'Synthetic-only-password-42!',
      );
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('go_signin')));
        await Future<void>.delayed(const Duration(milliseconds: 60));
      });
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.text('Resend code'));
        await Future<void>.delayed(const Duration(milliseconds: 60));
      });
      await tester.pumpAndSettle();
      expect(paths, [
        '/v1/auth/signup/password/start',
        '/v1/auth/signup/password/start',
      ]);
      expect(requestBodies, [
        {
          'email': 'synthetic@example.test',
          'password': 'Synthetic-only-password-42!',
        },
        {
          'email': 'synthetic@example.test',
          'password': 'Synthetic-only-password-42!',
        },
      ]);
      await tester.tap(find.text('Use another email'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('go_password')))
            .controller!
            .text,
        isEmpty,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'apparent expiry never blocks verification when the phone clock is ahead',
    (tester) async {
      var now = DateTime.utc(2026, 11, 24);
      resendAfter = now;
      expiresAt = now.add(const Duration(seconds: 2));
      await tester.pumpWidget(build(now: () => now));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('go_email')),
        'synthetic@example.test',
      );
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('go_signin')));
        await Future<void>.delayed(const Duration(milliseconds: 60));
      });
      await tester.pumpAndSettle();
      now = now.add(const Duration(seconds: 2));
      await tester.pump(const Duration(seconds: 2));
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('go_verify')))
            .onPressed,
        isNotNull,
      );
      expect(
        find.text(
          'This code may have expired. You can try it or request a new code.',
        ),
        findsOneWidget,
      );
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Resend code'))
            .onPressed,
        isNotNull,
      );
      expect(paths, ['/v1/auth/otp/start']);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'Go password sign-in selects response UUID and sign-out opens guest',
    (tester) async {
      await tester.pumpWidget(build());
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('go_email')),
        'synthetic@example.test',
      );
      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('go_password')),
        'synthetic-only',
      );
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('go_signin')));
        await Future<void>.delayed(const Duration(milliseconds: 60));
      });
      await tester.pumpAndSettle();
      expect(app.auth.accountId, userA);
      expect(paths, contains('/v1/auth/password/login'));
      expect(find.byKey(const Key('go_account_email')), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(find.text('Sign out'));
        await app.auth.notebookSettled;
        await Future<void>.delayed(const Duration(milliseconds: 60));
      });
      await tester.pumpAndSettle();
      expect(await tester.runAsync(app.repo.notebookOwner), isNull);
      expect(app.auth.isSignedIn, isFalse);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
