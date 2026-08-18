import 'package:flutter/foundation.dart';

/// Aggregate counters shown in the status line.
///
/// Computed once per data change by the repository rather than recalculated on
/// every widget rebuild, which is what the previous provider did.
@immutable
class VocabularyStats {
  const VocabularyStats({
    required this.totalWords,
    required this.streakDays,
    required this.wordsThisWeek,
  });

  static const empty = VocabularyStats(
    totalWords: 0,
    streakDays: 0,
    wordsThisWeek: 0,
  );

  final int totalWords;
  final int streakDays;
  final int wordsThisWeek;

  @override
  bool operator ==(Object other) =>
      other is VocabularyStats &&
      other.totalWords == totalWords &&
      other.streakDays == streakDays &&
      other.wordsThisWeek == wordsThisWeek;

  @override
  int get hashCode => Object.hash(totalWords, streakDays, wordsThisWeek);
}
