import 'dart:convert';

enum MasteryLevel { newWord, learning, familiar, mastered }

extension MasteryLevelX on MasteryLevel {
  String get value => switch (this) {
    MasteryLevel.newWord => 'new',
    MasteryLevel.learning => 'learning',
    MasteryLevel.familiar => 'familiar',
    MasteryLevel.mastered => 'mastered',
  };

  String get label => switch (this) {
    MasteryLevel.newWord => 'New',
    MasteryLevel.learning => 'Learning',
    MasteryLevel.familiar => 'Familiar',
    MasteryLevel.mastered => 'Mastered',
  };

  MasteryLevel get next => switch (this) {
    MasteryLevel.newWord => MasteryLevel.learning,
    MasteryLevel.learning => MasteryLevel.familiar,
    MasteryLevel.familiar => MasteryLevel.mastered,
    MasteryLevel.mastered => MasteryLevel.mastered,
  };

  static MasteryLevel fromValue(String? value) {
    return switch (value) {
      'learning' => MasteryLevel.learning,
      'familiar' => MasteryLevel.familiar,
      'mastered' => MasteryLevel.mastered,
      _ => MasteryLevel.newWord,
    };
  }
}

class VocabularyWord {
  final String id;
  final String word;
  final String vietnameseMeaning;
  final String contextSentence;
  final List<String> examples;
  final List<String> synonyms;
  final List<String> antonyms;
  final List<String> idioms;
  final List<String> phrases;
  final String? imageUrl;
  final MasteryLevel masteryLevel;
  final DateTime? lastReviewedAt;
  final DateTime nextReviewAt;
  final int reviewCount;
  final String date; // YYYY-MM-DD
  final DateTime createdAt;

  VocabularyWord({
    required this.id,
    required this.word,
    required this.vietnameseMeaning,
    required this.contextSentence,
    this.examples = const [],
    this.synonyms = const [],
    this.antonyms = const [],
    this.idioms = const [],
    this.phrases = const [],
    this.imageUrl,
    this.masteryLevel = MasteryLevel.newWord,
    this.lastReviewedAt,
    DateTime? nextReviewAt,
    this.reviewCount = 0,
    required this.date,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now(),
       nextReviewAt = nextReviewAt ?? DateTime.now();

  VocabularyWord copyWith({
    String? id,
    String? word,
    String? vietnameseMeaning,
    String? contextSentence,
    List<String>? examples,
    List<String>? synonyms,
    List<String>? antonyms,
    List<String>? idioms,
    List<String>? phrases,
    String? imageUrl,
    MasteryLevel? masteryLevel,
    DateTime? lastReviewedAt,
    DateTime? nextReviewAt,
    int? reviewCount,
    String? date,
    DateTime? createdAt,
  }) {
    return VocabularyWord(
      id: id ?? this.id,
      word: word ?? this.word,
      vietnameseMeaning: vietnameseMeaning ?? this.vietnameseMeaning,
      contextSentence: contextSentence ?? this.contextSentence,
      examples: examples ?? this.examples,
      synonyms: synonyms ?? this.synonyms,
      antonyms: antonyms ?? this.antonyms,
      idioms: idioms ?? this.idioms,
      phrases: phrases ?? this.phrases,
      imageUrl: imageUrl ?? this.imageUrl,
      masteryLevel: masteryLevel ?? this.masteryLevel,
      lastReviewedAt: lastReviewedAt ?? this.lastReviewedAt,
      nextReviewAt: nextReviewAt ?? this.nextReviewAt,
      reviewCount: reviewCount ?? this.reviewCount,
      date: date ?? this.date,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'word': word,
    'vietnameseMeaning': vietnameseMeaning,
    'contextSentence': contextSentence,
    'examples': examples,
    'synonyms': synonyms,
    'antonyms': antonyms,
    'idioms': idioms,
    'phrases': phrases,
    'imageUrl': imageUrl,
    'masteryLevel': masteryLevel.value,
    'lastReviewedAt': lastReviewedAt?.toIso8601String(),
    'nextReviewAt': nextReviewAt.toIso8601String(),
    'reviewCount': reviewCount,
    'date': date,
    'createdAt': createdAt.toIso8601String(),
  };

  factory VocabularyWord.fromJson(Map<String, dynamic> json) {
    return VocabularyWord(
      id: json['id'] as String,
      word: json['word'] as String,
      vietnameseMeaning: json['vietnameseMeaning'] as String,
      contextSentence: json['contextSentence'] as String? ?? '',
      examples: (json['examples'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          [],
      synonyms: (json['synonyms'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          [],
      antonyms: (json['antonyms'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          [],
      idioms: (json['idioms'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          [],
      phrases: (json['phrases'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          [],
      imageUrl: json['imageUrl'] as String?,
      masteryLevel: MasteryLevelX.fromValue(json['masteryLevel'] as String?),
      lastReviewedAt: json['lastReviewedAt'] != null
          ? DateTime.parse(json['lastReviewedAt'] as String)
          : null,
      nextReviewAt: json['nextReviewAt'] != null
          ? DateTime.parse(json['nextReviewAt'] as String)
          : DateTime.now(),
      reviewCount: json['reviewCount'] as int? ?? 0,
      date: json['date'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
    );
  }

  Map<String, dynamic> toDbMap() => {
    'id': id,
    'word': word,
    'vietnamese_meaning': vietnameseMeaning,
    'context_sentence': contextSentence,
    'examples': json.encode(examples),
    'synonyms': json.encode(synonyms),
    'antonyms': json.encode(antonyms),
    'idioms': json.encode(idioms),
    'phrases': json.encode(phrases),
    'image_url': imageUrl,
    'mastery_level': masteryLevel.value,
    'last_reviewed_at': lastReviewedAt?.toIso8601String(),
    'next_review_at': nextReviewAt.toIso8601String(),
    'review_count': reviewCount,
    'date': date,
    'created_at': createdAt.toIso8601String(),
  };

  factory VocabularyWord.fromDbMap(Map<String, dynamic> map) {
    return VocabularyWord(
      id: map['id'] as String,
      word: map['word'] as String,
      vietnameseMeaning: map['vietnamese_meaning'] as String,
      contextSentence: map['context_sentence'] as String? ?? '',
      examples: (json.decode(map['examples'] as String? ?? '[]') as List<dynamic>)
          .map((e) => e as String)
          .toList(),
      synonyms: (json.decode(map['synonyms'] as String? ?? '[]') as List<dynamic>)
          .map((e) => e as String)
          .toList(),
      antonyms: (json.decode(map['antonyms'] as String? ?? '[]') as List<dynamic>)
          .map((e) => e as String)
          .toList(),
      idioms: (json.decode(map['idioms'] as String? ?? '[]') as List<dynamic>)
          .map((e) => e as String)
          .toList(),
      phrases: (json.decode(map['phrases'] as String? ?? '[]') as List<dynamic>)
          .map((e) => e as String)
          .toList(),
      imageUrl: map['image_url'] as String?,
      masteryLevel: MasteryLevelX.fromValue(map['mastery_level'] as String?),
      lastReviewedAt: map['last_reviewed_at'] != null
          ? DateTime.parse(map['last_reviewed_at'] as String)
          : null,
      nextReviewAt: map['next_review_at'] != null
          ? DateTime.parse(map['next_review_at'] as String)
          : DateTime.now(),
      reviewCount: map['review_count'] as int? ?? 0,
      date: map['date'] as String,
      createdAt: DateTime.parse(map['created_at'] as String),
    );
  }

  static String encode(List<VocabularyWord> words) =>
      json.encode(words.map((w) => w.toJson()).toList());

  static List<VocabularyWord> decode(String encoded) =>
      (json.decode(encoded) as List<dynamic>)
          .map((item) => VocabularyWord.fromJson(item as Map<String, dynamic>))
          .toList();
}
