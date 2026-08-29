import 'package:flutter/material.dart';

import '../../widgets/pixel/pixel_icon.dart';
import 'arcade_game_context.dart';

/// Categories of mini-games available in the Arcade Center.
enum ArcadeGameCategory {
  retroArcade,
  speedQuiz,
  puzzle,
  rhythm,
  strategy,
  community,
}

/// Manifest defining an Arcade Game's identity, metadata, and screen builder.
///
/// Open-source contributors implement this manifest to register new games
/// into the Veea English Arcade Center.
class ArcadeGameManifest {
  const ArcadeGameManifest({
    required this.id,
    required this.title,
    required this.tagline,
    required this.author,
    required this.version,
    required this.glyph,
    required this.category,
    required this.badge,
    required this.builder,
    this.authorUrl,
    this.difficulty = 'NORMAL',
    this.minWordsRequired = 4,
  });

  /// Unique identifier (e.g. 'vocab_invaders', 'vocab_snake').
  final String id;

  /// Display title in 8-bit uppercase (e.g. 'VOCAB INVADERS').
  final String title;

  /// Short 1-line subtitle explaining gameplay.
  final String tagline;

  /// Author username or GitHub handle (e.g. '@veea_team', '@community_dev').
  final String author;

  /// Semantic version (e.g. '1.0.0').
  final String version;

  /// 7x7 pixel glyph for icon rendering.
  final PixelGlyph glyph;

  /// Game category for filtering and badges.
  final ArcadeGameCategory category;

  /// Badge text displayed on card (e.g. 'SPACE SHOOTER', 'NEW', 'COMMUNITY').
  final String badge;

  /// Factory builder producing the game screen widget.
  final Widget Function(ArcadeGameContext context) builder;

  /// Optional website or GitHub profile link for the author.
  final String? authorUrl;

  /// Difficulty rating (e.g. 'EASY', 'NORMAL', 'HARD').
  final String difficulty;

  /// Minimum vocabulary words needed in user notebook before game can be played.
  final int minWordsRequired;
}
