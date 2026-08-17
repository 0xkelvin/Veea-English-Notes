import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:veea_english_app/data/local/sqlite_vocabulary_repository.dart';
import 'package:veea_english_app/models/part_of_speech.dart';
import 'package:veea_english_app/models/vocabulary_word.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  // Fixed "today" so streak and week-boundary assertions never drift.
  final today = DateTime(2026, 8, 18, 10);
  late SqliteVocabularyRepository repo;

  setUp(() async {
    repo = await SqliteVocabularyRepository.open(
      path: inMemoryDatabasePath,
      now: () => today,
    );
  });

  tearDown(() => repo.close());

  VocabularyWord makeWord({
    required String id,
    String word = 'resilient',
    String meaning = 'kiên cường',
    String date = '2026-08-18',
    DateTime? createdAt,
    String? source,
    List<String> examples = const [],
    List<String> tags = const [],
  }) {
    final stamp = createdAt ?? today;
    return VocabularyWord.create(
      id: id,
      word: word,
      meaning: meaning,
      date: date,
      now: stamp,
      source: source,
      examples: examples,
      tags: tags,
      partOfSpeech: PartOfSpeech.adjective,
    );
  }

  group('reads and writes', () {
    test('stores and returns a word for its day', () async {
      await repo.insert(makeWord(id: 'a'));

      final words = await repo.wordsForDate('2026-08-18');
      expect(words, hasLength(1));
      expect(words.single.word, 'resilient');
      expect(words.single.partOfSpeech, PartOfSpeech.adjective);
    });

    test('returns words newest first', () async {
      await repo.insert(
        makeWord(id: 'old', word: 'alpha', createdAt: DateTime(2026, 8, 18, 8)),
      );
      await repo.insert(
        makeWord(id: 'new', word: 'beta', createdAt: DateTime(2026, 8, 18, 9)),
      );

      final words = await repo.wordsForDate('2026-08-18');
      expect(words.map((w) => w.word), ['beta', 'alpha']);
    });

    test('does not leak words from other days', () async {
      await repo.insert(makeWord(id: 'a', date: '2026-08-18'));
      await repo.insert(makeWord(id: 'b', date: '2026-08-17'));

      expect(await repo.wordsForDate('2026-08-18'), hasLength(1));
    });

    test('trims whitespace and drops blank examples', () async {
      await repo.insert(
        makeWord(id: 'a', examples: ['  a real one  ', '   ', '']),
      );

      final word = (await repo.wordsForDate('2026-08-18')).single;
      expect(word.examples, ['a real one']);
    });
  });

  group('search', () {
    setUp(() async {
      await repo.insert(
        makeWord(
          id: 'a',
          word: 'resilient',
          meaning: 'kiên cường',
          examples: ['a resilient distributed system'],
          source: 'PR review',
        ),
      );
      await repo.insert(
        makeWord(id: 'b', word: 'throttle', meaning: 'điều tiết'),
      );
    });

    test('matches the English word', () async {
      expect((await repo.search('resil')).single.id, 'a');
    });

    test('matches Vietnamese with diacritics', () async {
      expect((await repo.search('kiên')).single.id, 'a');
    });

    test('matches Vietnamese typed without diacritics', () async {
      // The whole point of the folded search column.
      expect((await repo.search('kien cuong')).single.id, 'a');
      expect((await repo.search('dieu tiet')).single.id, 'b');
    });

    test('is case-insensitive across scripts', () async {
      expect((await repo.search('RESILIENT')).single.id, 'a');
      expect((await repo.search('KIÊN')).single.id, 'a');
    });

    test('matches example sentences and source', () async {
      expect((await repo.search('distributed')).single.id, 'a');
      expect((await repo.search('PR review')).single.id, 'a');
    });

    test('ranks a word-prefix match above an incidental one', () async {
      await repo.insert(
        makeWord(
          id: 'c',
          word: 'zebra',
          meaning: 'ngựa vằn',
          examples: ['not a resilient animal'],
        ),
      );

      final results = await repo.search('resilient');
      expect(results.first.id, 'a');
      expect(results.map((w) => w.id), containsAll(['a', 'c']));
    });

    test('returns nothing for a blank query', () async {
      expect(await repo.search('   '), isEmpty);
    });

    test('treats SQL wildcards as literal characters', () async {
      // Without escaping, '%' would match every row.
      expect(await repo.search('%'), isEmpty);
      expect(await repo.search('_'), isEmpty);
    });

    test('excludes deleted words', () async {
      await repo.softDelete('a', today);
      expect(await repo.search('resilient'), isEmpty);
    });
  });

  group('deletion', () {
    test('soft delete hides the word but keeps a tombstone to sync', () async {
      await repo.insert(makeWord(id: 'a'));
      await repo.markSynced(['a'], today);

      await repo.softDelete('a', today);

      expect(await repo.wordsForDate('2026-08-18'), isEmpty);
      final tombstone = await repo.findById('a');
      expect(tombstone!.isDeleted, isTrue);
      // Must be re-uploaded, else other devices resurrect the word.
      expect(tombstone.isDirty, isTrue);
    });

    test('restore brings the word back', () async {
      await repo.insert(makeWord(id: 'a'));
      await repo.softDelete('a', today);
      await repo.restore('a', today);

      expect(await repo.wordsForDate('2026-08-18'), hasLength(1));
    });

    test('purge removes only acknowledged tombstones', () async {
      await repo.insert(makeWord(id: 'a'));
      await repo.insert(makeWord(id: 'b'));
      await repo.softDelete('a', today);
      await repo.softDelete('b', today);
      await repo.markSynced(['a'], today);

      await repo.purgeSyncedTombstones();

      expect(await repo.findById('a'), isNull);
      expect(await repo.findById('b'), isNotNull);
    });

    test('deleted words are excluded from the totals', () async {
      await repo.insert(makeWord(id: 'a'));
      await repo.softDelete('a', today);
      expect((await repo.stats()).totalWords, 0);
    });
  });

  group('stats', () {
    test('are zero on an empty database', () async {
      expect((await repo.stats()).totalWords, 0);
      expect((await repo.stats()).streakDays, 0);
    });

    test('counts consecutive days ending today', () async {
      for (final date in ['2026-08-18', '2026-08-17', '2026-08-16']) {
        await repo.insert(makeWord(id: date, date: date));
      }
      expect((await repo.stats()).streakDays, 3);
    });

    test('a gap ends the streak', () async {
      for (final date in ['2026-08-18', '2026-08-16', '2026-08-15']) {
        await repo.insert(makeWord(id: date, date: date));
      }
      expect((await repo.stats()).streakDays, 1);
    });

    test(
      'yesterday still counts so an unstarted today does not reset it',
      () async {
        for (final date in ['2026-08-17', '2026-08-16']) {
          await repo.insert(makeWord(id: date, date: date));
        }
        expect((await repo.stats()).streakDays, 2);
      },
    );

    test('a stale streak reads as zero', () async {
      await repo.insert(makeWord(id: 'a', date: '2026-08-01'));
      expect((await repo.stats()).streakDays, 0);
    });

    test('this-week count starts on Monday', () async {
      // 2026-08-18 is a Tuesday, so the week starts 2026-08-17.
      await repo.insert(makeWord(id: 'mon', date: '2026-08-17'));
      await repo.insert(makeWord(id: 'sun', date: '2026-08-16'));

      expect((await repo.stats()).wordsThisWeek, 1);
    });
  });

  group('sync bookkeeping', () {
    test('new words start dirty and clear once marked synced', () async {
      await repo.insert(makeWord(id: 'a'));
      expect(await repo.pendingChanges(), hasLength(1));

      await repo.markSynced(['a'], today);
      expect(await repo.pendingChanges(), isEmpty);
      expect((await repo.findById('a'))!.syncedAt, isNotNull);
    });

    test('editing a synced word makes it dirty again', () async {
      await repo.insert(makeWord(id: 'a'));
      await repo.markSynced(['a'], today);

      final word = await repo.findById('a');
      await repo.update(
        word!.edited(word: 'resilient', meaning: 'bền bỉ', now: today),
      );

      expect(await repo.pendingChanges(), hasLength(1));
    });

    test('a newer server row overwrites a clean local row', () async {
      await repo.insert(makeWord(id: 'a', meaning: 'old'));
      await repo.markSynced(['a'], today);

      await repo.mergeFromServer([
        makeWord(
          id: 'a',
          meaning: 'from server',
        ).copyWith(updatedAt: today.add(const Duration(hours: 1))),
      ]);

      expect((await repo.findById('a'))!.meaning, 'from server');
    });

    test('an older server row is ignored', () async {
      await repo.insert(makeWord(id: 'a', meaning: 'local wins'));
      await repo.markSynced(['a'], today);

      await repo.mergeFromServer([
        makeWord(
          id: 'a',
          meaning: 'stale',
        ).copyWith(updatedAt: today.subtract(const Duration(hours: 1))),
      ]);

      expect((await repo.findById('a'))!.meaning, 'local wins');
    });

    test('an unsent local edit is never clobbered by the server', () async {
      await repo.insert(makeWord(id: 'a', meaning: 'unsent edit'));
      // Still dirty — the push half has not run yet.

      await repo.mergeFromServer([
        makeWord(
          id: 'a',
          meaning: 'from server',
        ).copyWith(updatedAt: today.add(const Duration(days: 1))),
      ]);

      expect((await repo.findById('a'))!.meaning, 'unsent edit');
      expect(await repo.pendingChanges(), hasLength(1));
    });

    test('unseen server rows are inserted as clean', () async {
      await repo.mergeFromServer([makeWord(id: 'remote')]);

      expect((await repo.findById('remote'))!.isDirty, isFalse);
      expect(await repo.pendingChanges(), isEmpty);
    });
  });

  test('datesWithWords lists only days that still hold words', () async {
    await repo.insert(makeWord(id: 'a', date: '2026-08-18'));
    await repo.insert(makeWord(id: 'b', date: '2026-08-17'));
    await repo.softDelete('b', today);

    expect(await repo.datesWithWords(), {'2026-08-18'});
  });
}
