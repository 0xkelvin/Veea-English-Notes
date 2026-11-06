import '../models/gamification_badge.dart';
import '../models/gate_config.dart';
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
  Future<List<VocabularyWord>> wordsDueForReview({
    String? asOfDate,
    int limit = 30,
  });

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

  /// Selects a single word for an App Gate challenge following the 4-tier
  /// Smart Review Queue priority order:
  /// 1. Previously failed gate words (`last_gate_failed = 1`).
  /// 2. Recent captures in the last 72 hours with `srs_stage < 3`.
  /// 3. Spaced repetition due (`next_review_at <= now`).
  /// 4. Fallback: least-recently reviewed active word.
  Future<VocabularyWord?> selectGateWord({DateTime? now});

  /// Updates `srs_stage`, `next_review_at`, `last_reviewed_at`, and
  /// `last_gate_failed` on the solved word and records a `gate_logs` entry.
  ///
  /// [attempts] is the number of wrong attempts before solving (`0` = solved on
  /// 1st try, `1` = solved on 2nd try after hint, `>= 2` = solved after Teach &
  /// Retype).
  Future<VocabularyWord?> recordGateCompletion({
    required String wordId,
    required String targetApp,
    required int attempts,
    DateTime? now,
  });

  /// Reads the singleton App Gate configuration row (`id = 1`).
  Future<GateConfig> getGateConfig();

  /// Saves the singleton App Gate configuration row (`id = 1`).
  Future<void> saveGateConfig(GateConfig config);

  /// Recent App Gate completion logs, newest first.
  Future<List<GateLog>> recentGateLogs({int limit = 20});

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

  /// Fetches every active word without any limit for full backup export.
  Future<List<VocabularyWord>> exportAll();

  /// Total number of pending unsynced changes.
  Future<int> countPendingChanges();

  /// Atomically inserts and updates imported words in a single transaction.
  Future<void> bulkImport({
    required List<VocabularyWord> toInsert,
    required List<VocabularyWord> toUpdate,
  });

  /// Removes every locally stored word.
  ///
  /// Used when the account is deleted, and when signing in as someone else:
  /// leaving the previous account's vocabulary on the device would show one
  /// person another's notes.
  Future<void> deleteAll();

  Future<void> close();
}
