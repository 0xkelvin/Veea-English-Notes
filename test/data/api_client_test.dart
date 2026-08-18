import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:veea_english_app/data/remote/api_client.dart';

import '../support/fake_token_store.dart';

void main() {
  const baseUrl = 'https://example.test/api/v1';
  late FakeTokenStore tokens;

  setUp(() {
    tokens = FakeTokenStore()
      ..accessToken = 'stale-access'
      ..refreshToken = 'good-refresh';
  });

  ApiClient clientWith(MockClient mock) =>
      ApiClient(tokenStore: tokens, httpClient: mock, baseUrl: baseUrl);

  http.Response ok(Object body) => http.Response(
    jsonEncode(body),
    200,
    headers: {'content-type': 'application/json'},
  );

  test('unwraps the data envelope', () async {
    final client = clientWith(
      MockClient(
        (_) async => ok({
          'data': {'word': 'resilient'},
        }),
      ),
    );

    expect(await client.get('/x'), {'word': 'resilient'});
  });

  test('attaches the access token', () async {
    String? seen;
    final client = clientWith(
      MockClient((request) async {
        seen = request.headers['authorization'];
        return ok({'data': <String, Object?>{}});
      }),
    );

    await client.get('/x');
    expect(seen, 'Bearer stale-access');
  });

  test('omits the token on an unauthenticated call', () async {
    String? seen;
    final client = clientWith(
      MockClient((request) async {
        seen = request.headers['authorization'];
        return ok({'data': <String, Object?>{}});
      }),
    );

    await client.post('/auth/login', authenticated: false);
    expect(seen, isNull);
  });

  test('surfaces the server error message', () async {
    final client = clientWith(
      MockClient(
        (_) async => http.Response(
          jsonEncode({
            'error': {'code': 'VALIDATION_ERROR', 'message': 'Bad email'},
          }),
          400,
          headers: {'content-type': 'application/json'},
        ),
      ),
    );

    await expectLater(
      client.post('/x'),
      throwsA(
        isA<ApiException>()
            .having((e) => e.message, 'message', 'Bad email')
            .having((e) => e.code, 'code', 'VALIDATION_ERROR')
            .having((e) => e.isTransient, 'isTransient', isFalse),
      ),
    );
  });

  test('a connection failure becomes an OfflineException', () async {
    final client = clientWith(
      MockClient((_) async => throw http.ClientException('no route')),
    );

    await expectLater(
      client.get('/x'),
      throwsA(
        isA<OfflineException>().having(
          (e) => e.isTransient,
          'isTransient',
          isTrue,
        ),
      ),
    );
  });

  group('token refresh', () {
    test('refreshes once on 401 and replays the request', () async {
      final calls = <String>[];
      final client = clientWith(
        MockClient((request) async {
          final path = request.url.path;
          calls.add(path);

          if (path.endsWith('/auth/refresh')) {
            return ok({
              'data': {
                'access_token': 'fresh-access',
                'refresh_token': 'fresh-refresh',
              },
            });
          }
          // Reject the stale token, accept the refreshed one.
          if (request.headers['authorization'] == 'Bearer fresh-access') {
            return ok({
              'data': {'ok': true},
            });
          }
          return http.Response('{}', 401);
        }),
      );

      expect(await client.get('/words'), {'ok': true});
      expect(calls, ['/api/v1/words', '/api/v1/auth/refresh', '/api/v1/words']);
      expect(tokens.accessToken, 'fresh-access');
      expect(tokens.refreshToken, 'fresh-refresh');
    });

    test('parallel 401s share a single refresh', () async {
      var refreshes = 0;
      final client = clientWith(
        MockClient((request) async {
          if (request.url.path.endsWith('/auth/refresh')) {
            refreshes++;
            // Yield, so the other callers reach the refresh point while this
            // one is still in flight.
            await Future<void>.delayed(const Duration(milliseconds: 10));
            return ok({
              'data': {
                'access_token': 'fresh-access',
                'refresh_token': 'fresh-refresh',
              },
            });
          }
          if (request.headers['authorization'] == 'Bearer fresh-access') {
            return ok({'data': <String, Object?>{}});
          }
          return http.Response('{}', 401);
        }),
      );

      await Future.wait([client.get('/a'), client.get('/b'), client.get('/c')]);

      // Without the shared future each call would refresh, and each new
      // refresh token would invalidate the one before it.
      expect(refreshes, 1);
    });

    test('a rejected refresh token ends the session', () async {
      var expired = 0;
      final client = clientWith(
        MockClient((_) async => http.Response('{}', 401)),
      )..onSessionExpired = () => expired++;

      await expectLater(client.get('/x'), throwsA(isA<ApiException>()));

      expect(expired, 1);
      expect(tokens.clearCount, 1);
    });

    test('a refresh that fails offline keeps the session', () async {
      var attempt = 0;
      final client = clientWith(
        MockClient((request) async {
          if (request.url.path.endsWith('/auth/refresh')) {
            throw http.ClientException('offline');
          }
          attempt++;
          return http.Response('{}', 401);
        }),
      );

      await expectLater(client.get('/x'), throwsA(isA<ApiException>()));

      // The credentials survive so a later attempt can succeed.
      expect(tokens.refreshToken, 'good-refresh');
      expect(tokens.clearCount, 0);
      expect(attempt, 1);
    });

    test('does not attempt a refresh without a refresh token', () async {
      tokens.refreshToken = null;
      var refreshes = 0;
      final client = clientWith(
        MockClient((request) async {
          if (request.url.path.endsWith('/auth/refresh')) refreshes++;
          return http.Response('{}', 401);
        }),
      );

      await expectLater(client.get('/x'), throwsA(isA<ApiException>()));
      expect(refreshes, 0);
    });
  });
}
