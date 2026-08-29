import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/vocabulary_provider.dart';
import '../../services/tts_service.dart';
import '../contracts/arcade_game_context.dart';
import '../contracts/arcade_vocab_word.dart';

/// Standard provider-backed implementation of [ArcadeGameContext].
class DefaultArcadeContext implements ArcadeGameContext {
  DefaultArcadeContext(this.buildContext);

  @override
  final BuildContext buildContext;

  @override
  List<ArcadeVocabWord> getVocabularyDeck({int count = 20}) {
    final vocab = buildContext.read<VocabularyProvider>();
    final rawWords = vocab.words.isNotEmpty ? vocab.words : [];

    if (rawWords.isEmpty) {
      // Fallback sample deck if user has no words captured yet
      return const [
        ArcadeVocabWord(
          id: 'sample_resilient',
          word: 'resilient',
          meaning: 'kiên cường, dẻo dai',
          ipa: '/rɪˈzɪliənt/',
          partOfSpeech: 'adj.',
          example: 'a resilient distributed system',
        ),
        ArcadeVocabWord(
          id: 'sample_eloquent',
          word: 'eloquent',
          meaning: 'hùng hồn, lưu loát',
          ipa: '/ˈeləkwənt/',
          partOfSpeech: 'adj.',
          example: 'an eloquent speaker',
        ),
        ArcadeVocabWord(
          id: 'sample_serendipity',
          word: 'serendipity',
          meaning: 'sự tình cờ may mắn',
          ipa: '/ˌserənˈdɪpəti/',
          partOfSpeech: 'n.',
          example: 'a stroke of serendipity',
        ),
        ArcadeVocabWord(
          id: 'sample_tenacious',
          word: 'tenacious',
          meaning: 'kiên trì, bền bỉ',
          ipa: '/təˈneɪʃəs/',
          partOfSpeech: 'adj.',
          example: 'a tenacious researcher',
        ),
      ];
    }

    return rawWords
        .take(count)
        .map(
          (w) => ArcadeVocabWord(
            id: w.id,
            word: w.word,
            meaning: w.meaning,
            ipa: w.pronunciation ?? '',
            partOfSpeech: w.partOfSpeech?.short ?? '',
            example: w.examples.isNotEmpty ? w.examples.first : '',
          ),
        )
        .toList();
  }

  @override
  Future<void> pronounce(String word) async {
    try {
      final tts = buildContext.read<TtsService>();
      await tts.speak(word);
    } catch (e) {
      debugPrint('Arcade TTS speech error: $e');
    }
  }

  @override
  void playSfx(ArcadeSfx sfx) {
    // SFX triggers can be mapped to haptic feedback / audio synth
  }

  @override
  void recordHit({required String wordId, int scorePoints = 100}) {
    // Word hit recorded for current session
    debugPrint('Arcade word hit recorded: $wordId, points: $scorePoints');
  }

  @override
  void finishGame({required int finalScore, required int wordsReviewed}) {
    debugPrint('Game finished with score $finalScore, words: $wordsReviewed');
  }
}
