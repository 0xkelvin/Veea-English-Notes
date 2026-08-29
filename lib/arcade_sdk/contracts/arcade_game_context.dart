import 'package:flutter/material.dart';

import 'arcade_vocab_word.dart';

/// 8-Bit Retro Sound FX enum for Arcade Games.
enum ArcadeSfx {
  hit,
  explode,
  coin,
  levelUp,
  dead,
  jump,
  score,
}

/// Execution and environment context supplied to an Arcade Game.
///
/// Gives developers clean access to vocabulary, audio pronunciation,
/// sound effects, high-score tracking, and Spaced Repetition (SRS) hooks.
abstract class ArcadeGameContext {
  /// Context for navigating and querying theme palette.
  BuildContext get buildContext;

  /// Retrieves an active deck of vocabulary words with IPA, part of speech,
  /// and Vietnamese meanings for gameplay.
  List<ArcadeVocabWord> getVocabularyDeck({int count = 20});

  /// Pronounces the English word via native Text-to-Speech audio.
  Future<void> pronounce(String word);

  /// Triggers an 8-bit retro sound effect or haptic pulse.
  void playSfx(ArcadeSfx sfx);

  /// Records a successful word hit for player score and spaced review progress.
  void recordHit({required String wordId, int scorePoints = 100});

  /// Saves the final game score and records review statistics.
  void finishGame({required int finalScore, required int wordsReviewed});
}
