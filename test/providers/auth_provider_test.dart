import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:veea_english_app/data/local/sqlite_vocabulary_repository.dart';
import 'package:veea_english_app/data/remote/api_client.dart';
import 'package:veea_english_app/data/remote/auth_api.dart';
import 'package:veea_english_app/data/remote/vocabulary_api.dart';
import 'package:veea_english_app/models/vocabulary_word.dart';
import 'package:veea_english_app/providers/auth_provider.dart';
import 'package:veea_english_app/services/sync_service.dart';

import '../support/fake_token_store.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  TestWidgetsFlutterBinding.ensureInitialized();

  const baseUrl = 'https://example.test/api/v1';
  final today = DateTime(2026, 8, 18, 10);

  late FakeTokenStore tokens;
  late SqliteVocabularyRepository repo;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tokens = FakeTokenStore()
      ..accessToken = 'access'
      ..refreshToken = 'refresh'
      ..identifier = 'kelvin@example.com';
    repo = await SqliteVocabularyRepository.open(
      path: inMemoryDatabasePath,
      now: () => today,
    );
  });

  tearDown(() => repo.close());

  /// Builds a provider over a scripted server.
  AuthProvider providerWith(MockClient mock) {
    final client = ApiClient(
      tokenStore: tokens,
      httpClient: mock,
      baseUrl: baseUrl,
    );
    return AuthProvider(
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

  Future<void> seedWord(String id) => repo.insert(
    VocabularyWord.create(
      id: id,
      word: 'resilient',
      meaning: 'kiên cường',
      date: '2026-08-18',
      now: today,
    ),
  );

  /// What the server actually returns when the confirmation password is
  /// wrong: 403, not 401, so the client does not mistake it for a dead
  /// session and sign the user out.
  http.Response invalidPassword() => http.Response(
    jsonEncode({
      'error': {
        'code': 'INVALID_PASSWORD',
        'message': 'That password is not right',
      },
    }),
    403,
    headers: {'content-type': 'application/json'},
  );

  http.Response ok(Object body) => http.Response(
    jsonEncode(body),
    200,
    headers: {'content-type': 'application/json'},
  );

  group('sign in', () {
    test('stores the session and remembers the identifier', () async {
      final auth = providerWith(
        MockClient(
          (_) async => ok({
            'data': {
              'access_token': 'new-access',
              'refresh_token': 'new-refresh',
            },
          }),
        ),
      );

      final ok_ = await auth.signIn(
        identifier: '+84901234567',
        password: 'hunter22',
      );

      expect(ok_, isTrue);
      expect(auth.isSignedIn, isTrue);
      expect(auth.identifier, '+84901234567');
      expect(tokens.accessToken, 'new-access');
    });

    test('sends the identifier field, not email', () async {
      Map<String, Object?>? sent;
      final auth = providerWith(
        MockClient((request) async {
          sent = jsonDecode(request.body) as Map<String, Object?>;
          return ok({
            'data': {'access_token': 'a', 'refresh_token': 'r'},
          });
        }),
      );

      await auth.signIn(identifier: 'kelvin@example.com', password: 'hunter22');

      expect(sent!.containsKey('identifier'), isTrue);
      expect(sent!.containsKey('email'), isFalse);
    });

    test('a wrong password reads as a password problem', () async {
      final auth = providerWith(
        MockClient((_) async => http.Response('{}', 401)),
      );

      expect(
        await auth.signIn(identifier: 'a@b.com', password: 'wrong'),
        isFalse,
      );
      expect(auth.isSignedIn, isFalse);
      expect(auth.lastError, contains('password'));
    });
  });

  group('register', () {
    test('reads the tokens nested under the new user', () async {
      final auth = providerWith(
        MockClient(
          (_) async => ok({
            'data': {
              'user_id': '00000000-0000-0000-0000-000000000001',
              'identifier': 'kelvin@example.com',
              'tokens': {
                'access_token': 'new-access',
                'refresh_token': 'new-refresh',
              },
            },
          }),
        ),
      );

      expect(
        await auth.register(
          identifier: 'kelvin@example.com',
          password: 'hunter22',
        ),
        isTrue,
      );
      expect(tokens.refreshToken, 'new-refresh');
    });

    test(
      'an already-registered identifier surfaces the server message',
      () async {
        final auth = providerWith(
          MockClient(
            (_) async => http.Response(
              jsonEncode({
                'error': {
                  'code': 'CONFLICT',
                  'message': 'that email or phone number is already registered',
                },
              }),
              409,
              headers: {'content-type': 'application/json'},
            ),
          ),
        );

        expect(
          await auth.register(identifier: 'a@b.com', password: 'hunter22'),
          isFalse,
        );
        expect(auth.lastError, contains('already registered'));
      },
    );
  });

  group('delete account', () {
    test(
      'wipes the local words and the session once the server confirms',
      () async {
        await seedWord('w1');
        await seedWord('w2');

        final auth = providerWith(
          MockClient((request) async {
            expect(request.method, 'DELETE');
            return http.Response('', 204);
          }),
        );

        expect(await auth.deleteAccount(password: 'hunter22'), isTrue);

        expect((await repo.stats()).totalWords, 0);
        expect(await repo.pendingChanges(), isEmpty);
        expect(auth.isSignedIn, isFalse);
        expect(tokens.refreshToken, isNull);
      },
    );

    test('a wrong password leaves the words and the session alone', () async {
      await seedWord('w1');

      final auth = providerWith(MockClient((_) async => invalidPassword()));
      await auth.restore();

      expect(await auth.deleteAccount(password: 'wrong'), isFalse);

      // The whole point: a failed delete must not destroy anything.
      expect((await repo.stats()).totalWords, 1);
      expect(tokens.refreshToken, 'refresh');
      expect(auth.lastError, contains('password'));
    });

    test('being offline leaves the words alone', () async {
      await seedWord('w1');

      final auth = providerWith(
        MockClient((_) async => throw http.ClientException('offline')),
      );

      expect(await auth.deleteAccount(password: 'hunter22'), isFalse);
      expect((await repo.stats()).totalWords, 1);
      expect(auth.lastError, contains('reach the server'));
    });

    test('sends the password for confirmation', () async {
      Map<String, Object?>? sent;
      final auth = providerWith(
        MockClient((request) async {
          sent = jsonDecode(request.body) as Map<String, Object?>;
          return http.Response('', 204);
        }),
      );

      await auth.deleteAccount(password: 'hunter22');
      expect(sent!['password'], 'hunter22');
    });
  });

  group('change password', () {
    test(
      'signs the user out, because the server revoked every session',
      () async {
        final auth = providerWith(
          MockClient((request) async {
            expect(request.method, 'PUT');
            return http.Response('', 204);
          }),
        );

        expect(
          await auth.changePassword(
            currentPassword: 'hunter22',
            newPassword: 'hunter333',
          ),
          isTrue,
        );

        expect(auth.isSignedIn, isFalse);
        expect(tokens.refreshToken, isNull);
        expect(auth.lastMessage, contains('sign in again'));
      },
    );

    test('a wrong current password keeps the session', () async {
      final auth = providerWith(MockClient((_) async => invalidPassword()));
      await auth.restore();

      expect(
        await auth.changePassword(
          currentPassword: 'wrong',
          newPassword: 'hunter333',
        ),
        isFalse,
      );
      expect(tokens.refreshToken, 'refresh');
      expect(auth.lastError, contains('password'));
    });
  });

  group('change identifier', () {
    test('keeps both identifiers and updates the cached one', () async {
      final auth = providerWith(
        MockClient(
          (_) async => ok({
            'data': {
              'email': 'kelvin@example.com',
              'phone': '+84901234567',
              'role': 'user',
              'status': 'active',
              'created_at': '2026-08-18T00:00:00Z',
              'updated_at': '2026-08-18T00:00:00Z',
            },
          }),
        ),
      );

      expect(
        await auth.changeIdentifier(
          identifier: '+84901234567',
          password: 'hunter22',
        ),
        isTrue,
      );

      expect(auth.profile!.email, 'kelvin@example.com');
      expect(auth.profile!.phone, '+84901234567');
      // Email stays primary, matching the server's rule.
      expect(auth.identifier, 'kelvin@example.com');
      // The session survives; this is not a sign-out.
      expect(auth.isSignedIn, isTrue);
    });

    test('a taken identifier surfaces the conflict', () async {
      final auth = providerWith(
        MockClient(
          (_) async => http.Response(
            jsonEncode({
              'error': {
                'code': 'CONFLICT',
                'message': 'that email or phone number is already registered',
              },
            }),
            409,
            headers: {'content-type': 'application/json'},
          ),
        ),
      );
      await auth.restore();

      expect(
        await auth.changeIdentifier(
          identifier: '+84901234567',
          password: 'hunter22',
        ),
        isFalse,
      );
      expect(auth.lastError, contains('already registered'));
      expect(auth.isSignedIn, isTrue);
    });
  });

  test('export returns the document the server sent', () async {
    final auth = providerWith(
      MockClient(
        (_) async => ok({
          'data': {'version': 1, 'count': 2, 'words': []},
        }),
      ),
    );

    final export = await auth.exportWords();
    expect(export!['count'], 2);
  });

  test('restore reads a session left on the device', () async {
    final auth = providerWith(MockClient((_) async => ok({'data': {}})));

    await auth.restore();

    expect(auth.isSignedIn, isTrue);
    expect(auth.identifier, 'kelvin@example.com');
  });

  test('restore with no stored session reports signed out', () async {
    tokens.refreshToken = null;
    final auth = providerWith(MockClient((_) async => ok({'data': {}})));

    await auth.restore();

    expect(auth.state, AuthState.signedOut);
  });
}
