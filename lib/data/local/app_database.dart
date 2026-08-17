import 'dart:convert';

import 'package:path/path.dart' show join;
import 'package:sqflite/sqflite.dart';

import '../../models/text_normalizer.dart';

/// Owns the SQLite schema and its migrations.
///
/// Kept separate from the repository so tests can point at an in-memory
/// database while reusing the exact production schema.
class AppDatabase {
  AppDatabase._();

  static const String fileName = 'veea_english.db';
  static const String wordsTable = 'words';

  /// Bump this and add a branch to [_upgrade] whenever the schema changes.
  static const int version = 2;

  /// Opens the database, creating or migrating the schema as needed.
  ///
  /// [path] is injected by tests (`inMemoryDatabasePath`); production resolves
  /// the platform-specific database directory.
  static Future<Database> open({String? path}) async {
    return openDatabase(
      path ?? await _defaultPath(),
      version: version,
      onConfigure: _configure,
      onCreate: _create,
      onUpgrade: _upgrade,
    );
  }

  static Future<String> _defaultPath() async {
    final dir = await getDatabasesPath();
    return join(dir, fileName);
  }

  static Future<void> _configure(Database db) async {
    await db.execute('PRAGMA foreign_keys = ON');
  }

  static Future<void> _create(Database db, int version) async {
    await _createV2Schema(db, wordsTable);
  }

  static Future<void> _upgrade(Database db, int from, int to) async {
    if (from < 2) {
      await _migrateV1ToV2(db);
    }
  }

  /// v1 stored only `vietnamese_meaning` and had no sync bookkeeping.
  ///
  /// The table is rebuilt rather than patched with `ALTER TABLE` because the
  /// meaning column is being renamed as well as extended, and a rebuild works
  /// on every SQLite version sqflite may bundle. Existing rows are preserved:
  /// `updated_at` seeds from `created_at`, and every row starts dirty so the
  /// first sync uploads the pre-existing vocabulary.
  static Future<void> _migrateV1ToV2(Database db) async {
    const temp = 'words_v2';
    await db.transaction((txn) async {
      await _createV2Schema(txn, temp, withIndexes: false);
      await txn.execute('''
        INSERT INTO $temp (
          id, word, meaning, pronunciation, part_of_speech, source,
          examples, tags, search_text, date, created_at, updated_at,
          is_deleted, is_dirty, synced_at
        )
        SELECT
          id, word, vietnamese_meaning, NULL, NULL, NULL,
          COALESCE(examples, '[]'), '[]', '', date, created_at, created_at,
          0, 1, NULL
        FROM $wordsTable
      ''');
      await txn.execute('DROP TABLE $wordsTable');
      await txn.execute('ALTER TABLE $temp RENAME TO $wordsTable');
      await _createIndexes(txn, wordsTable);
    });
    // search_text folds Unicode, which SQL cannot do, so it is backfilled in
    // Dart once the rows are in place.
    await backfillSearchText(db);
  }

  /// Recomputes `search_text` for every row.
  ///
  /// Runs after a v1 upgrade and is safe to call at any time.
  static Future<void> backfillSearchText(DatabaseExecutor db) async {
    final rows = await db.query(
      wordsTable,
      columns: [
        'id',
        'word',
        'meaning',
        'pronunciation',
        'source',
        'examples',
        'tags',
      ],
    );
    if (rows.isEmpty) return;

    final batch = db.batch();
    for (final row in rows) {
      batch.update(
        wordsTable,
        {
          'search_text': TextNormalizer.haystack([
            row['word'] as String?,
            row['meaning'] as String?,
            row['pronunciation'] as String?,
            row['source'] as String?,
            _flatten(row['examples'] as String?),
            _flatten(row['tags'] as String?),
          ]),
        },
        where: 'id = ?',
        whereArgs: [row['id']],
      );
    }
    await batch.commit(noResult: true);
  }

  static String _flatten(String? jsonList) {
    if (jsonList == null || jsonList.isEmpty) return '';
    final decoded = jsonDecode(jsonList);
    return decoded is List ? decoded.join(' ') : '';
  }

  static Future<void> _createV2Schema(
    DatabaseExecutor db,
    String table, {
    bool withIndexes = true,
  }) async {
    await db.execute('''
      CREATE TABLE $table (
        id             TEXT    PRIMARY KEY,
        word           TEXT    NOT NULL,
        meaning        TEXT    NOT NULL,
        pronunciation  TEXT,
        part_of_speech TEXT,
        source         TEXT,
        examples       TEXT    NOT NULL DEFAULT '[]',
        tags           TEXT    NOT NULL DEFAULT '[]',
        search_text    TEXT    NOT NULL DEFAULT '',
        date           TEXT    NOT NULL,
        created_at     TEXT    NOT NULL,
        updated_at     TEXT    NOT NULL,
        is_deleted     INTEGER NOT NULL DEFAULT 0,
        is_dirty       INTEGER NOT NULL DEFAULT 1,
        synced_at      TEXT
      )
    ''');
    if (withIndexes) await _createIndexes(db, table);
  }

  static Future<void> _createIndexes(DatabaseExecutor db, String table) async {
    // Every list query filters on is_deleted, so it leads each index.
    await db.execute(
      'CREATE INDEX idx_words_date ON $table(is_deleted, date, created_at DESC)',
    );
    // Drives the sync push query.
    await db.execute('CREATE INDEX idx_words_dirty ON $table(is_dirty)');
    // Drives the sync pull cursor.
    await db.execute('CREATE INDEX idx_words_updated ON $table(updated_at)');
  }
}
