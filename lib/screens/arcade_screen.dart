import 'package:flutter/material.dart';

import '../core/theme/pixel_metrics.dart';
import '../core/theme/pixel_palette.dart';
import '../widgets/pixel/pixel_box.dart';
import '../widgets/pixel/pixel_button.dart';
import '../widgets/pixel/pixel_icon.dart';
import 'games/breakout_vocab_game.dart';
import 'games/pixel_duel_game.dart';
import 'games/vocab_angler_game.dart';
import 'games/vocab_chomp_game.dart';
import 'games/vocab_frogger_game.dart';
import 'games/vocab_invaders_game.dart';
import 'games/vocab_snake_game.dart';
import 'games/word_rush_game.dart';
import 'games/word_stacker_game.dart';

/// 8-Bit Retro Arcade Center for Vocabulary Practice & Mini-Games.
class ArcadeScreen extends StatelessWidget {
  const ArcadeScreen({super.key});

  void _launch(BuildContext context, Widget screen) {
    Navigator.of(context).push(
      PageRouteBuilder<void>(
        pageBuilder: (_, _, _) => screen,
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: palette.paper,
      body: SafeArea(
        child: Column(
          children: [
            // Top Bar
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: PixelMetrics.space4,
                vertical: PixelMetrics.space2,
              ),
              decoration: BoxDecoration(
                color: palette.surface,
                border: Border(
                  bottom: BorderSide(
                    color: palette.border,
                    width: PixelMetrics.border,
                  ),
                ),
              ),
              child: Row(
                children: [
                  PixelIconButton(
                    glyph: PixelGlyph.arrowLeft,
                    semanticLabel: 'Back to journal',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  const SizedBox(width: PixelMetrics.space2),
                  Text(
                    'ARCADE CENTER',
                    style: theme.textTheme.titleMedium,
                  ),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: palette.accent,
                      border: Border.all(
                        color: palette.border,
                        width: PixelMetrics.border,
                      ),
                    ),
                    child: Text(
                      '9 GAMES',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: palette.onAccent,
                        fontWeight: FontWeight.bold,
                        fontSize: 10,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // Game Cards List
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(PixelMetrics.space4),
                children: [
                  // 1. Word Rush 60s
                  _GameCabinetCard(
                    title: 'WORD RUSH 60S',
                    subtitle: 'RAPID SPEED MATCH',
                    description:
                        'Match English words to definitions within 60 seconds. Build combos for Fever multiplier.',
                    glyph: PixelGlyph.bolt,
                    buttonLabel: 'Start Rush',
                    onPlay: () => _launch(context, const WordRushGame()),
                  ),
                  const SizedBox(height: PixelMetrics.space4),

                  // 2. Vocab Snake
                  _GameCabinetCard(
                    title: 'VOCAB SNAKE',
                    subtitle: '8-BIT NIBBLER QUEST',
                    description:
                        'Steer your pixel snake to eat matching English words directly on the grid and grow longer.',
                    glyph: PixelGlyph.gamepad,
                    buttonLabel: 'Play Snake',
                    onPlay: () => _launch(context, const VocabSnakeGame()),
                  ),
                  const SizedBox(height: PixelMetrics.space4),

                  // 3. Vocab Invaders
                  _GameCabinetCard(
                    title: 'VOCAB INVADERS',
                    subtitle: 'GALAGA SPACE DEFENDER',
                    description:
                        'Blast descending alien UFO ships carrying matching English vocabulary before they reach base.',
                    glyph: PixelGlyph.alien,
                    buttonLabel: 'Launch Defense',
                    onPlay: () => _launch(context, const VocabInvadersGame()),
                  ),
                  const SizedBox(height: PixelMetrics.space4),

                  // 4. Breakout Vocab
                  _GameCabinetCard(
                    title: 'BREAKOUT VOCAB',
                    subtitle: 'ARKANOID BRICK SHATTER',
                    description:
                        'Deflect the bouncing pixel ball into target vocabulary bricks to shatter the wall and earn combos.',
                    glyph: PixelGlyph.brick,
                    buttonLabel: 'Break Bricks',
                    onPlay: () => _launch(context, const BreakoutVocabGame()),
                  ),
                  const SizedBox(height: PixelMetrics.space4),

                  // 5. Vocab Frogger
                  _GameCabinetCard(
                    title: 'VOCAB FROGGER',
                    subtitle: 'HIGHWAY & RIVER CROSSING',
                    description:
                        'Hop across speeding highway traffic and jump onto matching vocabulary logs to reach safety.',
                    glyph: PixelGlyph.frog,
                    buttonLabel: 'Hop Crossing',
                    onPlay: () => _launch(context, const VocabFroggerGame()),
                  ),
                  const SizedBox(height: PixelMetrics.space4),

                  // 6. Vocab Chomp
                  _GameCabinetCard(
                    title: 'VOCAB CHOMP',
                    subtitle: 'PAC-MAN MAZE RUNNER',
                    description:
                        'Chomp vocabulary pellets in an 8-bit maze, dodge roaming ghosts, and grab power pellets to strike back.',
                    glyph: PixelGlyph.pacman,
                    buttonLabel: 'Chomp Maze',
                    onPlay: () => _launch(context, const VocabChompGame()),
                  ),
                  const SizedBox(height: PixelMetrics.space4),

                  // 7. Word Stacker
                  _GameCabinetCard(
                    title: 'WORD STACKER',
                    subtitle: 'TETRIS COLUMN DROP',
                    description:
                        'Drop falling vocabulary blocks into matching definition sorting columns to clear lines and prevent overflow.',
                    glyph: PixelGlyph.tetris,
                    buttonLabel: 'Stack Blocks',
                    onPlay: () => _launch(context, const WordStackerGame()),
                  ),
                  const SizedBox(height: PixelMetrics.space4),

                  // 8. Vocab Angler
                  _GameCabinetCard(
                    title: 'VOCAB ANGLER',
                    subtitle: 'DEEP SEA FISHING',
                    description:
                        'Cast your line into ocean currents and hook swimming vocabulary fish that match the prompt definition.',
                    glyph: PixelGlyph.fish,
                    buttonLabel: 'Cast Line',
                    onPlay: () => _launch(context, const VocabAnglerGame()),
                  ),
                  const SizedBox(height: PixelMetrics.space4),

                  // 9. Pixel Duel
                  _GameCabinetCard(
                    title: 'PIXEL DUEL',
                    subtitle: 'WILD WEST QUICK DRAW',
                    description:
                        'High-noon outlaw standoff! Watch for the DRAW flash and tap the correct vocabulary holster faster than the outlaw.',
                    glyph: PixelGlyph.target,
                    buttonLabel: 'Enter Standoff',
                    onPlay: () => _launch(context, const PixelDuelGame()),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GameCabinetCard extends StatelessWidget {
  const _GameCabinetCard({
    required this.title,
    required this.subtitle,
    required this.description,
    required this.glyph,
    required this.buttonLabel,
    required this.onPlay,
  });

  final String title;
  final String subtitle;
  final String description;
  final PixelGlyph glyph;
  final String buttonLabel;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final theme = Theme.of(context);

    return PixelBox(
      raised: true,
      padding: const EdgeInsets.all(PixelMetrics.space4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(PixelMetrics.space2),
                decoration: BoxDecoration(
                  color: palette.accent,
                  border: Border.all(
                    color: palette.border,
                    width: PixelMetrics.border,
                  ),
                ),
                child: PixelIcon(
                  glyph,
                  color: palette.onAccent,
                  scale: 2.5,
                ),
              ),
              const SizedBox(width: PixelMetrics.space3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: palette.inkFaint,
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: PixelMetrics.space3),
          Text(
            description,
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: PixelMetrics.space3),
          PixelButton(
            label: buttonLabel,
            glyph: PixelGlyph.gamepad,
            filled: true,
            expand: true,
            onPressed: onPlay,
          ),
        ],
      ),
    );
  }
}
