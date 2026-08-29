import '../../screens/games/breakout_vocab_game.dart';
import '../../screens/games/pixel_duel_game.dart';
import '../../screens/games/vocab_angler_game.dart';
import '../../screens/games/vocab_chomp_game.dart';
import '../../screens/games/vocab_frogger_game.dart';
import '../../screens/games/vocab_invaders_game.dart';
import '../../screens/games/vocab_snake_game.dart';
import '../../screens/games/word_rush_game.dart';
import '../../screens/games/word_stacker_game.dart';
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

      // 4. Breakout Vocab
      ArcadeGameManifest(
        id: 'breakout_vocab',
        title: 'BREAKOUT VOCAB',
        tagline: 'Bounce the retro ball to smash bricks with matching meanings.',
        author: '@veea_team',
        version: '1.0.0',
        glyph: PixelGlyph.brick,
        category: ArcadeGameCategory.retroArcade,
        badge: 'PADDLE BOUNCE',
        builder: (ctx) => const BreakoutVocabGame(),
      ),

      // 5. Vocab Chomp
      ArcadeGameManifest(
        id: 'vocab_chomp',
        title: 'VOCAB CHOMP',
        tagline: 'Navigate the maze, dodge phantoms, and chomp correct terms.',
        author: '@veea_team',
        version: '1.0.0',
        glyph: PixelGlyph.pacman,
        category: ArcadeGameCategory.retroArcade,
        badge: 'MAZE RUNNER',
        builder: (ctx) => const VocabChompGame(),
      ),

      // 6. Word Stacker
      ArcadeGameManifest(
        id: 'word_stacker',
        title: 'WORD STACKER',
        tagline: 'Stack falling blocks neatly by identifying vocabulary terms.',
        author: '@veea_team',
        version: '1.0.0',
        glyph: PixelGlyph.tetris,
        category: ArcadeGameCategory.puzzle,
        badge: 'BLOCK PUZZLE',
        builder: (ctx) => const WordStackerGame(),
      ),

      // 7. Vocab Angler
      ArcadeGameManifest(
        id: 'vocab_angler',
        title: 'VOCAB ANGLER',
        tagline: 'Cast your hook deep underwater and catch the target definition.',
        author: '@veea_team',
        version: '1.0.0',
        glyph: PixelGlyph.fish,
        category: ArcadeGameCategory.retroArcade,
        badge: 'DEEP SEA FISHING',
        builder: (ctx) => const VocabAnglerGame(),
      ),

      // 8. Vocab Frogger
      ArcadeGameManifest(
        id: 'vocab_frogger',
        title: 'VOCAB FROGGER',
        tagline: 'Hop across busy retro traffic to reach the matching lily pad.',
        author: '@veea_team',
        version: '1.0.0',
        glyph: PixelGlyph.frog,
        category: ArcadeGameCategory.retroArcade,
        badge: 'CROSS THE ROAD',
        builder: (ctx) => const VocabFroggerGame(),
      ),

      // 9. Pixel Duel
      ArcadeGameManifest(
        id: 'pixel_duel',
        title: 'PIXEL DUEL 1V1',
        tagline: 'Turn-based RPG battle: attack bosses by solving vocabulary.',
        author: '@veea_team',
        version: '1.0.0',
        glyph: PixelGlyph.gamepad,
        category: ArcadeGameCategory.strategy,
        badge: 'TURN-BASED RPG',
        builder: (ctx) => const PixelDuelGame(),
      ),

      // 10. Community Starter Game (SDK Demonstration)
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
