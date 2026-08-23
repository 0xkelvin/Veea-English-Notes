import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:veea_english_app/data/local/sqlite_vocabulary_repository.dart';
import 'package:veea_english_app/data/vocabulary_repository.dart';
import 'package:veea_english_app/models/vocabulary_stats.dart';
import 'package:veea_english_app/models/vocabulary_word.dart';
import 'package:veea_english_app/providers/vocabulary_provider.dart';

/// Wraps a real repository and fails writes on demand, so the provider's
/// failure handling is tested against genuine SQL behaviour rather than a
/// hand-rolled stub.
class FlakyRepository implements VocabularyRepository {
  FlakyRepository(this._inner);

  final VocabularyRepository _inner;
  bool failWrites = false;

  void _guard() {
    if (failWrites) throw StateError('disk unavailable');
  }

  @override
  Future<void> insert(VocabularyWord word) async {
    _guard();
    return _inner.insert(word);
  }

  @override
  Future<void> update(VocabularyWord word) async {
    _guard();
    return _inner.update(word);
  }

  @override
  Future<void> softDelete(String id, DateTime now) async {
    _guard();
    return _inner.softDelete(id, now);
  }

  @override
  Future<void> restore(String id, DateTime now) async {
    _guard();
    return _inner.restore(id, now);
  }

  @override
  Future<List<VocabularyWord>> wordsForDate(String date) =>
      _inner.wordsForDate(date);
  @override
  Future<List<VocabularyWord>> recentWords({int limit = 50}) =>
      _inner.recentWords(limit: limit);
  @override
  Future<List<VocabularyWord>> search(String query, {int limit = 200}) =>
      _inner.search(query, limit: limit);
  @override
  Future<VocabularyStats> stats() => _inner.stats();
  @override
  Future<Set<String>> datesWithWords() => _inner.datesWithWords();
  @override
  Future<VocabularyWord?> findById(String id) => _inner.findById(id);
  @override
  Future<void> purgeSyncedTombstones() => _inner.purgeSyncedTombstones();
  @override
  Future<List<VocabularyWord>> pendingChanges({int limit = 200}) =>
      _inner.pendingChanges(limit: limit);
  @override
  Future<void> markSynced(List<String> ids, DateTime syncedAt) =>
      _inner.markSynced(ids, syncedAt);
  @override
  Future<void> mergeFromServer(List<VocabularyWord> remote) =>
      _inner.mergeFromServer(remote);
  @override
  Future<void> deleteAll() => _inner.deleteAll();
  @override
  Future<void> close() => _inner.close();
}

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  final today = DateTime(2026, 8, 18, 10);
  late FlakyRepository repo;
  late VocabularyProvider provider;

  setUp(() async {
    repo = FlakyRepository(
      await SqliteVocabularyRepository.open(
        path: inMemoryDatabasePath,
        now: () => today,
      ),
    );
    provider = VocabularyProvider(repo, now: () => today);
    await provider.init();
  });

  tearDown(() => repo.close());

  test('starts on today with an empty list', () {
    expect(provider.status, LoadStatus.ready);
    expect(provider.selectedDateKey, '2026-08-18');
    expect(provider.isToday, isTrue);
    expect(provider.words, isEmpty);
  });

  test('adding a word shows it and updates the stats', () async {
    await provider.addWord(word: 'resilient', meaning: 'kiên cường');

    expect(provider.words.single.word, 'resilient');
    expect(provider.stats.totalWords, 1);
    expect(provider.stats.streakDays, 1);
    expect(provider.markedDates, contains('2026-08-18'));
  });

  test('a word is filed under the day being viewed, not today', () async {
    await provider.selectDate(DateTime(2026, 8, 15));
    await provider.addWord(word: 'brittle', meaning: 'giòn');

    expect(provider.words.single.date, '2026-08-15');

    await provider.goToToday();
    expect(provider.words, isEmpty);
  });

  test('editing replaces the values on screen', () async {
    await provider.addWord(word: 'resilient', meaning: 'kiên cường');

    await provider.updateWord(
      provider.words.single,
      word: 'resilient',
      meaning: 'bền bỉ',
      pronunciation: '/rɪˈzɪliənt/',
    );

    expect(provider.words.single.meaning, 'bền bỉ');
    expect(provider.words.single.pronunciation, '/rɪˈzɪliənt/');
  });

  test('deleting removes the word and offers an undo', () async {
    await provider.addWord(word: 'resilient', meaning: 'kiên cường');
    final id = provider.words.single.id;

    await provider.deleteWord(id);
    expect(provider.words, isEmpty);
    expect(provider.undoableDeletionId, id);

    await provider.undoDelete();
    expect(provider.words, hasLength(1));
    expect(provider.undoableDeletionId, isNull);
  });

  group('when a write fails', () {
    test('the word is not shown as saved', () async {
      repo.failWrites = true;
      await provider.addWord(word: 'resilient', meaning: 'kiên cường');

      // The old provider mutated its list before awaiting the write, so a
      // failure left a phantom word on screen that vanished on restart.
      expect(provider.words, isEmpty);
      expect(provider.lastError, isNotNull);
    });

    test('a delete failure leaves the word in place', () async {
      await provider.addWord(word: 'resilient', meaning: 'kiên cường');
      final id = provider.words.single.id;

      repo.failWrites = true;
      await provider.deleteWord(id);

      expect(provider.words, hasLength(1));
      expect(provider.lastError, isNotNull);
      expect(provider.undoableDeletionId, isNull);
    });

    test('the error clears once the UI has shown it', () async {
      repo.failWrites = true;
      await provider.addWord(word: 'x', meaning: 'y');
      expect(provider.lastError, isNotNull);

      provider.consumeError();
      expect(provider.lastError, isNull);
    });

    test('a later successful write clears the error', () async {
      repo.failWrites = true;
      await provider.addWord(word: 'x', meaning: 'y');

      repo.failWrites = false;
      await provider.addWord(word: 'resilient', meaning: 'kiên cường');

      expect(provider.lastError, isNull);
      expect(provider.words, hasLength(1));
    });
  });

  group('date navigation', () {
    test('moves a day at a time', () async {
      await provider.goToPreviousDay();
      expect(provider.selectedDateKey, '2026-08-17');
      await provider.goToNextDay();
      expect(provider.selectedDateKey, '2026-08-18');
      expect(provider.isToday, isTrue);
    });

    test('ignores reselecting the same day', () async {
      var notifications = 0;
      provider.addListener(() => notifications++);

      await provider.selectDate(DateTime(2026, 8, 18, 23, 59));
      expect(notifications, 0);
    });

    test('clears a pending undo when the day changes', () async {
      await provider.addWord(word: 'resilient', meaning: 'kiên cường');
      await provider.deleteWord(provider.words.single.id);
      expect(provider.undoableDeletionId, isNotNull);

      // Undoing after navigating away would restore a word the user can no
      // longer see, so the offer is withdrawn.
      await provider.goToPreviousDay();
      expect(provider.undoableDeletionId, isNull);
    });
  });

  test('search reaches words from any day', () async {
    await provider.selectDate(DateTime(2026, 8, 1));
    await provider.addWord(word: 'ergonomic', meaning: 'tiện dụng');
    await provider.goToToday();

    // The whole reason search exists: this word is 17 days back.
    final results = await provider.search('tien dung');
    expect(results.single.word, 'ergonomic');
  });
}
