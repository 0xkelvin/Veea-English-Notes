import 'package:flutter/material.dart';

import '../../core/theme/pixel_metrics.dart';
import '../../core/theme/pixel_palette.dart';
import '../../widgets/pixel/pixel_button.dart';
import '../../widgets/pixel/pixel_icon.dart';
import '../arcade_sdk.dart';

/// 🕹️ Community Starter Template Game
///
/// An example retro mini-game demonstrating how easy it is to build
/// vocabulary games using the Veea Arcade SDK.
class StarterTemplateGame extends StatefulWidget {
  const StarterTemplateGame({super.key, required this.gameContext});

  final ArcadeGameContext gameContext;

  @override
  State<StarterTemplateGame> createState() => _StarterTemplateGameState();
}

class _StarterTemplateGameState extends State<StarterTemplateGame> {
  late List<ArcadeVocabWord> _deck;
  int _currentIndex = 0;
  int _score = 0;
  int _streak = 0;
  final List<ArcadeFallingBadgeData> _fallingBadges = [];
  final List<ArcadeParticle> _particles = [];
  late List<String> _optionChoices;

  @override
  void initState() {
    super.initState();
    _deck = widget.gameContext.getVocabularyDeck(count: 15);
    _setupRound();
  }

  void _setupRound() {
    if (_deck.isEmpty) return;
    final currentWord = _deck[_currentIndex % _deck.length];
    
    // Generate 3 choices (1 correct, 2 distractors)
    final otherMeanings = _deck
        .where((w) => w.id != currentWord.id)
        .map((w) => w.meaning)
        .toList()
      ..shuffle();

    _optionChoices = [
      currentWord.meaning,
      if (otherMeanings.isNotEmpty) otherMeanings[0] else 'Ý nghĩa khác A',
      if (otherMeanings.length > 1) otherMeanings[1] else 'Ý nghĩa khác B',
    ]..shuffle();
  }

  void _handleChoice(String selectedMeaning) {
    final currentWord = _deck[_currentIndex % _deck.length];
    final isCorrect = selectedMeaning == currentWord.meaning;

    if (isCorrect) {
      // 1. Play pronunciation of the word
      widget.gameContext.pronounce(currentWord.word);

      // 2. Spawn falling Vietnamese meaning badge
      setState(() {
        _score += 100 + (_streak * 20);
        _streak++;
        _fallingBadges.add(
          ArcadeFallingBadgeData(
            id: DateTime.now().toIso8601String(),
            meaning: currentWord.meaning,
            x: 180,
            y: 80,
          ),
        );
        _particles.addAll(
          ArcadeParticle.createExplosion(
            originX: 180,
            originY: 100,
            color: const Color(0xFFCBE32B),
          ),
        );
      });

      // 3. Record spaced repetition progress
      widget.gameContext.recordHit(wordId: currentWord.id, scorePoints: 100);

      // 4. Advance to next word
      Future.delayed(const Duration(milliseconds: 300), () {
        if (!mounted) return;
        setState(() {
          _currentIndex = (_currentIndex + 1) % _deck.length;
          _setupRound();
        });
      });
    } else {
      setState(() {
        _streak = 0;
        _particles.addAll(
          ArcadeParticle.createExplosion(
            originX: 180,
            originY: 100,
            color: const Color(0xFFE53935),
          ),
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final theme = Theme.of(context);
    if (_deck.isEmpty) return const SizedBox.shrink();

    final currentWord = _deck[_currentIndex % _deck.length];

    return Scaffold(
      backgroundColor: palette.paper,
      body: SafeArea(
        child: Column(
          children: [
            // Top Nav Bar
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
                    semanticLabel: 'Back',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  const SizedBox(width: PixelMetrics.space2),
                  Text('STARTER GAME', style: theme.textTheme.titleMedium),
                  const Spacer(),
                  Text(
                    'SCORE: $_score',
                    style: TextStyle(
                      fontFamily: 'Handjet',
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: palette.accent,
                    ),
                  ),
                ],
              ),
            ),

            // Game CRT Screen Area
            Expanded(
              child: ArcadeCrtScreen(
                scoreText: 'SCORE $_score',
                statusBadge: '🔥 STREAK $_streak',
                child: Stack(
                  children: [
                    // Main Prompt
                    Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'MATCH THE MEANING',
                            style: TextStyle(
                              fontFamily: 'Handjet',
                              fontSize: 12,
                              color: palette.inkFaint,
                              letterSpacing: 1.2,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            currentWord.word,
                            style: const TextStyle(
                              fontFamily: 'Handjet',
                              fontSize: 32,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFFE0DFD5),
                            ),
                          ),
                          if (currentWord.ipa.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(
                              currentWord.ipa,
                              style: const TextStyle(
                                fontFamily: 'Handjet',
                                fontSize: 16,
                                color: Color(0xFFCBE32B),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),

                    // Particle explosions
                    CustomPaint(
                      size: Size.infinite,
                      painter: ArcadeParticlesPainter(particles: _particles),
                    ),

                    // Falling meaning badge
                    ArcadeFallingBadgesOverlay(badges: _fallingBadges),
                  ],
                ),
              ),
            ),

            // Bottom Choices
            Container(
              padding: const EdgeInsets.all(PixelMetrics.space3),
              decoration: BoxDecoration(
                color: palette.surface,
                border: Border(
                  top: BorderSide(
                    color: palette.border,
                    width: PixelMetrics.border,
                  ),
                ),
              ),
              child: Column(
                children: [
                  for (final choice in _optionChoices)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: SizedBox(
                        width: double.infinity,
                        child: PixelButton(
                          label: choice,
                          filled: false,
                          onPressed: () => _handleChoice(choice),
                        ),
                      ),
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
