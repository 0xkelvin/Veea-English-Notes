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

class VocabBrick {
  VocabBrick({
    required this.id,
    required this.row,
    required this.col,
    required this.word,
    required this.isTarget,
    this.isBroken = false,
  });

  final String id;
  final int row;
  final int col;
  final String word;
  final bool isTarget;
  bool isBroken;
}

/// 8-Bit Brick Breaker / Arkanoid Game for Vocabulary Practice.
class BreakoutVocabGame extends StatefulWidget {
  const BreakoutVocabGame({super.key});

  @override
  State<BreakoutVocabGame> createState() => _BreakoutVocabGameState();
}

class _BreakoutVocabGameState extends State<BreakoutVocabGame> {
  final FocusNode _focusNode = FocusNode();
  List<VocabularyWord> _deck = [];
  bool _isLoading = true;

  Timer? _gameLoop;
  VocabularyWord? _currentTargetWord;
  List<VocabBrick> _bricks = [];

  double _paddleX = 0.5; // 0.0 to 1.0
  double _ballX = 0.5;
  double _ballY = 0.82;
  double _ballVx = 0.012;
  double _ballVy = -0.015;
  bool _ballInPlay = false;

  int _score = 0;
  int _boardsCleared = 0;
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
      _boardsCleared = 0;
      _lives = 3;
      _isGameOver = false;
      _paddleX = 0.5;
      _resetBall();
    });

    _spawnBricks();
    _startGameLoop();
  }

  void _resetBall() {
    _ballX = _paddleX;
    _ballY = 0.82;
    _ballVx = (Random().nextBool() ? 1 : -1) * 0.012;
    _ballVy = -0.015;
    _ballInPlay = false;
  }

  void _startGameLoop() {
    _gameLoop?.cancel();
    _gameLoop = Timer.periodic(const Duration(milliseconds: 32), (_) {
      _tick();
    });
  }

  void _spawnBricks() {
    if (_deck.isEmpty) return;
    final random = Random();
    final target = _deck[random.nextInt(_deck.length)];

    final distractors = _deck
        .where((w) => w.id != target.id)
        .map((w) => w.word)
        .toSet()
        .toList()
      ..shuffle();

    final bricks = <VocabBrick>[];
    const rows = 3;
    const cols = 3;
    final total = rows * cols;
    final targetIdx = random.nextInt(total);

    var distractorIdx = 0;
    var idx = 0;
    for (var r = 0; r < rows; r++) {
      for (var c = 0; c < cols; c++) {
        final isTarget = idx == targetIdx;
        final word = isTarget
            ? target.word
            : (distractorIdx < distractors.length
                ? distractors[distractorIdx++]
                : target.word);
        bricks.add(
          VocabBrick(
            id: '$r-$c',
            row: r,
            col: c,
            word: word,
            isTarget: isTarget,
          ),
        );
        idx++;
      }
    }

    setState(() {
      _currentTargetWord = target;
      _bricks = bricks;
      _resetBall();
    });
  }

  void _movePaddle(double delta) {
    setState(() {
      _paddleX = (_paddleX + delta).clamp(0.15, 0.85);
      if (!_ballInPlay) _ballX = _paddleX;
    });
  }

  void _launchBall() {
    if (!_ballInPlay && !_isGameOver) {
      setState(() {
        _ballInPlay = true;
      });
    }
  }

  void _tick() {
    if (_isGameOver || !_ballInPlay) return;

    _ballX += _ballVx;
    _ballY += _ballVy;

    // Wall Bounces
    if (_ballX <= 0.03) {
      _ballX = 0.03;
      _ballVx = _ballVx.abs();
    } else if (_ballX >= 0.97) {
      _ballX = 0.97;
      _ballVx = -_ballVx.abs();
    }

    if (_ballY <= 0.03) {
      _ballY = 0.03;
      _ballVy = _ballVy.abs();
    }

    // Paddle Bounce (paddle sits at y=0.86)
    if (_ballY >= 0.84 && _ballY <= 0.88) {
      final paddleDist = _ballX - _paddleX;
      if (paddleDist.abs() < 0.15) {
        _ballY = 0.84;
        _ballVy = -_ballVy.abs();
        _ballVx = paddleDist * 0.12; // Angular deflection based on hit spot
      }
    }

    // Ball Drop
    if (_ballY > 0.96) {
      _lives--;
      if (_lives > 0) {
        _resetBall();
      } else {
        _isGameOver = true;
        _gameLoop?.cancel();
      }
      setState(() {});
      return;
    }

    // Brick Collisions
    // Brick area: rows 0..2 map to y in [0.08, 0.40]
    const rowHeight = 0.09;
    const topMargin = 0.06;
    for (final brick in _bricks) {
      if (brick.isBroken) continue;
      final brickTop = topMargin + (brick.row * rowHeight);
      final brickBottom = brickTop + rowHeight - 0.01;
      final brickLeft = 0.05 + (brick.col * 0.31);
      final brickRight = brickLeft + 0.28;

      if (_ballX >= brickLeft &&
          _ballX <= brickRight &&
          _ballY >= brickTop &&
          _ballY <= brickBottom) {
        brick.isBroken = true;
        _ballVy = -_ballVy;

        if (brick.isTarget) {
          _score += 300;
          _boardsCleared++;
          _spawnBricks();
          return;
        } else {
          _score += 50;
        }
        break;
      }
    }

    setState(() {});
  }

  void _handleKey(KeyEvent event) {
    if (event is! KeyDownEvent) return;
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowLeft:
      case LogicalKeyboardKey.keyA:
        _movePaddle(-0.06);
        break;
      case LogicalKeyboardKey.arrowRight:
      case LogicalKeyboardKey.keyD:
        _movePaddle(0.06);
        break;
      case LogicalKeyboardKey.space:
      case LogicalKeyboardKey.arrowUp:
      case LogicalKeyboardKey.keyW:
        _launchBall();
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
                    ? const Center(child: Text('LOADING BRICKS…'))
                    : _isGameOver
                    ? _buildGameOver(context)
                    : _buildCourt(context),
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
            semanticLabel: 'Exit Breakout',
            onPressed: () => Navigator.of(context).pop(),
          ),
          const SizedBox(width: PixelMetrics.space2),
          Text('BREAKOUT VOCAB', style: Theme.of(context).textTheme.titleMedium),
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

  Widget _buildCourt(BuildContext context) {
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
                'SHATTER TARGET WORD BRICK:',
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

        // Breakout Court
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
                        _paddleX = (_paddleX + (details.delta.dx / w)).clamp(0.15, 0.85);
                        if (!_ballInPlay) _ballX = _paddleX;
                      });
                    },
                    onTapUp: (_) => _launchBall(),
                    child: Stack(
                      children: [
                        // Bricks Grid
                        for (final brick in _bricks)
                          if (!brick.isBroken)
                            Positioned(
                              left: (0.05 + (brick.col * 0.31)) * w,
                              top: (0.06 + (brick.row * 0.09)) * h,
                              width: 0.28 * w,
                              height: 0.075 * h,
                              child: Container(
                                padding: const EdgeInsets.all(2),
                                decoration: BoxDecoration(
                                  color: brick.isTarget
                                      ? palette.accent
                                      : palette.surface,
                                  border: Border.all(
                                    color: palette.border,
                                    width: 1.5,
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: palette.border.withValues(alpha: 0.3),
                                      offset: const Offset(1, 1),
                                      blurRadius: 0,
                                    ),
                                  ],
                                ),
                                child: Center(
                                  child: Text(
                                    brick.word.toUpperCase(),
                                    style: TextStyle(
                                      fontFamily: 'Handjet',
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                      color: brick.isTarget
                                          ? palette.onAccent
                                          : palette.ink,
                                      height: 1.0,
                                    ),
                                    textAlign: TextAlign.center,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ),
                            ),

                        // Bouncing Ball
                        Positioned(
                          left: (_ballX * w) - 6,
                          top: (_ballY * h) - 6,
                          child: Container(
                            width: 12,
                            height: 12,
                            decoration: BoxDecoration(
                              color: palette.danger,
                              border: Border.all(color: palette.border, width: 1),
                            ),
                          ),
                        ),

                        // Paddle
                        Positioned(
                          left: (_paddleX * w) - 35,
                          top: 0.86 * h,
                          width: 70,
                          height: 14,
                          child: Container(
                            decoration: BoxDecoration(
                              color: palette.ink,
                              border: Border.all(color: palette.border, width: 1.5),
                            ),
                          ),
                        ),

                        // Launch Prompt
                        if (!_ballInPlay)
                          Positioned(
                            bottom: 24,
                            left: 0,
                            right: 0,
                            child: Center(
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: palette.paper,
                                  border: Border.all(color: palette.border, width: 1),
                                ),
                                child: Text(
                                  'TAP OR PRESS FIRE TO LAUNCH BALL',
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
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

        // Controls
        Padding(
          padding: const EdgeInsets.fromLTRB(
            PixelMetrics.space3,
            0,
            PixelMetrics.space3,
            PixelMetrics.space3,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              PixelButton(
                label: '◀ Left',
                glyph: PixelGlyph.arrowLeft,
                onPressed: () => _movePaddle(-0.08),
              ),
              const SizedBox(width: PixelMetrics.space3),
              PixelButton(
                label: _ballInPlay ? 'IN PLAY' : 'LAUNCH ⚪',
                glyph: PixelGlyph.brick,
                filled: !_ballInPlay,
                onPressed: _launchBall,
              ),
              const SizedBox(width: PixelMetrics.space3),
              PixelButton(
                label: 'Right ▶',
                glyph: PixelGlyph.arrowRight,
                onPressed: () => _movePaddle(0.08),
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
                '☠ BALLS DEPLETED ☠',
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
                  Text('BOARDS CLEARED', style: theme.textTheme.labelSmall),
                  const Spacer(),
                  Text('$_boardsCleared', style: theme.textTheme.titleMedium),
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
