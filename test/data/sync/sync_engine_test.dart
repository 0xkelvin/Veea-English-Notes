import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:veea_english_app/data/local/sqlite_vocabulary_repository.dart';
import 'package:veea_english_app/data/sync/learning_sync_api.dart';
import 'package:veea_english_app/data/sync/sync_engine.dart';
import 'package:veea_english_app/models/vocabulary_word.dart';
import 'package:veea_english_app/services/backup_service.dart';

const alice = '00000000-0000-4000-8000-000000000001';
const bob = '00000000-0000-4000-8000-000000000002';
const partition = 'account:$alice';
final now = DateTime.utc(2026, 11, 14, 8);
Map<String, Object?> record(
  String id, {
  String meaning = 'server',
  int revision = 1,
}) => {
  'entity_id': id,
  'deleted': false,
  'revision': revision,
  'content': {
    'word': id,
    'meaning': meaning,
    'pronunciation': null,
    'part_of_speech': null,
    'source': null,
    'examples': <String>[],
    'tags': <String>[],
  },
  'capture_day': '2026-11-14',
  'client_created_at': now.toIso8601String(),
  'updated_at': now.toIso8601String(),
};
http.Response response(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);
http.Response problem(String code, int status, {String? reason}) =>
    response({'code': code, 'reason': ?reason, 'epoch': 'epoch'}, status);
http.Response snapshot(
  List<Map<String, Object?>> records, {
  String? next,
  String epoch = 'epoch',
}) => response({
  'epoch': epoch,
  'snapshot_revision': 10,
  'items': records,
  'next_page_token': next,
  'catch_up_cursor': 'c1.10',
});
http.Response feed(
  List<Map<String, Object?>> records, {
  bool more = false,
  String cursor = 'c1.12',
}) => response({
  'epoch': 'epoch',
  'changes': records,
  'cursor': cursor,
  'has_more': more,
});
http.Response state({
  bool active = true,
  String epoch = 'epoch',
  int words = 0,
  int last = 1,
}) => response({
  'epoch': epoch,
  'head_revision': 10,
  'tombstone_horizon': 0,
  'live_words': words,
  'word_limit': 50000,
  'content_bytes': 0,
  'content_byte_limit': 67108864,
  'writer': {'writer_id': 'writer', 'active': active, 'last_seq': last},
});
http.Response result(
  Map<String, dynamic> mutation, {
  String outcome = 'applied',
  String? code,
  Map<String, Object?>? canonical,
  String? original,
}) => response({
  'results': [
    {
      'seq': mutation['seq'],
      'entity_id': mutation['entity_id'],
      'outcome': outcome,
      'code': ?code,
      'original_outcome': ?original,
      'record': canonical,
    },
  ],
  'head_revision': 10,
  'live_words': 1,
  'content_bytes': 100,
  'last_seq': mutation['seq'],
});
void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  late Directory dir;
  late SqliteVocabularyRepository repo;
  late String path;
  setUp(() async {
    dir = Directory.systemTemp.createTempSync('veea-sync-');
    path = '${dir.path}/db.sqlite';
    repo = await SqliteVocabularyRepository.open(path: path, now: () => now);
    await repo.activateNotebook(alice);
  });
  tearDown(() async {
    await repo.close();
    dir.deleteSync(recursive: true);
  });
  Future<void> reopen() async {
    await repo.close();
    repo = await SqliteVocabularyRepository.open(path: path, now: () => now);
  }

  Future<void> part({String? cursor = 'c1.1'}) => repo.database
      .insert('sync_partitions', {
        'partition': partition,
        'writer_id': 'writer',
        'epoch': 'epoch',
        'cursor': cursor,
        'next_seq': 0,
      })
      .then((_) {});
  Future<void> word(
    String id, {
    bool dirty = true,
    bool deleted = false,
    bool synced = false,
    String meaning = 'local',
    String provenance = 'account',
  }) async {
    await repo.database.insert('words', {
      ...VocabularyWord.create(
        id: id,
        word: id,
        meaning: meaning,
        date: '2026-11-14',
        now: now,
      ).toDbMap(),
      'is_dirty': dirty ? 1 : 0,
      'is_deleted': deleted ? 1 : 0,
      'provenance': provenance,
      if (synced) 'server_revision': 1,
      if (synced) 'server_copy': jsonEncode(record(id)),
    });
  }

  Future<void> queue(String id, String op) async {
    await repo.database.insert('sync_queue', {
      'partition': partition,
      'writer_id': 'writer',
      'seq': 1,
      'kind': 'push',
      'entity_id': id,
      'op': op,
      'unknown': 1,
      'payload': utf8.encode(
        jsonEncode({
          'seq': 1,
          'op': op,
          'entity_id': id,
          'base_revision': 1,
          if (op == 'update') 'changed_fields': ['meaning'],
          if (op == 'update') 'data': {'meaning': 'local'},
        }),
      ),
      'local_updated_at': now.toIso8601String(),
      'request_id': 'request',
    });
    await repo.database.update(
      'sync_partitions',
      {'next_seq': 1},
      where: 'partition = ?',
      whereArgs: [partition],
    );
  }

  SyncEngine engine(FutureOr<http.Response> Function(http.Request) route) =>
      SyncEngine(
        db: repo.database,
        now: () => now,
        api: LearningSyncApi(
          client: MockClient((r) async {
            if (r.url.path.endsWith('/writers')) {
              return response({
                'writer_id': 'new-writer',
                'epoch': 'epoch',
              }, 201);
            }
            return route(r);
          }),
          baseUrl: 'http://localhost',
          accessToken: () async => 'synthetic',
        ),
      );

  test(
    '§15.2.1 immutable queue survives restart, later 401/429/503 and authoritative last_seq',
    () async {
      await part();
      await word('one');
      final requests = <List<int>>[];
      var attempt = 0;
      Future<http.Response> route(http.Request r) async {
        if (r.url.path.endsWith('/state')) return state(last: 1);
        if (r.url.path.endsWith('/changes')) return feed([]);
        requests.add(List.of(r.bodyBytes));
        // This assertion executes at the transmission boundary, before the
        // simulated process loss; uncertainty must already be durable.
        expect((await repo.database.query('sync_queue')).single['unknown'], 1);
        attempt++;
        if (attempt == 1) throw TimeoutException('lost response');
        if (attempt <= 4) {
          return problem('unauthorized', [401, 429, 503][attempt - 2]);
        }
        final m =
            ((jsonDecode(r.body) as Map)['mutations'] as List).single
                as Map<String, dynamic>;
        return result(
          m,
          outcome: 'duplicate',
          original: 'applied',
          canonical: record('one', meaning: 'local'),
        );
      }

      expect(await engine(route).sync(), SyncRun.pending);
      for (var i = 0; i < 3; i++) {
        await reopen();
        expect(
          await engine(route).sync(),
          i == 0 ? SyncRun.unauthorized : SyncRun.pending,
        );
        expect((await repo.database.query('sync_queue')).single['seq'], 1);
      }
      await reopen();
      expect(await engine(route).sync(), SyncRun.done);
      for (final request in requests) {
        expect(
          sha256.convert(request).toString(),
          sha256.convert(requests.first).toString(),
        );
        expect(request, requests.first);
      }
      expect(await repo.database.query('sync_queue'), isEmpty);
      expect(
        (await repo.database.query('sync_partitions')).single['next_seq'],
        1,
      );
    },
  );

  for (final reflected in [true, false]) {
    test(
      '§15.2.2 expired mutation ${reflected ? 'reconciles' : 'reviews'} without renumbering',
      () async {
        await part();
        await word('one', synced: true);
        await queue('one', 'update');
        var sends = 0;
        final e = engine((r) {
          if (r.url.path.endsWith('/state')) return state();
          if (r.url.path.endsWith('/changes')) return feed([]);
          sends++;
          final m =
              ((jsonDecode(r.body) as Map)['mutations'] as List).single
                  as Map<String, dynamic>;
          return result(
            m,
            outcome: 'rejected',
            code: 'mutation_expired',
            canonical: record('one', meaning: reflected ? 'local' : 'other'),
          );
        });
        expect(await e.sync(), SyncRun.done);
        expect(sends, 1);
        expect((await e.reviewItems()).length, reflected ? 0 : 1);
        expect(
          (await repo.database.query('sync_partitions')).single['next_seq'],
          1,
        );
        expect(await e.sync(), SyncRun.done);
        expect(sends, 1);
      },
    );
  }

  test(
    '§15.2.3 paginated snapshot, concurrent feed, empty tail, compaction restart stage atomically',
    () async {
      await part(cursor: null);
      await word('old', dirty: false, synced: true);
      var snapshots = 0, tails = 0;
      final e = engine((r) async {
        // All pages see the original cache, never a partial snapshot.
        expect((await repo.database.query('words')).single['id'], 'old');
        if (r.url.path.endsWith('/snapshot')) {
          snapshots++;
          return r.url.queryParameters['page_token'] == null
              ? snapshot([
                  record(snapshots == 1 ? 'discarded' : 'one'),
                ], next: 's1.next')
              : snapshot([record('two')]);
        }
        tails++;
        if (tails == 1) {
          return problem(
            'sync_reset_required',
            410,
            reason: 'cursor_compacted',
          );
        }
        if (tails == 2) {
          return feed(
            [record('one', meaning: 'concurrent', revision: 11)],
            more: true,
            cursor: 'c1.11',
          );
        }
        return feed([], cursor: 'c1.12');
      });
      expect(await e.sync(), SyncRun.done);
      expect(snapshots, 4);
      expect(tails, 3);
      final rows = await repo.database.query('words', orderBy: 'id');
      expect(rows.map((r) => r['id']), ['one', 'two']);
      expect(rows.first['meaning'], 'concurrent');
      expect(await repo.database.query('sync_staging'), isEmpty);
      expect(
        (await repo.database.query('sync_partitions')).single['cursor'],
        'c1.12',
      );
    },
  );

  for (final restore in [false, true]) {
    test(
      '§15.2.4 ${restore ? 'restore' : 'retired writer'} reviews sent delete and never-sent update individually',
      () async {
        await part();
        await word('sent', deleted: true, synced: true);
        await queue('sent', 'delete');
        await word('never', synced: true);
        await word('clean-lost', dirty: false, synced: true);
        var pushes = 0;
        final e = engine((r) {
          if (r.url.path.endsWith('/state')) {
            return state(
              active: restore,
              epoch: restore ? 'restored' : 'epoch',
            );
          }
          if (r.url.path.endsWith('/snapshot')) {
            return snapshot([record('sent'), record('never')]);
          }
          if (r.url.path.endsWith('/changes')) return feed([]);
          pushes++;
          return problem('sync_unavailable', 503);
        });
        expect(await e.sync(), SyncRun.done);
        expect(pushes, 0);
        final items = await e.reviewItems();
        final sent = items.firstWhere((r) => r.entityId == 'sent');
        expect(sent.op, 'delete');
        expect(sent.row['writer_id'], 'writer');
        expect(sent.row['seq'], 1);
        expect(
          jsonDecode(
            utf8.decode(sent.row['original_payload'] as List<int>),
          )['op'],
          'delete',
        );
        expect(items.firstWhere((r) => r.entityId == 'never').payload['data'], {
          'meaning': 'local',
        });
        if (restore) {
          expect(items.any((i) => i.entityId == 'clean-lost'), isTrue);
        }
        await e.applyReview(items.firstWhere((r) => r.entityId == 'sent').id);
        expect(
          (await repo.database.query(
            'words',
            where: 'id = ?',
            whereArgs: ['sent'],
          )).single['is_deleted'],
          1,
        );
        await e.discardReview(
          items.firstWhere((r) => r.entityId == 'never').id,
        );
        expect(pushes, 0);
        expect(await repo.database.query('sync_queue'), isEmpty);
      },
    );
  }

  test(
    '§15.2.4 missing update requires distinct new-id recreation; absent deletes resolve',
    () async {
      await part();
      await word('missing', synced: true);
      await queue('missing', 'update');
      final e = engine((r) {
        if (r.url.path.endsWith('/state')) return state(active: false);
        if (r.url.path.endsWith('/snapshot')) return snapshot([]);
        return feed([]);
      });
      await e.sync();
      final item = (await e.reviewItems()).single;
      await expectLater(
        e.applyReview(item.id),
        throwsA(isA<ReviewActionUnavailable>()),
      );
      final id = await e.addAgainAsNewWord(item.id);
      expect(id, isNot('missing'));
      expect(await e.reviewItems(), isEmpty);
      await repo.database.delete('words');
      await repo.database.update(
        'sync_partitions',
        {'writer_id': 'writer'},
        where: 'partition = ?',
        whereArgs: [partition],
      );
      await word('absent', deleted: true, synced: true);
      await queue('absent', 'delete');
      await e.sync();
      expect(await e.reviewItems(), isEmpty);
    },
  );

  test(
    '§15.2.5 sign-out opens guest, closes account and leaves its queue unsent; accounts stay isolated',
    () async {
      await repo.activateNotebook(null);
      await word('guest', provenance: 'guest_created');
      await repo.activateNotebook(alice);
      await part();
      await word('private');
      await queue('private', 'update');
      await repo.activateNotebook(null);
      var sends = 0;
      final e = engine((_) {
        sends++;
        return feed([]);
      });
      expect(await e.sync(), SyncRun.skipped);
      expect(sends, 0);
      expect((await repo.database.query('words')).single['id'], 'guest');
      expect(await repo.database.query('sync_queue'), hasLength(1));
      await repo.activateNotebook(bob);
      expect(await repo.database.query('words'), isEmpty);
      await repo.activateNotebook(alice);
      expect((await repo.database.query('words')).single['id'], 'private');
    },
  );

  test(
    '§15.2.6 consent per dataset, capacity selection, exclusions local and durable reconfirmation',
    () async {
      await repo.activateNotebook(null);
      await word('guest-one', provenance: 'guest_created');
      await word('guest-two', provenance: 'guest_created');
      await word('legacy', provenance: 'legacy_untagged');
      await repo.activateNotebook(alice);
      await part();
      var sends = 0, states = 0, changed = true;
      Future<http.Response> route(http.Request r) async {
        if (r.url.path.endsWith('/state')) {
          states++;
          return state(words: 49999);
        }
        if (r.url.path.endsWith('/import')) {
          sends++;
          if (changed) return problem('capacity_changed', 409);
          final m =
              ((jsonDecode(r.body) as Map)['mutations'] as List).single
                  as Map<String, dynamic>;
          return result(
            m,
            canonical: record(m['entity_id'] as String, meaning: 'local'),
          );
        }
        return feed([]);
      }

      var e = engine(route);
      expect(await e.shouldPromptImport(), isTrue);
      await e.declineImport();
      expect(await e.shouldPromptImport(), isFalse);
      final plan = await e.planImport();
      expect(plan.candidates, hasLength(2));
      await expectLater(
        e.importWords(plan, ['guest-one', 'guest-two']),
        throwsA(isA<ImportOverCapacity>()),
      );
      final refused = await e.importWords(plan, ['guest-one']);
      expect(refused.needsConfirmation, isTrue);
      expect(states, greaterThanOrEqualTo(2));
      await reopen();
      e = engine(route);
      expect(await e.sync(), SyncRun.needsImportConfirmation);
      expect(sends, 1);
      changed = false;
      final refreshed = await e.planImport();
      expect((await e.confirmImport(refreshed, ['guest-one'])).imported, 1);
      expect(await e.shouldPromptImport(), isFalse);
      await repo.activateNotebook(null);
      expect(
        (await repo.database.query('words', orderBy: 'id')).map((r) => r['id']),
        ['guest-two', 'legacy'],
      );
    },
  );

  test(
    '§15.2.7 real pre-rebuild migration conservatively tags current and archived data',
    () async {
      await repo.close();
      final db = await databaseFactory.openDatabase(path);
      // Recreate the exact v11 boundary by removing only v12/v13 additions.
      await db.execute('DROP TRIGGER words_provenance');
      for (final c in [
        'provenance',
        'server_revision',
        'server_copy',
        'sync_hold',
        'sync_intent',
      ]) {
        await db.execute('ALTER TABLE words DROP COLUMN $c');
      }
      for (final t in [
        'sync_partitions',
        'sync_queue',
        'sync_review',
        'sync_staging',
        'sync_import_decisions',
      ]) {
        await db.execute('DROP TABLE $t');
      }
      await db.insert(
        'words',
        VocabularyWord.create(
          id: 'old-backup',
          word: 'old',
          meaning: 'm',
          date: '2026-11-14',
          now: now,
        ).toDbMap(),
      );
      await db.insert('account_workspaces', {
        'account_id': bob,
        'payload': jsonEncode({
          'words': [
            VocabularyWord.create(
              id: 'old-archive',
              word: 'old',
              meaning: 'm',
              date: '2026-11-14',
              now: now,
            ).toDbMap(),
          ],
        }),
      });
      await db.setVersion(11);
      await db.close();
      repo = await SqliteVocabularyRepository.open(path: path);
      expect(await repo.notebookOwner(), isNull);
      expect(
        (await repo.database.query('words')).map((r) => r['provenance']),
        everyElement('legacy_untagged'),
      );
      expect((await repo.database.query('words')).map((r) => r['id']).toSet(), {
        'old-backup',
        'old-archive',
      });
      final saved =
          jsonDecode(
                (await repo.database.query(
                      'account_workspaces',
                      where: 'account_id = ?',
                      whereArgs: ['__legacy__:$bob'],
                    )).single['payload']
                    as String,
              )
              as Map;
      expect((saved['words'] as List).single['provenance'], 'legacy_untagged');
      await repo.database.update('words', {'meaning': 'edited'});
      expect(
        (await repo.database.query('words')).map((r) => r['provenance']),
        everyElement('legacy_untagged'),
      );
      await repo.activateNotebook(bob);
      expect(await repo.database.query('words'), isEmpty);
      await repo.activateNotebook(alice);
      expect(
        await engine(
          (_) => throw StateError('no HTTP expected'),
        ).shouldPromptImport(),
        isFalse,
      );
    },
  );

  test(
    '§15.2.8 backups enforce user_id and never upgrade legacy provenance across JSON/CSV',
    () async {
      final foreign = BackupService.exportToJson([
        VocabularyWord.create(
          id: 'old',
          word: 'old',
          meaning: 'm',
          date: '2026-11-14',
          now: now,
        ),
      ], userId: bob);
      expect(
        (await BackupService.importBackupText(
          rawContent: foreign,
          repository: repo,
        )).errorMessage,
        contains('another account'),
      );
      const legacy = '{"words":[{"id":"legacy", "word":"old", "meaning":"m"}]}';
      expect(
        (await BackupService.previewBackup(
          rawContent: legacy,
          repository: repo,
        )).errorMessage,
        contains('guest notebook'),
      );
      await repo.activateNotebook(null);
      expect(
        (await BackupService.importBackupText(
          rawContent: foreign,
          repository: repo,
        )).isSuccess,
        isFalse,
      );
      expect(
        (await BackupService.importBackupText(
          rawContent: legacy,
          repository: repo,
        )).inserted,
        1,
      );
      await word('fresh', provenance: 'guest_created');
      for (final export in [
        BackupService.exportNotebookJson,
        BackupService.exportNotebookCsv,
      ]) {
        final text = await export(repo);
        await repo.deleteAll();
        expect(
          (await BackupService.importBackupText(
            rawContent: text,
            repository: repo,
          )).isSuccess,
          isTrue,
        );
        final rows = await repo.database.query('words', orderBy: 'id');
        expect(rows.first['provenance'], 'guest_created');
        expect(rows.last['provenance'], 'legacy_untagged');
      }
    },
  );

  test('§15.2.9 quota holds stay local until explicit Back up now', () async {
    await part();
    await word('one');
    var sends = 0;
    final e = engine((r) {
      if (r.url.path.endsWith('/state')) return state();
      if (r.url.path.endsWith('/changes')) return feed([]);
      sends++;
      final m =
          ((jsonDecode(r.body) as Map)['mutations'] as List).single
              as Map<String, dynamic>;
      return sends == 1
          ? result(m, outcome: 'rejected', code: 'quota_exceeded')
          : result(m, canonical: record('one', meaning: 'local'));
    });
    await e.sync();
    await e.sync();
    expect(sends, 1);
    expect(await e.heldWords(), hasLength(1));
    await e.backUpNow('one');
    await e.sync();
    expect(sends, 2);
    expect(await e.heldWords(), isEmpty);
  });

  test(
    '§15.2.1 a later edit survives a canonical merge while the send is in flight',
    () async {
      await part();
      await word('one', synced: true);
      var pushes = 0;
      final e = engine((r) async {
        if (r.url.path.endsWith('/changes')) return feed([]);
        if (r.url.path.endsWith('/state')) return state();
        pushes++;
        if (pushes > 1) return problem('rate_limited', 429);
        final m =
            ((jsonDecode(r.body) as Map)['mutations'] as List).single
                as Map<String, dynamic>;
        await repo.database.update('words', {
          'meaning': 'later',
          'updated_at': now.add(const Duration(seconds: 1)).toIso8601String(),
        });
        final merged = record('one', meaning: 'local', revision: 2);
        (merged['content']! as Map)['source'] = 'concurrent remote source';
        return result(m, canonical: merged);
      });
      expect(await e.sync(), SyncRun.pending);
      final row = (await repo.database.query('words')).single;
      expect(row['meaning'], 'later');
      expect(row['source'], 'concurrent remote source');
      final queued = (await repo.database.query('sync_queue')).single;
      final mutation =
          jsonDecode(utf8.decode(queued['payload'] as List<int>)) as Map;
      expect(mutation['seq'], 2);
      expect(mutation['changed_fields'], ['meaning']);
    },
  );

  test(
    '§15.2.3 account switch during snapshot cannot replace the newly opened cache',
    () async {
      await part(cursor: null);
      await word('alice-private', dirty: false, synced: true);
      var switched = false;
      final e = engine((r) async {
        if (r.url.path.endsWith('/snapshot')) {
          await repo.activateNotebook(bob);
          await word('bob-private', dirty: false);
          switched = true;
          return snapshot([record('alice-remote')]);
        }
        return feed([]);
      });
      expect(await e.sync(), SyncRun.skipped);
      expect(switched, isTrue);
      expect((await repo.database.query('words')).single['id'], 'bob-private');
      await repo.activateNotebook(alice);
      expect(
        (await repo.database.query('words')).single['id'],
        'alice-private',
      );
    },
  );

  test(
    '§15.2.6 an uncertain import keeps its mutation bytes through capacity refusal and explicit confirmation',
    () async {
      await repo.activateNotebook(null);
      await word('guest', provenance: 'guest_created');
      await repo.activateNotebook(alice);
      await part();
      final mutations = <String>[];
      var attempt = 0;
      Future<http.Response> route(http.Request r) async {
        if (r.url.path.endsWith('/state')) return state();
        if (r.url.path.endsWith('/changes')) return feed([]);
        final j = jsonDecode(r.body) as Map;
        mutations.add(jsonEncode(j['mutations']));
        attempt++;
        if (attempt == 1) throw TimeoutException('unknown');
        if (attempt == 2) return problem('capacity_changed', 409);
        return result(
          (j['mutations'] as List).single as Map<String, dynamic>,
          canonical: record('guest', meaning: 'local'),
        );
      }

      var e = engine(route);
      final plan = await e.planImport();
      expect((await e.importWords(plan, ['guest'])).pending, isTrue);
      final payload = (await repo.database.query(
        'sync_queue',
      )).single['payload'];
      await reopen();
      e = engine(route);
      expect(await e.sync(), SyncRun.needsImportConfirmation);
      expect(
        (await repo.database.query('sync_queue')).single['payload'],
        payload,
      );
      expect(await e.sync(), SyncRun.needsImportConfirmation);
      expect(attempt, 2);
      expect(
        (await e.confirmImport(await e.planImport(), ['guest'])).imported,
        1,
      );
      expect(mutations, everyElement(mutations.first));
    },
  );

  test(
    '§15.2.2 expired unknown import is review-only and never becomes a fresh import automatically',
    () async {
      await repo.activateNotebook(null);
      await word('guest', provenance: 'guest_created');
      await repo.activateNotebook(alice);
      await part();
      var attempt = 0;
      final e = engine((r) {
        if (r.url.path.endsWith('/state')) return state();
        if (r.url.path.endsWith('/changes')) return feed([]);
        attempt++;
        if (attempt == 1) throw TimeoutException('unknown');
        final m =
            ((jsonDecode(r.body) as Map)['mutations'] as List).single
                as Map<String, dynamic>;
        return result(m, outcome: 'rejected', code: 'mutation_expired');
      });
      await e.importWords(await e.planImport(), ['guest']);
      await e.sync();
      expect(await e.reviewItems(), hasLength(1));
      expect((await e.planImport()).candidates, isEmpty);
      await e.sync();
      expect(attempt, 2);
      final original = (await e.reviewItems()).single;
      expect(await e.addAgainAsNewWord(original.id), isNot('guest'));
    },
  );

  test(
    '§15.2.8 own-account backup stays local until an explicit capacity-checked selection',
    () async {
      await part();
      final backup = BackupService.exportToJson([
        VocabularyWord.create(
          id: 'backup',
          word: 'backup',
          meaning: 'local',
          date: '2026-11-14',
          now: now,
        ),
      ], userId: alice);
      expect(
        (await BackupService.importBackupText(
          rawContent: backup,
          repository: repo,
        )).inserted,
        1,
      );
      var imports = 0;
      final e = engine((r) {
        if (r.url.path.endsWith('/state')) return state();
        if (r.url.path.endsWith('/changes')) return feed([]);
        expect(r.url.path, endsWith('/import'));
        imports++;
        final m =
            ((jsonDecode(r.body) as Map)['mutations'] as List).single
                as Map<String, dynamic>;
        return result(m, canonical: record('backup', meaning: 'local'));
      });
      await e.sync();
      expect(imports, 0);
      final plan = await e.planImport();
      expect(plan.candidates, hasLength(1));
      expect((await e.importWords(plan, ['backup'])).imported, 1);
      expect((await repo.database.query('words')).single['sync_hold'], isNull);
    },
  );

  test('§15.2.1 retries preserve noncanonical original JSON bytes', () async {
    await part();
    await word('one', synced: true);
    await queue('one', 'update');
    const raw =
        '{ "entity_id" : "one", "op":"update", "seq":1, "base_revision":1, "changed_fields":["meaning"], "data":{"meaning":"local"} }';
    await repo.database.update('sync_queue', {'payload': utf8.encode(raw)});
    final e = engine((r) {
      if (r.url.path.endsWith('/state')) return state();
      expect(r.body, contains(raw));
      return problem('rate_limited', 429);
    });
    await e.sync();
    await reopen();
    expect(
      utf8.decode(
        (await repo.database.query('sync_queue')).single['payload']
            as List<int>,
      ),
      raw,
    );
  });

  test(
    '§15.2.3 fresh snapshot discovers a restore during a compacted-cursor reset',
    () async {
      await part();
      await word('sent', synced: true, deleted: true);
      await queue('sent', 'delete');
      await word('clean-lost', synced: true, dirty: false);
      final e = engine((r) {
        if (r.url.path.endsWith('/state')) return state();
        if (r.url.path.endsWith('/push')) {
          return problem(
            'sync_reset_required',
            410,
            reason: 'cursor_compacted',
          );
        }
        if (r.url.path.endsWith('/snapshot')) {
          return snapshot([record('sent')], epoch: 'restored');
        }
        return response({
          'epoch': 'restored',
          'changes': [],
          'cursor': 'c1.restored',
          'has_more': false,
        });
      });
      expect(await e.sync(), SyncRun.done);
      final items = await e.reviewItems();
      expect(items.map((r) => r.entityId).toSet(), {'sent', 'clean-lost'});
      expect(
        items.firstWhere((r) => r.entityId == 'sent').reason,
        startsWith('pre_restore'),
      );
      expect(await repo.database.query('sync_queue'), isEmpty);
    },
  );

  test(
    '§15.2.1 v12 queued bytes migrate conservatively into durable uncertainty',
    () async {
      await part();
      await word('one', synced: true);
      await queue('one', 'update');
      await repo.database.update('sync_queue', {'unknown': 0});
      final bytes = (await repo.database.query('sync_queue')).single['payload'];
      await repo.database.execute(
        'ALTER TABLE sync_partitions DROP COLUMN import_confirmation',
      );
      await repo.database.execute(
        'ALTER TABLE sync_queue DROP COLUMN request_id',
      );
      for (final column in ['writer_id', 'seq', 'original_payload']) {
        await repo.database.execute(
          'ALTER TABLE sync_review DROP COLUMN $column',
        );
      }
      await repo.database.setVersion(12);
      await reopen();
      final migrated = (await repo.database.query('sync_queue')).single;
      expect(migrated['payload'], bytes);
      expect(migrated['unknown'], 1);
      final e = engine(
        (r) => r.url.path.endsWith('/state')
            ? state()
            : problem('rate_limited', 429),
      );
      await e.sync();
      expect((await repo.database.query('sync_queue')).single['seq'], 1);
      expect(
        (await repo.database.query('sync_queue')).single['payload'],
        bytes,
      );
    },
  );

  test(
    '§15.2.10 confirmed deletion clears every owned sync record even while guest is open',
    () async {
      await part();
      await word('private');
      await queue('private', 'update');
      await repo.database.insert('sync_review', {
        'partition': partition,
        'entity_id': 'private',
        'op': 'delete',
        'payload': '{}',
        'reason': 'reset',
        'created_at': now.toIso8601String(),
      });
      await repo.database.insert('sync_staging', {
        'partition': partition,
        'entity_id': 'private',
        'record': '{}',
      });
      await repo.database.insert('sync_import_decisions', {
        'user_id': alice,
        'guest_dataset_id': 'dataset',
        'decision': 'declined',
        'decided_at': now.toIso8601String(),
      });
      await repo.activateNotebook(null);
      await word('guest', provenance: 'guest_created');
      await repo.deleteAll(accountId: alice);
      for (final table in [
        'sync_queue',
        'sync_review',
        'sync_staging',
        'sync_partitions',
        'sync_import_decisions',
        'account_workspaces',
      ]) {
        expect(await repo.database.query(table), isEmpty, reason: table);
      }
      expect((await repo.database.query('words')).single['id'], 'guest');
      await repo.activateNotebook(alice);
      expect(await repo.database.query('words'), isEmpty);
    },
  );
}
