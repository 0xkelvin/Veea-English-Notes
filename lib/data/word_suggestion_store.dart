import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../models/part_of_speech.dart';
import '../models/word_suggestion.dart';

abstract class WordSuggestionStore {
  Future<WordSuggestion?> lookupNotebook(String word);
  Future<WordSuggestion?> lookupSaved(String word);
  Future<WordSuggestion?> lookupBundled(String word);
  Future<void> saveOnline(
    WordSuggestion suggestion, {
    required String provider,
  });
  Future<int> savedCount();
  Future<void> clearSaved();
}

/// The public dictionary is a separate, read-only database. Personal online
/// lookup results live in the device notebook database, outside sync tables.
class SqliteWordSuggestionStore implements WordSuggestionStore {
  SqliteWordSuggestionStore(
    this._db, {
    Future<Uint8List> Function()? loadAsset,
    Future<String> Function()? dictionaryDirectory,
  }) : _loadAsset = loadAsset ?? _loadBundledAsset,
       _dictionaryDirectory = dictionaryDirectory ?? getDatabasesPath;

  static const revision = 'viwiktionary-20261002-v1';
  static const assetPath = 'assets/dictionary/en_vi.sqlite.gz';
  static const noticePath = 'assets/dictionary/NOTICE.txt';
  static const licencePath = 'assets/dictionary/CC-BY-SA-4.0.txt';
  static const cacheTable = 'online_meaning_cache';
  final Database _db;
  final Future<Uint8List> Function() _loadAsset;
  final Future<String> Function() _dictionaryDirectory;
  Future<Database>? _dictionary;

  static Future<Uint8List> _loadBundledAsset() async {
    final data = await rootBundle.load(assetPath);
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }

  Future<Database> _openDictionary() async {
    final dir = await _dictionaryDirectory();
    await Directory(dir).create(recursive: true);
    final file = File(p.join(dir, 'veea-$revision.sqlite'));
    for (var attempt = 0; attempt < 2; attempt++) {
      Database? db;
      try {
        if (!await file.exists()) {
          final unpacked = await compute(_unpackDictionary, await _loadAsset());
          final staging = File(
            '${file.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
          );
          try {
            await staging.writeAsBytes(unpacked, flush: true);
            await staging.rename(file.path);
          } finally {
            if (await staging.exists()) await staging.delete();
          }
        }
        db = await openDatabase(
          file.path,
          readOnly: true,
          singleInstance: false,
        );
        final rows = await db.query(
          'metadata',
          where: 'key = ?',
          whereArgs: ['revision'],
        );
        if (rows.singleOrNull?['value'] != revision) {
          throw const FormatException('Unexpected offline dictionary version');
        }
        return db;
      } catch (_) {
        await db?.close();
        // Recover only our replaceable public dictionary copy, never the
        // notebook or saved-lookup database.
        if (await file.exists()) await file.delete();
        if (attempt == 1) rethrow;
      }
    }
    throw StateError('Could not open offline dictionary');
  }

  Future<Database> _ready() async {
    try {
      return await (_dictionary ??= _openDictionary());
    } catch (_) {
      _dictionary = null;
      rethrow;
    }
  }

  @override
  Future<WordSuggestion?> lookupNotebook(String word) async {
    final rows = await _db.query(
      'words',
      columns: ['meaning', 'part_of_speech'],
      where: 'is_deleted = 0 AND lower(trim(word)) = ? AND trim(meaning) != ?',
      whereArgs: [word, ''],
      orderBy: 'updated_at DESC, id ASC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return WordSuggestion(
      word: word,
      meaning: rows.first['meaning'] as String,
      partOfSpeech: PartOfSpeech.fromId(
        rows.first['part_of_speech'] as String?,
      ),
      source: 'Previous note',
    );
  }

  @override
  Future<WordSuggestion?> lookupSaved(String word) async {
    final rows = await _db.query(
      cacheTable,
      where: 'word = ?',
      whereArgs: [word],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    return WordSuggestion(
      word: word,
      meaning: row['meaning'] as String,
      partOfSpeech: PartOfSpeech.fromId(row['part_of_speech'] as String?),
      source: 'Saved online lookup',
    );
  }

  @override
  Future<WordSuggestion?> lookupBundled(String word) async {
    final db = await _ready();
    final direct = await _bundledWord(db, word);
    if (direct != null) return direct;
    // Conservative inflection fallback: exact headwords always win. Do not
    // guess when several different noun/verb lemmas are plausible.
    final candidates = <String>{};
    if (word.endsWith('ies') && word.length > 4) {
      candidates.add('${word.substring(0, word.length - 3)}y');
    }
    if (word.endsWith('es') && word.length > 4) {
      candidates.add(word.substring(0, word.length - 2));
    }
    if (word.endsWith('s') && !word.endsWith('ss') && word.length > 3) {
      candidates.add(word.substring(0, word.length - 1));
    }
    final matches = <WordSuggestion>[];
    for (final lemma in candidates) {
      final match = await _bundledWord(db, lemma);
      if (match?.partOfSpeech == PartOfSpeech.noun ||
          match?.partOfSpeech == PartOfSpeech.verb) {
        matches.add(match!);
      }
    }
    if (matches.length != 1) return null;
    final match = matches.single;
    return WordSuggestion(
      word: word,
      meaning: match.meaning,
      partOfSpeech: match.partOfSpeech,
      source: match.source,
      sourceUrl: match.sourceUrl,
    );
  }

  Future<WordSuggestion?> _bundledWord(Database db, String word) async {
    final rows = await db.query(
      'entries',
      where: 'word = ?',
      whereArgs: [word],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    final title = row['source_title'] as String;
    return WordSuggestion(
      word: word,
      meaning: row['meaning'] as String,
      partOfSpeech: PartOfSpeech.fromId(row['part_of_speech'] as String?),
      source: 'Wiktionary contributors',
      sourceUrl: Uri.https(
        'vi.wiktionary.org',
        '/wiki/${title.replaceAll(' ', '_')}',
      ).toString(),
    );
  }

  @override
  Future<void> saveOnline(
    WordSuggestion suggestion, {
    required String provider,
  }) async {
    final meaning = suggestion.meaning?.trim() ?? '';
    if (suggestion.word.isEmpty ||
        suggestion.word.length > 200 ||
        meaning.isEmpty ||
        meaning.length > 4000) {
      return;
    }
    await _db.insert(cacheTable, {
      'word': suggestion.word,
      'meaning': meaning,
      'part_of_speech': suggestion.partOfSpeech?.id,
      'provider': provider,
      'saved_at': DateTime.now().toUtc().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<int> savedCount() async =>
      Sqflite.firstIntValue(
        await _db.rawQuery('SELECT COUNT(*) FROM $cacheTable'),
      ) ??
      0;

  @override
  Future<void> clearSaved() async {
    await _db.delete(cacheTable);
  }

  Future<void> close() async {
    final pending = _dictionary;
    _dictionary = null;
    if (pending != null) await (await pending).close();
  }
}

Uint8List _unpackDictionary(Uint8List bytes) =>
    Uint8List.fromList(gzip.decode(bytes));
