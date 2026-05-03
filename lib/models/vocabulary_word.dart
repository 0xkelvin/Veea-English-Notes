import 'dart:convert';

class VocabularyWord {
  final String id;
  final String word;
  final String vietnameseMeaning;
  final String? phonetic;
  final List<String> examples;
  final String date; // YYYY-MM-DD
  final DateTime createdAt;

  // Spaced Repetition (SM-2)
  final int reviewCount;
  final double easeFactor;
  final int intervalDays;
  final String? nextReviewDate; // YYYY-MM-DD, null = never reviewed

  VocabularyWord({
    required this.id,
    required this.word,
    required this.vietnameseMeaning,
    this.phonetic,
    this.examples = const [],
    required this.date,
    DateTime? createdAt,
    this.reviewCount = 0,
    this.easeFactor = 2.5,
    this.intervalDays = 0,
    this.nextReviewDate,
  }) : createdAt = createdAt ?? DateTime.now();

  VocabularyWord copyWith({
    String? id,
    String? word,
    String? vietnameseMeaning,
    String? phonetic,
    List<String>? examples,
    String? date,
    DateTime? createdAt,
    int? reviewCount,
    double? easeFactor,
    int? intervalDays,
    String? nextReviewDate,
  }) {
    return VocabularyWord(
      id: id ?? this.id,
      word: word ?? this.word,
      vietnameseMeaning: vietnameseMeaning ?? this.vietnameseMeaning,
      phonetic: phonetic ?? this.phonetic,
      examples: examples ?? this.examples,
      date: date ?? this.date,
      createdAt: createdAt ?? this.createdAt,
      reviewCount: reviewCount ?? this.reviewCount,
      easeFactor: easeFactor ?? this.easeFactor,
      intervalDays: intervalDays ?? this.intervalDays,
      nextReviewDate: nextReviewDate ?? this.nextReviewDate,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'word': word,
    'vietnameseMeaning': vietnameseMeaning,
    'examples': examples,
    'date': date,
    'createdAt': createdAt.toIso8601String(),
    'reviewCount': reviewCount,
    'easeFactor': easeFactor,
    'intervalDays': intervalDays,
    'nextReviewDate': nextReviewDate,
  };

  factory VocabularyWord.fromJson(Map<String, dynamic> json) {
    return VocabularyWord(
      id: json['id'] as String,
      word: json['word'] as String,
      vietnameseMeaning: json['vietnameseMeaning'] as String,
      examples: (json['examples'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          [],
      date: json['date'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      reviewCount: json['reviewCount'] as int? ?? 0,
      easeFactor: (json['easeFactor'] as num?)?.toDouble() ?? 2.5,
      intervalDays: json['intervalDays'] as int? ?? 0,
      nextReviewDate: json['nextReviewDate'] as String?,
    );
  }

  Map<String, dynamic> toDbMap() => {
    'id': id,
    'word': word,
    'vietnamese_meaning': vietnameseMeaning,
    'examples': json.encode(examples),
    'date': date,
    'created_at': createdAt.toIso8601String(),
    'review_count': reviewCount,
    'ease_factor': easeFactor,
    'interval_days': intervalDays,
    'next_review_date': nextReviewDate,
  };

  factory VocabularyWord.fromDbMap(Map<String, dynamic> map) {
    return VocabularyWord(
      id: map['id'] as String,
      word: map['word'] as String,
      vietnameseMeaning: map['vietnamese_meaning'] as String,
      examples: (json.decode(map['examples'] as String? ?? '[]') as List<dynamic>)
          .map((e) => e as String)
          .toList(),
      date: map['date'] as String,
      createdAt: DateTime.parse(map['created_at'] as String),
      reviewCount: map['review_count'] as int? ?? 0,
      easeFactor: (map['ease_factor'] as num?)?.toDouble() ?? 2.5,
      intervalDays: map['interval_days'] as int? ?? 0,
      nextReviewDate: map['next_review_date'] as String?,
    );
  }

  static String encode(List<VocabularyWord> words) =>
      json.encode(words.map((w) => w.toJson()).toList());

  static List<VocabularyWord> decode(String encoded) =>
      (json.decode(encoded) as List<dynamic>)
          .map((item) => VocabularyWord.fromJson(item as Map<String, dynamic>))
          .toList();
}
