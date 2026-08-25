import '../models/gamification_badge.dart';
import '../models/srs_review.dart';
import '../models/vocabulary_stats.dart';
import '../models/vocabulary_word.dart';

/// Persistence boundary for vocabulary.
///
/// The provider depends on this interface rather than on SQLite directly, so
/// tests can substitute a fake and a future remote-backed implementation can
/// slot in without touching the UI layer.
abstract interface class VocabularyRepository {
  /// Words captured on [date] (`YYYY-MM-DD`), newest first.
  Future<List<VocabularyWord>> wordsForDate(String date);

  /// Recent active words across all days, newest first.
  Future<List<VocabularyWord>> recentWords({int limit = 50});

  /// Words due for spaced repetition review as of [asOfDate] (`YYYY-MM-DD`).
  Future<List<VocabularyWord>> wordsDueForReview({String? asOfDate, int limit = 30});

  /// Total number of words due for review.
  Future<int> dueReviewCount({String? asOfDate});

  /// Retrieves the SRS review progress for a specific word.
  Future<SrsReview?> getSrsReview(String wordId);

  /// Records an SM-2 review score and schedules the next review.
  Future<SrsReview> recordSrsReview({
    required String wordId,
    required SrsRating rating,
    DateTime? now,
  });

  /// Aggregate statistics for the activity heatmap and retro milestone badges.
  Future<GamificationStats> gamificationStats({int days = 112});

  /// Full-text search across word, meaning, pronunciation, source, examples
  /// and tags. Matching is case- and diacritic-insensitive.
  Future<List<VocabularyWord>> search(String query, {int limit = 200});

  /// Aggregate counters, computed in SQL.
  Future<VocabularyStats> stats();

  /// Distinct days that hold at least one word, used to mark the date bar.
  Future<Set<String>> datesWithWords();

  Future<VocabularyWord?> findById(String id);

  Future<void> insert(VocabularyWord word);

  Future<void> update(VocabularyWord word);

  /// Marks a word deleted without removing the row.
  ///
  /// The tombstone is kept so the deletion can be propagated; other devices
  /// would otherwise re-upload the word on their next sync.
  Future<void> softDelete(String id, DateTime now);

  /// Restores a soft-deleted word, backing the undo action.
  Future<void> restore(String id, DateTime now);

  /// Permanently removes tombstones the server has acknowledged.
  Future<void> purgeSyncedTombstones();

  /// Local rows with changes the server has not acknowledged.
  Future<List<VocabularyWord>> pendingChanges({int limit = 200});

  /// Marks [ids] as synced as of [syncedAt].
  Future<void> markSynced(List<String> ids, DateTime syncedAt);

  /// Applies rows received from the server, resolving conflicts by
  /// last-write-wins on `updatedAt`. Local dirty rows always win so unsent
  /// edits are never silently discarded.
  Future<void> mergeFromServer(List<VocabularyWord> remote);

  /// Removes every locally stored word.
  ///
  /// Used when the account is deleted, and when signing in as someone else:
  /// leaving the previous account's vocabulary on the device would show one
  /// person another's notes.
  Future<void> deleteAll();

  Future<void> close();
}
