import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart' show Sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:veea_english_app/data/local/app_database.dart';
import 'package:veea_english_app/data/local/sqlite_vocabulary_repository.dart';
import 'package:veea_english_app/models/vocabulary_word.dart';
import 'package:veea_english_app/services/pronunciation_service.dart';

/// Exercises the real bundled asset, not a stub: the point of these tests is
/// that the shipped dictionary actually answers for ordinary words.
void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  // rootBundle needs the binding to resolve the asset.
  TestWidgetsFlutterBinding.ensureInitialized();

  final today = DateTime(2026, 8, 18, 10);

  late SqliteVocabularyRepository repo;
  late PronunciationService pronunciation;

  setUp(() async {
    repo = await SqliteVocabularyRepository.open(
      path: inMemoryDatabasePath,
      now: () => today,
    );
    pronunciation = PronunciationService(repo.database);
  });

  tearDown(() => repo.close());

  group('import', () {
    test('starts empty and reports itself unready', () async {
      expect(await pronunciation.isReady, isFalse);
      expect(await pronunciation.lookup('resilient'), isNull);
    });

    test('loads the bundled dictionary', () async {
      await pronunciation.importIfNeeded();

      expect(await pronunciation.isReady, isTrue);
      final count = Sqflite.firstIntValue(
        await repo.database.rawQuery(
          'SELECT COUNT(*) FROM ${AppDatabase.pronunciationsTable}',
        ),
      );
      // The generated asset carries ~126k entries; assert the order of
      // magnitude rather than an exact number that changes with upstream.
      expect(count, greaterThan(100000));
    });

    test('a second run is a no-op', () async {
      await pronunciation.importIfNeeded();
      final first = Sqflite.firstIntValue(
        await repo.database.rawQuery(
          'SELECT COUNT(*) FROM ${AppDatabase.pronunciationsTable}',
        ),
      );

      await pronunciation.importIfNeeded();
      final second = Sqflite.firstIntValue(
        await repo.database.rawQuery(
          'SELECT COUNT(*) FROM ${AppDatabase.pronunciationsTable}',
        ),
      );

      expect(second, first);
    });
  });

  group('lookup', () {
    setUp(() => pronunciation.importIfNeeded());

    test('answers for ordinary words', () async {
      expect(await pronunciation.lookup('resilient'), 'rɪˈzɪljənt');
      expect(await pronunciation.lookup('brittle'), 'ˈbrɪtəl');
      expect(await pronunciation.lookup('banana'), 'bəˈnænə');
    });

    test('marks primary and secondary stress', () async {
      final ipa = await pronunciation.lookup('ergonomic');
      expect(ipa, 'ˌɜrɡəˈnɑmɪk');
      expect(ipa, contains('ˈ')); // primary
      expect(ipa, contains('ˌ')); // secondary
    });

    test('leaves a one-syllable word unmarked', () async {
      // A stress mark on a single syllable has nothing to contrast with.
      expect(await pronunciation.lookup('cat'), 'kæt');
    });

    test('ignores case and surrounding space', () async {
      expect(await pronunciation.lookup('  ReSiLiEnT '), 'rɪˈzɪljənt');
    });

    test('transcribes a multi-word phrase', () async {
      // Idioms are a normal thing to capture, so they should not come back
      // empty just because the dictionary is keyed by single words.
      expect(await pronunciation.lookup('break the ice'), isNotNull);
      expect(await pronunciation.lookup('break the ice'), contains(' '));
    });

    test('returns nothing rather than a partial phrase', () async {
      // Half a transcription would look like the whole answer and mislead.
      expect(await pronunciation.lookup('break the zzzqqq'), isNull);
    });

    test('returns nothing for an unknown word', () async {
      expect(await pronunciation.lookup('zzzqqqxyz'), isNull);
    });

    test('returns nothing for empty input', () async {
      expect(await pronunciation.lookup('   '), isNull);
    });

    test('formats with the slashes a dictionary prints', () {
      expect(PronunciationService.format('rɪˈzɪljənt'), '/rɪˈzɪljənt/');
    });
  });

  group('backfill', () {
    setUp(() => pronunciation.importIfNeeded());

    Future<void> seed(String id, String word, {String? ipa}) {
      return repo.insert(
        VocabularyWord.create(
          id: id,
          word: word,
          meaning: 'nghĩa',
          date: '2026-08-18',
          now: today,
          pronunciation: ipa,
        ),
      );
    }

    test('fills words captured before the dictionary shipped', () async {
      await seed('a', 'resilient');
      await repo.markSynced(['a'], today);

      expect(await repo.backfillPronunciations(pronunciation.lookup), isTrue);

      final word = await repo.findById('a');
      expect(word!.pronunciation, 'rɪˈzɪljənt');
      // Marked dirty so the transcription reaches the user's other devices.
      expect(word.isDirty, isTrue);
    });

    test('leaves a transcription the user already has alone', () async {
      await seed('a', 'resilient', ipa: 'my own version');

      expect(await repo.backfillPronunciations(pronunciation.lookup), isFalse);
      expect((await repo.findById('a'))!.pronunciation, 'my own version');
    });

    test('skips words the dictionary does not know', () async {
      await seed('a', 'zzzqqqxyz');

      expect(await repo.backfillPronunciations(pronunciation.lookup), isFalse);
      expect((await repo.findById('a'))!.pronunciation, isNull);
    });

    test('reports no change when there is nothing to fill', () async {
      expect(await repo.backfillPronunciations(pronunciation.lookup), isFalse);
    });

    test('keeps the word searchable by its new transcription', () async {
      await seed('a', 'resilient');
      await repo.backfillPronunciations(pronunciation.lookup);

      // search_text has to be recomputed, or the row would still be indexed
      // under its old, transcription-free text.
      expect(await repo.search('zɪljənt'), hasLength(1));
    });
  });
}
