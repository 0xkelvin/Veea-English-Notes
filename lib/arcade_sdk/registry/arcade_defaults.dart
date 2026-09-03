import '../../screens/games/pixel_typer_game.dart';
import '../../screens/games/vocab_invaders_game.dart';
import '../../screens/games/vocab_snake_game.dart';
import '../../screens/games/word_rush_game.dart';
import '../../widgets/pixel/pixel_icon.dart';
import '../contracts/arcade_game_manifest.dart';
import '../templates/starter_template_game.dart';
import 'arcade_registry.dart';

/// Pre-registers all standard official and community mini-games into the registry.
class ArcadeDefaults {
  static void registerDefaults() {
    if (ArcadeRegistry.isInitialized) return;

    ArcadeRegistry.registerAll([
      // 1. Word Rush 60s
      ArcadeGameManifest(
        id: 'word_rush',
        title: 'WORD RUSH 60S',
        tagline: 'High-speed multiple-choice blitz before time expires.',
        author: '@veea_team',
        version: '1.0.0',
        glyph: PixelGlyph.fire,
        category: ArcadeGameCategory.speedQuiz,
        badge: 'FAST PACED',
        builder: (ctx) => const WordRushGame(),
      ),

      // 2. Vocab Snake
      ArcadeGameManifest(
        id: 'vocab_snake',
        title: 'VOCAB SNAKE',
        tagline: 'Slither through the grid and devour pellets of matching words.',
        author: '@veea_team',
        version: '1.0.0',
        glyph: PixelGlyph.target,
        category: ArcadeGameCategory.retroArcade,
        badge: 'CLASSIC NOSTALGIA',
        builder: (ctx) => const VocabSnakeGame(),
      ),

      // 3. Vocab Invaders
      ArcadeGameManifest(
        id: 'vocab_invaders',
        title: 'VOCAB INVADERS',
        tagline: 'Shoot the descending alien carrying the correct definition.',
        author: '@veea_team',
        version: '1.0.0',
        glyph: PixelGlyph.alien,
        category: ArcadeGameCategory.retroArcade,
        badge: 'SPACE SHOOTER',
        builder: (ctx) => const VocabInvadersGame(),
      ),

      // 4. Pixel Typer
      ArcadeGameManifest(
        id: 'pixel_typer',
        title: 'PIXEL TYPER',
        tagline: 'Type the English word from memory before it breaches.',
        author: '@veea_team',
        version: '1.0.0',
        glyph: PixelGlyph.skull,
        category: ArcadeGameCategory.typing,
        badge: 'TYPE TO RECALL',
        difficulty: 'HARD',
        minWordsRequired: 3,
        builder: (ctx) => const PixelTyperGame(),
      ),

      // 11. Community Starter Game (SDK Demonstration)
      ArcadeGameManifest(
        id: 'starter_template',
        title: 'COMMUNITY MATCH',
        tagline: 'SDK starter template: tap the right definition and earn streak XP.',
        author: '@community_dev',
        version: '1.0.0',
        glyph: PixelGlyph.cards,
        category: ArcadeGameCategory.community,
        badge: 'COMMUNITY SDK',
        builder: (ctx) => StarterTemplateGame(gameContext: ctx),
      ),
    ]);

    ArcadeRegistry.markInitialized();
  }
}
