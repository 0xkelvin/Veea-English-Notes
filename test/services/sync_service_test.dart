import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:veea_english_app/data/local/sqlite_vocabulary_repository.dart';
import 'package:veea_english_app/data/remote/api_client.dart';
import 'package:veea_english_app/data/remote/vocabulary_api.dart';
import 'package:veea_english_app/models/vocabulary_word.dart';
import 'package:veea_english_app/services/sync_service.dart';

/// Scripted server. Records what was pushed and replays queued responses.
class FakeVocabularyApi implements VocabularyApi {
  final List<List<VocabularyWord>> pushes = [];
  final List<DateTime?> cursors = [];
  final List<SyncResult> responses = [];

  Object? throwOnCall;

  @override
  Future<SyncResult> sync({
    required List<VocabularyWord> changes,
    DateTime? since,
  }) async {
    pushes.add(changes);
    cursors.add(since);

    if (throwOnCall != null) throw throwOnCall!;

    if (responses.isEmpty) {
      return SyncResult(
        acceptedIds: changes.map((w) => w.id).toList(),
        changes: const [],
        serverTime: DateTime.utc(2026, 8, 18, 12),
        hasMore: false,
      );
    }
    return responses.removeAt(0);
  }
}

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  TestWidgetsFlutterBinding.ensureInitialized();

  final today = DateTime(2026, 8, 18, 10);

  late SqliteVocabularyRepository repo;
  late FakeVocabularyApi api;
  late SyncService sync;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    repo = await SqliteVocabularyRepository.open(
      path: inMemoryDatabasePath,
      now: () => today,
    );
    api = FakeVocabularyApi();
    sync = SyncService(repository: repo, api: api, now: () => today);
  });

  tearDown(() => repo.close());

  VocabularyWord makeWord({
    required String id,
    String word = 'resilient',
    String meaning = 'kiên cường',
    String date = '2026-08-18',
    DateTime? updatedAt,
  }) {
    final base = VocabularyWord.create(
      id: id,
      word: word,
      meaning: meaning,
      date: date,
      now: today,
    );
    return updatedAt == null ? base : base.copyWith(updatedAt: updatedAt);
  }

  group('push', () {
    test('sends local changes and clears their pending flag', () async {
      await repo.insert(makeWord(id: 'a'));

      expect(await sync.synchronise(), isTrue);

      expect(api.pushes.single.map((w) => w.id), ['a']);
      expect(await repo.pendingChanges(), isEmpty);
      expect(sync.pendingCount, 0);
    });

    test('sends nothing when there is nothing pending', () async {
      await repo.insert(makeWord(id: 'a'));
      await repo.markSynced(['a'], today);

      await sync.synchronise();

      expect(api.pushes.single, isEmpty);
    });

    test('a word the server rejects stays pending', () async {
      await repo.insert(makeWord(id: 'mine'));
      await repo.insert(makeWord(id: 'foreign'));

      api.responses.add(
        SyncResult(
          // 'foreign' is withheld: it belongs to another account.
          acceptedIds: const ['mine'],
          changes: const [],
          serverTime: DateTime.utc(2026, 8, 18, 12),
          hasMore: false,
        ),
      );

      await sync.synchronise();

      final stillPending = await repo.pendingChanges();
      expect(stillPending.map((w) => w.id), ['foreign']);
    });
  });

  group('pull', () {
    test('applies changes the server returns', () async {
      api.responses.add(
        SyncResult(
          acceptedIds: const [],
          changes: [
            makeWord(id: 'remote', word: 'ergonomic', meaning: 'tiện dụng'),
          ],
          serverTime: DateTime.utc(2026, 8, 18, 12),
          hasMore: false,
        ),
      );

      await sync.synchronise();

      final stored = await repo.findById('remote');
      expect(stored!.word, 'ergonomic');
      // Rows from the server arrive clean; re-uploading them would loop.
      expect(stored.isDirty, isFalse);
    });

    test('a tombstone from the server removes the word locally', () async {
      await repo.insert(makeWord(id: 'a'));
      await repo.markSynced(['a'], today);

      api.responses.add(
        SyncResult(
          acceptedIds: const [],
          changes: [
            makeWord(
              id: 'a',
              updatedAt: today.add(const Duration(hours: 1)),
            ).copyWith(isDeleted: true),
          ],
          serverTime: DateTime.utc(2026, 8, 18, 12),
          hasMore: false,
        ),
      );

      await sync.synchronise();

      expect(await repo.wordsForDate('2026-08-18'), isEmpty);
    });

    test('the first sync asks for everything', () async {
      await sync.synchronise();
      expect(api.cursors.single, isNull);
    });

    test('the next sync resumes from the stored cursor', () async {
      final serverTime = DateTime.utc(2026, 8, 18, 12);
      api.responses.add(
        SyncResult(
          acceptedIds: const [],
          changes: const [],
          serverTime: serverTime,
          hasMore: false,
        ),
      );

      await sync.synchronise();
      await sync.synchronise();

      expect(api.cursors.last, serverTime);
    });

    test('keeps paging while the server reports more', () async {
      api.responses.addAll([
        SyncResult(
          acceptedIds: const [],
          changes: [makeWord(id: 'p1')],
          serverTime: DateTime.utc(2026, 8, 18, 12),
          hasMore: true,
        ),
        SyncResult(
          acceptedIds: const [],
          changes: [makeWord(id: 'p2')],
          serverTime: DateTime.utc(2026, 8, 18, 13),
          hasMore: false,
        ),
      ]);

      await sync.synchronise();

      expect(api.pushes, hasLength(2));
      // The push rides only on the first page; repeating it would duplicate
      // work on every subsequent page.
      expect(api.pushes[1], isEmpty);
      expect(await repo.findById('p1'), isNotNull);
      expect(await repo.findById('p2'), isNotNull);
    });
  });

  group('when the network is unavailable', () {
    setUp(() => api.throwOnCall = const OfflineException());

    test('reports failure without losing local words', () async {
      await repo.insert(makeWord(id: 'a'));

      expect(await sync.synchronise(), isFalse);

      expect(sync.state, SyncState.failed);
      expect(sync.lastError, contains('Offline'));
      // The word is untouched and still queued for the next attempt.
      expect(await repo.findById('a'), isNotNull);
      expect(await repo.pendingChanges(), hasLength(1));
    });

    test('does not advance the cursor', () async {
      await sync.synchronise();
      await sync.synchronise();

      // Both attempts asked from the same place.
      expect(api.cursors, [null, null]);
    });
  });

  test('a server error is reported without dropping local data', () async {
    api.throwOnCall = const ApiException('Boom', statusCode: 500);
    await repo.insert(makeWord(id: 'a'));

    expect(await sync.synchronise(), isFalse);
    expect(sync.state, SyncState.failed);
    expect(await repo.findById('a'), isNotNull);
  });

  test('acknowledged tombstones are purged after a successful sync', () async {
    await repo.insert(makeWord(id: 'a'));
    await repo.markSynced(['a'], today);
    await repo.softDelete('a', today);

    await sync.synchronise();

    // Pushed, acknowledged, and no longer worth storing.
    expect(await repo.findById('a'), isNull);
  });

  test('resetCursor forces the next sync to download everything', () async {
    api.responses.add(
      SyncResult(
        acceptedIds: const [],
        changes: const [],
        serverTime: DateTime.utc(2026, 8, 18, 12),
        hasMore: false,
      ),
    );
    await sync.synchronise();

    await sync.resetCursor();
    await sync.synchronise();

    expect(api.cursors.last, isNull);
  });

  test('a second call while syncing is ignored', () async {
    await repo.insert(makeWord(id: 'a'));

    final first = sync.synchronise();
    final second = sync.synchronise();

    expect(await first, isTrue);
    expect(await second, isFalse);
    expect(api.pushes, hasLength(1));
  });
}
