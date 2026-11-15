import 'package:veea_english_app/data/remote/api_client.dart' show ApiException;
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';
import 'package:veea_english_app/core/config/app_config.dart';
import 'package:veea_english_app/data/local/sqlite_vocabulary_repository.dart';
import 'package:veea_english_app/data/remote/go/api_client.dart';
import 'package:veea_english_app/data/sync/sync_engine.dart';
import 'package:veea_english_app/models/vocabulary_word.dart';
import 'package:veea_english_app/providers/auth_provider.dart';
import 'package:veea_english_app/services/backup_service.dart';

import '../support/secure_storage.dart';
import '../support/go_account_stack.dart';

/// Faults intercept responses AFTER the real Go handler commits. They neither
/// fabricate API successes nor bypass the Go router's OpenAPI validation.
class FaultClient extends http.BaseClient {
  final http.Client _inner = http.Client();
  bool holdRefresh = false,
      loseRefresh = false,
      loseDelete = false,
      blockReceipt = false,
      losePush = false;
  final refreshCommitted = Completer<void>(),
      releaseRefresh = Completer<void>();
  int refreshes = 0;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final path = request.url.path;
    if (blockReceipt && path.startsWith('/v1/account-rights/deletions/')) {
      throw http.ClientException('synthetic unavailable receipt');
    }
    final response = await http.Response.fromStream(await _inner.send(request));
    if (path == '/v1/auth/token/refresh') {
      refreshes++;
      if (holdRefresh) {
        refreshCommitted.complete();
        await releaseRefresh.future;
      }
      if (loseRefresh) {
        throw http.ClientException('synthetic lost refresh response');
      }
    }
    if (loseDelete &&
        path.startsWith('/v1/account-rights/delete/') &&
        path.endsWith('/complete')) {
      throw http.ClientException('synthetic lost deletion response');
    }
    if (losePush && path == '/v1/learning/sync/push') {
      losePush = false;
      throw http.ClientException('synthetic lost mutation response');
    }
    return http.StreamedResponse(
      Stream.value(response.bodyBytes),
      response.statusCode,
      headers: response.headers,
    );
  }

  @override
  void close() {
    _inner.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // This dedicated local-service test must use real loopback sockets.
  HttpOverrides.global = null;
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  final base = Platform.environment['VEEA_FLUTTER_GO_URL'];
  final control = Platform.environment['VEEA_FLUTTER_CONTROL_URL'];
  final mailpit = Platform.environment['VEEA_TEST_MAILPIT_API'];
  final configured = base != null && control != null && mailpit != null;
  if (configured) {
    for (final url in [base, control, mailpit]) {
      if (Uri.parse(url).host != '127.0.0.1') {
        throw StateError('E2E services must be loopback');
      }
    }
  }
  final httpClient = http.Client();
  late Directory dir;
  late GoAccountStack app;
  Future<Map<String, dynamic>> controlGet(String path) async {
    final r = await httpClient.get(Uri.parse('$control$path'));
    expect(r.statusCode, 200);
    return (jsonDecode(r.body) as Map).cast<String, dynamic>();
  }

  Future<void> command(
    String path, [
    Map<String, Object?> body = const {},
  ]) async {
    final r = await httpClient.post(
      Uri.parse('$control$path'),
      body: jsonEncode(body),
      headers: {'content-type': 'application/json'},
    );
    expect(r.statusCode, 200);
  }

  Future<Set<String>> existingMail(String email) async {
    final r = await httpClient.get(
      Uri.parse(
        '$mailpit/api/v1/search',
      ).replace(queryParameters: {'query': 'to:"$email"'}),
    );
    final body = jsonDecode(r.body) as Map;
    return ((body['messages'] ?? body['Messages']) as List)
        .map((m) => ((m as Map)['ID'] ?? m['id'])! as String)
        .toSet();
  }

  Future<String> emailCode(
    String email,
    String subject, {
    Set<String> exclude = const {},
  }) async {
    for (var i = 0; i < 200; i++) {
      final search = await httpClient.get(
        Uri.parse(
          '$mailpit/api/v1/search',
        ).replace(queryParameters: {'query': 'to:"$email"'}),
      );
      expect(search.statusCode, 200);
      final messages =
          (jsonDecode(search.body) as Map)['messages'] as List? ??
          (jsonDecode(search.body) as Map)['Messages'] as List? ??
          [];
      for (final message in messages) {
        final m = message as Map;
        if ((m['Subject'] ?? m['subject']) != subject) continue;
        final id = m['ID'] ?? m['id'];
        if (exclude.contains(id)) continue;
        final response = await httpClient.get(
          Uri.parse('$mailpit/api/v1/message/$id'),
        );
        final full = jsonDecode(response.body) as Map;
        final text = full['Text'] ?? full['text'];
        final code = RegExp(
          r'\b[0-9]{6}\b',
        ).firstMatch(text! as String)?.group(0);
        if (code != null) return code;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    throw StateError(
      'Mailpit did not receive the expected synthetic code email',
    );
  }

  String email() => '${const Uuid().v4()}@flutter.example.test';
  String password() => 'Test-only!${const Uuid().v4()}';
  Future<void> signup(GoAccountStack s, String email, String password) async {
    final prior = await existingMail(email);
    final challenge = await s.auth.startEmail(
      email,
      signup: true,
      password: password,
    );
    expect(challenge != null, isTrue);
    final code = await emailCode(
      email,
      'Your Veea sign-up code',
      exclude: prior,
    );
    expect(
      await s.auth.verifyEmail(challenge!, code),
      isTrue,
      reason: s.auth.lastError,
    );
  }

  Future<void> addWord(GoAccountStack s, String id) => s.repo.insert(
    VocabularyWord.create(
      id: id,
      word: 'synthetic $id',
      meaning: 'integration fixture',
      date: '2026-11-14',
      now: DateTime.utc(2026, 11, 14),
    ),
  );
  setUp(() async {
    if (!configured) return;
    AppConfig.overrideBaseUrl(base);
    dir = Directory.systemTemp.createTempSync('veea-go-e2e-');
    app = GoAccountStack(
      await SqliteVocabularyRepository.open(
        path: '${dir.path}/notebook.sqlite',
      ),
      TestSecureStorage(file: File('${dir.path}/secure.json')),
      base,
    );
    await app.auth.restore();
  });
  tearDown(() async {
    if (!configured) return;
    await app.close();
    dir.deleteSync(recursive: true);
    AppConfig.overrideBaseUrl(null);
  });
  tearDownAll(httpClient.close);

  test(
    'real signup Mailpit proof, stable UUID password/OTP sign-in, sessions, guest sign-out and fixture-only sync',
    () async {
      final address = email(), secret = password();
      final guestId = const Uuid().v4();
      await addWord(app, guestId);
      await signup(app, address, secret);
      final owner = app.auth.accountId!;
      expect(owner == address, isFalse);
      expect(await app.repo.notebookOwner(), owner);
      expect(await app.repo.exportAll(), isEmpty);
      final sessions = await app.api.sessions();
      expect((sessions['sessions']! as List).single['is_current'], isTrue);
      await expectLater(
        app.client.get('/v1/learning/sync/state'),
        throwsA(
          isA<ApiException>()
              .having((e) => e.statusCode, 'status', 503)
              .having((e) => e.code, 'code', 'sync_unavailable'),
        ),
      );
      await command('/open-fixture-sync');
      final id = const Uuid().v4();
      await addWord(app, id);
      expect(await app.engine.sync(), SyncRun.done);
      await app.auth.signOut();
      expect(await app.repo.notebookOwner(), isNull);
      expect((await app.repo.exportAll()).single.id, guestId);
      expect(
        await app.auth.signIn(identifier: address, password: secret),
        isTrue,
      );
      expect(app.auth.accountId, owner);
      expect((await app.repo.exportAll()).single.id, id);
      final other = await app.auth.startEmail(address);
      final code = await emailCode(address, 'Your Veea sign-in code');
      expect(await app.auth.verifyEmail(other!, code), isTrue);
      expect(app.auth.accountId, owner);
      final listed = (await app.api.sessions())['sessions']! as List;
      final foreignToCurrent = listed.cast<Map>().firstWhere(
        (s) => s['is_current'] == false,
      );
      await app.api.revokeSession(foreignToCurrent['id']! as String);
      await app.auth.signOutAll();
      expect(app.auth.isSignedIn, isFalse);
    },
    skip: !configured,
  );

  test(
    'real concurrent 401 requests rotate once and persist both tokens before reuse',
    () async {
      await signup(app, email(), password());
      final old = (await app.store.readSession())!;
      await command('/expire-access', {'session_id': old.sessionId});
      final fault = FaultClient();
      final client = GoApiClient(
        tokens: app.store,
        baseUrl: base,
        httpClient: fault,
      );
      try {
        await Future.wait(List.generate(20, (_) => client.get('/v1/me')));
        expect(fault.refreshes, 1);
        final next = (await app.store.readSession())!;
        expect(
          next.access != old.access && next.refresh != old.refresh,
          isTrue,
        );
        final status = await controlGet(
          '/session-state?session_id=${old.sessionId}',
        );
        expect(status['rotation'], 1);
        expect(status['revoked_reason'], isNull);
      } finally {
        client.dispose();
      }
    },
    skip: !configured,
  );

  for (final switching in [false, true]) {
    test(
      'real server rotates but a late response cannot restore credentials after ${switching ? 'account switch' : 'sign-out'}',
      () async {
        final address = email(), secret = password();
        await signup(app, address, secret);
        String? otherEmail, otherSecret, otherId;
        if (switching) {
          otherEmail = email();
          otherSecret = password();
          final other = GoAccountStack(
            await SqliteVocabularyRepository.open(
              path: '${dir.path}/other.sqlite',
            ),
            TestSecureStorage(),
            base!,
          );
          try {
            await signup(other, otherEmail, otherSecret);
            otherId = other.auth.accountId;
          } finally {
            await other.close();
          }
        }
        final old = (await app.store.readSession())!;
        final secure = app.secure;
        await app.close();
        final fault = FaultClient()..holdRefresh = true;
        app = GoAccountStack(
          await SqliteVocabularyRepository.open(
            path: '${dir.path}/notebook.sqlite',
          ),
          secure,
          base!,
          network: fault,
        );
        await app.auth.restore();
        await command('/expire-access', {'session_id': old.sessionId});
        final response = app.client
            .get('/v1/me')
            .then((_) => true, onError: (Object _) => false);
        await fault.refreshCommitted.future;
        if (switching) {
          expect(
            await app.auth.signIn(
              identifier: otherEmail!,
              password: otherSecret!,
            ),
            isTrue,
          );
        } else {
          await app.auth.signOut();
        }
        fault.releaseRefresh.complete();
        expect(await response, isFalse);
        expect(app.auth.accountId, switching ? otherId : null);
        expect(
          (await app.store.readSession())?.userId,
          switching ? otherId : null,
        );
        if (switching) expect((await app.client.get('/v1/me'))['id'], otherId);
      },
      skip: !configured,
    );
  }

  test(
    'real lost refresh response is not retried, including after provider/storage restart',
    () async {
      await signup(app, email(), password());
      final old = (await app.store.readSession())!;
      final secure = app.secure;
      await app.close();
      final fault = FaultClient()..loseRefresh = true;
      app = GoAccountStack(
        await SqliteVocabularyRepository.open(
          path: '${dir.path}/notebook.sqlite',
        ),
        secure,
        base!,
        network: fault,
      );
      await app.auth.restore();
      await command('/expire-access', {'session_id': old.sessionId});
      await expectLater(
        app.client.get('/v1/me'),
        throwsA(isA<FreshSignInRequired>()),
      );
      await app.auth.notebookSettled;
      expect(app.auth.isSignedIn, isFalse);
      expect(fault.refreshes, 1);
      await app.close();
      app = GoAccountStack(
        await SqliteVocabularyRepository.open(
          path: '${dir.path}/notebook.sqlite',
        ),
        TestSecureStorage(file: File('${dir.path}/secure.json')),
        base,
      );
      await app.auth.restore();
      await expectLater(
        app.client.get('/v1/me'),
        throwsA(isA<FreshSignInRequired>()),
      );
      final status = await controlGet(
        '/session-state?session_id=${old.sessionId}',
      );
      expect(status['rotation'], 1);
      expect(
        status['revoked_reason'],
        isNull,
        reason: 'the consumed token was never resent',
      );
    },
    skip: !configured,
  );

  test(
    'real deletion response loss, receipt after restart, local erase at acceptance, purge and same-email new UUID',
    () async {
      final address = email(), secret = password();
      final guest = const Uuid().v4();
      await addWord(app, guest);
      await signup(app, address, secret);
      final old = (await app.store.readSession())!;
      final word = const Uuid().v4();
      await addWord(app, word);
      expect(await app.engine.sync(), SyncRun.done);
      final backup = await BackupService.exportNotebookJson(app.repo);
      final secure = app.secure;
      await app.close();
      final fault = FaultClient()..losePush = true;
      app = GoAccountStack(
        await SqliteVocabularyRepository.open(
          path: '${dir.path}/notebook.sqlite',
        ),
        secure,
        base!,
        network: fault,
      );
      await app.auth.restore();
      await addWord(app, const Uuid().v4());
      expect(await app.engine.sync(), SyncRun.pending);
      expect(await app.repo.database.query('sync_queue'), isNotEmpty);
      await app.repo.database.insert('sync_review', {
        'partition': 'account:${old.userId}',
        'entity_id': word,
        'op': 'delete',
        'payload': '{}',
        'reason': 'fixture',
        'created_at': DateTime.now().toUtc().toIso8601String(),
      });
      expect(await app.auth.requestDeletion(), isTrue);
      final code = await emailCode(
        address,
        'Confirm deletion of your Veea account',
      );
      fault
        ..loseDelete = true
        ..blockReceipt = true;
      expect(await app.auth.confirmDeletion(code), isFalse);
      expect(await app.store.readSession(), isNull);
      expect(
        await app.repo.database.query('sync_queue'),
        isNotEmpty,
        reason: 'an unknown response is not local erase confirmation',
      );
      expect(await app.store.readReceipt(), isNotNull);
      await app.close();
      app = GoAccountStack(
        await SqliteVocabularyRepository.open(
          path: '${dir.path}/notebook.sqlite',
        ),
        TestSecureStorage(file: File('${dir.path}/secure.json')),
        base,
      );
      await app.auth.restore();
      expect(app.auth.deletionReceipt?.state, 'pending');
      expect(app.auth.deletionReceipt?.locallyCleared, isTrue);
      for (final table in [
        'sync_queue',
        'sync_review',
        'sync_staging',
        'sync_partitions',
      ]) {
        expect(
          await app.repo.database.query(
            table,
            where: 'partition = ?',
            whereArgs: ['account:${old.userId}'],
          ),
          isEmpty,
          reason: table,
        );
      }
      expect((await app.repo.exportAll()).single.id, guest);
      final rejected = await app.client.raw(
        'GET',
        '/v1/me',
        authenticated: false,
        extraHeaders: {'authorization': 'Bearer ${old.access}'},
      );
      expect(rejected.statusCode, 401);
      await command('/purge');
      expect(await app.auth.checkPendingDeletion(), DeletionOutcome.deleted);
      expect(app.auth.deletionReceipt?.state, 'completed');
      await command('/elapse-cooldowns');
      await signup(app, address, password());
      final newId = app.auth.accountId!;
      expect(newId != old.userId, isTrue);
      expect(app.auth.blocksCloudSync, isFalse);
      expect(await app.repo.exportAll(), isEmpty);
      expect(await app.repo.database.query('sync_queue'), isEmpty);
      expect(
        (await BackupService.importBackupText(
          rawContent: backup,
          repository: app.repo,
        )).isSuccess,
        isFalse,
      );
      expect(await app.auth.checkPendingDeletion(), DeletionOutcome.deleted);
      expect(
        (await app.store.readSession())?.userId,
        newId,
        reason: 'polling old receipts cannot sign out or wipe a new owner',
      );
      expect(await app.engine.sync(), SyncRun.done);
      expect(await app.repo.exportAll(), isEmpty);
    },
    skip: !configured,
  );
}
