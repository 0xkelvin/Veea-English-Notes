import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import '../../models/text_normalizer.dart';
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
  Future<List<VocabularyWord>> search(String query, {int limit = 200}) async {
    final needle = TextNormalizer.query(query);
    if (needle.isEmpty) return const [];

    // Written as a raw query because the ranking expression needs its own
    // placeholder, and `query()` only binds arguments for the WHERE clause.
    final pattern = '%${_escapeLike(needle)}%';
    final rows = await _db.rawQuery(
      '''
      SELECT ${_columns.join(', ')} FROM $_table
      WHERE is_deleted = 0 AND search_text LIKE ? ESCAPE ?
      ORDER BY
        CASE WHEN search_text LIKE ? ESCAPE ? THEN 0 ELSE 1 END,
        date DESC, created_at DESC
      LIMIT ?
      ''',
      [
        pattern,
        _likeEscape,
        // Words starting with the query rank above incidental matches buried
        // in an example sentence.
        '${_escapeLike(needle)}%',
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
  Future<void> markSynced(List<String> ids, DateTime syncedAt) async {
    if (ids.isEmpty) return;
    final batch = _db.batch();
    final stamp = syncedAt.toUtc().toIso8601String();
    for (final id in ids) {
      batch.update(
        _table,
        {'is_dirty': 0, 'synced_at': stamp},
        where: 'id = ?',
        whereArgs: [id],
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
          if (!incoming.updatedAt.toUtc().isAfter(localUpdatedAt.toUtc())) {
            continue;
          }
        }

        await txn.insert(
          _table,
          incoming.copyWith(isDirty: false).toDbMap(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
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
      columns: ['id', 'word'],
      where: "is_deleted = 0 AND (pronunciation IS NULL OR pronunciation = '')",
    );
    if (rows.isEmpty) return false;

    var updated = 0;
    final stamp = _now().toUtc().toIso8601String();

    for (final row in rows) {
      final ipa = await lookup(row['word']! as String);
      if (ipa == null) continue;

      // Written column-wise rather than through the model so search_text is
      // recomputed without loading and re-encoding the whole row.
      final word = await findById(row['id']! as String);
      if (word == null) continue;

      await _db.update(
        _table,
        {
          ...word.copyWith(pronunciation: ipa, isDirty: true).toDbMap(),
          'updated_at': stamp,
        },
        where: 'id = ?',
        whereArgs: [word.id],
      );
      updated++;
    }

    if (updated > 0) {
      debugPrint('Backfilled pronunciation for $updated word(s)');
    }
    return updated > 0;
  }

  @override
  Future<void> deleteAll() async {
    // A hard delete, not a tombstone: there is no server left to tell, and
    // tombstones would only be re-uploaded to whatever account signs in next.
    await _db.delete(_table);
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
}
