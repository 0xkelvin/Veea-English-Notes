import 'package:flutter/material.dart';

import '../core/theme/pixel_metrics.dart';
import '../core/theme/pixel_palette.dart';
import '../widgets/pixel/pixel_box.dart';
import '../widgets/pixel/pixel_button.dart';
import '../widgets/pixel/pixel_icon.dart';
import 'games/vocab_snake_game.dart';
import 'games/word_rush_game.dart';

/// 8-Bit Arcade Hub for Vocabulary Practice & Mini-Games.
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
                      '2 GAMES',
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
                  _GameCabinetCard(
                    title: 'VOCAB SNAKE',
                    subtitle: '8-BIT NIBBLER QUEST',
                    description:
                        'Steer your pixel snake to eat matching English words while avoiding distractors and walls.',
                    glyph: PixelGlyph.gamepad,
                    buttonLabel: 'Play Snake',
                    onPlay: () => _launch(context, const VocabSnakeGame()),
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
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      subtitle,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: palette.accent,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
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
            style: theme.textTheme.bodyMedium?.copyWith(
              color: palette.inkMuted,
            ),
          ),
          const SizedBox(height: PixelMetrics.space4),
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
