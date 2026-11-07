import 'vocabulary_word.dart';

/// Matches the repository's queue when rendering an already loaded notebook.
abstract final class GateWordQueue {
  /// Review all eligible words before repeating. Learning priority breaks ties
  /// among unreviewed words; it cannot repeatedly jump ahead of the pool.
  static VocabularyWord? selectInRotation(
    Iterable<VocabularyWord> words, {
    required DateTime now,
    required Map<String, int> turns,
    Set<String> excludeIds = const {},
  }) {
    final eligible = words
        .where((word) => !word.isDeleted && !excludeIds.contains(word.id))
        .toList();
    if (eligible.isEmpty) return null;
    final oldest = eligible
        .map((word) => turns[word.id] ?? 0)
        .reduce((a, b) => a < b ? a : b);
    return select(
      eligible.where((word) => (turns[word.id] ?? 0) == oldest),
      now: now,
    );
  }

  static VocabularyWord? select(
    Iterable<VocabularyWord> words, {
    required DateTime now,
    Set<String> excludeIds = const {},
  }) {
    final pool = words
        .where((w) => !w.isDeleted && !excludeIds.contains(w.id))
        .toList();
    if (pool.isEmpty) return null;
    int leastReviewed(VocabularyWord a, VocabularyWord b) =>
        (a.lastReviewedAt ?? 0).compareTo(b.lastReviewedAt ?? 0);
    final failed = pool.where((w) => w.lastGateFailed).toList()
      ..sort((a, b) {
        final order = leastReviewed(a, b);
        return order != 0 ? order : b.createdAt.compareTo(a.createdAt);
      });
    if (failed.isNotEmpty) return failed.first;
    final cutoff = now.subtract(const Duration(hours: 72));
    final recent =
        pool
            .where((w) => !w.createdAt.isBefore(cutoff) && w.srsStage < 3)
            .toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    if (recent.isNotEmpty) return recent.first;
    final due =
        pool
            .where(
              (w) =>
                  w.nextReviewAt != null &&
                  w.nextReviewAt! <= now.millisecondsSinceEpoch,
            )
            .toList()
          ..sort((a, b) {
            final stage = a.srsStage.compareTo(b.srsStage);
            return stage != 0
                ? stage
                : a.nextReviewAt!.compareTo(b.nextReviewAt!);
          });
    if (due.isNotEmpty) return due.first;
    pool.sort((a, b) {
      final order = leastReviewed(a, b);
      return order != 0 ? order : a.createdAt.compareTo(b.createdAt);
    });
    return pool.first;
  }
}
