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

    Future<void> seed(
      String id,
      String word,
      String meaning,
      String date, {
      List<String> tags = const [],
    }) {
      return repo.insert(
        VocabularyWord.create(
          id: id,
          word: word,
          meaning: meaning,
          date: date,
          tags: tags,
          now: today,
        ),
      );
    }

    // 3 words on 2026-08-18 (today)
    await seed('1', 'resilient', 'kiên cường', '2026-08-18', tags: ['tech', 'mindset']);
    await seed('2', 'brittle', 'dễ vỡ', '2026-08-18', tags: ['tech']);
    await seed('3', 'ergonomic', 'tiện dụng', '2026-08-18', tags: ['design']);

    // 2 words on 2026-08-17 (yesterday)
    await seed('4', 'ubiquitous', 'phổ biến', '2026-08-17', tags: ['general']);
    await seed('5', 'ephemeral', 'ngắn ngủi', '2026-08-17', tags: ['tech']);

    // 1 word on 2026-08-16 (day before)
    await seed('6', 'tenacious', 'bền bỉ', '2026-08-16', tags: ['mindset']);

    // Record an SRS review
    await repo.recordSrsReview(wordId: '1', rating: SrsRating.good, now: today);
  });

  tearDown(() => repo.close());

  test('gamificationStats calculates aggregate metrics correctly', () async {
    final stats = await repo.gamificationStats(days: 30);

    expect(stats.totalWords, equals(6));
    expect(stats.currentStreak, equals(3));
    expect(stats.maxStreak, equals(3));
    expect(stats.maxWordsInDay, equals(3));
    expect(stats.totalReviews, equals(1));
    expect(stats.uniqueTagsCount, equals(4)); // tech, mindset, design, general

    expect(stats.dailyCounts['2026-08-18'], equals(3));
    expect(stats.dailyCounts['2026-08-17'], equals(2));
    expect(stats.dailyCounts['2026-08-16'], equals(1));
  });
}
