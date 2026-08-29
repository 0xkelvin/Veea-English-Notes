import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/pixel_metrics.dart';
import '../../core/theme/pixel_palette.dart';
import '../../models/vocabulary_word.dart';
import '../../providers/vocabulary_provider.dart';
import '../../widgets/pixel/pixel_box.dart';
import '../../widgets/pixel/pixel_button.dart';
import '../../widgets/pixel/pixel_icon.dart';

enum DuelState { waiting, ready, draw, won, lost }

/// 8-Bit Wild West Quick Draw / Standoff Game for Vocabulary Practice.
class PixelDuelGame extends StatefulWidget {
  const PixelDuelGame({super.key});

  @override
  State<PixelDuelGame> createState() => _PixelDuelGameState();
}

class _PixelDuelGameState extends State<PixelDuelGame> {
  List<VocabularyWord> _deck = [];
  bool _isLoading = true;

  DuelState _state = DuelState.waiting;
  Timer? _countdownTimer;
  Timer? _outlawShotTimer;
  Stopwatch _reactionStopwatch = Stopwatch();

  VocabularyWord? _currentTargetWord;
  List<String> _choiceOptions = [];
  int _lastReactionMs = 0;

  int _score = 0;
  int _outlawsDefeated = 0;
  int _lives = 3;
  bool _isGameOver = false;

  @override
  void initState() {
    super.initState();
    _initGame();
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _outlawShotTimer?.cancel();
    super.dispose();
  }

  Future<void> _initGame() async {
    final provider = context.read<VocabularyProvider>();
    var words = await provider.wordsDueForReview(limit: 50);
    if (words.length < 3) words = provider.words;

    if (!mounted) return;
    setState(() {
      _deck = List.of(words)..shuffle();
      _isLoading = false;
      _score = 0;
      _outlawsDefeated = 0;
      _lives = 3;
      _isGameOver = false;
    });

    _startNewDuel();
  }

  void _startNewDuel() {
    if (_deck.isEmpty) return;
    _countdownTimer?.cancel();
    _outlawShotTimer?.cancel();

    final random = Random();
    final target = _deck[random.nextInt(_deck.length)];

    final distractors = _deck
        .where((w) => w.id != target.id)
        .map((w) => w.word)
        .toSet()
        .toList()
      ..shuffle();

    final choices = <String>[
      target.word,
      if (distractors.isNotEmpty) distractors[0],
      if (distractors.length > 1) distractors[1],
    ]..shuffle();

    setState(() {
      _currentTargetWord = target;
      _choiceOptions = choices;
      _state = DuelState.ready;
    });

    // Random tension countdown: 1.5 to 3.0 seconds
    final waitMs = 1500 + random.nextInt(1500);
    _countdownTimer = Timer(Duration(milliseconds: waitMs), () {
      if (!mounted || _state != DuelState.ready) return;
      setState(() {
        _state = DuelState.draw;
        _reactionStopwatch = Stopwatch()..start();
      });

      // Outlaw reaction time: gets faster as you beat more outlaws (1200ms -> 550ms)
      final outlawLimitMs = (1200 - (_outlawsDefeated * 60)).clamp(550, 1200);
      _outlawShotTimer = Timer(Duration(milliseconds: outlawLimitMs), () {
        if (!mounted || _state != DuelState.draw) return;
        _handleOutlawShotFirst();
      });
    });
  }

  void _selectWord(String word) {
    if (_state != DuelState.draw) return;
    _reactionStopwatch.stop();
    _outlawShotTimer?.cancel();

    final ms = _reactionStopwatch.elapsedMilliseconds;
    _lastReactionMs = ms;

    if (word == _currentTargetWord?.word) {
      // Player Quick Draw Win!
      final speedBonus = (1000 - ms).clamp(50, 500);
      _score += 200 + speedBonus;
      _outlawsDefeated++;
      setState(() {
        _state = DuelState.won;
      });
      Future.delayed(const Duration(milliseconds: 1200), () {
        if (mounted && !_isGameOver) _startNewDuel();
      });
    } else {
      // Wrong word shot
      _handleOutlawShotFirst();
    }
  }

  void _handleOutlawShotFirst() {
    _reactionStopwatch.stop();
    _outlawShotTimer?.cancel();
    setState(() {
      _lives--;
      _state = DuelState.lost;
      if (_lives <= 0) {
        _isGameOver = true;
      }
    });

    if (!_isGameOver) {
      Future.delayed(const Duration(milliseconds: 1400), () {
        if (mounted && !_isGameOver) _startNewDuel();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    return Scaffold(
      backgroundColor: palette.paper,
      body: SafeArea(
        child: Column(
          children: [
            _buildTopBar(context),
            Expanded(
              child: _isLoading
                  ? const Center(child: Text('LOADING STANDOFF…'))
                  : _isGameOver
                  ? _buildGameOver(context)
                  : _buildStandoffArena(context),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar(BuildContext context) {
    final palette = context.palette;

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: PixelMetrics.space4,
        vertical: PixelMetrics.space2,
      ),
      decoration: BoxDecoration(
        color: palette.surface,
        border: Border(
          bottom: BorderSide(color: palette.border, width: PixelMetrics.border),
        ),
      ),
      child: Row(
        children: [
          PixelIconButton(
            glyph: PixelGlyph.arrowLeft,
            semanticLabel: 'Exit Duel',
            onPressed: () => Navigator.of(context).pop(),
          ),
          const SizedBox(width: PixelMetrics.space2),
          Text('PIXEL DUEL', style: Theme.of(context).textTheme.titleMedium),
          const Spacer(),
          Row(
            children: List.generate(3, (i) {
              final isFull = i < _lives;
              return Padding(
                padding: const EdgeInsets.only(right: 3),
                child: PixelIcon(
                  PixelGlyph.heart,
                  color: isFull ? palette.danger : palette.inkFaint,
                  scale: 2,
                ),
              );
            }),
          ),
          const SizedBox(width: PixelMetrics.space3),
          Text(
            'SCORE: $_score',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStandoffArena(BuildContext context) {
    final palette = context.palette;
    final theme = Theme.of(context);

    return Column(
      children: [
        // Target HUD
        Container(
          width: double.infinity,
          margin: const EdgeInsets.all(PixelMetrics.space3),
          padding: const EdgeInsets.symmetric(
            horizontal: PixelMetrics.space3,
            vertical: PixelMetrics.space2,
          ),
          decoration: BoxDecoration(
            color: palette.surface,
            border: Border.all(color: palette.border, width: PixelMetrics.border),
          ),
          child: Column(
            children: [
              Text(
                'TARGET VOCABULARY:',
                style: theme.textTheme.labelSmall?.copyWith(fontSize: 10),
              ),
              const SizedBox(height: 2),
              Text(
                '"${_currentTargetWord?.meaning ?? ''}"',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: palette.accent,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),

        // Saloon Standoff View
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: PixelMetrics.space3),
            child: Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: palette.surface,
                border: Border.all(color: palette.border, width: PixelMetrics.border),
              ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // Outlaw Sprite
                  Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      PixelIcon(
                        PixelGlyph.skull,
                        color: _state == DuelState.won
                            ? palette.inkFaint
                            : (_state == DuelState.lost
                                ? palette.danger
                                : palette.ink),
                        scale: 4.5,
                      ),
                      const SizedBox(height: PixelMetrics.space2),
                      Text(
                        _state == DuelState.won
                            ? '💥 OUTLAW DEFEATED!'
                            : (_state == DuelState.lost
                                ? '💥 OUTLAW SHOT FIRST!'
                                : 'OUTLAW # ${_outlawsDefeated + 1}'),
                        style: TextStyle(
                          fontFamily: 'Handjet',
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: _state == DuelState.won
                              ? palette.accent
                              : (_state == DuelState.lost
                                  ? palette.danger
                                  : palette.ink),
                        ),
                      ),
                      if (_lastReactionMs > 0 && _state == DuelState.won)
                        Text(
                          'DRAW SPEED: ${_lastReactionMs}ms',
                          style: TextStyle(
                            fontFamily: 'Handjet',
                            fontSize: 12,
                            color: palette.accent,
                          ),
                        ),
                    ],
                  ),

                  // Standoff Status Flash
                  if (_state == DuelState.ready)
                    Positioned(
                      top: 24,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: palette.paper,
                          border: Border.all(color: palette.border, width: 1),
                        ),
                        child: const Text(
                          'HOLD STEADY… WAIT FOR SIGNAL…',
                          style: TextStyle(
                            fontFamily: 'Handjet',
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    )
                  else if (_state == DuelState.draw)
                    Positioned(
                      top: 20,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: palette.danger,
                          border: Border.all(color: palette.border, width: 1.5),
                        ),
                        child: const Text(
                          '⚡⚡ DRAW! TAP QUICK! ⚡⚡',
                          style: TextStyle(
                            fontFamily: 'Handjet',
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),

        const SizedBox(height: PixelMetrics.space3),

        // Holster Choice Buttons
        Padding(
          padding: const EdgeInsets.fromLTRB(
            PixelMetrics.space3,
            0,
            PixelMetrics.space3,
            PixelMetrics.space3,
          ),
          child: Column(
            children: [
              for (final word in _choiceOptions) ...[
                PixelButton(
                  label: _state == DuelState.draw
                      ? '⚡ ${word.toUpperCase()}'
                      : '🔒 [READY]',
                  glyph: PixelGlyph.target,
                  filled: _state == DuelState.draw,
                  expand: true,
                  onPressed: _state == DuelState.draw
                      ? () => _selectWord(word)
                      : null,
                ),
                const SizedBox(height: PixelMetrics.space2),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildGameOver(BuildContext context) {
    final palette = context.palette;
    final theme = Theme.of(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(PixelMetrics.space5),
        child: PixelBox(
          raised: true,
          padding: const EdgeInsets.all(PixelMetrics.space5),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '☠ DEFEATED IN DUEL ☠',
                style: theme.textTheme.headlineSmall?.copyWith(
                  color: palette.danger,
                  fontFamily: 'Handjet',
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: PixelMetrics.space4),
              Row(
                children: [
                  Text('FINAL SCORE', style: theme.textTheme.labelSmall),
                  const Spacer(),
                  Text(
                    '$_score',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: PixelMetrics.space2),
              Row(
                children: [
                  Text('OUTLAWS BESTED', style: theme.textTheme.labelSmall),
                  const Spacer(),
                  Text('$_outlawsDefeated', style: theme.textTheme.titleMedium),
                ],
              ),
              const SizedBox(height: PixelMetrics.space5),
              PixelButton(
                label: 'Play Again',
                glyph: PixelGlyph.gamepad,
                filled: true,
                expand: true,
                onPressed: _initGame,
              ),
              const SizedBox(height: PixelMetrics.space2),
              PixelButton(
                label: 'Exit Arcade',
                expand: true,
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
