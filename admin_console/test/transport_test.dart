import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:veea_admin_console/src/transport.dart';

String tok(String p, int n) => '${p}_${n.toString().padLeft(43, '0')}';

Map<String, Object?> tokens(int n) => {
  'session_id': '00000000-0000-7000-8000-000000000001',
  'access_token': tok('vat', n),
  'refresh_token': tok('vrt', n),
  'user': {'id': '00000000-0000-7000-8000-000000000002', 'email': 'a@b.test'},
};

http.Response json(int s, Object b) => http.Response(jsonEncode(b), s);

void main() {
  test(
    'one single-flight refresh serves concurrent 401s, then retries',
    () async {
      var refreshes = 0;
      var current = tok('vat', 1);
      final t = AdminTransport(
        baseUrl: 'http://x.test',
        client: MockClient((r) async {
          if (r.url.path == '/v1/auth/password/login') {
            return json(200, tokens(1));
          }
          if (r.url.path == '/v1/auth/token/refresh') {
            refreshes++;
            await Future<void>.delayed(const Duration(milliseconds: 10));
            current = tok('vat', 2);
            return json(200, tokens(2));
          }
          if (r.headers['authorization'] != 'Bearer $current') {
            return json(401, {'code': 'unauthorized'});
          }
          return json(200, {'ok': true});
        }),
      );
      await t.passwordLogin('a@b.test', 'pw');
      current = 'expired';
      final results = await Future.wait([
        t.request('GET', '/v1/me'),
        t.request('GET', '/v1/me'),
        t.request('GET', '/v1/me'),
      ]);
      expect(results.every((r) => r['ok'] == true), isTrue);
      expect(refreshes, 1);
    },
  );

  test(
    'a refused or lost refresh ends the session and drops the tokens',
    () async {
      for (final lost in [false, true]) {
        final t = AdminTransport(
          baseUrl: 'http://x.test',
          client: MockClient((r) async {
            if (r.url.path == '/v1/auth/password/login') {
              return json(200, tokens(1));
            }
            if (r.url.path == '/v1/auth/token/refresh') {
              if (lost) throw http.ClientException('lost');
              return json(401, {'code': 'unauthorized'});
            }
            return json(401, {'code': 'unauthorized'});
          }),
        );
        await t.passwordLogin('a@b.test', 'pw');
        await expectLater(
          t.request('GET', '/v1/me'),
          throwsA(isA<SessionEnded>()),
        );
        expect(t.signedIn, isFalse);
        await expectLater(
          t.request('GET', '/v1/me'),
          throwsA(isA<SessionEnded>()),
        );
      }
    },
  );

  test(
    'problem documents keep only code and account_status; no token in URLs',
    () async {
      final seen = <Uri>[];
      final t = AdminTransport(
        baseUrl: 'http://x.test',
        client: MockClient((r) async {
          seen.add(r.url);
          if (r.url.path == '/v1/auth/password/login') {
            return json(200, tokens(1));
          }
          return json(409, {
            'code': 'status_conflict',
            'account_status': 'pending_deletion',
            'title': 'server text',
          });
        }),
      );
      await t.passwordLogin('a@b.test', 'pw');
      try {
        await t.request(
          'POST',
          '/v1/admin/users/x/lifecycle-transitions',
          body: {'a': 1},
        );
        fail('expected a problem');
      } on AdminApiException catch (e) {
        expect(e.status, 409);
        expect(e.code, 'status_conflict');
        expect(e.accountStatus, 'pending_deletion');
      }
      expect(
        seen.any(
          (u) => u.toString().contains('vat_') || u.toString().contains('vrt_'),
        ),
        isFalse,
      );
    },
  );

  test(
    'malformed sign-in responses are refused; offline is reported',
    () async {
      final bad = AdminTransport(
        baseUrl: 'http://x.test',
        client: MockClient((r) async => json(200, {'access_token': 'nope'})),
      );
      await expectLater(
        bad.passwordLogin('a@b.test', 'pw'),
        throwsA(isA<AdminApiException>()),
      );
      expect(bad.signedIn, isFalse);
      final down = AdminTransport(
        baseUrl: 'http://x.test',
        client: MockClient((r) async => throw http.ClientException('down')),
      );
      await expectLater(
        down.passwordLogin('a@b.test', 'pw'),
        throwsA(isA<Offline>()),
      );
    },
  );

  test('logout clears locally even when the server call fails', () async {
    final t = AdminTransport(
      baseUrl: 'http://x.test',
      client: MockClient((r) async {
        if (r.url.path == '/v1/auth/password/login') {
          return json(200, tokens(1));
        }
        throw http.ClientException('down');
      }),
    );
    await t.passwordLogin('a@b.test', 'pw');
    await t.logout();
    expect(t.signedIn, isFalse);
  });
}
