import 'package:flutter/foundation.dart';
import 'package:path/path.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import '../models/vocabulary_word.dart';

class StorageService {
  static const String _dbName = 'veea_english.db';
  static const String _tableName = 'words';
  static const int _dbVersion = 1;

  static const String _migrationKey = 'sqlite_migration_done';

  Database? _db;

  Future<Database> get database async {
    _db ??= await _initDb();
    return _db!;
  }

  Future<Database> _initDb() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, _dbName);

    return openDatabase(
      path,
      version: _dbVersion,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE $_tableName (
            id TEXT PRIMARY KEY,
            word TEXT NOT NULL,
            vietnamese_meaning TEXT NOT NULL,
            examples TEXT NOT NULL DEFAULT '[]',
            date TEXT NOT NULL,
            created_at TEXT NOT NULL
          )
        ''');
        await db.execute(
          'CREATE INDEX idx_words_date ON $_tableName(date)',
        );
      },
    );
  }

  /// Migrate existing SharedPreferences data to SQLite (runs once)
  Future<void> migrateFromSharedPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_migrationKey) == true) return;

    final encoded = prefs.getString('vocabulary_words');
    if (encoded != null && encoded.isNotEmpty) {
      try {
        final words = VocabularyWord.decode(encoded);
        final db = await database;
        final batch = db.batch();
        for (final word in words) {
          batch.insert(
            _tableName,
            word.toDbMap(),
            conflictAlgorithm: ConflictAlgorithm.ignore,
          );
        }
        await batch.commit(noResult: true);
        debugPrint('Migrated ${words.length} words from SharedPreferences to SQLite');
      } catch (e) {
        debugPrint('Migration error: $e');
      }
    }

    await prefs.setBool(_migrationKey, true);
  }

  Future<List<VocabularyWord>> loadWords() async {
    final db = await database;
    final maps = await db.query(
      _tableName,
      orderBy: 'created_at DESC',
    );
    return maps.map(VocabularyWord.fromDbMap).toList();
  }

  Future<void> insertWord(VocabularyWord word) async {
    final db = await database;
    await db.insert(
      _tableName,
      word.toDbMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> updateWord(VocabularyWord word) async {
    final db = await database;
    await db.update(
      _tableName,
      word.toDbMap(),
      where: 'id = ?',
      whereArgs: [word.id],
    );
  }

  Future<void> deleteWord(String id) async {
    final db = await database;
    await db.delete(
      _tableName,
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<List<VocabularyWord>> getWordsByDate(String date) async {
    final db = await database;
    final maps = await db.query(
      _tableName,
      where: 'date = ?',
      whereArgs: [date],
      orderBy: 'created_at DESC',
    );
    return maps.map(VocabularyWord.fromDbMap).toList();
  }

  Future<int> getTotalWordCount() async {
    final db = await database;
    final result = await db.rawQuery('SELECT COUNT(*) as count FROM $_tableName');
    return Sqflite.firstIntValue(result) ?? 0;
  }

  Future<List<String>> getDistinctDates() async {
    final db = await database;
    final result = await db.rawQuery(
      'SELECT DISTINCT date FROM $_tableName ORDER BY date',
    );
    return result.map((r) => r['date'] as String).toList();
  }

  Future<int> getWordCountSince(String sinceDate) async {
    final db = await database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) as count FROM $_tableName WHERE date >= ?',
      [sinceDate],
    );
    return Sqflite.firstIntValue(result) ?? 0;
  }
}
