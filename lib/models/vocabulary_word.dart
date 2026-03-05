import 'dart:convert';

class VocabularyWord {
  final String id;
  final String word;
  final String vietnameseMeaning;
  final List<String> examples;
  final String date; // YYYY-MM-DD
  final DateTime createdAt;

  VocabularyWord({
    required this.id,
    required this.word,
    required this.vietnameseMeaning,
    this.examples = const [],
    required this.date,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  VocabularyWord copyWith({
    String? id,
    String? word,
    String? vietnameseMeaning,
    List<String>? examples,
    String? date,
    DateTime? createdAt,
  }) {
    return VocabularyWord(
      id: id ?? this.id,
      word: word ?? this.word,
      vietnameseMeaning: vietnameseMeaning ?? this.vietnameseMeaning,
      examples: examples ?? this.examples,
      date: date ?? this.date,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'word': word,
    'vietnameseMeaning': vietnameseMeaning,
    'examples': examples,
    'date': date,
    'createdAt': createdAt.toIso8601String(),
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
    );
  }

  static String encode(List<VocabularyWord> words) =>
      json.encode(words.map((w) => w.toJson()).toList());

  static List<VocabularyWord> decode(String encoded) =>
      (json.decode(encoded) as List<dynamic>)
          .map((item) => VocabularyWord.fromJson(item as Map<String, dynamic>))
          .toList();
}
