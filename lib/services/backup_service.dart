import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:share_plus/share_plus.dart';
import 'package:uuid/uuid.dart';

import '../data/vocabulary_repository.dart';
import '../models/part_of_speech.dart';
import '../models/vocabulary_word.dart';

class BackupImportResult {
  const BackupImportResult({
    required this.totalParsed,
    required this.inserted,
    required this.merged,
    required this.skipped,
    this.errorMessage,
  });

  final int totalParsed;
  final int inserted;
  final int merged;
  final int skipped;
  final String? errorMessage;

  bool get isSuccess => errorMessage == null;

  String get summary {
    if (errorMessage != null) return 'IMPORT FAILED: $errorMessage';
    return '$inserted added, $merged merged, $skipped skipped';
  }
}

class BackupPreviewResult {
  const BackupPreviewResult({
    required this.totalParsed,
    required this.wouldInsert,
    required this.wouldMerge,
    required this.wouldSkip,
    this.errorMessage,
  });

  final int totalParsed;
  final int wouldInsert;
  final int wouldMerge;
  final int wouldSkip;
  final String? errorMessage;

  bool get isSuccess => errorMessage == null && totalParsed > 0;

  String get summary {
    if (errorMessage != null) return errorMessage!;
    return '$totalParsed words found: $wouldInsert new, $wouldMerge updates, $wouldSkip skipped';
  }
}

/// 100% offline local SQLite export and import service.
///
/// Supports JSON and CSV formats with automatic duplicate detection & merge.
class BackupService {
  const BackupService();

  /// Exports all [words] to pretty-printed JSON.
  static String exportToJson(List<VocabularyWord> words) {
    final payload = {
      'version': 1,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'appName': 'Veea English',
      'wordCount': words.length,
      'words': words.map((w) {
        return {
          'id': w.id,
          'word': w.word,
          'meaning': w.meaning,
          'pronunciation': w.pronunciation,
          'partOfSpeech': w.partOfSpeech?.name,
          'source': w.source,
          'examples': w.examples,
          'tags': w.tags,
          'date': w.date,
          'createdAt': w.createdAt.toUtc().toIso8601String(),
          'updatedAt': w.updatedAt.toUtc().toIso8601String(),
        };
      }).toList(),
    };
    return const JsonEncoder.withIndent('  ').convert(payload);
  }

  /// Exports all [words] to standard RFC 4180 CSV.
  static String exportToCsv(List<VocabularyWord> words) {
    final buffer = StringBuffer();
    // CSV Header
    buffer.writeln(
      'Word,Meaning,Part of Speech,Pronunciation,Date,Examples,Tags,Source',
    );

    for (final w in words) {
      final fields = [
        _escapeCsv(w.word),
        _escapeCsv(w.meaning),
        _escapeCsv(w.partOfSpeech?.name ?? ''),
        _escapeCsv(w.pronunciation ?? ''),
        _escapeCsv(w.date),
        _escapeCsv(w.examples.join(' ; ')),
        _escapeCsv(w.tags.join(', ')),
        _escapeCsv(w.source ?? ''),
      ];
      buffer.writeln(fields.join(','));
    }

    return buffer.toString();
  }

  /// Shares backup content using system share sheet.
  static Future<void> shareBackup({
    required String content,
    required String filename,
    required String mimeType,
  }) async {
    try {
      final bytes = Uint8List.fromList(utf8.encode(content));
      final xfile = XFile.fromData(bytes, name: filename, mimeType: mimeType);
      await SharePlus.instance.share(
        ShareParams(files: [xfile], subject: filename),
      );
    } catch (e) {
      debugPrint('System share sheet failed: $e, falling back to text share');
      await SharePlus.instance.share(
        ShareParams(text: content, subject: filename),
      );
    }
  }

  static bool _isValidDateKey(String? date) {
    if (date == null) return false;
    final trimmed = date.trim();
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(trimmed)) return false;
    try {
      final parsed = DateTime.parse(trimmed);
      return parsed.year >= 2000 && parsed.year <= 2100;
    } catch (_) {
      return false;
    }
  }

  /// Parses raw backup content and returns a preview of what would be inserted,
  /// merged, or skipped without modifying the database.
  static Future<BackupPreviewResult> previewBackup({
    required String rawContent,
    required VocabularyRepository repository,
  }) async {
    final text = rawContent.trim();
    if (text.isEmpty) {
      return const BackupPreviewResult(
        totalParsed: 0,
        wouldInsert: 0,
        wouldMerge: 0,
        wouldSkip: 0,
        errorMessage: 'File or input is empty',
      );
    }

    List<_ParsedWordEntry> parsedEntries;
    try {
      if (text.startsWith('{') || text.startsWith('[')) {
        parsedEntries = _parseJson(text);
      } else {
        parsedEntries = _parseCsv(text);
      }
    } catch (e) {
      return BackupPreviewResult(
        totalParsed: 0,
        wouldInsert: 0,
        wouldMerge: 0,
        wouldSkip: 0,
        errorMessage: 'Malformed backup data: $e',
      );
    }

    if (parsedEntries.isEmpty) {
      return const BackupPreviewResult(
        totalParsed: 0,
        wouldInsert: 0,
        wouldMerge: 0,
        wouldSkip: 0,
        errorMessage: 'No valid words found in backup',
      );
    }

    final existingWords = await repository.exportAll();
    final existingByWord = <String, VocabularyWord>{};
    for (final w in existingWords) {
      existingByWord[w.word.trim().toLowerCase()] = w;
    }

    int wouldInsert = 0;
    int wouldMerge = 0;
    int wouldSkip = 0;

    for (final entry in parsedEntries) {
      final rawWord = entry.word.trim();
      if (rawWord.isEmpty) {
        wouldSkip++;
        continue;
      }
      final normKey = rawWord.toLowerCase();
      if (existingByWord.containsKey(normKey)) {
        wouldMerge++;
      } else {
        wouldInsert++;
      }
    }

    return BackupPreviewResult(
      totalParsed: parsedEntries.length,
      wouldInsert: wouldInsert,
      wouldMerge: wouldMerge,
      wouldSkip: wouldSkip,
    );
  }

  /// Imports and merges words into [repository] in a single atomic transaction.
  static Future<BackupImportResult> importBackupText({
    required String rawContent,
    required VocabularyRepository repository,
    DateTime Function()? now,
    Uuid uuid = const Uuid(),
  }) async {
    final text = rawContent.trim();
    if (text.isEmpty) {
      return const BackupImportResult(
        totalParsed: 0,
        inserted: 0,
        merged: 0,
        skipped: 0,
        errorMessage: 'File or input is empty',
      );
    }

    List<_ParsedWordEntry> parsedEntries;
    try {
      if (text.startsWith('{') || text.startsWith('[')) {
        parsedEntries = _parseJson(text);
      } else {
        parsedEntries = _parseCsv(text);
      }
    } catch (e) {
      return BackupImportResult(
        totalParsed: 0,
        inserted: 0,
        merged: 0,
        skipped: 0,
        errorMessage: 'Malformed backup data: $e',
      );
    }

    if (parsedEntries.isEmpty) {
      return const BackupImportResult(
        totalParsed: 0,
        inserted: 0,
        merged: 0,
        skipped: 0,
        errorMessage: 'No valid words found in input',
      );
    }

    final currentTime = (now ?? DateTime.now)();
    final todayKey =
        '${currentTime.year.toString().padLeft(4, '0')}-'
        '${currentTime.month.toString().padLeft(2, '0')}-'
        '${currentTime.day.toString().padLeft(2, '0')}';

    // Retrieve all existing words to detect duplicates & collisions
    final existingWords = await repository.exportAll();
    final Map<String, VocabularyWord> existingByWord = {};
    final Map<String, VocabularyWord> existingById = {};
    for (final w in existingWords) {
      existingByWord[w.word.trim().toLowerCase()] = w;
      existingById[w.id] = w;
    }

    final Set<String> allocatedIds = {...existingById.keys};
    final List<VocabularyWord> toInsert = [];
    final List<VocabularyWord> toUpdate = [];

    int inserted = 0;
    int merged = 0;
    int skipped = 0;

    for (final entry in parsedEntries) {
      final rawWord = entry.word.trim();
      if (rawWord.isEmpty) {
        skipped++;
        continue;
      }

      final normKey = rawWord.toLowerCase();
      final existing = existingByWord[normKey];

      if (existing != null) {
        // Duplicate detected: Merge details cleanly
        final mergedExamples = <String>{...existing.examples};
        for (final ex in entry.examples) {
          final trimmed = ex.trim();
          if (trimmed.isNotEmpty) mergedExamples.add(trimmed);
        }

        final mergedTags = <String>{...existing.tags};
        for (final tg in entry.tags) {
          final trimmed = tg.trim();
          if (trimmed.isNotEmpty) mergedTags.add(trimmed);
        }

        final updatedWord = existing.edited(
          word: existing.word,
          meaning: existing.meaning.isNotEmpty
              ? existing.meaning
              : (entry.meaning.isNotEmpty ? entry.meaning : existing.meaning),
          now: currentTime,
          pronunciation: existing.pronunciation ?? entry.pronunciation,
          partOfSpeech: existing.partOfSpeech ?? entry.partOfSpeech,
          source: existing.source ?? entry.source,
          examples: mergedExamples.toList(),
          tags: mergedTags.toList(),
        );

        toUpdate.add(updatedWord);
        existingByWord[normKey] = updatedWord;
        merged++;
      } else {
        // New word: Insert with valid date
        final date = _isValidDateKey(entry.date)
            ? entry.date!.trim()
            : todayKey;

        // Ensure non-colliding ID: if this ID exists on another word, regenerate it
        String wordId = entry.id?.trim() ?? '';
        if (wordId.isEmpty || allocatedIds.contains(wordId)) {
          wordId = uuid.v4();
        }
        allocatedIds.add(wordId);

        final newWord = VocabularyWord.create(
          id: wordId,
          word: rawWord,
          meaning: entry.meaning,
          date: date,
          now: currentTime,
          pronunciation: entry.pronunciation,
          partOfSpeech: entry.partOfSpeech,
          source: entry.source ?? 'Imported',
          examples: entry.examples,
          tags: entry.tags,
        );

        toInsert.add(newWord);
        existingByWord[normKey] = newWord;
        existingById[wordId] = newWord;
        inserted++;
      }
    }

    try {
      await repository.bulkImport(toInsert: toInsert, toUpdate: toUpdate);
    } catch (e) {
      return BackupImportResult(
        totalParsed: parsedEntries.length,
        inserted: 0,
        merged: 0,
        skipped: parsedEntries.length,
        errorMessage: 'Database import transaction failed: $e',
      );
    }

    return BackupImportResult(
      totalParsed: parsedEntries.length,
      inserted: inserted,
      merged: merged,
      skipped: skipped,
    );
  }

  static String _escapeCsv(String field) {
    if (field.contains(',') ||
        field.contains('"') ||
        field.contains('\n') ||
        field.contains('\r')) {
      final escaped = field.replaceAll('"', '""');
      return '"$escaped"';
    }
    return field;
  }

  static List<_ParsedWordEntry> _parseJson(String jsonText) {
    final decoded = json.decode(jsonText);
    List<dynamic> list;
    if (decoded is List) {
      list = decoded;
    } else if (decoded is Map && decoded['words'] is List) {
      list = decoded['words'] as List<dynamic>;
    } else {
      throw const FormatException(
        'Expected JSON array or object with "words" array',
      );
    }

    final results = <_ParsedWordEntry>[];
    for (final item in list) {
      if (item is! Map) continue;
      final map = item.cast<String, dynamic>();
      final word = (map['word'] ?? map['Word'] ?? '').toString();
      final meaning = (map['meaning'] ?? map['Meaning'] ?? '').toString();
      final pronunciation =
          map['pronunciation']?.toString() ?? map['Pronunciation']?.toString();
      final posStr =
          (map['partOfSpeech'] ?? map['part_of_speech'] ?? map['PartOfSpeech'])
              ?.toString();
      final source = map['source']?.toString() ?? map['Source']?.toString();
      final date = map['date']?.toString() ?? map['Date']?.toString();

      List<String> examples = [];
      final rawExamples = map['examples'] ?? map['Examples'];
      if (rawExamples is List) {
        examples = rawExamples.map((e) => e.toString()).toList();
      } else if (rawExamples is String && rawExamples.isNotEmpty) {
        examples = rawExamples.split(RegExp(r'\s*;\s*|\s*\|\s*'));
      }

      List<String> tags = [];
      final rawTags = map['tags'] ?? map['Tags'];
      if (rawTags is List) {
        tags = rawTags.map((e) => e.toString()).toList();
      } else if (rawTags is String && rawTags.isNotEmpty) {
        tags = rawTags.split(RegExp(r'\s*,\s*|\s*;\s*'));
      }

      results.add(
        _ParsedWordEntry(
          id: map['id']?.toString(),
          word: word,
          meaning: meaning,
          pronunciation: pronunciation,
          partOfSpeech: _parsePartOfSpeech(posStr),
          source: source,
          examples: examples,
          tags: tags,
          date: date,
        ),
      );
    }
    return results;
  }

  static List<_ParsedWordEntry> _parseCsv(String csvText) {
    final rows = _splitCsvRows(csvText);
    if (rows.isEmpty) return const [];

    // Check header
    final header = rows.first.map((h) => h.trim().toLowerCase()).toList();
    int wordIdx = header.indexOf('word');
    int meaningIdx = header.indexOf('meaning');
    int posIdx = header.indexOf('part of speech');
    if (posIdx == -1) posIdx = header.indexOf('pos');
    int pronIdx = header.indexOf('pronunciation');
    int dateIdx = header.indexOf('date');
    int examplesIdx = header.indexOf('examples');
    int tagsIdx = header.indexOf('tags');
    int sourceIdx = header.indexOf('source');

    int startRow = 1;
    if (wordIdx == -1) {
      // No header matching 'word'; assume first column is word, second is meaning
      wordIdx = 0;
      meaningIdx = 1;
      posIdx = 2;
      pronIdx = 3;
      dateIdx = 4;
      examplesIdx = 5;
      tagsIdx = 6;
      sourceIdx = 7;
      startRow = 0;
    }

    final results = <_ParsedWordEntry>[];
    for (int i = startRow; i < rows.length; i++) {
      final row = rows[i];
      if (row.isEmpty) continue;

      final word = wordIdx < row.length ? row[wordIdx].trim() : '';
      if (word.isEmpty) continue;

      final meaning = meaningIdx >= 0 && meaningIdx < row.length
          ? row[meaningIdx].trim()
          : '';
      final posStr = posIdx >= 0 && posIdx < row.length
          ? row[posIdx].trim()
          : null;
      final pronunciation = pronIdx >= 0 && pronIdx < row.length
          ? row[pronIdx].trim()
          : null;
      final date = dateIdx >= 0 && dateIdx < row.length
          ? row[dateIdx].trim()
          : null;

      List<String> examples = const [];
      if (examplesIdx >= 0 && examplesIdx < row.length) {
        final raw = row[examplesIdx].trim();
        if (raw.isNotEmpty) {
          examples = raw
              .split(RegExp(r'\s*;\s*|\s*\|\s*'))
              .where((e) => e.isNotEmpty)
              .toList();
        }
      }

      List<String> tags = const [];
      if (tagsIdx >= 0 && tagsIdx < row.length) {
        final raw = row[tagsIdx].trim();
        if (raw.isNotEmpty) {
          tags = raw
              .split(RegExp(r'\s*,\s*|\s*;\s*'))
              .where((t) => t.isNotEmpty)
              .toList();
        }
      }

      final source = sourceIdx >= 0 && sourceIdx < row.length
          ? row[sourceIdx].trim()
          : null;

      results.add(
        _ParsedWordEntry(
          word: word,
          meaning: meaning,
          pronunciation: pronunciation?.isNotEmpty == true
              ? pronunciation
              : null,
          partOfSpeech: _parsePartOfSpeech(posStr),
          source: source?.isNotEmpty == true ? source : null,
          examples: examples,
          tags: tags,
          date: date?.isNotEmpty == true ? date : null,
        ),
      );
    }
    return results;
  }

  static List<List<String>> _splitCsvRows(String text) {
    final rows = <List<String>>[];
    final currentRow = <String>[];
    final currentCell = StringBuffer();
    bool inQuotes = false;

    for (int i = 0; i < text.length; i++) {
      final char = text[i];
      final nextChar = (i + 1 < text.length) ? text[i + 1] : null;

      if (char == '"') {
        if (inQuotes && nextChar == '"') {
          // Escaped quote
          currentCell.write('"');
          i++; // skip next quote
        } else {
          inQuotes = !inQuotes;
        }
      } else if (char == ',' && !inQuotes) {
        currentRow.add(currentCell.toString());
        currentCell.clear();
      } else if ((char == '\n' || char == '\r') && !inQuotes) {
        if (char == '\r' && nextChar == '\n') i++; // Skip \r\n
        currentRow.add(currentCell.toString());
        currentCell.clear();
        if (currentRow.any((c) => c.trim().isNotEmpty)) {
          rows.add(List.from(currentRow));
        }
        currentRow.clear();
      } else {
        currentCell.write(char);
      }
    }

    if (currentCell.isNotEmpty || currentRow.isNotEmpty) {
      currentRow.add(currentCell.toString());
      if (currentRow.any((c) => c.trim().isNotEmpty)) {
        rows.add(List.from(currentRow));
      }
    }

    return rows;
  }

  static PartOfSpeech? _parsePartOfSpeech(String? val) {
    if (val == null) return null;
    final lower = val.trim().toLowerCase();
    for (final pos in PartOfSpeech.values) {
      if (pos.name == lower || pos.id == lower || pos.label == lower) {
        return pos;
      }
    }
    return null;
  }
}

class _ParsedWordEntry {
  const _ParsedWordEntry({
    this.id,
    required this.word,
    required this.meaning,
    this.pronunciation,
    this.partOfSpeech,
    this.source,
    this.examples = const [],
    this.tags = const [],
    this.date,
  });

  final String? id;
  final String word;
  final String meaning;
  final String? pronunciation;
  final PartOfSpeech? partOfSpeech;
  final String? source;
  final List<String> examples;
  final List<String> tags;
  final String? date;
}
