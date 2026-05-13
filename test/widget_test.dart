import 'package:flutter_test/flutter_test.dart';
import 'package:veea_english_app/models/vocabulary_word.dart';
import 'package:veea_english_app/providers/vocabulary_provider.dart';
import 'package:veea_english_app/services/ai_enrichment_service.dart';
import 'package:veea_english_app/services/storage_service.dart';

void main() {
  test('addWord saves context and applies AI enrichment', () async {
    final storage = _FakeStorageService();
    final provider = VocabularyProvider(
      storage,
      aiEnrichmentService: _FakeAiEnrichmentService(),
    );

    await provider.init();
    await provider.addWord(
      word: 'diligent',
      vietnameseMeaning: 'chăm chỉ',
      contextSentence: 'She is diligent in her daily study routine.',
    );

    expect(provider.totalWords, 1);
    final saved = provider.allWords.first;
    expect(saved.contextSentence, contains('daily study'));
    expect(saved.synonyms, isNotEmpty);
    expect(saved.antonyms, isNotEmpty);
    expect(saved.idioms, isNotEmpty);
    expect(saved.phrases, isNotEmpty);
    expect(saved.imageUrl, isNotEmpty);
  });

  test('daily review advances mastery and updates due queue', () async {
    final storage = _FakeStorageService();
    final provider = VocabularyProvider(
      storage,
      aiEnrichmentService: _FakeAiEnrichmentService(),
    );

    await provider.init();
    await provider.addWord(
      word: 'adapt',
      vietnameseMeaning: 'thích nghi',
      contextSentence: 'I can adapt quickly in new environments.',
    );

    final wordId = provider.allWords.first.id;
    expect(provider.dueWords.length, 1);

    await provider.markWordReviewed(wordId);
    final reviewed = provider.allWords.first;
    expect(reviewed.masteryLevel, MasteryLevel.learning);
    expect(reviewed.reviewCount, 1);
    expect(provider.dueWords, isEmpty);
  });
}

class _FakeStorageService extends StorageService {
  final List<VocabularyWord> _words = [];

  @override
  Future<void> migrateFromSharedPreferences() async {}

  @override
  Future<List<VocabularyWord>> loadWords() async => List.unmodifiable(_words);

  @override
  Future<void> insertWord(VocabularyWord word) async {
    _words.add(word);
  }

  @override
  Future<void> updateWord(VocabularyWord word) async {
    final index = _words.indexWhere((item) => item.id == word.id);
    if (index != -1) {
      _words[index] = word;
    }
  }

  @override
  Future<void> deleteWord(String id) async {
    _words.removeWhere((word) => word.id == id);
  }
}

class _FakeAiEnrichmentService extends AiEnrichmentService {
  @override
  Future<WordAiEnrichment> enrichWord({
    required String word,
    required String contextSentence,
  }) async {
    return WordAiEnrichment(
      synonyms: ['$word-synonym-1', '$word-synonym-2'],
      antonyms: ['$word-opposite'],
      idioms: ['hit the books'],
      phrases: ['practice $word daily'],
      imageUrl: 'https://example.com/$word.png',
    );
  }
}
