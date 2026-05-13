import 'dart:math';

class WordAiEnrichment {
  final List<String> synonyms;
  final List<String> antonyms;
  final List<String> idioms;
  final List<String> phrases;
  final String imageUrl;

  const WordAiEnrichment({
    required this.synonyms,
    required this.antonyms,
    required this.idioms,
    required this.phrases,
    required this.imageUrl,
  });
}

/// Lightweight local placeholder for enrichment until remote AI API is wired in.
class AiEnrichmentService {
  Future<WordAiEnrichment> enrichWord({
    required String word,
    required String contextSentence,
  }) async {
    final normalizedWord = word.trim().toLowerCase();
    if (normalizedWord.isEmpty) {
      return const WordAiEnrichment(
        synonyms: [],
        antonyms: [],
        idioms: [],
        phrases: [],
        imageUrl: '',
      );
    }
    final context = contextSentence.trim();
    final cleanWord = normalizedWord;
    final root = cleanWord.length > 3 ? cleanWord.substring(0, cleanWord.length - 1) : cleanWord;
    final imagePrompt = Uri.encodeComponent('$cleanWord, $context, cinematic lighting');
    final imageUri = Uri.parse('https://image.pollinations.ai/prompt/$imagePrompt');
    final random = Random(
      cleanWord.codeUnits.fold<int>(0, (a, b) => (a + b) & 0x7fffffff),
    );

    final synonymSeeds = <String>[
      'useful',
      'helpful',
      '$cleanWord-related',
      '$root style',
    ]..shuffle(random);
    final antonymSeeds = <String>[
      'opposite of $cleanWord',
      'irrelevant',
      'unhelpful',
      'contrary',
    ]..shuffle(random);
    final idiomSeeds = <String>[
      'learn the ropes',
      'hit the books',
      'on the same page',
      'practice makes perfect',
    ]..shuffle(random);
    final phraseSeeds = <String>[
      '$cleanWord in context',
      'build confidence with $cleanWord',
      'daily $cleanWord practice',
      '$cleanWord for real-life situations',
    ]..shuffle(random);

    return WordAiEnrichment(
      synonyms: synonymSeeds.take(3).toList(),
      antonyms: antonymSeeds.take(3).toList(),
      idioms: idiomSeeds.take(2).toList(),
      phrases: phraseSeeds.take(3).toList(),
      imageUrl: imageUri.toString(),
    );
  }
}
