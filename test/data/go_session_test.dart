import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:veea_english_app/data/sync/learning_sync_api.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:veea_english_app/data/remote/api_client.dart';
import 'package:veea_english_app/data/remote/go/api_client.dart';
import 'package:veea_english_app/data/remote/go/session_store.dart';

import '../support/secure_storage.dart';

const userA = '00000000-0000-4000-8000-000000000001';
const userB = '00000000-0000-4000-8000-000000000002';
Map<String, Object?> tokens({
  String user = userA,
  String access = 'a',
  String refresh = 'r',
}) => {
  'session_id': '00000000-0000-4000-8000-000000000003',
  'user': {'id': user, 'email': 'synthetic@example.test'},
  'access_token': 'vat_${List.filled(43, access).join()}',
  'refresh_token': 'vrt_${List.filled(43, refresh).join()}',
  'access_expires_at': '2026-12-01T00:00:00Z',
  'refresh_expires_at': '2026-12-31T00:00:00Z',
};
http.Response response(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status);
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late TestSecureStorage secure;
  late GoTokenStore store;
  setUp(() async {
    secure = TestSecureStorage();
    store = GoTokenStore(storage: secure);
    await store.establish(tokens());
  });
  GoApiClient client(Future<http.Response> Function(http.Request) handler) =>
      GoApiClient(
        tokens: store,
        httpClient: MockClient(handler),
        baseUrl: 'http://localhost',
      );

  test(
    'owner-bound cartridge dispatch refuses a switched account before sending HTTP',
    () async {
      await store.establish(tokens(user: userB));
      var calls = 0;
      final c = client((r) async {
        calls++;
        return response({});
      });
      await expectLater(
        c.raw(
          'POST',
          '/v1/cartridges/synthetic/versions/1/install',
          expectedUserId: userA,
        ),
        throwsA(isA<SessionChanged>()),
      );
      expect(calls, 0);
      c.dispose();
    },
  );

  test(
    '25 concurrent 401s rotate once and observe one atomic persisted pair',
    () async {
      var calls = 0;
      final c = client((r) async {
        if (r.url.path.endsWith('/refresh')) {
          calls++;
          await Future<void>.delayed(const Duration(milliseconds: 10));
          expect((await store.readSession())!.refreshState, 'in_flight');
          expect(r.headers.containsKey('authorization'), isFalse);
          return response(tokens(access: 'b', refresh: 's'));
        }
        return r.headers['authorization'] ==
                'Bearer ${tokens(access: 'b')['access_token']}'
            ? response({'id': userA})
            : response({'code': 'unauthorized'}, 401);
      });
      await Future.wait(List.generate(25, (_) => c.get('/v1/me')));
      expect(calls, 1);
      final saved = (await store.readSession())!;
      expect(saved.access == tokens(access: 'b')['access_token'], isTrue);
      expect(saved.refresh == tokens(refresh: 's')['refresh_token'], isTrue);
      for (final write in secure.writes) {
        if (write[GoTokenStore.sessionKey] case final String value) {
          final data = jsonDecode(value) as Map;
          expect(
            (data['access_token'] == tokens(access: 'b')['access_token']) ==
                (data['refresh_token'] ==
                    tokens(refresh: 's')['refresh_token']),
            isTrue,
          );
        }
      }
    },
  );
  test(
    'a delayed old 401 uses the new pair without a second rotation',
    () async {
      final release = Completer<void>();
      var gets = 0, rotates = 0;
      final c = client((r) async {
        if (r.url.path.endsWith('/refresh')) {
          rotates++;
          return response(tokens(access: 'b', refresh: 's'));
        }
        if (r.headers['authorization']!.endsWith(
          tokens(access: 'b')['access_token']! as String,
        )) {
          return response({'ok': true});
        }
        gets++;
        if (gets == 2) await release.future;
        return response({'code': 'unauthorized'}, 401);
      });
      final first = c.get('/v1/me'), second = c.get('/v1/me');
      await first;
      release.complete();
      await second;
      expect(rotates, 1);
    },
  );
  for (final switchAccount in [false, true]) {
    test(
      'late refresh cannot restore credentials after ${switchAccount ? 'account switch' : 'sign-out'}',
      () async {
        final started = Completer<void>(), release = Completer<void>();
        final c = client((r) async {
          if (r.url.path.endsWith('/refresh')) {
            started.complete();
            await release.future;
            return response(tokens(access: 'b', refresh: 's'));
          }
          return response({'code': 'unauthorized'}, 401);
        });
        var expired = 0;
        c.onSessionExpired = () {
          expired++;
        };
        final pending = c.get('/v1/me');
        final outcome = pending.then((_) => false, onError: (Object _) => true);
        await started.future;
        await store.clear();
        if (switchAccount) {
          await store.establish(tokens(user: userB, access: 'c', refresh: 't'));
        }
        release.complete();
        expect(await outcome, isTrue);
        expect(expired, 0);
        expect(
          (await store.readSession())?.userId,
          switchAccount ? userB : null,
        );
      },
    );
  }
  for (final failure in ['lost', '500', 'malformed', 'wrong owner']) {
    test(
      '$failure refresh outcome requires new sign-in and never resends the old token',
      () async {
        var calls = 0;
        final c = client((r) async {
          if (!r.url.path.endsWith('/refresh')) {
            return response({'code': 'unauthorized'}, 401);
          }
          calls++;
          if (failure == 'lost') {
            throw http.ClientException('synthetic lost response');
          }
          if (failure == '500') {
            return response({'code': 'internal_error'}, 500);
          }
          if (failure == 'malformed') return http.Response('{', 200);
          return response(tokens(user: userB, access: 'b', refresh: 's'));
        });
        await expectLater(c.get('/v1/me'), throwsA(isA<FreshSignInRequired>()));
        await expectLater(c.get('/v1/me'), throwsA(isA<FreshSignInRequired>()));
        expect(calls, 1);
        expect(await store.readSession(), isNull);
      },
    );
  }
  test(
    'crash after durable refresh marker refuses transmission after restart',
    () async {
      await store.beginRefresh((await store.readSession())!);
      store = GoTokenStore(storage: secure);
      var requests = 0;
      final c = client((_) async {
        requests++;
        return response({});
      });
      await expectLater(c.get('/v1/me'), throwsA(isA<FreshSignInRequired>()));
      expect(requests, 0);
      expect(await store.readSession(), isNull);
    },
  );
  test(
    'an explicit 429 permits a later attempt without rotating immediately',
    () async {
      var requests = 0;
      final c = client((r) async {
        if (r.url.path.endsWith('/refresh')) {
          requests++;
          return response({'code': 'rate_limited'}, 429);
        }
        return response({'code': 'unauthorized'}, 401);
      });
      await expectLater(
        c.get('/v1/me'),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 429)),
      );
      expect((await store.readSession())?.refreshState, 'ready');
      expect(requests, 1);
    },
  );
  test(
    'refresh HTTP response cannot overwrite another session identity',
    () async {
      final before = (await store.readSession())!;
      await store.beginRefresh(before);
      await store.establish(tokens(user: userB));
      expect(
        await store.finishRefresh(before, tokens(access: 'b', refresh: 's')),
        isNull,
      );
      expect((await store.readSession())?.userId, userB);
    },
  );
  test('problem errors never echo upstream payloads or credentials', () async {
    final c = client(
      (_) async => response({
        'code': 'unknown_secret',
        'title': 'do not echo credentials or OTPs',
      }, 500),
    );
    await expectLater(
      c.get('/v1/me'),
      throwsA(
        isA<ApiException>().having(
          (e) => e.message.contains('credentials or OTPs'),
          'echo',
          isFalse,
        ),
      ),
    );
  });
  test('sync refresh replay preserves the original mutation bytes', () async {
    const mutation =
        '{ "seq":1, "op":"delete", "entity_id":"00000000-0000-4000-8000-000000000009", "base_revision":1 }';
    final attempts = <String>[];
    final c = client((r) async {
      if (r.url.path.endsWith('/refresh')) {
        return response(tokens(access: 'b', refresh: 's'));
      }
      attempts.add(r.body);
      expect(r.body.contains(mutation), isTrue);
      if (attempts.length == 1) return response({'code': 'unauthorized'}, 401);
      return response({
        'results': [],
        'head_revision': 1,
        'live_words': 0,
        'content_bytes': 0,
        'last_seq': 1,
      });
    });
    final sync = LearningSyncApi(
      client: GoLearningHttpClient(c),
      baseUrl: 'http://localhost',
      accessToken: store.readAccessToken,
    );
    await sync.push(
      epoch: 'epoch',
      writerId: userA,
      mutations: [Uint8List.fromList(utf8.encode(mutation))],
    );
    expect(attempts.length, 2);
    expect(attempts.first == attempts.last, isTrue);
  });
}
