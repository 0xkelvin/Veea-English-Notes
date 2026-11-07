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

  /// Bundled IPA lookup table, imported from an asset rather than typed by the
  /// user; see [PronunciationService].
  static const String pronunciationsTable = 'pronunciations';

  /// Spaced repetition review tracking table.
  static const String srsReviewsTable = 'srs_reviews';

  /// Singleton configuration table for App Gate ("Word Toll").
  static const String gateConfigTable = 'gate_config';

  /// Completion history table for App Gate challenges.
  static const String gateLogsTable = 'gate_logs';
  static const String gateProgressTable = 'gate_round_progress';

  /// Bump this and add a branch to [_upgrade] whenever the schema changes.
  static const int version = 11;

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
    await _createPronunciationsTable(db);
    await _createSrsReviewsTable(db);
    await _migrateToV5(db);
    await _createGateProgress(db);
    await _migrateLearningRules(db);
    await _createGateRotation(db);
    await _migrateWordSearch(db);
    await _createAccountWorkspaces(db);
  }

  static Future<void> _upgrade(Database db, int from, int to) async {
    if (from < 2) {
      await _migrateV1ToV2(db);
    }
    if (from < 3) {
      await _createPronunciationsTable(db);
    }
    if (from < 4) {
      await _createSrsReviewsTable(db);
    }
    if (from < 6) {
      await _migrateToV5(db);
    }
    if (from < 7) await _createGateProgress(db);
    if (from < 8) await _migrateLearningRules(db);
    if (from < 9) await _createGateRotation(db);
    if (from < 10) await _migrateWordSearch(db);
    if (from < 11) await _createAccountWorkspaces(db);
  }

  static Future<void> _createAccountWorkspaces(DatabaseExecutor db) async {
    await db.execute(
      'CREATE TABLE account_workspaces (account_id TEXT PRIMARY KEY, payload TEXT NOT NULL)',
    );
    await db.execute(
      'CREATE TABLE app_metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
    );
    await db.execute('''CREATE TABLE feedback_outbox (
      id TEXT PRIMARY KEY, owner_id TEXT NOT NULL, kind TEXT NOT NULL,
      message TEXT NOT NULL, contact TEXT, diagnostics TEXT NOT NULL DEFAULT '{}',
      screenshot_base64 TEXT, status TEXT NOT NULL DEFAULT 'queued',
      team_reply TEXT, last_error TEXT, created_at TEXT NOT NULL
    )''');
  }

  /// Keep word-only search independent of translations and example sentences.
  /// Only derived search data changes; user content and learning state stay intact.
  static Future<void> _migrateWordSearch(DatabaseExecutor db) async {
    await db.execute(
      "ALTER TABLE $wordsTable ADD COLUMN word_search_text TEXT NOT NULL DEFAULT ''",
    );
    final rows = await db.query(wordsTable, columns: ['id', 'word']);
    final batch = db.batch();
    for (final row in rows) {
      batch.update(
        wordsTable,
        {'word_search_text': TextNormalizer.query(row['word']! as String)},
        where: 'id = ?',
        whereArgs: [row['id']],
      );
    }
    await batch.commit(noResult: true);
  }

  static Future<void> _createGateRotation(DatabaseExecutor db) async {
    await db.execute(
      'CREATE TABLE IF NOT EXISTS gate_word_rotation (word_id TEXT PRIMARY KEY REFERENCES $wordsTable(id) ON DELETE CASCADE, last_turn INTEGER NOT NULL)',
    );
    final reviewed = await db.query(
      wordsTable,
      columns: ['id'],
      where: 'last_reviewed_at IS NOT NULL AND is_deleted = 0',
      orderBy: 'last_reviewed_at ASC, id ASC',
    );
    final batch = db.batch();
    for (var index = 0; index < reviewed.length; index++) {
      batch.insert('gate_word_rotation', {
        'word_id': reviewed[index]['id'],
        'last_turn': index + 1,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    await batch.commit(noResult: true);
  }

  static Future<void> _migrateLearningRules(DatabaseExecutor db) async {
    final columns = (await db.rawQuery(
      'PRAGMA table_info($gateConfigTable)',
    )).map((row) => row['name']).toSet();
    for (final entry in {
      'auto_pronounce': 'INTEGER NOT NULL DEFAULT 0',
      'daily_word_goal': 'INTEGER NOT NULL DEFAULT 0',
      'practice_word_ids_json': 'TEXT',
    }.entries) {
      if (!columns.contains(entry.key)) {
        await db.execute(
          'ALTER TABLE $gateConfigTable ADD COLUMN ${entry.key} ${entry.value}',
        );
      }
    }
    await db.execute(
      'UPDATE $gateConfigTable SET daily_word_goal = 1 WHERE require_daily_capture = 1',
    );
    await db.execute('UPDATE $gateConfigTable SET require_daily_capture = 0');
  }

  static Future<void> _createGateProgress(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $gateProgressTable (
        target_app TEXT NOT NULL,
        word_id TEXT NOT NULL REFERENCES $wordsTable(id) ON DELETE CASCADE,
        PRIMARY KEY (target_app, word_id)
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS gate_pending_answers (
        target_app TEXT PRIMARY KEY,
        word_id TEXT NOT NULL REFERENCES $wordsTable(id) ON DELETE CASCADE,
        attempts INTEGER NOT NULL
      )
    ''');
  }

  /// v5 migration for App Gate ("Word Toll"):
  /// - Extends `words` with `srs_stage`, `next_review_at`, `last_reviewed_at`,
  ///   and `last_gate_failed`.
  /// - Creates `gate_config` singleton table (seeded with `id = 1`).
  /// - Creates `gate_logs` history table.
  static Future<void> _migrateToV5(DatabaseExecutor db) async {
    final tableInfo = await db.rawQuery('PRAGMA table_info($wordsTable)');
    final existingColumns = {
      for (final row in tableInfo) row['name'] as String?,
    };

    if (!existingColumns.contains('srs_stage')) {
      await db.execute(
        'ALTER TABLE $wordsTable ADD COLUMN srs_stage INTEGER NOT NULL DEFAULT 0',
      );
    }
    if (!existingColumns.contains('next_review_at')) {
      await db.execute(
        'ALTER TABLE $wordsTable ADD COLUMN next_review_at INTEGER',
      );
    }
    if (!existingColumns.contains('last_reviewed_at')) {
      await db.execute(
        'ALTER TABLE $wordsTable ADD COLUMN last_reviewed_at INTEGER',
      );
    }
    if (!existingColumns.contains('last_gate_failed')) {
      await db.execute(
        'ALTER TABLE $wordsTable ADD COLUMN last_gate_failed INTEGER NOT NULL DEFAULT 0',
      );
    }

    await db.execute('''
      CREATE TABLE IF NOT EXISTS $gateConfigTable (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        enabled INTEGER NOT NULL DEFAULT 0,
        pass_duration_minutes INTEGER NOT NULL DEFAULT 15,
        words_per_unlock INTEGER NOT NULL DEFAULT 1,
        require_daily_capture INTEGER NOT NULL DEFAULT 0,
        gated_apps_json TEXT NOT NULL DEFAULT '[]'
      )
    ''');

    final gateConfigInfo = await db.rawQuery(
      'PRAGMA table_info($gateConfigTable)',
    );
    final gateConfigCols = {
      for (final row in gateConfigInfo) row['name'] as String?,
    };
    if (!gateConfigCols.contains('words_per_unlock')) {
      await db.execute(
        'ALTER TABLE $gateConfigTable ADD COLUMN words_per_unlock INTEGER NOT NULL DEFAULT 1',
      );
    }

    await db.execute('''
      INSERT OR IGNORE INTO $gateConfigTable (
        id, enabled, pass_duration_minutes, words_per_unlock, require_daily_capture, gated_apps_json
      ) VALUES (1, 0, 15, 1, 0, '[]')
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS $gateLogsTable (
        id TEXT PRIMARY KEY,
        word_id TEXT NOT NULL,
        target_app TEXT NOT NULL,
        attempts INTEGER NOT NULL,
        passed_at INTEGER NOT NULL
      )
    ''');
  }

  /// Table for Spaced Repetition (SM-2) review states.
  static Future<void> _createSrsReviewsTable(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $srsReviewsTable (
        word_id          TEXT    PRIMARY KEY,
        interval_days    INTEGER NOT NULL DEFAULT 0,
        ease_factor      REAL    NOT NULL DEFAULT 2.5,
        next_review_date TEXT    NOT NULL,
        last_reviewed_at TEXT,
        repetitions      INTEGER NOT NULL DEFAULT 0,
        lapses           INTEGER NOT NULL DEFAULT 0,
        FOREIGN KEY (word_id) REFERENCES $wordsTable (id) ON DELETE CASCADE
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_srs_next_review ON $srsReviewsTable(next_review_date)',
    );
  }

  /// Lookup table for automatic pronunciation.
  ///
  /// Held in SQLite rather than an in-memory map: 126k entries as a Dart `Map`
  /// costs tens of megabytes of resident memory, while an indexed table costs
  /// almost none and answers a lookup in microseconds.
  ///
  /// The rows are reference data, not user data — they are never synced, and
  /// they are rebuilt from the bundled asset rather than migrated.
  static Future<void> _createPronunciationsTable(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $pronunciationsTable (
        word TEXT PRIMARY KEY,
        ipa  TEXT NOT NULL
      )
    ''');
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
