import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:veea_english_app/data/local/sqlite_vocabulary_repository.dart';
import 'package:veea_english_app/models/srs_review.dart';
import 'package:veea_english_app/models/vocabulary_word.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  final today = DateTime(2026, 8, 18, 10);
  late SqliteVocabularyRepository repo;

  setUp(() async {
    repo = await SqliteVocabularyRepository.open(
      path: inMemoryDatabasePath,
      now: () => today,
    );

    Future<void> seed(String id, String word, String meaning, String date) {
      return repo.insert(
        VocabularyWord.create(
          id: id,
          word: word,
          meaning: meaning,
          date: date,
          now: today,
        ),
      );
    }

    await seed('1', 'resilient', 'kiên cường', '2026-08-18');
    await seed('2', 'brittle', 'dễ vỡ', '2026-08-17');
    await seed('3', 'ergonomic', 'tiện dụng', '2026-08-16');
  });

  tearDown(() => repo.close());

  test('words with no prior SRS records are all considered due', () async {
    final count = await repo.dueReviewCount(asOfDate: '2026-08-18');
    expect(count, equals(3));

    final due = await repo.wordsDueForReview(asOfDate: '2026-08-18');
    expect(due.length, equals(3));
  });

  test('recording a review reschedules the word into the future', () async {
    final review = await repo.recordSrsReview(
      wordId: '1',
      rating: SrsRating.easy, // +3 days -> due 2026-08-21
      now: today,
    );

    expect(review.intervalDays, equals(3));
    expect(review.nextReviewDate, equals('2026-08-21'));

    // Today only 2 words remain due
    final dueToday = await repo.dueReviewCount(asOfDate: '2026-08-18');
    expect(dueToday, equals(2));

    // On 2026-08-21 word 1 is due again
    final dueLater = await repo.dueReviewCount(asOfDate: '2026-08-21');
    expect(dueLater, equals(3));
  });

  test('retrieving SRS state for an unreviewed word returns null', () async {
    final state = await repo.getSrsReview('unknown');
    expect(state, isNull);
  });
}
