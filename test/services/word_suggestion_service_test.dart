import 'package:flutter_test/flutter_test.dart';
import 'package:veea_english_app/models/part_of_speech.dart';
import 'package:veea_english_app/models/vocabulary_word.dart';
import 'package:veea_english_app/services/word_suggestion_service.dart';

void main() {
  group('WordSuggestionService', () {
    test('suggests Vietnamese meaning and PartOfSpeech for solution', () async {
      final suggestion = await WordSuggestionService.suggest('solution');
      expect(suggestion, isNotNull);
      expect(suggestion!.meaning, contains('giải pháp'));
      expect(suggestion.partOfSpeech, PartOfSpeech.noun);
    });

    test('suggests Vietnamese meaning and PartOfSpeech for common dictionary words', () async {
      final suggestion = await WordSuggestionService.suggest('resilient');
      expect(suggestion, isNotNull);
      expect(suggestion!.meaning, contains('kiên cường'));
      expect(suggestion.partOfSpeech, PartOfSpeech.adjective);
    });

    test('suggests fast synchronously from local dictionary', () {
      final suggestion = WordSuggestionService.suggestFast('solution');
      expect(suggestion, isNotNull);
      expect(suggestion!.meaning, contains('giải pháp'));
      expect(suggestion.partOfSpeech, PartOfSpeech.noun);
    });

    test('suggests from career cartridges', () async {
      final suggestion = await WordSuggestionService.suggest('idempotent');
      expect(suggestion, isNotNull);
      expect(suggestion!.meaning, contains('Bảo toàn kết quả'));
      expect(suggestion.partOfSpeech, PartOfSpeech.adjective);
      expect(suggestion.source, 'Tech Cartridge');
    });

    test('prefers user previous notes if provided', () async {
      final userWords = [
        VocabularyWord.create(
          id: '1',
          word: 'customword',
          meaning: 'nghĩa đặc biệt của tôi',
          date: '2026-09-03',
          partOfSpeech: PartOfSpeech.noun,
          now: DateTime.now(),
        ),
      ];

      final suggestion = await WordSuggestionService.suggest('customword', userWords: userWords);
      expect(suggestion, isNotNull);
      expect(suggestion!.meaning, 'nghĩa đặc biệt của tôi');
      expect(suggestion.partOfSpeech, PartOfSpeech.noun);
      expect(suggestion.source, 'Previous note');
    });

    test('detects grammatical PartOfSpeech for unknown words using suffix heuristics', () {
      expect(WordSuggestionService.detectPartOfSpeech('modernization'), PartOfSpeech.noun);
      expect(WordSuggestionService.detectPartOfSpeech('thoughtfully'), PartOfSpeech.adverb);
      expect(WordSuggestionService.detectPartOfSpeech('orchestrate'), PartOfSpeech.verb);
      expect(WordSuggestionService.detectPartOfSpeech('effortless'), PartOfSpeech.adjective);
      expect(WordSuggestionService.detectPartOfSpeech('in a heartbeat'), PartOfSpeech.phrase);
    });

    test('returns null for blank or 1-letter inputs', () async {
      expect(await WordSuggestionService.suggest(''), isNull);
      expect(await WordSuggestionService.suggest('a'), isNull);
      expect(WordSuggestionService.suggestFast(''), isNull);
    });
  });
}
