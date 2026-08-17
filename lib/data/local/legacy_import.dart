import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/vocabulary_word.dart';
import '../vocabulary_repository.dart';

/// One-shot import of vocabulary that predates the SQLite store.
///
/// The very first version of the app kept words as a JSON blob in
/// SharedPreferences. This runs once, copies anything it finds, and sets a
/// flag so it never runs again. Failures are logged and swallowed: a broken
/// legacy blob must not stop the app from starting.
class LegacyImport {
  const LegacyImport(this._repository);

  static const String _doneKey = 'sqlite_migration_done';
  static const String _blobKey = 'vocabulary_words';

  final VocabularyRepository _repository;

  Future<void> runIfNeeded() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_doneKey) ?? false) return;

    final blob = prefs.getString(_blobKey);
    if (blob != null && blob.isNotEmpty) {
      try {
        final decoded = jsonDecode(blob);
        if (decoded is List) {
          var imported = 0;
          for (final entry in decoded) {
            if (entry is! Map) continue;
            final word = VocabularyWord.fromLegacyJson(
              entry.cast<String, Object?>(),
            );
            // Skip anything already present so a partial previous run does not
            // clobber edits made since.
            if (await _repository.findById(word.id) != null) continue;
            await _repository.insert(word);
            imported++;
          }
          debugPrint('LegacyImport: imported $imported word(s)');
        }
      } catch (error, stack) {
        debugPrint('LegacyImport failed: $error\n$stack');
      }
    }

    await prefs.setBool(_doneKey, true);
  }
}
