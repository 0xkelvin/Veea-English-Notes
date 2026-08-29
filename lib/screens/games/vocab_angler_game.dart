import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/theme/pixel_metrics.dart';
import '../../core/theme/pixel_palette.dart';
import '../../models/vocabulary_word.dart';
import '../../providers/vocabulary_provider.dart';
import '../../widgets/pixel/pixel_box.dart';
import '../../widgets/pixel/pixel_button.dart';
import '../../widgets/pixel/pixel_icon.dart';

class SwimmingFish {
  SwimmingFish({
    required this.x,
    required this.y,
    required this.speed,
    required this.word,
    required this.isTarget,
  });

  double x; // 0.0 to 1.0
  final double y;
  final double speed;
  final String word;
  final bool isTarget;
}

/// 8-Bit Deep Sea Fishing / Angler Game for Vocabulary Practice.
class VocabAnglerGame extends StatefulWidget {
  const VocabAnglerGame({super.key});

  @override
  State<VocabAnglerGame> createState() => _VocabAnglerGameState();
}

class _VocabAnglerGameState extends State<VocabAnglerGame> {
  final FocusNode _focusNode = FocusNode();
  List<VocabularyWord> _deck = [];
  bool _isLoading = true;

  Timer? _gameLoop;
  VocabularyWord? _currentTargetWord;
  List<SwimmingFish> _fishes = [];

  double _hookX = 0.5;
  double _hookY = 0.15; // 0.15 at top boat, up to 0.85 in deep sea
  bool _isReeling = false;

  int _score = 0;
  int _catches = 0;
  int _lives = 3;
  bool _isGameOver = false;

  @override
  void initState() {
    super.initState();
    _initGame();
  }

  @override
  void dispose() {
    _gameLoop?.cancel();
    _focusNode.dispose();
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
      _catches = 0;
      _lives = 3;
      _isGameOver = false;
      _hookX = 0.5;
      _hookY = 0.15;
      _isReeling = false;
    });

    _spawnFishSchool();
    _startGameLoop();
  }

  void _startGameLoop() {
    _gameLoop?.cancel();
    _gameLoop = Timer.periodic(const Duration(milliseconds: 50), (_) {
      _tick();
    });
  }

  void _spawnFishSchool() {
    if (_deck.isEmpty) return;
    final random = Random();
    final target = _deck[random.nextInt(_deck.length)];

    final distractors = _deck
        .where((w) => w.id != target.id)
        .map((w) => w.word)
        .toSet()
        .toList()
      ..shuffle();

    final words = <({String word, bool isTarget})>[
      (word: target.word, isTarget: true),
      (word: distractors.isNotEmpty ? distractors[0] : target.word, isTarget: false),
      (word: distractors.length > 1 ? distractors[1] : target.word, isTarget: false),
    ]..shuffle();

    final depths = [0.35, 0.55, 0.75]..shuffle();
    final fishes = <SwimmingFish>[];
    for (var i = 0; i < 3; i++) {
      final direction = i % 2 == 0 ? 1 : -1;
      fishes.add(
        SwimmingFish(
          x: random.nextDouble(),
          y: depths[i],
          speed: (0.006 + random.nextDouble() * 0.004) * direction,
          word: words[i].word,
          isTarget: words[i].isTarget,
        ),
      );
    }

    setState(() {
      _currentTargetWord = target;
      _fishes = fishes;
      _hookY = 0.15;
      _isReeling = false;
    });
  }

  void _moveHook(double dx) {
    if (_isGameOver) return;
    setState(() {
      _hookX = (_hookX + dx).clamp(0.1, 0.9);
    });
  }

  void _toggleDropReel() {
    if (_isGameOver) return;
    setState(() {
      _isReeling = !_isReeling;
    });
  }

  void _tick() {
    if (_isGameOver) return;

    // Move Hook
    if (_isReeling) {
      _hookY = (_hookY - 0.025).clamp(0.15, 0.85);
      if (_hookY <= 0.15) _isReeling = false;
    } else {
      _hookY = (_hookY + 0.015).clamp(0.15, 0.85);
      if (_hookY >= 0.85) _isReeling = true;
    }

    // Move Fish
    for (final fish in _fishes) {
      fish.x += fish.speed;
      if (fish.x > 1.2) fish.x = -0.2;
      if (fish.x < -0.2) fish.x = 1.2;

      // Check Hook Collision
      final dx = (_hookX - fish.x).abs();
      final dy = (_hookY - fish.y).abs();
      if (dx < 0.10 && dy < 0.06) {
        if (fish.isTarget) {
          _score += 250;
          _catches++;
          _spawnFishSchool();
          return;
        } else {
          _lives--;
          if (_lives > 0) {
            _hookY = 0.15;
            _isReeling = false;
            _spawnFishSchool();
          } else {
            _isGameOver = true;
            _gameLoop?.cancel();
          }
          setState(() {});
          return;
        }
      }
    }

    setState(() {});
  }

  void _handleKey(KeyEvent event) {
    if (event is! KeyDownEvent) return;
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowLeft:
      case LogicalKeyboardKey.keyA:
        _moveHook(-0.08);
        break;
      case LogicalKeyboardKey.arrowRight:
      case LogicalKeyboardKey.keyD:
        _moveHook(0.08);
        break;
      case LogicalKeyboardKey.space:
      case LogicalKeyboardKey.arrowDown:
      case LogicalKeyboardKey.arrowUp:
        _toggleDropReel();
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    return KeyboardListener(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _handleKey,
      child: Scaffold(
        backgroundColor: palette.paper,
        body: SafeArea(
          child: Column(
            children: [
              _buildTopBar(context),
              Expanded(
                child: _isLoading
                    ? const Center(child: Text('CASTING LINE…'))
                    : _isGameOver
                    ? _buildGameOver(context)
                    : _buildOcean(context),
              ),
            ],
          ),
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
            semanticLabel: 'Exit Angler',
            onPressed: () => Navigator.of(context).pop(),
          ),
          const SizedBox(width: PixelMetrics.space2),
          Text('VOCAB ANGLER', style: Theme.of(context).textTheme.titleMedium),
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

  Widget _buildOcean(BuildContext context) {
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
                'HOOK MATCHING WORD FISH:',
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

        // Deep Sea Ocean Area
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: PixelMetrics.space3),
            child: Container(
              decoration: BoxDecoration(
                color: palette.surface,
                border: Border.all(color: palette.border, width: PixelMetrics.border),
              ),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final w = constraints.maxWidth;
                  final h = constraints.maxHeight;

                  return GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onHorizontalDragUpdate: (details) {
                      setState(() {
                        _hookX = (_hookX + (details.delta.dx / w)).clamp(0.1, 0.9);
                      });
                    },
                    onTapUp: (_) => _toggleDropReel(),
                    child: Stack(
                      children: [
                        // Sea Surface & Boat
                        Positioned(
                          top: 0,
                          left: 0,
                          right: 0,
                          height: 0.15 * h,
                          child: Container(
                            color: palette.accent.withValues(alpha: 0.15),
                            child: Align(
                              alignment: Alignment.bottomCenter,
                              child: Container(
                                width: double.infinity,
                                height: 2,
                                color: palette.border,
                              ),
                            ),
                          ),
                        ),

                        // Fishing Boat at Top
                        Positioned(
                          left: (_hookX * w) - 20,
                          top: (0.15 * h) - 16,
                          child: Container(
                            width: 40,
                            height: 16,
                            decoration: BoxDecoration(
                              color: palette.ink,
                              border: Border.all(color: palette.border, width: 1),
                            ),
                          ),
                        ),

                        // Fishing Line
                        Positioned(
                          left: _hookX * w,
                          top: 0.15 * h,
                          width: 2,
                          height: (_hookY - 0.15) * h,
                          child: Container(
                            color: palette.inkFaint,
                          ),
                        ),

                        // Fishing Hook
                        Positioned(
                          left: (_hookX * w) - 6,
                          top: _hookY * h,
                          child: Container(
                            width: 12,
                            height: 12,
                            decoration: BoxDecoration(
                              color: palette.accent,
                              border: Border.all(color: palette.border, width: 1),
                            ),
                          ),
                        ),

                        // Swimming Word Fish
                        for (final fish in _fishes)
                          Positioned(
                            left: (fish.x * w) - 35,
                            top: fish.y * h,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                PixelIcon(
                                  PixelGlyph.fish,
                                  color: palette.ink,
                                  scale: 2.2,
                                ),
                                const SizedBox(width: 4),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 4,
                                    vertical: 1,
                                  ),
                                  decoration: BoxDecoration(
                                    color: palette.paper,
                                    border: Border.all(color: palette.border, width: 1),
                                  ),
                                  child: Text(
                                    fish.word.toUpperCase(),
                                    style: const TextStyle(
                                      fontFamily: 'Handjet',
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                      height: 1.0,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        ),

        const SizedBox(height: PixelMetrics.space3),

        // Ergonomic Two-Handed Controls
        Padding(
          padding: const EdgeInsets.fromLTRB(
            PixelMetrics.space3,
            0,
            PixelMetrics.space3,
            PixelMetrics.space3,
          ),
          child: Row(
            children: [
              // Left Thumb: Hook Movement
              _AnglerTouchButton(
                glyph: PixelGlyph.arrowLeft,
                label: '◀',
                semanticLabel: 'Move Hook Left',
                onAction: () => _moveHook(-0.06),
              ),
              const SizedBox(width: PixelMetrics.space2),
              _AnglerTouchButton(
                glyph: PixelGlyph.arrowRight,
                label: '▶',
                semanticLabel: 'Move Hook Right',
                onAction: () => _moveHook(0.06),
              ),

              const Spacer(),

              // Right Thumb: Big Reel/Drop Button
              _AnglerReelButton(
                glyph: PixelGlyph.fish,
                label: _isReeling ? 'REEL UP 🎣' : 'DROP LINE ⚓',
                isReeling: _isReeling,
                onToggle: _toggleDropReel,
              ),
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
                '☠ LINE SNAPPED ☠',
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
                  Text('FISH CAUGHT', style: theme.textTheme.labelSmall),
                  const Spacer(),
                  Text('$_catches', style: theme.textTheme.titleMedium),
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

class _AnglerTouchButton extends StatefulWidget {
  const _AnglerTouchButton({
    required this.glyph,
    required this.label,
    required this.semanticLabel,
    required this.onAction,
  });

  final PixelGlyph glyph;
  final String label;
  final String semanticLabel;
  final VoidCallback onAction;

  @override
  State<_AnglerTouchButton> createState() => _AnglerTouchButtonState();
}

class _AnglerTouchButtonState extends State<_AnglerTouchButton> {
  Timer? _holdTimer;
  bool _pressed = false;

  void _start() {
    widget.onAction();
    setState(() => _pressed = true);
    _holdTimer?.cancel();
    _holdTimer = Timer.periodic(const Duration(milliseconds: 40), (_) {
      widget.onAction();
    });
  }

  void _stop() {
    _holdTimer?.cancel();
    if (mounted) setState(() => _pressed = false);
  }

  @override
  void dispose() {
    _holdTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    return Semantics(
      label: widget.semanticLabel,
      button: true,
      child: GestureDetector(
        onTapDown: (_) => _start(),
        onTapUp: (_) => _stop(),
        onTapCancel: _stop,
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: 58,
          height: 48,
          decoration: BoxDecoration(
            color: _pressed ? palette.accent : palette.surface,
            border: Border.all(color: palette.border, width: PixelMetrics.border),
            boxShadow: _pressed
                ? []
                : [
                    BoxShadow(
                      color: palette.border.withValues(alpha: 0.4),
                      offset: const Offset(1, 1),
                      blurRadius: 0,
                    ),
                  ],
          ),
          child: Center(
            child: PixelIcon(
              widget.glyph,
              color: _pressed ? palette.onAccent : palette.ink,
              scale: 2.2,
            ),
          ),
        ),
      ),
    );
  }
}

class _AnglerReelButton extends StatelessWidget {
  const _AnglerReelButton({
    required this.glyph,
    required this.label,
    required this.isReeling,
    required this.onToggle,
  });

  final PixelGlyph glyph;
  final String label;
  final bool isReeling;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    return GestureDetector(
      onTap: onToggle,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        decoration: BoxDecoration(
          color: isReeling ? palette.accent : palette.danger,
          border: Border.all(color: palette.border, width: PixelMetrics.border),
          boxShadow: [
            BoxShadow(
              color: palette.border.withValues(alpha: 0.4),
              offset: const Offset(2, 2),
              blurRadius: 0,
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            PixelIcon(
              glyph,
              color: Colors.white,
              scale: 2.0,
            ),
            const SizedBox(width: 8),
            Text(
              label,
              style: const TextStyle(
                fontFamily: 'Handjet',
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: Colors.white,
                letterSpacing: 0.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
