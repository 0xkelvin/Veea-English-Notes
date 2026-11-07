import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import '../../models/gamification_badge.dart';
import '../../models/gate_config.dart';
import '../../models/srs_review.dart';
import '../../models/text_normalizer.dart';
import '../../models/word_identity.dart';
import '../../models/vocabulary_stats.dart';
import '../../models/vocabulary_word.dart';
import '../vocabulary_repository.dart';
import 'app_database.dart';

/// SQLite-backed [VocabularyRepository].
///
/// All filtering, counting and ordering happens in SQL. The previous
/// implementation loaded every row into memory and filtered in Dart, which
/// also meant the streak was recomputed on every widget rebuild.
class SqliteVocabularyRepository implements VocabularyRepository {
  /// [now] is injectable so streak and week-boundary logic is testable without
  /// waiting for the calendar to move.
  SqliteVocabularyRepository(this._db, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final DateTime Function() _now;

  /// The open connection, shared with services that own their own tables —
  /// currently the bundled pronunciation dictionary.
  Database get database => _db;

  static const String _table = AppDatabase.wordsTable;

  /// Columns shared by every read, kept in one place so the projection cannot
  /// drift from [VocabularyWord.fromDbMap].
  static const List<String> _columns = [
    'id',
    'word',
    'meaning',
    'pronunciation',
    'part_of_speech',
    'source',
    'examples',
    'tags',
    'date',
    'created_at',
    'updated_at',
    'is_deleted',
    'is_dirty',
    'synced_at',
    'srs_stage',
    'next_review_at',
    'last_reviewed_at',
    'last_gate_failed',
  ];

  final Database _db;

  /// Opens the production database and returns a ready repository.
  static Future<SqliteVocabularyRepository> open({
    String? path,
    DateTime Function()? now,
  }) async {
    return SqliteVocabularyRepository(
      await AppDatabase.open(path: path),
      now: now,
    );
  }

  @override
  Future<List<VocabularyWord>> wordsForDate(String date) async {
    final rows = await _db.query(
      _table,
      columns: _columns,
      where: 'is_deleted = 0 AND date = ?',
      whereArgs: [date],
      orderBy: 'created_at DESC',
    );
    return rows.map(VocabularyWord.fromDbMap).toList(growable: false);
  }

  @override
  Future<List<VocabularyWord>> recentWords({int limit = 50}) async {
    final rows = await _db.query(
      _table,
      columns: _columns,
      where: 'is_deleted = 0',
      orderBy: 'created_at DESC',
      limit: limit,
    );
    return rows.map(VocabularyWord.fromDbMap).toList(growable: false);
  }

  @override
  Future<List<VocabularyWord>> wordsDueForReview({
    String? asOfDate,
    int limit = 30,
  }) async {
    final date = asOfDate ?? _dateKey(_now());
    final srsTable = AppDatabase.srsReviewsTable;
    final rows = await _db.rawQuery(
      '''
      SELECT ${_columns.map((c) => 'w.$c').join(', ')}
      FROM $_table w
      LEFT JOIN $srsTable r ON w.id = r.word_id
      WHERE w.is_deleted = 0
        AND (r.next_review_date IS NULL OR r.next_review_date <= ?)
      ORDER BY
        CASE WHEN r.next_review_date IS NULL THEN 0 ELSE 1 END,
        COALESCE(r.next_review_date, w.date) ASC,
        w.created_at DESC
      LIMIT ?
      ''',
      [date, limit],
    );
    return rows.map(VocabularyWord.fromDbMap).toList(growable: false);
  }

  @override
  Future<int> dueReviewCount({String? asOfDate}) async {
    final date = asOfDate ?? _dateKey(_now());
    final srsTable = AppDatabase.srsReviewsTable;
    final row = await _db.rawQuery(
      '''
      SELECT COUNT(*) AS c
      FROM $_table w
      LEFT JOIN $srsTable r ON w.id = r.word_id
      WHERE w.is_deleted = 0
        AND (r.next_review_date IS NULL OR r.next_review_date <= ?)
      ''',
      [date],
    );
    return Sqflite.firstIntValue(row) ?? 0;
  }

  @override
  Future<SrsReview?> getSrsReview(String wordId) async {
    final rows = await _db.query(
      AppDatabase.srsReviewsTable,
      where: 'word_id = ?',
      whereArgs: [wordId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return SrsReview.fromDbMap(rows.first);
  }

  @override
  Future<SrsReview> recordSrsReview({
    required String wordId,
    required SrsRating rating,
    DateTime? now,
  }) async {
    final currentTime = now ?? _now();
    final existing =
        await getSrsReview(wordId) ??
        SrsReview.initial(wordId, now: currentTime);
    final next = existing.calculateNext(rating: rating, now: currentTime);

    await _db.insert(
      AppDatabase.srsReviewsTable,
      next.toDbMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    return next;
  }

  @override
  Future<VocabularyWord?> selectGateWord({
    DateTime? now,
    Set<String> excludeIds = const {},
  }) async {
    final currentTime = now ?? _now();
    final exclusions = excludeIds.isEmpty
        ? ''
        : ' AND id NOT IN (${List.filled(excludeIds.length, '?').join(',')})';

    // 1. Previously Failed Gate Words: last_gate_failed = 1
    final failedRows = await _db.query(
      _table,
      columns: _columns,
      where: 'is_deleted = 0 AND last_gate_failed = 1$exclusions',
      whereArgs: excludeIds.toList(),
      orderBy:
          'CASE WHEN last_reviewed_at IS NULL THEN 0 ELSE 1 END ASC, '
          'last_reviewed_at ASC, created_at DESC',
      limit: 1,
    );
    if (failedRows.isNotEmpty) {
      return VocabularyWord.fromDbMap(failedRows.first);
    }

    // 2. Recent Captures (Last 3 Days / 72 Hours) with srs_stage < 3
    final recentCutoff = currentTime
        .subtract(const Duration(hours: 72))
        .toUtc()
        .toIso8601String();
    final recentRows = await _db.query(
      _table,
      columns: _columns,
      where: 'is_deleted = 0 AND created_at >= ? AND srs_stage < 3$exclusions',
      whereArgs: [recentCutoff, ...excludeIds],
      orderBy: 'created_at DESC',
      limit: 1,
    );
    if (recentRows.isNotEmpty) {
      return VocabularyWord.fromDbMap(recentRows.first);
    }

    // 3. Spaced Repetition Due: next_review_at <= now
    final nowMs = currentTime.millisecondsSinceEpoch;
    final dueRows = await _db.query(
      _table,
      columns: _columns,
      where:
          'is_deleted = 0 AND next_review_at IS NOT NULL AND next_review_at <= ?$exclusions',
      whereArgs: [nowMs, ...excludeIds],
      orderBy: 'srs_stage ASC, next_review_at ASC',
      limit: 1,
    );
    if (dueRows.isNotEmpty) {
      return VocabularyWord.fromDbMap(dueRows.first);
    }

    // 4. Fallback: Least-recently reviewed active word
    final fallbackRows = await _db.query(
      _table,
      columns: _columns,
      where: 'is_deleted = 0$exclusions',
      whereArgs: excludeIds.toList(),
      orderBy:
          'CASE WHEN last_reviewed_at IS NULL THEN 0 ELSE 1 END ASC, '
          'last_reviewed_at ASC, created_at ASC',
      limit: 1,
    );
    if (fallbackRows.isNotEmpty) {
      return VocabularyWord.fromDbMap(fallbackRows.first);
    }

    return null;
  }

  @override
  Future<VocabularyWord?> recordGateCompletion({
    required String wordId,
    required String targetApp,
    required int attempts,
    DateTime? now,
    bool completesRound = true,
  }) async {
    final currentTime = now ?? _now();
    final nowMs = currentTime.millisecondsSinceEpoch;
    final existing = await findById(wordId);
    if (existing == null || existing.isDeleted) return null;

    final int newSrsStage;
    final bool newLastGateFailed;
    final int newNextReviewAt;

    if (attempts == 0) {
      // Stage 0 — Solved on Attempt 1
      newSrsStage = existing.srsStage + 1;
      newLastGateFailed = false;
      const intervals = [1, 3, 7, 14, 30];
      final intervalDays =
          intervals[math.min(newSrsStage - 1, intervals.length - 1)];
      newNextReviewAt = currentTime
          .add(Duration(days: intervalDays))
          .millisecondsSinceEpoch;
    } else if (attempts == 1) {
      // Stage 1 — Solved on Attempt 2 (keep srs_stage unchanged)
      newSrsStage = existing.srsStage;
      newLastGateFailed = false;
      newNextReviewAt = currentTime
          .add(const Duration(days: 1))
          .millisecondsSinceEpoch;
    } else {
      // Stage 2 — Solved after Teach & Retype (reset srs_stage = 0, last_gate_failed = 1)
      newSrsStage = 0;
      newLastGateFailed = true;
      newNextReviewAt = currentTime
          .add(const Duration(hours: 4))
          .millisecondsSinceEpoch;
    }

    await _db.transaction((txn) async {
      final target = targetApp.trim().toLowerCase();
      final recorded = await txn.query(
        AppDatabase.gateProgressTable,
        where: 'target_app = ? AND word_id = ?',
        whereArgs: [target, wordId],
      );
      if (recorded.isNotEmpty) return;
      final sequence = Sqflite.firstIntValue(
        await txn.rawQuery(
          'SELECT COALESCE(MAX(last_turn), 0) + 1 FROM gate_word_rotation',
        ),
      )!;
      await txn.insert('gate_word_rotation', {
        'word_id': wordId,
        'last_turn': sequence,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await txn.update(
        _table,
        {
          'srs_stage': newSrsStage,
          'next_review_at': newNextReviewAt,
          'last_reviewed_at': nowMs,
          'last_gate_failed': newLastGateFailed ? 1 : 0,
        },
        where: 'id = ?',
        whereArgs: [wordId],
      );

      final logId = '${wordId}_${nowMs}_${targetApp.hashCode.abs()}';
      await txn.insert(
        AppDatabase.gateLogsTable,
        GateLog(
          id: logId,
          wordId: wordId,
          targetApp: targetApp,
          attempts: attempts,
          passedAt: nowMs,
        ).toDbMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      if (completesRound) {
        await txn.delete(
          AppDatabase.gateProgressTable,
          where: 'target_app = ?',
          whereArgs: [target],
        );
      } else {
        await txn.insert(AppDatabase.gateProgressTable, {
          'target_app': target,
          'word_id': wordId,
        });
      }
      await txn.delete(
        'gate_pending_answers',
        where: 'target_app = ? AND word_id = ?',
        whereArgs: [target, wordId],
      );
    });

    return await findById(wordId);
  }

  @override
  Future<Map<String, Set<String>>> gateRoundProgress() async {
    final rows = await _db.rawQuery('''
      SELECT p.target_app, p.word_id FROM ${AppDatabase.gateProgressTable} p
      JOIN $_table w ON w.id = p.word_id WHERE w.is_deleted = 0
    ''');
    final result = <String, Set<String>>{};
    for (final row in rows) {
      (result[row['target_app'] as String] ??= {}).add(
        row['word_id'] as String,
      );
    }
    return result;
  }

  @override
  Future<Map<String, int>> gateWordTurns() async {
    final rows = await _db.rawQuery(
      'SELECT r.word_id, r.last_turn FROM gate_word_rotation r JOIN $_table w ON w.id = r.word_id WHERE w.is_deleted = 0',
    );
    return {
      for (final row in rows) row['word_id'] as String: row['last_turn'] as int,
    };
  }

  @override
  Future<void> clearGateRoundProgress(String targetApp) async {
    final target = targetApp.trim().toLowerCase();
    await _db.transaction((txn) async {
      await txn.delete(
        AppDatabase.gateProgressTable,
        where: 'target_app = ?',
        whereArgs: [target],
      );
      await txn.delete(
        'gate_pending_answers',
        where: 'target_app = ?',
        whereArgs: [target],
      );
    });
  }

  @override
  Future<Map<String, GatePendingAnswer>> pendingGateAnswers() async {
    final rows = await _db.rawQuery(
      'SELECT p.* FROM gate_pending_answers p JOIN $_table w ON w.id = p.word_id WHERE w.is_deleted = 0',
    );
    return {
      for (final row in rows)
        row['target_app'] as String: GatePendingAnswer(
          wordId: row['word_id'] as String,
          attempts: row['attempts'] as int,
        ),
    };
  }

  @override
  Future<void> savePendingGateAnswer(
    String targetApp,
    GatePendingAnswer answer,
  ) async {
    await _db.insert('gate_pending_answers', {
      'target_app': targetApp.trim().toLowerCase(),
      'word_id': answer.wordId,
      'attempts': answer.attempts,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<void> pruneGateRoundProgress(Set<String> allowedWordIds) async {
    await _db.transaction((txn) async {
      for (final table in [
        AppDatabase.gateProgressTable,
        'gate_pending_answers',
      ]) {
        final rows = await txn.query(table, columns: ['target_app', 'word_id']);
        final batch = txn.batch();
        for (final row in rows) {
          if (!allowedWordIds.contains(row['word_id'])) {
            batch.delete(
              table,
              where: 'target_app = ? AND word_id = ?',
              whereArgs: [row['target_app'], row['word_id']],
            );
          }
        }
        await batch.commit(noResult: true);
      }
    });
  }

  @override
  Future<GateConfig> getGateConfig() async {
    final rows = await _db.query(
      AppDatabase.gateConfigTable,
      where: 'id = 1',
      limit: 1,
    );
    if (rows.isEmpty) return const GateConfig();
    return GateConfig.fromDbMap(rows.first);
  }

  @override
  Future<void> saveGateConfig(GateConfig config) async {
    await _db.insert(
      AppDatabase.gateConfigTable,
      config.toDbMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<List<GateLog>> recentGateLogs({int limit = 20}) async {
    final rows = await _db.query(
      AppDatabase.gateLogsTable,
      orderBy: 'passed_at DESC',
      limit: limit,
    );
    return rows.map(GateLog.fromDbMap).toList(growable: false);
  }

  @override
  Future<GamificationStats> gamificationStats({int days = 112}) async {
    final today = _now();
    final cutoffDate = _dateKey(today.subtract(Duration(days: days)));

    final totalRow = await _db.rawQuery(
      'SELECT COUNT(*) AS c FROM $_table WHERE is_deleted = 0',
    );
    final totalWords = Sqflite.firstIntValue(totalRow) ?? 0;

    final maxWordsRow = await _db.rawQuery(
      'SELECT MAX(c) AS max_c FROM (SELECT COUNT(*) AS c FROM $_table WHERE is_deleted = 0 GROUP BY date)',
    );
    final maxWordsInDay = Sqflite.firstIntValue(maxWordsRow) ?? 0;

    final reviewsRow = await _db.rawQuery(
      'SELECT COALESCE(SUM(repetitions + lapses), 0) AS s FROM ${AppDatabase.srsReviewsTable}',
    );
    final totalReviews = Sqflite.firstIntValue(reviewsRow) ?? 0;

    final tagsRows = await _db.query(
      _table,
      columns: ['tags'],
      where: 'is_deleted = 0',
    );
    final uniqueTags = <String>{};
    for (final row in tagsRows) {
      final raw = row['tags'] as String?;
      if (raw == null || raw.isEmpty) continue;
      try {
        final list = (jsonDecode(raw) as List).cast<String>();
        uniqueTags.addAll(list);
      } catch (_) {}
    }

    final allDates = await datesWithWords();
    final currentStreak = _streakFrom(allDates, today);
    final maxStreak = _maxStreakFrom(allDates);

    final dailyCountsRows = await _db.rawQuery(
      '''
      SELECT date, COUNT(*) AS count
      FROM $_table
      WHERE is_deleted = 0 AND date >= ?
      GROUP BY date
      ORDER BY date ASC
      ''',
      [cutoffDate],
    );
    final dailyCounts = <String, int>{
      for (final r in dailyCountsRows) r['date']! as String: r['count']! as int,
    };

    return GamificationStats(
      totalWords: totalWords,
      currentStreak: currentStreak,
      maxStreak: maxStreak,
      totalReviews: totalReviews,
      uniqueTagsCount: uniqueTags.length,
      maxWordsInDay: maxWordsInDay,
      dailyCounts: dailyCounts,
    );
  }

  @override
  Future<List<VocabularyWord>> search(
    String query, {
    int limit = 200,
    bool includeNotes = false,
  }) async {
    final needle = TextNormalizer.query(query);
    if (needle.isEmpty) return const [];

    // Written as a raw query because the ranking expression needs its own
    // placeholder, and `query()` only binds arguments for the WHERE clause.
    final pattern = '%${_escapeLike(needle)}%';
    final searchColumn = includeNotes ? 'search_text' : 'word_search_text';
    final rows = await _db.rawQuery(
      '''
      SELECT ${_columns.join(', ')} FROM $_table
      WHERE is_deleted = 0 AND $searchColumn LIKE ? ESCAPE ?
      ORDER BY
        CASE
          WHEN word_search_text = ? THEN 0
          WHEN word_search_text LIKE ? ESCAPE ? THEN 1
          WHEN word_search_text LIKE ? ESCAPE ? THEN 2
          ELSE 3
        END,
        date DESC, created_at DESC, id ASC
      LIMIT ?
      ''',
      [
        pattern,
        _likeEscape,
        needle,
        '${_escapeLike(needle)}%',
        _likeEscape,
        pattern,
        _likeEscape,
        limit,
      ],
    );
    return rows.map(VocabularyWord.fromDbMap).toList(growable: false);
  }

  @override
  Future<VocabularyStats> stats() async {
    final totalRow = await _db.rawQuery(
      'SELECT COUNT(*) AS c FROM $_table WHERE is_deleted = 0',
    );
    final total = Sqflite.firstIntValue(totalRow) ?? 0;
    if (total == 0) return VocabularyStats.empty;

    final today = _now();
    final weekRow = await _db.rawQuery(
      'SELECT COUNT(*) AS c FROM $_table WHERE is_deleted = 0 AND date >= ?',
      [_dateKey(_startOfWeek(today))],
    );

    return VocabularyStats(
      totalWords: total,
      wordsThisWeek: Sqflite.firstIntValue(weekRow) ?? 0,
      streakDays: _streakFrom(await datesWithWords(), today),
    );
  }

  @override
  Future<Set<String>> datesWithWords() async {
    final rows = await _db.rawQuery(
      'SELECT DISTINCT date FROM $_table WHERE is_deleted = 0 ORDER BY date DESC',
    );
    return {for (final row in rows) row['date']! as String};
  }

  @override
  Future<VocabularyWord?> findById(String id) async {
    final rows = await _db.query(
      _table,
      columns: _columns,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : VocabularyWord.fromDbMap(rows.first);
  }

  Future<List<VocabularyWord>> _matchingWords(
    DatabaseExecutor db,
    String spelling, {
    String? excludeId,
  }) async {
    final identity = WordIdentity.key(spelling);
    if (identity.isEmpty) return const [];
    final candidate = TextNormalizer.query(WordIdentity.candidate(spelling));
    final rows = await db.query(
      _table,
      columns: _columns,
      where: 'is_deleted = 0 AND word_search_text LIKE ? ESCAPE ?',
      whereArgs: ['%${_escapeLike(candidate)}%', _likeEscape],
      orderBy: 'date DESC, created_at DESC, id ASC',
    );
    return rows
        .map(VocabularyWord.fromDbMap)
        .where((w) => w.id != excludeId && WordIdentity.key(w.word) == identity)
        .toList(growable: false);
  }

  @override
  Future<List<VocabularyWord>> matchingWords(
    String spelling, {
    String? excludeId,
  }) => _matchingWords(_db, spelling, excludeId: excludeId);

  Future<void> _writeChecked(
    VocabularyWord word, {
    required bool update,
    required bool allowDifferentMeaning,
  }) => _db.transaction((txn) async {
    final matches = await _matchingWords(
      txn,
      word.word,
      excludeId: update ? word.id : null,
    );
    if (matches.isNotEmpty &&
        (!allowDifferentMeaning ||
            matches.any((w) => WordIdentity.sameSense(w, word)))) {
      throw DuplicateWordException(matches);
    }
    if (update) {
      await txn.update(
        _table,
        word.toDbMap(),
        where: 'id = ?',
        whereArgs: [word.id],
      );
    } else {
      // Never replace a word ID: replacing would cascade its learning history.
      await txn.insert(_table, word.toDbMap());
    }
  });

  @override
  Future<void> insertChecked(
    VocabularyWord word, {
    bool allowDifferentMeaning = false,
  }) => _writeChecked(
    word,
    update: false,
    allowDifferentMeaning: allowDifferentMeaning,
  );
  @override
  Future<void> updateChecked(
    VocabularyWord word, {
    bool allowDifferentMeaning = false,
  }) => _writeChecked(
    word,
    update: true,
    allowDifferentMeaning: allowDifferentMeaning,
  );

  @override
  Future<void> insert(VocabularyWord word) async {
    await _db.insert(
      _table,
      word.toDbMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<void> update(VocabularyWord word) async {
    await _db.update(
      _table,
      word.toDbMap(),
      where: 'id = ?',
      whereArgs: [word.id],
    );
  }

  @override
  Future<void> softDelete(String id, DateTime now) async {
    await _db.update(
      _table,
      {
        'is_deleted': 1,
        'is_dirty': 1,
        'updated_at': now.toUtc().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  @override
  Future<void> restore(String id, DateTime now) async {
    await _db.update(
      _table,
      {
        'is_deleted': 0,
        'is_dirty': 1,
        'updated_at': now.toUtc().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  @override
  Future<void> purgeSyncedTombstones() async {
    await _db.delete(_table, where: 'is_deleted = 1 AND is_dirty = 0');
  }

  @override
  Future<List<VocabularyWord>> pendingChanges({int limit = 200}) async {
    final rows = await _db.query(
      _table,
      columns: _columns,
      where: 'is_dirty = 1',
      orderBy: 'updated_at ASC',
      limit: limit,
    );
    return rows.map(VocabularyWord.fromDbMap).toList(growable: false);
  }

  @override
  Future<void> markSynced(
    List<String> ids,
    DateTime syncedAt, {
    Map<String, DateTime>? expectedVersions,
  }) async {
    if (ids.isEmpty) return;
    final batch = _db.batch();
    final stamp = syncedAt.toUtc().toIso8601String();
    for (final id in ids) {
      batch.update(
        _table,
        {'is_dirty': 0, 'synced_at': stamp},
        where: expectedVersions == null
            ? 'id = ?'
            : 'id = ? AND updated_at = ?',
        whereArgs: [
          id,
          if (expectedVersions != null)
            expectedVersions[id]?.toUtc().toIso8601String(),
        ],
      );
    }
    await batch.commit(noResult: true);
  }

  @override
  Future<void> mergeFromServer(List<VocabularyWord> remote) async {
    if (remote.isEmpty) return;
    await _db.transaction((txn) async {
      for (final incoming in remote) {
        final existing = await txn.query(
          _table,
          columns: ['updated_at', 'is_dirty'],
          where: 'id = ?',
          whereArgs: [incoming.id],
          limit: 1,
        );

        if (existing.isNotEmpty) {
          // An unsent local edit is never overwritten — the push half of the
          // sync will send it and the server resolves the conflict.
          if ((existing.first['is_dirty'] as int? ?? 0) == 1) continue;

          final localUpdatedAt = DateTime.parse(
            existing.first['updated_at']! as String,
          );
          if (incoming.updatedAt.toUtc().isBefore(localUpdatedAt.toUtc())) {
            continue;
          }
        }

        final values = incoming.copyWith(isDirty: false).toDbMap();
        if (existing.isEmpty) {
          await txn.insert(_table, values);
        } else {
          // UPDATE preserves foreign-key learning records; REPLACE deletes the
          // old row and cascades its review history and unfinished rounds.
          for (final key in [
            'srs_stage',
            'next_review_at',
            'last_reviewed_at',
            'last_gate_failed',
          ]) {
            values.remove(key);
          }
          await txn.update(
            _table,
            values,
            where: 'id = ?',
            whereArgs: [incoming.id],
          );
        }
      }
    });
  }

  /// Fills in pronunciation for words that have none.
  ///
  /// Words captured before the dictionary shipped have an empty transcription,
  /// and the editor only fills one in when a word is opened. This gives them
  /// all one on the first launch after upgrading.
  ///
  /// Rows are marked dirty so the transcription reaches the user's other
  /// devices; the alternative is every device deriving it separately, which
  /// would differ whenever the bundled dictionaries differ.
  ///
  /// Returns whether anything changed, so the caller knows to reload.
  Future<bool> backfillPronunciations(
    Future<String?> Function(String word) lookup,
  ) async {
    final rows = await _db.query(
      _table,
      columns: _columns,
      where: "is_deleted = 0 AND (pronunciation IS NULL OR pronunciation = '')",
    );
    if (rows.isEmpty) return false;

    var updated = 0;
    final stamp = _now().toUtc().toIso8601String();
    final batch = _db.batch();

    for (final row in rows) {
      final wordObj = VocabularyWord.fromDbMap(row);
      final ipa = await lookup(wordObj.word);
      if (ipa == null) continue;

      final updatedWord = wordObj.copyWith(pronunciation: ipa, isDirty: true);
      batch.update(
        _table,
        {...updatedWord.toDbMap(), 'updated_at': stamp},
        where: 'id = ?',
        whereArgs: [wordObj.id],
      );
      updated++;
    }

    if (updated > 0) {
      await batch.commit(noResult: true);
      debugPrint('Backfilled pronunciation for $updated word(s)');
    }
    return updated > 0;
  }

  @override
  Future<void> deleteAll() async {
    // A hard delete, not a tombstone: there is no server left to tell, and
    // tombstones would only be re-uploaded to whatever account signs in next.
    await _db.transaction((txn) async {
      await txn.delete('gate_logs');
      await txn.delete(_table);
      final owner = await txn.query(
        'app_metadata',
        where: 'key = ?',
        whereArgs: ['notebook_owner'],
      );
      if (owner.isNotEmpty) {
        await txn.delete(
          'account_workspaces',
          where: 'account_id = ?',
          whereArgs: [owner.first['value']],
        );
      }
      await txn.delete(
        'app_metadata',
        where: 'key = ?',
        whereArgs: ['notebook_owner'],
      );
      await txn.update('gate_config', {
        'practice_word_ids_json': null,
        'words_per_unlock': 1,
      }, where: 'id = 1');
    });
  }

  @override
  Future<String?> activateNotebook(String? accountId) async {
    if (accountId == null) {
      await _db.delete(
        'app_metadata',
        where: 'key = ?',
        whereArgs: ['notebook_owner'],
      );
      return null;
    }
    if (accountId.isEmpty) throw ArgumentError('Account identity is required');
    const tables = [
      'words',
      'srs_reviews',
      'gate_logs',
      'gate_round_progress',
      'gate_pending_answers',
      'gate_word_rotation',
    ];
    return _db.transaction((txn) async {
      final metadata = await txn.query(
        'app_metadata',
        where: 'key = ?',
        whereArgs: ['notebook_owner'],
      );
      final previous = metadata.isEmpty
          ? null
          : metadata.first['value'] as String;
      if (previous == accountId) return previous;
      if (previous != null) {
        final payload = <String, Object?>{};
        for (final table in tables) {
          payload[table] = await txn.query(table);
        }
        final config = (await txn.query('gate_config', where: 'id = 1')).single;
        payload['practice_pool'] = {
          'practice_word_ids_json': config['practice_word_ids_json'],
          'words_per_unlock': config['words_per_unlock'],
        };
        await txn.insert('account_workspaces', {
          'account_id': previous,
          'payload': jsonEncode(payload),
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        await txn.delete('gate_logs');
        await txn.delete('words');
        await txn.update('gate_config', {
          'practice_word_ids_json': null,
          'words_per_unlock': 1,
        }, where: 'id = 1');
        final saved = await txn.query(
          'account_workspaces',
          where: 'account_id = ?',
          whereArgs: [accountId],
        );
        if (saved.isNotEmpty) {
          final payload =
              jsonDecode(saved.single['payload'] as String)
                  as Map<String, dynamic>;
          for (final table in tables) {
            for (final row in payload[table] as List) {
              await txn.insert(table, Map<String, Object?>.from(row as Map));
            }
          }
          await txn.update(
            'gate_config',
            Map<String, Object?>.from(payload['practice_pool'] as Map),
            where: 'id = 1',
          );
        }
      }
      await txn.insert('app_metadata', {
        'key': 'notebook_owner',
        'value': accountId,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      return previous;
    });
  }

  @override
  Future<List<VocabularyWord>> exportAll() async {
    final rows = await _db.query(
      _table,
      columns: _columns,
      where: 'is_deleted = 0',
      orderBy: 'created_at DESC',
    );
    return rows.map(VocabularyWord.fromDbMap).toList(growable: false);
  }

  @override
  Future<int> countPendingChanges() async {
    final result = await _db.rawQuery(
      'SELECT COUNT(*) as count FROM $_table WHERE is_dirty = 1',
    );
    return Sqflite.firstIntValue(result) ?? 0;
  }

  @override
  Future<void> bulkImport({
    required List<VocabularyWord> toInsert,
    required List<VocabularyWord> toUpdate,
  }) async {
    await _db.transaction((txn) async {
      final batch = txn.batch();
      for (final word in toInsert) {
        batch.insert(
          _table,
          word.toDbMap(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      for (final word in toUpdate) {
        batch.update(
          _table,
          word.toDbMap(),
          where: 'id = ?',
          whereArgs: [word.id],
        );
      }
      await batch.commit(noResult: true);
    });
  }

  @override
  Future<void> close() => _db.close();

  // `\` escapes the SQL wildcards so a query containing % or _ is treated
  // literally instead of matching everything.
  static const String _likeEscape = r'\';

  static String _escapeLike(String value) => value
      .replaceAll(r'\', r'\\')
      .replaceAll('%', r'\%')
      .replaceAll('_', r'\_');

  static DateTime _startOfWeek(DateTime now) {
    final day = DateTime(now.year, now.month, now.day);
    return day.subtract(Duration(days: day.weekday - DateTime.monday));
  }

  static String _dateKey(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';

  /// Counts consecutive days ending today (or yesterday, so an in-progress day
  /// does not break a streak) that contain at least one word.
  static int _streakFrom(Set<String> dates, DateTime today) {
    if (dates.isEmpty) return 0;

    var cursor = DateTime(today.year, today.month, today.day);
    if (!dates.contains(_dateKey(cursor))) {
      cursor = cursor.subtract(const Duration(days: 1));
      if (!dates.contains(_dateKey(cursor))) return 0;
    }

    var streak = 0;
    while (dates.contains(_dateKey(cursor))) {
      streak++;
      cursor = cursor.subtract(const Duration(days: 1));
    }
    return streak;
  }

  /// Calculates the maximum streak length achieved across all recorded dates.
  static int _maxStreakFrom(Set<String> dates) {
    if (dates.isEmpty) return 0;
    final sorted = dates.map(DateTime.parse).toList()..sort();
    var maxStreak = 1;
    var current = 1;
    for (var i = 1; i < sorted.length; i++) {
      final prev = sorted[i - 1];
      final curr = sorted[i];
      if (curr.difference(prev).inDays == 1) {
        current++;
        if (current > maxStreak) maxStreak = current;
      } else if (curr.difference(prev).inDays > 1) {
        current = 1;
      }
    }
    return maxStreak;
  }
}
