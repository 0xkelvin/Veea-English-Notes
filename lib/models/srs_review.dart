import 'dart:math' as math;

/// 4-point rating based on the SuperMemo (SM-2) spaced repetition algorithm.
enum SrsRating {
  again(1, 'AGAIN', '< 10 MIN'),
  hard(2, 'HARD', '1 DAY'),
  good(3, 'GOOD', '3-6 DAYS'),
  easy(4, 'EASY', '7+ DAYS');

  const SrsRating(this.score, this.label, this.estimatedInterval);

  final int score;
  final String label;
  final String estimatedInterval;
}

/// Spaced repetition state for a single vocabulary word.
class SrsReview {
  const SrsReview({
    required this.wordId,
    required this.intervalDays,
    required this.easeFactor,
    required this.nextReviewDate,
    this.lastReviewedAt,
    this.repetitions = 0,
    this.lapses = 0,
  });

  /// Default initial state for a newly encountered word.
  factory SrsReview.initial(String wordId, {DateTime? now}) {
    final today = now ?? DateTime.now();
    return SrsReview(
      wordId: wordId,
      intervalDays: 0,
      easeFactor: 2.5,
      nextReviewDate: _dateKey(today),
      repetitions: 0,
      lapses: 0,
    );
  }

  final String wordId;

  /// Number of days before the next review.
  final int intervalDays;

  /// SM-2 ease factor (minimum 1.3).
  final double easeFactor;

  /// Date the card is next due (`YYYY-MM-DD`).
  final String nextReviewDate;

  final DateTime? lastReviewedAt;

  /// Number of consecutive successful recalls (ratings Good or Easy).
  final int repetitions;

  /// Number of times the user rated "Again".
  final int lapses;

  /// Calculates the next spaced repetition schedule given a [rating].
  SrsReview calculateNext({
    required SrsRating rating,
    DateTime? now,
  }) {
    final currentTime = now ?? DateTime.now();
    int newReps = repetitions;
    int newInterval = intervalDays;
    double newEase = easeFactor;
    int newLapses = lapses;

    switch (rating) {
      case SrsRating.again:
        newReps = 0;
        newInterval = 1;
        newEase = math.max(1.3, easeFactor - 0.2);
        newLapses += 1;
        break;

      case SrsRating.hard:
        newReps += 1;
        newInterval = intervalDays <= 1 ? 1 : (intervalDays * 1.2).round();
        newEase = math.max(1.3, easeFactor - 0.15);
        break;

      case SrsRating.good:
        if (repetitions == 0) {
          newInterval = 1;
        } else if (repetitions == 1) {
          newInterval = 3;
        } else {
          newInterval = (intervalDays * easeFactor).round();
        }
        newReps += 1;
        break;

      case SrsRating.easy:
        if (repetitions == 0) {
          newInterval = 3;
        } else if (repetitions == 1) {
          newInterval = 7;
        } else {
          newInterval = (intervalDays * easeFactor * 1.3).round();
        }
        newEase = easeFactor + 0.15;
        newReps += 1;
        break;
    }

    // Ensure interval is at least 1 day for next review
    newInterval = math.max(1, newInterval);

    final nextDate = currentTime.add(Duration(days: newInterval));
    final nextDateKey = _dateKey(nextDate);

    return SrsReview(
      wordId: wordId,
      intervalDays: newInterval,
      easeFactor: double.parse(newEase.toStringAsFixed(2)),
      nextReviewDate: nextDateKey,
      lastReviewedAt: currentTime,
      repetitions: newReps,
      lapses: newLapses,
    );
  }

  Map<String, Object?> toDbMap() => {
    'word_id': wordId,
    'interval_days': intervalDays,
    'ease_factor': easeFactor,
    'next_review_date': nextReviewDate,
    'last_reviewed_at': lastReviewedAt?.toUtc().toIso8601String(),
    'repetitions': repetitions,
    'lapses': lapses,
  };

  factory SrsReview.fromDbMap(Map<String, Object?> map) {
    return SrsReview(
      wordId: map['word_id']! as String,
      intervalDays: map['interval_days']! as int,
      easeFactor: (map['ease_factor'] as num).toDouble(),
      nextReviewDate: map['next_review_date']! as String,
      lastReviewedAt: map['last_reviewed_at'] == null
          ? null
          : DateTime.parse(map['last_reviewed_at']! as String).toLocal(),
      repetitions: (map['repetitions'] as int? ?? 0),
      lapses: (map['lapses'] as int? ?? 0),
    );
  }

  static String _dateKey(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';
}
