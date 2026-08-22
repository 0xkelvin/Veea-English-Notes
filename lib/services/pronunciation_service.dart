import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:sqflite/sqflite.dart';

import '../data/local/app_database.dart';

/// Looks up how a word is pronounced.
///
/// The app fills this in rather than asking, because a phone keyboard cannot
/// type `/rɪˈzɪljənt/` — every character in an IPA transcription is off the
/// standard layout, so a field that asks for one stays empty forever.
///
/// The dictionary is bundled and queried locally: capturing a word usually
/// happens mid-conversation, and waiting on a network round trip (or failing
/// without one) would defeat the point.
class PronunciationService {
  PronunciationService(this._db);

  /// Gzipped `word<TAB>ipa` table, General American, derived from the CMU
  /// Pronouncing Dictionary. Regenerate with
  /// `tool/build_pronunciation_dictionary.py`.
  static const String assetPath = 'assets/pronunciation/en_us_ipa.txt.gz';

  static const String _table = AppDatabase.pronunciationsTable;

  /// Rows inserted per batch during the import.
  ///
  /// One batch of 126k statements holds a large intermediate list in memory
  /// and blocks the database for the whole import; chunking keeps both bounded.
  static const int _importChunk = 5000;

  final Database _db;

  /// Small cache in front of SQLite, since the editor looks the same word up
  /// repeatedly as the user types.
  final Map<String, String?> _cache = {};

  bool? _isReady;

  /// Whether the dictionary has been imported.
  Future<bool> get isReady async {
    if (_isReady == true) return true;
    final count = Sqflite.firstIntValue(
      await _db.rawQuery('SELECT COUNT(*) FROM $_table LIMIT 1'),
    );
    return _isReady = (count ?? 0) > 0;
  }

  /// Imports the bundled dictionary if it is not already present.
  ///
  /// Safe to call on every launch; it returns immediately once populated. Run
  /// it off the first frame — the import takes a second or two on a phone.
  Future<void> importIfNeeded() async {
    if (await isReady) return;

    final started = DateTime.now();
    try {
      final bytes = (await rootBundle.load(assetPath)).buffer.asUint8List();
      final text = utf8.decode(gzip.decode(bytes));

      var batch = _db.batch();
      var pending = 0;
      var imported = 0;

      for (final line in const LineSplitter().convert(text)) {
        final tab = line.indexOf('\t');
        if (tab <= 0) continue;

        batch.insert(_table, {
          'word': line.substring(0, tab),
          'ipa': line.substring(tab + 1),
        }, conflictAlgorithm: ConflictAlgorithm.replace);

        pending++;
        imported++;
        if (pending >= _importChunk) {
          await batch.commit(noResult: true);
          batch = _db.batch();
          pending = 0;
        }
      }
      if (pending > 0) await batch.commit(noResult: true);

      _isReady = imported > 0;
      debugPrint(
        'Pronunciation dictionary: imported $imported entries in '
        '${DateTime.now().difference(started).inMilliseconds}ms',
      );
    } catch (error, stack) {
      // A missing or corrupt asset must not stop the app starting; the
      // pronunciation line simply does not appear.
      debugPrint('Pronunciation import failed: $error\n$stack');
      _isReady = false;
    }
  }

  /// The IPA for [input], or null when it is not in the dictionary.
  ///
  /// Multi-word input is looked up word by word and joined, so an idiom like
  /// `break the ice` still gets a transcription. If any word is unknown the
  /// whole thing returns null rather than a partial answer, which would be
  /// misleading.
  Future<String?> lookup(String input) async {
    final key = input.trim().toLowerCase();
    if (key.isEmpty) return null;
    if (_cache.containsKey(key)) return _cache[key];

    final result = await _lookupUncached(key);

    // Bounded so a long editing session cannot grow it without limit.
    if (_cache.length > 500) _cache.clear();
    return _cache[key] = result;
  }

  static final RegExp _whitespaceRegExp = RegExp(r'\s+');
  static final RegExp _punctuationRegExp = RegExp(r"^[^a-z']+|[^a-z']+$");

  Future<String?> _lookupUncached(String key) async {
    try {
      final direct = await _word(key);
      if (direct != null) return direct;

      final parts = key.split(_whitespaceRegExp).where((p) => p.isNotEmpty);
      if (parts.length < 2) return null;

      final transcribed = <String>[];
      for (final part in parts) {
        // Strip punctuation that rides along with a word in a phrase.
        final cleaned = part.replaceAll(_punctuationRegExp, '');
        final ipa = cleaned.isEmpty ? null : await _word(cleaned);
        if (ipa == null) return null;
        transcribed.add(ipa);
      }
      return transcribed.join(' ');
    } catch (error) {
      debugPrint('Pronunciation lookup failed for "$key": $error');
      return null;
    }
  }

  Future<String?> _word(String word) async {
    final rows = await _db.query(
      _table,
      columns: ['ipa'],
      where: 'word = ?',
      whereArgs: [word],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['ipa'] as String?;
  }

  /// Wraps a transcription in the slashes a dictionary would print.
  ///
  /// Idempotent: transcriptions typed by a user, or captured before the
  /// dictionary shipped, often already carry slashes, and wrapping those again
  /// would render `//rɪˈzɪljənt//`.
  static String format(String ipa) => '/${normalise(ipa)}/';

  /// Canonical stored form: no surrounding slashes, no surrounding space.
  ///
  /// Slashes are presentation. Keeping them out of the stored value means one
  /// spelling in the database, so search and comparison behave.
  static String normalise(String ipa) {
    var value = ipa.trim();
    while (value.startsWith('/')) {
      value = value.substring(1);
    }
    while (value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    return value.trim();
  }
}
