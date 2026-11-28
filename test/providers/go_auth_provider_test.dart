import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:veea_english_app/data/local/sqlite_vocabulary_repository.dart';
import 'package:veea_english_app/data/remote/go/session_store.dart';
import 'package:veea_english_app/models/vocabulary_word.dart';
import 'package:veea_english_app/providers/auth_provider.dart';

import '../data/go_session_test.dart' show tokens, userA, userB;
import '../support/go_account_stack.dart';
import '../support/secure_storage.dart';

const operation = '00000000-0000-4000-8000-000000000005';
Map<String, Object?> status(String state) => {
  'operation_id': operation,
  'action': 'delete',
  'state': state,
  'accepted_at': state == 'pending' || state == 'completed'
      ? '2026-11-14T00:00:00Z'
      : null,
  'expires_at': '2026-12-14T00:00:00Z',
  'backup_expiry_due_at': null,
};
GoDeletionReceipt receipt({bool submitted = false, bool accepted = false}) =>
    GoDeletionReceipt({
      'user_id': userA,
      'operation_id': operation,
      'operation_token': 'vop_${'c' * 43}',
      'challenge_token': 'vct_${'d' * 43}',
      'proof_expires_at': '2026-12-01T00:00:00Z',
      'submitted': submitted,
      'locally_cleared': false,
      'state': accepted ? 'pending' : 'awaiting_proof',
      if (accepted) 'accepted_at': '2026-11-14T00:00:00Z',
    });
http.Response response(Object body, [int code = 200]) =>
    http.Response(jsonEncode(body), code);
void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  late GoAccountStack app;
  late TestSecureStorage secure;
  late Future<http.Response> Function(http.Request) handler;
  setUp(() async {
    secure = TestSecureStorage();
    handler = (r) async {
      if (r.url.path.endsWith('/password/login')) {
        final body = jsonDecode(r.body) as Map;
        return response(
          tokens(user: body['email'] == 'b@example.test' ? userB : userA),
        );
      }
      if (r.url.path == '/v1/me') {
        return response({
          'id': (await app.store.readSession())!.userId,
          'email': 'a@example.test',
        });
      }
      return response({});
    };
    app = GoAccountStack(
      await SqliteVocabularyRepository.open(path: inMemoryDatabasePath),
      secure,
      'http://localhost',
      network: MockClient((r) => handler(r)),
    );
    await app.auth.restore();
  });
  tearDown(() => app.close());
  Future<void> word(String id) => app.repo.insert(
    VocabularyWord.create(
      id: id,
      word: id,
      meaning: 'm',
      date: '2026-11-14',
      now: DateTime.utc(2026, 11, 14),
    ),
  );
  Future<void> seedReceipt(GoDeletionReceipt r) async {
    await app.store.saveReceipt(r);
    await app.auth.restore();
  }

  test(
    'startup removes only the legacy purchase owner and can retry',
    () async {
      const key = 'auth.go.purchase-owner.v1';
      final saved = await app.store.establish(tokens());
      await app.store.saveReceipt(receipt().withValues({'state': 'expired'}));
      await secure.write(key: 'unrelated', value: 'keep');
      final expected = secure.values;
      await secure.write(key: key, value: userB);

      secure.failingDeleteKey = key;
      await app.auth.restore();
      expect(app.auth.accountId, saved.userId);
      expect(secure.values[key], userB);

      secure.failingDeleteKey = null;
      await app.auth.restore();
      await app.auth.restore();
      expect(secure.values, expected);
      expect((await app.store.readSession())?.generation, saved.generation);
      expect(app.auth.deletionReceipt?.operationId, operation);
    },
  );

  test(
    'Go user.id selects the notebook; email is never the cache key',
    () async {
      await word('guest');
      expect(
        await app.auth.signIn(
          identifier: 'a@example.test',
          password: 'synthetic',
        ),
        isTrue,
      );
      expect(await app.repo.notebookOwner(), userA);
      expect(await app.repo.exportAll(), isEmpty);
      await word('a');
      await app.auth.signOut();
      expect((await app.repo.exportAll()).single.id, 'guest');
      await app.auth.signIn(
        identifier: 'b@example.test',
        password: 'synthetic',
      );
      expect(await app.repo.exportAll(), isEmpty);
      await app.auth.signIn(
        identifier: 'a@example.test',
        password: 'synthetic',
      );
      expect((await app.repo.exportAll()).single.id, 'a');
    },
  );
  test(
    'a login response arriving after sign-out cannot commit a new session',
    () async {
      final pending = Completer<http.Response>(), started = Completer<void>();
      handler = (r) async {
        if (r.url.path.endsWith('/password/login')) {
          started.complete();
          return pending.future;
        }
        return response({});
      };
      final login = app.auth.signIn(
        identifier: 'a@example.test',
        password: 'synthetic',
      );
      await started.future;
      await app.auth.signOut();
      pending.complete(response(tokens()));
      expect(await login, isFalse);
      expect(await app.store.readSession(), isNull);
      expect(await app.repo.notebookOwner(), isNull);
    },
  );
  test(
    'malformed stable identity is refused without opening or uploading a cache',
    () async {
      await word('guest');
      handler = (_) async => response(tokens(user: 'a@example.test'));
      expect(
        await app.auth.signIn(
          identifier: 'a@example.test',
          password: 'synthetic',
        ),
        isFalse,
      );
      expect(await app.repo.notebookOwner(), isNull);
      expect((await app.repo.exportAll()).single.id, 'guest');
    },
  );
  test(
    'fresh delete proof is saved before submission and a first wrong code erases nothing',
    () async {
      await app.auth.signIn(
        identifier: 'a@example.test',
        password: 'synthetic',
      );
      await word('owned');
      handler = (r) async {
        if (r.url.path == '/v1/me') {
          return response({'id': userA, 'email': 'a@example.test'});
        }
        if (r.url.path.endsWith('/start')) {
          return response({
            'operation_id': operation,
            'operation_token': receipt().capability,
            'challenge_token': receipt().challenge,
            'expires_at': '2026-12-01T00:00:00Z',
            'resend_after': '2026-11-14T00:01:00Z',
          }, 202);
        }
        expect(
          r.headers['authorization'] == 'Rights ${receipt().capability}',
          isTrue,
        );
        expect((await app.store.readReceipt())?.submitted, isTrue);
        expect((jsonDecode(r.body) as Map)['confirm'], 'delete_account');
        return response({'code': 'invalid_code'}, 400);
      };
      expect(await app.auth.requestDeletion(), isTrue);
      expect(await app.auth.confirmDeletion('000000'), isFalse);
      expect((await app.repo.exportAll()).single.id, 'owned');
      expect((await app.store.readReceipt())?.submitted, isFalse);
      expect(app.auth.isSignedIn, isTrue);
    },
  );
  test(
    'confirmed old-account receipt erases only that UUID while another account is signed in',
    () async {
      await app.auth.signIn(
        identifier: 'a@example.test',
        password: 'synthetic',
      );
      await word('a');
      await app.store.saveReceipt(receipt(submitted: true));
      await app.auth.restore();
      await app.auth.signIn(
        identifier: 'b@example.test',
        password: 'synthetic',
      );
      await word('b');
      handler = (_) async => response(status('pending'));
      expect(await app.auth.checkPendingDeletion(), DeletionOutcome.deleted);
      expect(app.auth.accountId, userB);
      expect(app.auth.blocksCloudSync, isFalse);
      expect((await app.store.readSession())?.userId, userB);
      expect((await app.repo.exportAll()).single.id, 'b');
      await app.repo.activateNotebook(userA);
      expect(await app.repo.exportAll(), isEmpty);
    },
  );
  test(
    'persisted acceptance finishes local erase offline after restart',
    () async {
      await word('guest');
      await app.auth.signIn(
        identifier: 'a@example.test',
        password: 'synthetic',
      );
      await word('owned');
      handler = (_) async => throw http.ClientException('synthetic offline');
      await seedReceipt(receipt(submitted: true, accepted: true));
      expect((await app.repo.exportAll()).single.id, 'guest');
      expect((await app.store.readReceipt())?.locallyCleared, isTrue);
      await app.repo.activateNotebook(userA);
      expect(await app.repo.exportAll(), isEmpty);
    },
  );
  for (final refusal in [401, 404]) {
    test('receipt $refusal is not evidence to erase an account', () async {
      await app.auth.signIn(
        identifier: 'a@example.test',
        password: 'synthetic',
      );
      await word('owned');
      handler = (_) async => response({'code': 'not_found'}, refusal);
      await seedReceipt(receipt(submitted: true));
      expect(await app.auth.checkPendingDeletion(), DeletionOutcome.unknown);
      expect((await app.store.readReceipt())?.locallyCleared, isFalse);
      await app.repo.activateNotebook(userA);
      expect((await app.repo.exportAll()).single.id, 'owned');
    });
  }
  test(
    'receipt from a different operation cannot trigger local erasure',
    () async {
      await app.auth.signIn(
        identifier: 'a@example.test',
        password: 'synthetic',
      );
      await word('owned');
      handler = (_) async => response({
        ...status('pending'),
        'operation_id': '00000000-0000-4000-8000-000000000099',
      });
      await seedReceipt(receipt(submitted: true));
      expect((await app.store.readReceipt())?.locallyCleared, isFalse);
      await app.repo.activateNotebook(userA);
      expect((await app.repo.exportAll()).single.id, 'owned');
    },
  );
}
