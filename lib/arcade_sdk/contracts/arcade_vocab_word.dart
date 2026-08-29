/// Standardized vocabulary word representation for Arcade Games.
class ArcadeVocabWord {
  const ArcadeVocabWord({
    required this.id,
    required this.word,
    required this.meaning,
    this.ipa = '',
    this.partOfSpeech = '',
    this.example = '',
  });

  final String id;
  final String word;
  final String meaning;
  final String ipa;
  final String partOfSpeech;
  final String example;
}
