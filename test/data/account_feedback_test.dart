import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:veea_english_app/core/config/app_config.dart';
import 'package:veea_english_app/data/feedback_repository.dart';
import 'package:veea_english_app/data/local/sqlite_vocabulary_repository.dart';
import 'package:veea_english_app/data/remote/api_client.dart';
import 'package:veea_english_app/data/remote/auth_api.dart';
import 'package:veea_english_app/data/remote/vocabulary_api.dart';
import 'package:veea_english_app/models/vocabulary_word.dart';
import 'package:veea_english_app/providers/auth_provider.dart';
import 'package:veea_english_app/providers/feedback_provider.dart';
import 'package:veea_english_app/providers/phone_auth_controller.dart';
import 'package:veea_english_app/services/sync_service.dart';
import '../support/fake_token_store.dart';

class MemoryReceipts extends FeedbackReceiptStore {
  final keys = <String, String>{};
  @override
  Future<String> keyFor(String owner) async => keys.putIfAbsent(
    owner,
    () => base64UrlEncode(
      utf8.encode('receipt-for-$owner-${'x' * 32}'),
    ).replaceAll('=', ''),
  );
}

class FailingTokens extends FakeTokenStore {
  bool failWrite = false;
  @override
  Future<void> save({
    required String accessToken,
    required String refreshToken,
    String? identifier,
    String? accountId,
    String? authMethod,
  }) async {
    if (failWrite) throw StateError('Keychain unavailable');
    await super.save(
      accessToken: accessToken,
      refreshToken: refreshToken,
      identifier: identifier,
      accountId: accountId,
      authMethod: authMethod,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  late SqliteVocabularyRepository repo;
  late FakeTokenStore tokens;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    AppConfig.overrideBaseUrl('https://veea.test');
    repo = await SqliteVocabularyRepository.open(path: inMemoryDatabasePath);
    tokens = FakeTokenStore();
  });
  tearDown(() async {
    AppConfig.overrideBaseUrl(null);
    await repo.close();
  });
  ApiClient transport(Future<http.Response> Function(http.Request) responder) =>
      ApiClient(
        tokenStore: tokens,
        httpClient: MockClient(responder),
        baseUrl: 'https://veea.test/api/v1',
      );
  http.Response ok(Object data) =>
      http.Response(jsonEncode({'data': data}), 200);
  Future<void> seed(String id) => repo.insert(
    VocabularyWord.create(
      id: id,
      word: 'consent',
      meaning: 'đồng ý',
      date: '2026-11-07',
      now: DateTime.utc(2026, 11, 7),
    ),
  );
  AuthProvider authFor(ApiClient client) => AuthProvider(
    authApi: AuthApi(client: client, tokens: tokens),
    tokens: tokens,
    client: client,
    repository: repo,
    sync: SyncService(repository: repo, api: VocabularyApi(client)),
  );

  test('normalizes Vietnamese mobile numbers and rejects ambiguous input', () {
    for (final number in ['0901234567', '+84 90 123 4567', '901234567']) {
      expect(vietnamPhone(number), '+84901234567');
    }
    for (final number in [
      '+840901234567',
      '+1901234567',
      'abc',
      '123',
      '+84',
    ]) {
      expect(vietnamPhone(number), isNull);
    }
  });
  test('OTP response is staged until notebook activation and commit', () async {
    final client = transport((r) async {
      expect(jsonDecode(r.body), {
        'challenge_id': 'challenge',
        'code': '123456',
      });
      return ok({
        'user_id': 'owner-A',
        'identifier': '+84901234567',
        'tokens': {'access_token': 'access-A', 'refresh_token': 'refresh-A'},
      });
    });
    final api = AuthApi(client: client, tokens: tokens);
    final session = await api.verifyOtp(
      const OtpChallenge(
        id: 'challenge',
        expiresIn: 600,
        retryAfter: 60,
        phone: '+84901234567',
      ),
      '123456',
    );
    expect(tokens.accessToken, isNull);
    await api.commitSession(session);
    expect(await tokens.readAccountId(), 'owner-A');
    expect(await tokens.readAuthMethod(), 'phone_otp');
  });
  test('OTP cooldown and expiry block unnecessary server requests', () async {
    var sends = 0, verifies = 0;
    var clock = DateTime.utc(2026, 11, 7);
    final auth = authFor(
      transport((r) async {
        if (r.url.path.endsWith('/config')) {
          return ok({'phone_otp_available': true});
        }
        if (r.url.path.endsWith('/request')) {
          sends++;
          return ok({
            'challenge_id': 'challenge',
            'expires_in': 600,
            'retry_after': 60,
          });
        }
        verifies++;
        return http.Response('{}', 400);
      }),
    );
    final flow = PhoneAuthController(auth, now: () => clock);
    addTearDown(flow.dispose);
    addTearDown(auth.dispose);
    await flow.initialize();
    expect(await flow.send('bad'), false);
    expect(sends, 0);
    expect(await flow.send('0901234567'), true);
    expect(await flow.send('0901234567'), false);
    expect(sends, 1);
    expect(await flow.verify('abc'), false);
    expect(verifies, 0);
    clock = clock.add(const Duration(minutes: 11));
    expect(await flow.verify('123456'), false);
    expect(flow.error, contains('expired'));
    expect(verifies, 0);
  });
  test('unavailable OTP never creates a fake session', () async {
    final auth = authFor(
      transport((_) async => ok({'phone_otp_available': false})),
    );
    final flow = PhoneAuthController(auth);
    addTearDown(flow.dispose);
    addTearDown(auth.dispose);
    await flow.initialize();
    expect(await flow.send('0901234567'), false);
    expect(tokens.accessToken, isNull);
  });
  test(
    'switching notebooks restores words, dirty flags, review history and practice pool',
    () async {
      await seed('private-A');
      await repo.activateNotebook('A');
      await repo.database.update('gate_config', {
        'practice_word_ids_json': '["private-A"]',
        'words_per_unlock': 1,
      }, where: 'id = 1');
      await repo.database.insert('srs_reviews', {
        'word_id': 'private-A',
        'next_review_date': '2026-11-08',
        'repetitions': 3,
      });
      final before = await repo.database.query('srs_reviews');
      await repo.activateNotebook('B');
      expect(await repo.exportAll(), isEmpty);
      expect(await repo.countPendingChanges(), 0);
      await seed('private-B');
      await repo.activateNotebook('A');
      expect((await repo.exportAll()).single.id, 'private-A');
      expect(await repo.countPendingChanges(), 1);
      expect(await repo.database.query('srs_reviews'), before);
      expect((await repo.getGateConfig()).practiceWordIds, ['private-A']);
      await repo.activateNotebook('B');
      expect((await repo.exportAll()).single.id, 'private-B');
    },
  );
  test(
    'sync acknowledgement cannot clear a newer edit; merge keeps local learning history',
    () async {
      await seed('word');
      final sent = (await repo.pendingChanges()).single;
      final edited = sent.copyWith(
        meaning: 'new local edit',
        updatedAt: sent.updatedAt.add(const Duration(seconds: 1)),
      );
      await repo.update(edited);
      await repo.markSynced(
        ['word'],
        DateTime.now(),
        expectedVersions: {'word': sent.updatedAt},
      );
      expect(await repo.countPendingChanges(), 1);
      await repo.markSynced(
        ['word'],
        DateTime.now(),
        expectedVersions: {'word': edited.updatedAt},
      );
      await repo.database.insert('srs_reviews', {
        'word_id': 'word',
        'next_review_date': '2026-11-08',
        'repetitions': 3,
      });
      await repo.mergeFromServer([
        edited.copyWith(meaning: 'canonical', updatedAt: edited.updatedAt),
      ]);
      expect((await repo.exportAll()).single.meaning, 'canonical');
      expect(await repo.database.query('srs_reviews'), hasLength(1));
    },
  );
  test(
    'feedback survives offline delivery and retries with the same id and receipt',
    () async {
      var offline = true;
      final sent = <Map>[];
      final keys = <String>[];
      final client = transport((r) async {
        if (r.url.path.endsWith('/config')) return ok({});
        if (r.method == 'GET') return ok({'reports': []});
        sent.add(jsonDecode(r.body) as Map);
        keys.add(r.headers['x-feedback-key']!);
        if (offline) throw http.ClientException('offline');
        return ok({'id': sent.last['id'], 'status': 'received'});
      });
      final store = FeedbackRepository(
        repo.database,
        client,
        receipts: MemoryReceipts(),
      );
      final feedback = FeedbackProvider(store);
      addTearDown(feedback.dispose);
      await feedback.activate(null);
      expect(
        await feedback.submit(
          kind: 'feature',
          message: 'Please add desktop sync',
        ),
        true,
      );
      expect(feedback.reports.single.status, 'queued');
      await feedback.refresh();
      expect(feedback.reports.single.status, 'queued');
      final restarted = FeedbackProvider(store);
      addTearDown(restarted.dispose);
      await restarted.activate(null);
      expect(restarted.reports, hasLength(1));
      offline = false;
      await restarted.refresh();
      expect(restarted.reports.single.status, 'received');
      expect(sent[0]['id'], sent[1]['id']);
      expect(keys[0], keys[1]);
      expect(sent[0]['diagnostics'], isEmpty);
      expect(sent[0]['contact'], isNull);
      await restarted.activate('other-account');
      expect(restarted.reports, isEmpty);
    },
  );
  test(
    'malformed feedback acknowledgement stays queued and diagnostics are opt-in',
    () async {
      Map? payload;
      final client = transport((r) async {
        if (r.url.path.endsWith('/config')) return ok({});
        payload = jsonDecode(r.body) as Map;
        return ok({'id': 'wrong', 'status': 'received'});
      });
      final feedback = FeedbackProvider(
        FeedbackRepository(repo.database, client, receipts: MemoryReceipts()),
      );
      addTearDown(feedback.dispose);
      await feedback.submit(
        kind: 'bug',
        message: 'Cannot hear pronunciation',
        diagnostics: true,
      );
      await feedback.refresh();
      expect(feedback.reports.single.queued, true);
      expect(
        (payload!['diagnostics'] as Map).keys,
        unorderedEquals(['app_version', 'platform', 'screen']),
      );
      expect(await feedback.submit(kind: 'bug', message: ' '), false);
    },
  );
  test(
    'failed session storage rolls back notebook ownership and keeps old credentials',
    () async {
      final saved = FailingTokens()
        ..accessToken = 'old-access'
        ..refreshToken = 'old-refresh'
        ..identifier = '+84901234567'
        ..accountId = 'A'
        ..authMethod = 'phone_otp';
      tokens = saved;
      await repo.activateNotebook('A');
      await seed('private-A');
      final auth = authFor(
        transport(
          (_) async => ok({
            'user_id': 'B',
            'identifier': '+84901234568',
            'tokens': {
              'access_token': 'new-access',
              'refresh_token': 'new-refresh',
            },
          }),
        ),
      );
      addTearDown(auth.dispose);
      await auth.restore();
      saved.failWrite = true;
      final result = await auth.verifyPhone(
        const OtpChallenge(
          id: 'challenge',
          expiresIn: 600,
          retryAfter: 60,
          phone: '+84901234568',
        ),
        '123456',
      );
      expect(result, false);
      expect(auth.accountId, 'A');
      expect(tokens.accessToken, 'old-access');
      expect((await repo.exportAll()).single.id, 'private-A');
      expect((await repo.database.query('app_metadata')).single['value'], 'A');
    },
  );
  test('failed first sign-in leaves the guest notebook unclaimed', () async {
    final saved = FailingTokens()..failWrite = true;
    tokens = saved;
    await seed('guest-word');
    final auth = authFor(
      transport(
        (_) async => ok({
          'user_id': 'A',
          'identifier': '+84901234567',
          'tokens': {'access_token': 'access', 'refresh_token': 'refresh'},
        }),
      ),
    );
    addTearDown(auth.dispose);
    expect(
      await auth.verifyPhone(
        const OtpChallenge(
          id: 'challenge',
          expiresIn: 600,
          retryAfter: 60,
          phone: '+84901234567',
        ),
        '123456',
      ),
      false,
    );
    expect(await repo.database.query('app_metadata'), isEmpty);
    expect((await repo.exportAll()).single.id, 'guest-word');
    expect(tokens.accessToken, isNull);
  });
  test('pull cursors stay separate for each account', () async {
    final cursors = <String>[];
    final client = transport((r) async {
      cursors.add((jsonDecode(r.body) as Map)['cursor'] as String);
      return ok({
        'accepted': [],
        'changes': [],
        'canonical': [],
        'cursor': '42',
        'serverTime': '2026-11-07T00:00:00Z',
        'hasMore': false,
      });
    });
    final sync = SyncService(repository: repo, api: VocabularyApi(client));
    addTearDown(sync.dispose);
    sync.resumeForAccount('A');
    expect(await sync.synchronise(), true);
    sync.resumeForAccount('B');
    expect(await sync.synchronise(), true);
    sync.resumeForAccount('A');
    expect(await sync.synchronise(), true);
    expect(cursors, ['0', '0', '42']);
  });
  test('only a trusted Zalo group link is accepted', () {
    expect(
      trustedZaloCommunity('https://zalo.me/g/abc123'),
      'https://zalo.me/g/abc123',
    );
    for (final url in [
      'http://zalo.me/g/a',
      'https://zalo.me.evil/g/a',
      'https://zalo.me@g.evil/g/a',
      'https://zalo.me/g/a?redirect=evil',
      'https://zalo.me/g/a/../../evil',
    ]) {
      expect(trustedZaloCommunity(url), isNull);
    }
  });
}
