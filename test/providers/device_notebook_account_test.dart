import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:veea_english_app/data/local/sqlite_vocabulary_repository.dart';
import 'package:veea_english_app/models/vocabulary_word.dart';
import 'package:veea_english_app/providers/vocabulary_provider.dart';
import '../data/go_session_test.dart' show tokens, userA, userB;
import '../support/go_account_stack.dart';
import '../support/secure_storage.dart';
import 'package:veea_english_app/providers/pro_provider.dart';
import 'package:veea_english_app/data/pro_repository.dart';
import 'pro_provider_test.dart' show TestPro;
import 'go_auth_provider_test.dart' show receipt, status;

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  test(
    'one device notebook survives sign-in, sign-out, account switch and confirmed deletion',
    () async {
      final repo = await SqliteVocabularyRepository.open(
        path: inMemoryDatabasePath,
      );
      final app = GoAccountStack(
        repo,
        TestSecureStorage(),
        'http://localhost',
        accountNotebooks: false,
        network: MockClient((r) async {
          if (r.url.path.endsWith('/password/login')) {
            return http.Response(
              jsonEncode(
                tokens(
                  user: (jsonDecode(r.body) as Map)['email'] == 'b@example.test'
                      ? userB
                      : userA,
                ),
              ),
              200,
            );
          }
          if (r.url.path.contains('/account-rights/deletions/')) {
            return http.Response(jsonEncode(status('completed')), 200);
          }
          return http.Response('{}', 200);
        }),
      );
      await repo.insert(
        VocabularyWord.create(
          id: 'local',
          word: 'hello',
          meaning: 'xin chào',
          date: '2026-11-17',
          now: DateTime.now(),
        ),
      );
      await app.auth.restore();
      await app.auth.signIn(
        identifier: 'a@example.test',
        password: 'synthetic',
      );
      expect((await repo.exportAll()).single.id, 'local');
      await app.auth.signOut();
      expect((await repo.exportAll()).single.id, 'local');
      await app.auth.signIn(
        identifier: 'b@example.test',
        password: 'synthetic',
      );
      expect((await repo.exportAll()).single.id, 'local');
      await app.auth.signIn(
        identifier: 'a@example.test',
        password: 'synthetic',
      );
      await app.store.saveReceipt(receipt(submitted: true, accepted: true));
      await app.auth.restore();
      await app.auth.checkPendingDeletion();
      expect((await repo.exportAll()).single.id, 'local');
      await app.close();
    },
  );
  test(
    'device backup is portable independently of account identity and imports only locally',
    () async {
      final a = await SqliteVocabularyRepository.open(
        path: inMemoryDatabasePath,
      );
      await a.activateNotebook(userA);
      await a.insert(
        VocabularyWord.create(
          id: 'private',
          word: 'hello',
          meaning: 'xin chào',
          date: '2026-11-17',
          now: DateTime.now(),
        ),
      );
      final source = VocabularyProvider(a, deviceNotebook: true);
      final json = await source.exportBackupJson();
      expect((jsonDecode(json) as Map)['source'], {'kind': 'device'});
      final csv = await source.exportBackupCsv();
      final b = await SqliteVocabularyRepository.open(
        path: inMemoryDatabasePath,
      );
      await b.activateNotebook(userB);
      final target = VocabularyProvider(b, deviceNotebook: true);
      expect((await target.previewBackup(json)).isSuccess, isTrue);
      expect((await target.importBackup(json)).isSuccess, isTrue);
      expect((await b.exportAll()).single.word, 'hello');
      expect((await target.previewBackup(csv)).isSuccess, isTrue);
      source.dispose();
      target.dispose();
      await a.close();
      await b.close();
    },
  );
  test(
    'network refresh failure keeps the verified purchase identity, explicit sign-out clears it',
    () async {
      var offline = false;
      final app = GoAccountStack(
        await SqliteVocabularyRepository.open(path: inMemoryDatabasePath),
        TestSecureStorage(),
        'http://localhost',
        accountNotebooks: false,
        network: MockClient((r) async {
          if (r.url.path.endsWith('/password/login')) {
            return http.Response(jsonEncode(tokens()), 200);
          }
          if (offline && r.url.path.endsWith('/token/refresh')) {
            throw http.ClientException('offline');
          }
          if (offline && r.url.path == '/v1/me') {
            return http.Response('{"code":"unauthorized"}', 401);
          }
          return http.Response('{}', 200);
        }),
      );
      await app.auth.restore();
      await app.auth.signIn(
        identifier: 'a@example.test',
        password: 'synthetic',
      );
      expect(app.auth.purchaseOwner, userA);
      final store = TestPro()
        ..state = const ProStoreState(hasPro: true, hasLifetime: true);
      final pro = ProProvider(auth: app.auth, repository: store);
      await pro.initializeDevice();
      offline = true;
      try {
        await app.client.get('/v1/me');
      } catch (_) {}
      await app.auth.notebookSettled;
      await Future<void>.delayed(Duration.zero);
      expect(app.auth.isSignedIn, isFalse);
      expect(app.auth.purchaseOwner, userA);
      expect(pro.hasPro, isTrue);
      expect(await app.store.readPurchaseOwner(), userA);
      await app.auth.signOut();
      await Future<void>.delayed(Duration.zero);
      expect(app.auth.purchaseOwner, isNull);
      expect(await app.store.readPurchaseOwner(), isNull);
      expect(pro.hasPro, isFalse);
      pro.dispose();
      await app.close();
    },
  );
  test(
    'explicit server session refusal clears cached purchase identity',
    () async {
      final app = GoAccountStack(
        await SqliteVocabularyRepository.open(path: inMemoryDatabasePath),
        TestSecureStorage(),
        'http://localhost',
        accountNotebooks: false,
        network: MockClient(
          (r) async => r.url.path.endsWith('/password/login')
              ? http.Response(jsonEncode(tokens()), 200)
              : http.Response('{"code":"unauthorized"}', 401),
        ),
      );
      await app.auth.restore();
      await app.auth.signIn(
        identifier: 'a@example.test',
        password: 'synthetic',
      );
      expect(app.auth.purchaseOwner, userA);
      try {
        await app.client.get('/v1/me');
      } catch (_) {}
      await app.auth.notebookSettled;
      expect(app.auth.purchaseOwner, isNull);
      expect(await app.store.readPurchaseOwner(), isNull);
      await app.close();
    },
  );
}
