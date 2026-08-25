import 'package:flutter_test/flutter_test.dart';
import 'package:veea_english_app/models/srs_review.dart';

void main() {
  final baseDate = DateTime(2026, 8, 18, 10, 0);

  group('SrsReview SM-2 Algorithm', () {
    test('initial state has 0 interval and 2.5 ease factor', () {
      final initial = SrsReview.initial('word-1', now: baseDate);
      expect(initial.wordId, equals('word-1'));
      expect(initial.intervalDays, equals(0));
      expect(initial.easeFactor, equals(2.5));
      expect(initial.nextReviewDate, equals('2026-08-18'));
      expect(initial.repetitions, equals(0));
      expect(initial.lapses, equals(0));
    });

    test('Rating Again resets repetitions and increases lapse count', () {
      final initial = SrsReview(
        wordId: 'word-1',
        intervalDays: 6,
        easeFactor: 2.5,
        nextReviewDate: '2026-08-18',
        repetitions: 3,
        lapses: 0,
      );

      final next = initial.calculateNext(rating: SrsRating.again, now: baseDate);
      expect(next.repetitions, equals(0));
      expect(next.intervalDays, equals(1));
      expect(next.easeFactor, equals(2.3));
      expect(next.lapses, equals(1));
      expect(next.nextReviewDate, equals('2026-08-19'));
    });

    test('Rating Hard scales interval gently and reduces ease factor', () {
      final initial = SrsReview(
        wordId: 'word-1',
        intervalDays: 5,
        easeFactor: 2.5,
        nextReviewDate: '2026-08-18',
        repetitions: 2,
      );

      final next = initial.calculateNext(rating: SrsRating.hard, now: baseDate);
      expect(next.repetitions, equals(3));
      expect(next.intervalDays, equals(6)); // (5 * 1.2).round() = 6
      expect(next.easeFactor, equals(2.35)); // 2.5 - 0.15 = 2.35
      expect(next.nextReviewDate, equals('2026-08-24'));
    });

    test('Rating Good follows standard progression: 1 -> 3 -> interval * easeFactor', () {
      final rep0 = SrsReview.initial('word-1', now: baseDate);

      // First review: 1 day
      final rep1 = rep0.calculateNext(rating: SrsRating.good, now: baseDate);
      expect(rep1.repetitions, equals(1));
      expect(rep1.intervalDays, equals(1));
      expect(rep1.nextReviewDate, equals('2026-08-19'));

      // Second review: 3 days
      final rep2 = rep1.calculateNext(
        rating: SrsRating.good,
        now: DateTime(2026, 8, 19),
      );
      expect(rep2.repetitions, equals(2));
      expect(rep2.intervalDays, equals(3));
      expect(rep2.nextReviewDate, equals('2026-08-22'));

      // Third review: 3 * 2.5 = 7.5 -> 8 days
      final rep3 = rep2.calculateNext(
        rating: SrsRating.good,
        now: DateTime(2026, 8, 22),
      );
      expect(rep3.repetitions, equals(3));
      expect(rep3.intervalDays, equals(8));
      expect(rep3.nextReviewDate, equals('2026-08-30'));
    });

    test('Rating Easy jumps intervals faster and boosts ease factor', () {
      final rep0 = SrsReview.initial('word-1', now: baseDate);

      // First review as Easy: 3 days
      final rep1 = rep0.calculateNext(rating: SrsRating.easy, now: baseDate);
      expect(rep1.repetitions, equals(1));
      expect(rep1.intervalDays, equals(3));
      expect(rep1.easeFactor, equals(2.65));

      // Second review as Easy: 7 days
      final rep2 = rep1.calculateNext(
        rating: SrsRating.easy,
        now: DateTime(2026, 8, 21),
      );
      expect(rep2.repetitions, equals(2));
      expect(rep2.intervalDays, equals(7));
      expect(rep2.easeFactor, equals(2.8));
    });

    test('ease factor never drops below 1.3', () {
      var review = SrsReview(
        wordId: 'word-1',
        intervalDays: 1,
        easeFactor: 1.35,
        nextReviewDate: '2026-08-18',
      );

      review = review.calculateNext(rating: SrsRating.again, now: baseDate);
      expect(review.easeFactor, equals(1.3));
    });

    test('serialization roundtrip through dbMap', () {
      final review = SrsReview(
        wordId: 'word-42',
        intervalDays: 14,
        easeFactor: 2.65,
        nextReviewDate: '2026-09-01',
        lastReviewedAt: baseDate,
        repetitions: 4,
        lapses: 1,
      );

      final map = review.toDbMap();
      final reconstructed = SrsReview.fromDbMap(map);

      expect(reconstructed.wordId, equals(review.wordId));
      expect(reconstructed.intervalDays, equals(review.intervalDays));
      expect(reconstructed.easeFactor, equals(review.easeFactor));
      expect(reconstructed.nextReviewDate, equals(review.nextReviewDate));
      expect(reconstructed.repetitions, equals(review.repetitions));
      expect(reconstructed.lapses, equals(review.lapses));
    });
  });
}
