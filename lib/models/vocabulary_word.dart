import 'dart:convert';

import 'part_of_speech.dart';
import 'text_normalizer.dart';

/// A single English word captured on a given day.
///
/// Instances are immutable; use [copyWith] to derive a modified copy. The
/// sync-related fields ([updatedAt], [isDeleted], [isDirty], [syncedAt]) are
/// maintained locally and consumed by the sync layer — the UI ignores them.
class VocabularyWord {
  const VocabularyWord({
    required this.id,
    required this.word,
    required this.meaning,
    required this.date,
    required this.createdAt,
    required this.updatedAt,
    this.pronunciation,
    this.partOfSpeech,
    this.source,
    this.examples = const [],
    this.tags = const [],
    this.isDeleted = false,
    this.isDirty = true,
    this.syncedAt,
  });

  /// Builds a brand-new word, stamping [createdAt]/[updatedAt] from [now].
  ///
  /// [now] is injected rather than read from the clock so tests stay
  /// deterministic.
  factory VocabularyWord.create({
    required String id,
    required String word,
    required String meaning,
    required String date,
    required DateTime now,
    String? pronunciation,
    PartOfSpeech? partOfSpeech,
    String? source,
    List<String> examples = const [],
    List<String> tags = const [],
  }) {
    return VocabularyWord(
      id: id,
      word: word.trim(),
      meaning: meaning.trim(),
      date: date,
      createdAt: now,
      updatedAt: now,
      pronunciation: _nullIfBlank(pronunciation),
      partOfSpeech: partOfSpeech,
      source: _nullIfBlank(source),
      examples: _clean(examples),
      tags: _clean(tags),
    );
  }

  /// Client-generated UUID, also the primary key on the server.
  final String id;

  /// The English word or phrase itself.
  final String word;

  /// Translation or definition in the learner's own language.
  final String meaning;

  /// Optional IPA transcription, e.g. `/rɪˈzɪliənt/`.
  final String? pronunciation;

  final PartOfSpeech? partOfSpeech;

  /// Where the word was encountered — a podcast, a PR review, a colleague.
  final String? source;

  final List<String> examples;

  final List<String> tags;

  /// Day the word belongs to, formatted `YYYY-MM-DD`.
  ///
  /// Stored as text so it sorts and compares lexicographically in SQL.
  final String date;

  final DateTime createdAt;

  /// Last local modification, used for last-write-wins conflict resolution.
  final DateTime updatedAt;

  /// Tombstone flag. Deleted rows are retained until the server confirms the
  /// deletion, otherwise other devices would resurrect them on the next pull.
  final bool isDeleted;

  /// Whether this row has local changes the server has not acknowledged.
  final bool isDirty;

  final DateTime? syncedAt;

  bool get hasExamples => examples.isNotEmpty;

  bool get hasTags => tags.isNotEmpty;

  /// Normalised haystack persisted to `search_text` and matched by `LIKE`.
  String get searchText => TextNormalizer.haystack([
    word,
    meaning,
    pronunciation,
    source,
    ...examples,
    ...tags,
  ]);

  VocabularyWord copyWith({
    String? word,
    String? meaning,
    String? date,
    DateTime? updatedAt,
    Object? pronunciation = _unset,
    Object? partOfSpeech = _unset,
    Object? source = _unset,
    List<String>? examples,
    List<String>? tags,
    bool? isDeleted,
    bool? isDirty,
    Object? syncedAt = _unset,
  }) {
    return VocabularyWord(
      id: id,
      word: word ?? this.word,
      meaning: meaning ?? this.meaning,
      date: date ?? this.date,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      pronunciation: pronunciation == _unset
          ? this.pronunciation
          : pronunciation as String?,
      partOfSpeech: partOfSpeech == _unset
          ? this.partOfSpeech
          : partOfSpeech as PartOfSpeech?,
      source: source == _unset ? this.source : source as String?,
      examples: examples ?? this.examples,
      tags: tags ?? this.tags,
      isDeleted: isDeleted ?? this.isDeleted,
      isDirty: isDirty ?? this.isDirty,
      syncedAt: syncedAt == _unset ? this.syncedAt : syncedAt as DateTime?,
    );
  }

  /// Applies a user edit: normalises input and marks the row dirty so the sync
  /// layer picks it up.
  VocabularyWord edited({
    required String word,
    required String meaning,
    required DateTime now,
    String? pronunciation,
    PartOfSpeech? partOfSpeech,
    String? source,
    List<String> examples = const [],
    List<String> tags = const [],
  }) {
    return copyWith(
      word: word.trim(),
      meaning: meaning.trim(),
      pronunciation: _nullIfBlank(pronunciation),
      partOfSpeech: partOfSpeech,
      source: _nullIfBlank(source),
      examples: _clean(examples),
      tags: _clean(tags),
      updatedAt: now,
      isDirty: true,
    );
  }

  Map<String, Object?> toDbMap() => {
    'id': id,
    'word': word,
    'meaning': meaning,
    'pronunciation': pronunciation,
    'part_of_speech': partOfSpeech?.id,
    'source': source,
    'examples': jsonEncode(examples),
    'tags': jsonEncode(tags),
    'search_text': searchText,
    'date': date,
    'created_at': createdAt.toUtc().toIso8601String(),
    'updated_at': updatedAt.toUtc().toIso8601String(),
    'is_deleted': isDeleted ? 1 : 0,
    'is_dirty': isDirty ? 1 : 0,
    'synced_at': syncedAt?.toUtc().toIso8601String(),
  };

  factory VocabularyWord.fromDbMap(Map<String, Object?> map) {
    return VocabularyWord(
      id: map['id']! as String,
      word: map['word']! as String,
      meaning: map['meaning']! as String,
      pronunciation: map['pronunciation'] as String?,
      partOfSpeech: PartOfSpeech.fromId(map['part_of_speech'] as String?),
      source: map['source'] as String?,
      examples: _decodeList(map['examples'] as String?),
      tags: _decodeList(map['tags'] as String?),
      date: map['date']! as String,
      createdAt: DateTime.parse(map['created_at']! as String).toLocal(),
      updatedAt: DateTime.parse(map['updated_at']! as String).toLocal(),
      isDeleted: (map['is_deleted'] as int? ?? 0) == 1,
      isDirty: (map['is_dirty'] as int? ?? 0) == 1,
      syncedAt: map['synced_at'] == null
          ? null
          : DateTime.parse(map['synced_at']! as String).toLocal(),
    );
  }

  /// Wire format for the cloud API. Local-only bookkeeping is not sent.
  Map<String, Object?> toApiJson() => {
    'id': id,
    'word': word,
    'meaning': meaning,
    'pronunciation': pronunciation,
    'partOfSpeech': partOfSpeech?.id,
    'source': source,
    'examples': examples,
    'tags': tags,
    'date': date,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'deleted': isDeleted,
  };

  factory VocabularyWord.fromApiJson(Map<String, Object?> json) {
    return VocabularyWord(
      id: json['id']! as String,
      word: json['word']! as String,
      meaning: json['meaning']! as String,
      pronunciation: json['pronunciation'] as String?,
      partOfSpeech: PartOfSpeech.fromId(json['partOfSpeech'] as String?),
      source: json['source'] as String?,
      examples: _asStringList(json['examples']),
      tags: _asStringList(json['tags']),
      date: json['date']! as String,
      createdAt: DateTime.parse(json['createdAt']! as String).toLocal(),
      updatedAt: DateTime.parse(json['updatedAt']! as String).toLocal(),
      isDeleted: json['deleted'] as bool? ?? false,
      isDirty: false,
    );
  }

  /// Reads a row written by the pre-migration (v1) schema, used by the
  /// SharedPreferences import path.
  factory VocabularyWord.fromLegacyJson(Map<String, Object?> json) {
    final createdAt =
        DateTime.tryParse(json['createdAt'] as String? ?? '')?.toLocal() ??
        DateTime.fromMillisecondsSinceEpoch(0);
    return VocabularyWord(
      id: json['id']! as String,
      word: json['word']! as String,
      meaning: json['vietnameseMeaning'] as String? ?? '',
      examples: _asStringList(json['examples']),
      date: json['date']! as String,
      createdAt: createdAt,
      updatedAt: createdAt,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is VocabularyWord &&
      other.id == id &&
      other.updatedAt == updatedAt &&
      other.isDirty == isDirty &&
      other.isDeleted == isDeleted;

  @override
  int get hashCode => Object.hash(id, updatedAt, isDirty, isDeleted);

  @override
  String toString() => 'VocabularyWord($id, $word, $date)';

  static const Object _unset = Object();

  static String? _nullIfBlank(String? value) {
    final trimmed = value?.trim();
    return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
  }

  static List<String> _clean(List<String> values) => values
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList(growable: false);

  static List<String> _decodeList(String? encoded) {
    if (encoded == null || encoded.isEmpty) return const [];
    final decoded = jsonDecode(encoded);
    return decoded is List
        ? decoded.map((e) => e.toString()).toList(growable: false)
        : const [];
  }

  static List<String> _asStringList(Object? value) => value is List
      ? value.map((e) => e.toString()).toList(growable: false)
      : const [];
}
