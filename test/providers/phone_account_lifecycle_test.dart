import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:veea_english_app/core/config/app_config.dart';
import 'package:veea_english_app/data/local/sqlite_vocabulary_repository.dart';
import 'package:veea_english_app/data/remote/api_client.dart';
import 'package:veea_english_app/data/remote/auth_api.dart';
import 'package:veea_english_app/data/remote/token_store.dart';
import 'package:veea_english_app/data/remote/vocabulary_api.dart';
import 'package:veea_english_app/models/vocabulary_word.dart';
import 'package:veea_english_app/providers/auth_provider.dart';
import 'package:veea_english_app/providers/phone_auth_controller.dart';
import 'package:veea_english_app/services/sync_service.dart';

import '../support/fake_token_store.dart';

const accountA = '11111111-1111-1111-1111-111111111111';
const accountB = '22222222-2222-2222-2222-222222222222';

/// One scripted reply per path suffix; every request is recorded.
class ScriptedServer {
  final requests = <http.Request>[];
  final replies = <String, http.Response Function(http.Request)>{};

  void on(String suffix, http.Response Function(http.Request) reply) =>
      replies[suffix] = reply;

  Map<String, Object?> bodyOf(String suffix) =>
      jsonDecode(requests.lastWhere((r) => r.url.path.endsWith(suffix)).body)
          as Map<String, Object?>;

  int count(String suffix) =>
      requests.where((r) => r.url.path.endsWith(suffix)).length;

  MockClient get client => MockClient((request) async {
    requests.add(request);
    for (final entry in replies.entries) {
      if (request.url.path.endsWith(entry.key)) return entry.value(request);
    }
    return http.Response('{}', 404);
  });
}

http.Response ok(Object data) => http.Response(
  jsonEncode({'data': data}),
  200,
  headers: {'content-type': 'application/json'},
);

http.Response fail(int status, String message, {String code = 'ERROR'}) =>
    http.Response(
      jsonEncode({
        'error': {'code': code, 'message': message},
      }),
      status,
      headers: {'content-type': 'application/json'},
    );

http.Response offline(http.Request _) => throw http.ClientException('offline');

Map<String, Object?> challenge([String id = 'challenge']) => {
  'challenge_id': id,
  'expires_in': 600,
  'retry_after': 60,
};

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  TestWidgetsFlutterBinding.ensureInitialized();

  final today = DateTime(2026, 11, 10, 9);
  late DateTime authNow;
  late FakeTokenStore tokens;
  late SqliteVocabularyRepository repo;
  late ScriptedServer server;

  setUp(() async {
    authNow = today;
    SharedPreferences.setMockInitialValues({});
    AppConfig.overrideBaseUrl('https://veea.test');
    server = ScriptedServer();
    tokens = FakeTokenStore();
    repo = await SqliteVocabularyRepository.open(
      path: inMemoryDatabasePath,
      now: () => today,
    );
  });

  tearDown(() async {
    AppConfig.overrideBaseUrl(null);
    await repo.close();
  });

  AuthProvider provider() {
    final client = ApiClient(
      tokenStore: tokens,
      httpClient: server.client,
      baseUrl: 'https://veea.test/api/v1',
    );
    return AuthProvider(
      now: () => authNow,
      authApi: AuthApi(client: client, tokens: tokens),
      tokens: tokens,
      client: client,
      repository: repo,
      sync: SyncService(
        repository: repo,
        api: VocabularyApi(client),
        now: () => today,
      ),
    );
  }

  Future<void> seed(String id) => repo.insert(
    VocabularyWord.create(
      id: id,
      word: 'resilient',
      meaning: 'kiên cường',
      date: '2026-11-10',
      now: today,
    ),
  );

  Future<List<String>> wordIds() async =>
      (await repo.recentWords()).map((w) => w.id).toList();

  Future<List<String>> archives() async => (await repo.database.query(
    'account_workspaces',
  )).map((r) => r['account_id'] as String).toList();

  /// Signed in as phone account A with A's notebook active.
  Future<AuthProvider> signedInAsA() async {
    await repo.activateNotebook(accountA);
    await seed('a-word');
    tokens
      ..accessToken = 'access-A'
      ..refreshToken = 'refresh-A'
      ..identifier = '+84901234567'
      ..accountId = accountA
      ..authMethod = 'phone_otp'
      ..lastAccount = accountA;
    final auth = provider();
    await auth.restore();
    return auth;
  }

  group('phone sign-in / sign-up (one flow)', () {
    test('sends the normalized phone and stores the server UUID', () async {
      server
        ..on('/otp/request', (_) => ok(challenge()))
        ..on(
          '/otp/verify',
          (_) => ok({
            'user_id': accountA,
            'identifier': '+84901234567',
            'auth_method': 'phone_otp',
            'tokens': {'access_token': 'a', 'refresh_token': 'r'},
          }),
        );
      final auth = provider();
      final flow = PhoneAuthController(auth)..available = true;
      expect(await flow.send('090 123 4567'), isTrue);
      expect(server.bodyOf('/otp/request'), {'phone': '+84901234567'});
      expect(await flow.verify('123456'), isTrue);
      expect(server.bodyOf('/otp/verify'), {
        'challenge_id': 'challenge',
        'code': '123456',
      });
      expect(auth.isSignedIn, isTrue);
      expect(tokens.accountId, accountA);
      expect(tokens.authMethod, 'phone_otp');
      flow.dispose();
    });

    test('a guest notebook is adopted by the first sign-in', () async {
      await seed('guest-word');
      server.on(
        '/otp/verify',
        (_) => ok({
          'user_id': accountA,
          'identifier': '+84901234567',
          'tokens': {'access_token': 'a', 'refresh_token': 'r'},
        }),
      );
      final auth = provider();
      expect(
        await auth.verifyPhone(
          const OtpChallenge(id: 'c', expiresIn: 600, retryAfter: 60),
          '123456',
        ),
        isTrue,
      );
      expect(await wordIds(), ['guest-word']);
    });

    test('OTP errors are phone-specific, never "password"', () async {
      final auth = provider();
      const c = OtpChallenge(id: 'c', expiresIn: 600, retryAfter: 60);
      server.on(
        '/otp/verify',
        (_) => fail(400, 'That code is incorrect or expired.'),
      );
      expect(await auth.verifyPhone(c, '000000'), isFalse);
      expect(auth.lastError, contains('incorrect or expired'));
      expect(auth.lastError, isNot(contains('password')));

      server.on('/otp/verify', (_) => fail(429, 'Too many requests'));
      expect(await auth.verifyPhone(c, '000000'), isFalse);
      expect(auth.lastError, contains('Too many attempts'));

      server.on(
        '/otp/verify',
        (_) => fail(409, 'This older account needs a migration.'),
      );
      expect(await auth.verifyPhone(c, '000000'), isFalse);
      expect(auth.lastError, contains('older account'));

      server.on('/otp/verify', offline);
      expect(await auth.verifyPhone(c, '000000'), isFalse);
      expect(auth.lastError, contains('saved on this device'));
      expect(auth.isSignedIn, isFalse);
    });

    test('send rate limit starts a cooldown', () async {
      server.on('/otp/request', (_) => fail(429, 'Too many requests'));
      final flow = PhoneAuthController(provider())..available = true;
      expect(await flow.send('0901234567'), isFalse);
      expect(flow.error, contains('Too many requests'));
      expect(flow.retryIn, greaterThan(0));
      expect(await flow.send('0901234567'), isFalse);
      expect(server.count('/otp/request'), 1);
      flow.dispose();
    });
  });

  group('OTP timers', () {
    testWidgets('expiry is announced without user input and blocks verify', (
      tester,
    ) async {
      var now = today;
      server.on(
        '/otp/request',
        (_) => ok({'challenge_id': 'c', 'expires_in': 120, 'retry_after': 30}),
      );
      final flow = PhoneAuthController(provider(), now: () => now)
        ..available = true;
      var notified = 0;
      flow.addListener(() => notified++);
      // Runs in the fake-async zone so pump() drives the countdown ticker.
      final sent = flow.send('0901234567');
      await tester.pump();
      expect(await sent, isTrue);
      expect(flow.retryIn, 30);
      now = now.add(const Duration(seconds: 31));
      await tester.pump(const Duration(seconds: 1));
      expect(flow.retryIn, 0);
      expect(flow.expired, isFalse);
      expect(flow.error, isNull);
      // Earlier versions stopped ticking here, so expiry was never shown.
      now = now.add(const Duration(seconds: 90));
      final before = notified;
      await tester.pump(const Duration(seconds: 1));
      expect(notified, greaterThan(before));
      expect(flow.expired, isTrue);
      expect(flow.error, codeExpiredMessage);
      expect(await flow.verify('123456'), isFalse);
      expect(server.count('/otp/verify'), 0);
      flow.dispose();
      await tester.pump(const Duration(seconds: 2)); // no tick after dispose
    });
  });

  group('verified phone change', () {
    void scriptHappyPath({String confirmedAccount = accountA}) {
      server
        ..on('/phone-change/current-code', (_) => ok(challenge('current')))
        ..on(
          '/phone-change/current-verify',
          (_) => ok({'proof_id': 'proof', 'expires_in': 900}),
        )
        ..on('/phone-change/new-code', (_) => ok(challenge('new')))
        ..on(
          '/phone-change/confirm',
          (_) => ok({
            'user_id': confirmedAccount,
            'identifier': '+84987654321',
            'auth_method': 'phone_otp',
            'revoked_sessions': 2,
            'tokens': {
              'access_token': 'access-2',
              'refresh_token': 'refresh-2',
            },
          }),
        );
    }

    test(
      'keeps the same UUID, notebook and cursor; stores the replacement session',
      () async {
        final auth = await signedInAsA();
        final prefsBefore = (await SharedPreferences.getInstance()).getKeys();
        scriptHappyPath();
        final flow = PhoneChangeController(auth);
        expect(await flow.sendCurrentCode(), isTrue);
        expect(flow.step, PhoneChangeStep.confirmCurrent);
        expect(await flow.verifyCurrent('111111'), isTrue);
        expect(server.bodyOf('/phone-change/current-verify'), {
          'challenge_id': 'current',
          'code': '111111',
        });
        expect(flow.step, PhoneChangeStep.enterNew);
        expect(await flow.sendNewCode('0987 654 321'), isTrue);
        expect(server.bodyOf('/phone-change/new-code'), {
          'proof_id': 'proof',
          'new_phone': '+84987654321',
        });
        expect(flow.step, PhoneChangeStep.verifyNew);
        expect(await flow.confirm('222222'), isTrue);
        expect(server.bodyOf('/phone-change/confirm'), {
          'challenge_id': 'new',
          'code': '222222',
        });
        expect(flow.step, PhoneChangeStep.done);
        expect(auth.isSignedIn, isTrue);
        expect(auth.accountId, accountA);
        expect(auth.identifier, '+84987654321');
        expect(tokens.accountId, accountA);
        expect(tokens.refreshToken, 'refresh-2');
        expect(tokens.identifier, '+84987654321');
        expect(await wordIds(), ['a-word']);
        expect(await archives(), isEmpty, reason: 'no notebook switch');
        expect(
          (await SharedPreferences.getInstance()).getKeys(),
          containsAll(prefsBefore),
          reason: 'sync cursor kept',
        );
        // All requests on the authenticated routes carried the session.
        for (final r in server.requests) {
          expect(r.headers['authorization'], 'Bearer access-A');
        }
        flow.dispose();
      },
    );

    test('a replacement session for another UUID is never stored', () async {
      final auth = await signedInAsA();
      scriptHappyPath(confirmedAccount: accountB);
      final flow = PhoneChangeController(auth);
      await flow.sendCurrentCode();
      await flow.verifyCurrent('111111');
      await flow.sendNewCode('0987654321');
      expect(await flow.confirm('222222'), isFalse);
      expect(flow.blocked, isTrue);
      expect(flow.error, contains('nothing on this device was changed'));
      expect(tokens.refreshToken, 'refresh-A');
      expect(tokens.accountId, accountA);
      expect(auth.accountId, accountA);
      expect(auth.identifier, '+84901234567');
      expect(await wordIds(), ['a-word']);
      flow.dispose();
    });

    test('wrong current-phone code stays on step 1', () async {
      final auth = await signedInAsA();
      scriptHappyPath();
      server.on(
        '/phone-change/current-verify',
        (_) => fail(400, 'That code is incorrect or expired.'),
      );
      final flow = PhoneChangeController(auth);
      await flow.sendCurrentCode();
      expect(await flow.verifyCurrent('000000'), isFalse);
      expect(flow.step, PhoneChangeStep.confirmCurrent);
      expect(flow.error, contains('incorrect'));
      expect(flow.proof, isNull);
      flow.dispose();
    });

    test('same number and invalid numbers never reach the server', () async {
      final auth = await signedInAsA();
      scriptHappyPath();
      final flow = PhoneChangeController(auth);
      await flow.sendCurrentCode();
      await flow.verifyCurrent('111111');
      expect(await flow.sendNewCode('0901234567'), isFalse);
      expect(flow.error, contains('already your number'));
      expect(await flow.sendNewCode('12345'), isFalse);
      expect(flow.error, contains('Vietnamese mobile'));
      expect(server.count('/phone-change/new-code'), 0);
      flow.dispose();
    });

    test(
      'a taken new number goes back to number entry, keeping the proof',
      () async {
        final auth = await signedInAsA();
        scriptHappyPath();
        server.on(
          '/phone-change/confirm',
          (_) =>
              fail(409, 'That number is already used by another Veea account.'),
        );
        final flow = PhoneChangeController(auth);
        await flow.sendCurrentCode();
        await flow.verifyCurrent('111111');
        await flow.sendNewCode('0987654321');
        expect(await flow.confirm('222222'), isFalse);
        expect(flow.step, PhoneChangeStep.enterNew);
        expect(flow.proof, isNotNull);
        expect(flow.error, contains('already used'));
        expect(tokens.refreshToken, 'refresh-A');
        expect(auth.identifier, '+84901234567');
        flow.dispose();
      },
    );

    test('a stale or spent proof restarts at step 1', () async {
      final auth = await signedInAsA();
      scriptHappyPath();
      server.on(
        '/phone-change/confirm',
        (_) => fail(404, 'Your confirmation of your current number expired.'),
      );
      final flow = PhoneChangeController(auth);
      await flow.sendCurrentCode();
      await flow.verifyCurrent('111111');
      await flow.sendNewCode('0987654321');
      expect(await flow.confirm('222222'), isFalse);
      expect(flow.step, PhoneChangeStep.confirmCurrent);
      expect(flow.proof, isNull);
      expect(flow.error, contains('expired'));
      flow.dispose();
    });

    test('a wrong new-phone code stays on step 3 with the error', () async {
      final auth = await signedInAsA();
      scriptHappyPath();
      server.on(
        '/phone-change/confirm',
        (_) => fail(400, 'That code is incorrect or expired.'),
      );
      final flow = PhoneChangeController(auth);
      await flow.sendCurrentCode();
      await flow.verifyCurrent('111111');
      await flow.sendNewCode('0987654321');
      expect(await flow.confirm('000000'), isFalse);
      expect(flow.step, PhoneChangeStep.verifyNew);
      expect(flow.error, contains('incorrect'));
      flow.dispose();
    });

    test(
      'a lost confirm response keeps the current session and notebook',
      () async {
        final auth = await signedInAsA();
        scriptHappyPath();
        server.on('/phone-change/confirm', offline);
        final flow = PhoneChangeController(auth);
        await flow.sendCurrentCode();
        await flow.verifyCurrent('111111');
        await flow.sendNewCode('0987654321');
        expect(await flow.confirm('222222'), isFalse);
        expect(flow.error, contains('sign in with the new number'));
        expect(tokens.refreshToken, 'refresh-A');
        expect(await wordIds(), ['a-word']);
        flow.dispose();
      },
    );

    test(
      'lost phone-change response reconciles the new number and keeps the notebook',
      () async {
        final auth = await signedInAsA();
        scriptHappyPath();
        server
          ..on('/phone-change/confirm', offline)
          ..on(
            '/users/me',
            (_) => ok({
              'id': accountA,
              'phone': '+84987654321',
              'auth_method': 'phone_otp',
            }),
          );
        final flow = PhoneChangeController(auth);
        await flow.sendCurrentCode();
        await flow.verifyCurrent('111111');
        await flow.sendNewCode('0987654321');
        expect(await flow.confirm('222222'), isFalse);
        expect(flow.blocked, isTrue);
        expect(flow.error, contains('Number changed'));
        expect(auth.isSignedIn, isFalse);
        expect(tokens.refreshToken, isNull);
        expect(await wordIds(), ['a-word']);
        flow.dispose();
      },
    );

    test('an expired local proof restarts without a request', () async {
      var now = today;
      final auth = await signedInAsA();
      scriptHappyPath();
      final flow = PhoneChangeController(auth, now: () => now);
      await flow.sendCurrentCode();
      await flow.verifyCurrent('111111');
      now = now.add(const Duration(minutes: 16));
      expect(await flow.sendNewCode('0987654321'), isFalse);
      expect(flow.step, PhoneChangeStep.confirmCurrent);
      expect(server.count('/phone-change/new-code'), 0);
      flow.dispose();
    });

    test('provider failure is reported as retryable', () async {
      final auth = await signedInAsA();
      server.on(
        '/phone-change/current-code',
        (_) => fail(503, 'Could not send a code.'),
      );
      final flow = PhoneChangeController(auth);
      expect(await flow.sendCurrentCode(), isFalse);
      expect(flow.error, contains('try again later'));
      expect(flow.blocked, isFalse);
      flow.dispose();
    });
  });

  group('account deletion', () {
    const c = OtpChallenge(id: 'del-challenge', expiresIn: 600, retryAfter: 60);

    Future<AuthProvider> twoNotebooks() async {
      await repo.activateNotebook(accountB);
      await seed('b-word');
      return signedInAsA(); // archives B, opens A
    }

    test(
      'success wipes this account’s notebook only and restores a guest workspace',
      () async {
        final auth = await twoNotebooks();
        expect(await archives(), [accountB]);
        server.on('/delete-otp', (_) => http.Response('', 204));
        expect(await auth.deletePhoneAccount(c, '123456'), isTrue);
        expect(server.bodyOf('/delete-otp'), {
          'challenge_id': 'del-challenge',
          'code': '123456',
        });
        expect(auth.isSignedIn, isFalse);
        expect(tokens.refreshToken, isNull);
        expect(tokens.pendingDeletion, isNull);
        expect(tokens.lastAccount, isNull);
        expect(await wordIds(), isEmpty);
        expect(await archives(), [accountB], reason: 'B’s notebook is kept');
        // Guest learning continues.
        await seed('guest-after');
        expect(await wordIds(), ['guest-after']);
      },
    );

    test(
      'a wrong code keeps everything and clears the pending check',
      () async {
        final auth = await signedInAsA();
        server.on('/delete-otp', (_) => fail(400, 'That code is incorrect.'));
        expect(await auth.deletePhoneAccount(c, '000000'), isFalse);
        expect(auth.isSignedIn, isTrue);
        expect(await wordIds(), ['a-word']);
        expect(tokens.pendingDeletion, isNull);
        expect(auth.lastError, contains('incorrect'));
        expect(server.count('/deletion-receipt'), 0);
      },
    );

    test('a lost response is resolved by the server receipt', () async {
      final auth = await signedInAsA();
      server
        ..on('/delete-otp', offline)
        ..on('/deletion-receipt', (_) => ok({'deleted': true}));
      expect(await auth.deletePhoneAccount(c, '123456'), isTrue);
      expect(server.bodyOf('/deletion-receipt'), {
        'user_id': accountA,
        'challenge_id': 'del-challenge',
      });
      expect(
        server.requests
            .lastWhere((r) => r.url.path.endsWith('/deletion-receipt'))
            .headers['authorization'],
        isNull,
      );
      expect(auth.isSignedIn, isFalse);
      expect(await wordIds(), isEmpty);
      expect(tokens.pendingDeletion, isNull);
    });

    test(
      'an unknown outcome keeps data and the check, then resolves later',
      () async {
        final auth = await signedInAsA();
        server
          ..on('/delete-otp', offline)
          ..on('/deletion-receipt', offline);
        expect(await auth.deletePhoneAccount(c, '123456'), isFalse);
        expect(await wordIds(), ['a-word']);
        expect(auth.hasPendingDeletion, isTrue);
        expect(tokens.pendingDeletion?.challengeId, 'del-challenge');
        expect(auth.lastError, contains('could not confirm'));

        // Survives a restart.
        final restarted = provider();
        await restarted.restore();
        expect(restarted.hasPendingDeletion, isTrue);
        server.on('/deletion-receipt', (_) => ok({'deleted': true}));
        expect(await restarted.checkPendingDeletion(), DeletionOutcome.deleted);
        expect(await wordIds(), isEmpty);
        expect(restarted.hasPendingDeletion, isFalse);
      },
    );

    test(
      'an early missing receipt stays pending and a later receipt finishes deletion',
      () async {
        final auth = await signedInAsA();
        server
          ..on('/delete-otp', offline)
          ..on('/deletion-receipt', (_) => ok({'deleted': false}));
        expect(await auth.deletePhoneAccount(c, '123456'), isFalse);
        expect(auth.hasPendingDeletion, isTrue);
        expect(
          tokens.pendingDeletion?.confirmUntil,
          authNow.add(const Duration(minutes: 11)),
        );
        expect(await wordIds(), ['a-word']);
        expect(await auth.deletePhoneAccount(c, '123456'), isFalse);
        expect(
          server.count('/delete-otp'),
          1,
          reason: 'Never overwrite an unresolved deletion',
        );
        final restarted = provider();
        await restarted.restore();
        expect(restarted.hasPendingDeletion, isTrue);
        expect(await wordIds(), ['a-word']);
        server.on('/deletion-receipt', (_) => ok({'deleted': true}));
        expect(await restarted.checkPendingDeletion(), DeletionOutcome.deleted);
        expect(await wordIds(), isEmpty);
        expect(restarted.hasPendingDeletion, isFalse);
      },
    );

    test(
      'negative receipt is final only after the actual code expiry plus grace',
      () async {
        final auth = await signedInAsA();
        server
          ..on('/delete-otp', offline)
          ..on('/deletion-receipt', (_) => ok({'deleted': false}));
        await auth.deletePhoneAccount(
          c,
          '123456',
          codeExpiresAt: authNow.add(const Duration(seconds: 5)),
        );
        authNow = authNow.add(const Duration(seconds: 64));
        expect(await auth.checkPendingDeletion(), DeletionOutcome.unknown);
        expect(await wordIds(), ['a-word']);
        authNow = authNow.add(const Duration(seconds: 2));
        expect(await auth.checkPendingDeletion(), DeletionOutcome.notDeleted);
        expect(auth.hasPendingDeletion, isFalse);
        expect(await wordIds(), ['a-word']);
        expect(auth.lastError, contains('no confirmation'));
      },
    );

    test('401 alone is not proof of deletion', () async {
      final auth = await signedInAsA();
      server
        ..on('/delete-otp', (_) => fail(401, 'Authentication required'))
        ..on('/auth/refresh', (_) => fail(401, 'expired'))
        ..on('/deletion-receipt', (_) => ok({'deleted': false}));
      expect(await auth.deletePhoneAccount(c, '123456'), isFalse);
      expect(await wordIds(), ['a-word'], reason: 'notebook kept');
      expect(auth.isSignedIn, isFalse, reason: 'the session really ended');
      expect(auth.hasPendingDeletion, isTrue);
      expect(auth.lastError, contains('Still confirming'));
    });

    test('404 alone is not proof of deletion', () async {
      final auth = await signedInAsA();
      server
        ..on('/delete-otp', (_) => fail(404, 'Not found'))
        ..on('/deletion-receipt', (_) => ok({'deleted': false}));
      expect(await auth.deletePhoneAccount(c, '123456'), isFalse);
      expect(await wordIds(), ['a-word']);
      expect(auth.isSignedIn, isTrue);
    });

    test(
      'a pending deletion blocks switching accounts until resolved',
      () async {
        final auth = await signedInAsA();
        server
          ..on('/delete-otp', offline)
          ..on('/deletion-receipt', offline);
        await auth.deletePhoneAccount(c, '123456');
        server.on(
          '/otp/verify',
          (_) => ok({
            'user_id': accountB,
            'identifier': '+84987654321',
            'tokens': {'access_token': 'b', 'refresh_token': 'rb'},
          }),
        );
        const signIn = OtpChallenge(id: 's', expiresIn: 600, retryAfter: 60);
        expect(await auth.verifyPhone(signIn, '123456'), isFalse);
        expect(auth.lastError, contains('still confirming'));
        expect(server.count('/otp/verify'), 0);
        expect(auth.accountId, accountA);

        server.on('/deletion-receipt', (_) => ok({'deleted': false}));
        authNow = authNow.add(const Duration(minutes: 12));
        expect(await auth.verifyPhone(signIn, '123456'), isTrue);
        expect(auth.accountId, accountB);
        expect(await archives(), contains(accountA), reason: 'A kept aside');
      },
    );
  });

  group('session expiry and sign-out ownership', () {
    test('generic session expiry never clears the notebook', () async {
      final auth = await signedInAsA();
      server
        ..on('/users/me', (_) => fail(401, 'Authentication required'))
        ..on('/auth/refresh', (_) => fail(401, 'expired'));
      await auth.loadProfile();
      expect(auth.isSignedIn, isFalse);
      expect(await wordIds(), ['a-word']);
      expect(tokens.pendingDeletion, isNull);
    });

    test(
      'words added after sign-out stay with the signed-out account’s notebook',
      () async {
        final auth = await signedInAsA();
        server.on('/auth/logout', (_) => http.Response('', 204));
        await auth.signOut();
        await seed('guest-after-signout');
        server.on(
          '/otp/verify',
          (_) => ok({
            'user_id': accountB,
            'identifier': '+84987654321',
            'tokens': {'access_token': 'b', 'refresh_token': 'rb'},
          }),
        );
        expect(
          await auth.verifyPhone(
            const OtpChallenge(id: 's', expiresIn: 600, retryAfter: 60),
            '123456',
          ),
          isTrue,
        );
        expect(await wordIds(), isEmpty, reason: 'B gets its own notebook');
        await repo.activateNotebook(accountA);
        expect((await wordIds()).toSet(), {'a-word', 'guest-after-signout'});
      },
    );
  });

  test('PendingDeletion survives TokenStore.clear in the fake', () async {
    tokens.pendingDeletion = const PendingDeletion(
      accountId: accountA,
      challengeId: 'x',
    );
    await tokens.clear();
    expect(tokens.pendingDeletion, isNotNull);
  });
  test(
    'secure storage preserves the deletion recovery deadline across session clearing',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      const storage = TokenStore();
      final deadline = DateTime.utc(2026, 11, 10, 3, 5);
      await storage.savePendingDeletion(
        PendingDeletion(
          accountId: accountA,
          challengeId: 'receipt',
          confirmUntil: deadline,
        ),
      );
      await storage.clear();
      final restored = await const TokenStore().readPendingDeletion();
      expect(restored?.accountId, accountA);
      expect(restored?.challengeId, 'receipt');
      expect(restored?.confirmUntil, deadline);
      await storage.clearPendingDeletion();
    },
  );
}
