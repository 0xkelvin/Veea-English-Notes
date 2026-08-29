import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/theme/pixel_metrics.dart';
import '../../core/theme/pixel_palette.dart';
import '../../models/vocabulary_word.dart';
import '../../providers/vocabulary_provider.dart';
import '../../services/tts_service.dart';
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

class BreakoutParticle {
  BreakoutParticle({
    required this.x,
    required this.y,
    required this.vx,
    required this.vy,
    required this.size,
    required this.color,
    this.life = 1.0,
    this.decay = 0.08,
  });

  double x;
  double y;
  double vx;
  double vy;
  double size;
  Color color;
  double life;
  double decay;
}

class BreakoutScorePopup {
  BreakoutScorePopup({
    required this.x,
    required this.y,
    required this.text,
    required this.color,
    this.life = 1.0,
  });

  double x;
  double y;
  final String text;
  final Color color;
  double life;
}

class BreakoutFallingMeaning {
  BreakoutFallingMeaning({
    required this.x,
    required this.y,
    required this.meaning,
    this.vy = 0.003,
    this.life = 1.0,
  });

  double x;
  double y;
  final String meaning;
  double vy;
  double life;
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
  List<BreakoutParticle> _particles = [];
  List<BreakoutScorePopup> _scorePopups = [];
  List<BreakoutFallingMeaning> _fallingMeanings = [];

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
  bool _isPlayerDying = false;

  double _screenShakeX = 0.0;
  double _screenShakeY = 0.0;
  double _screenFlashOpacity = 0.0;

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

  void _speakWord(String text) {
    try {
      context.read<TtsService>().speak(text);
    } catch (_) {}
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
      _isPlayerDying = false;
      _paddleX = 0.5;
      _particles = [];
      _scorePopups = [];
      _fallingMeanings = [];
      _screenShakeX = 0.0;
      _screenShakeY = 0.0;
      _screenFlashOpacity = 0.0;
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
    if (_isPlayerDying) return;
    setState(() {
      _paddleX = (_paddleX + delta).clamp(0.15, 0.85);
      if (!_ballInPlay) _ballX = _paddleX;
    });
  }

  void _launchBall() {
    if (!_ballInPlay && !_isGameOver && !_isPlayerDying) {
      setState(() {
        _ballInPlay = true;
      });
    }
  }

  void _spawnBrickDebris(double x, double y, {required bool isTarget, required String text}) {
    final random = Random();
    final palette = context.palette;
    final colors = isTarget
        ? [palette.accent, Colors.amberAccent, palette.danger, palette.ink]
        : [palette.inkFaint, palette.surface, palette.border];

    final newParticles = <BreakoutParticle>[];
    const count = 16;
    for (var i = 0; i < count; i++) {
      final angle = (i / count) * 2 * pi + (random.nextDouble() * 0.4 - 0.2);
      final speed = 0.006 + (random.nextDouble() * 0.018);
      newParticles.add(
        BreakoutParticle(
          x: x,
          y: y,
          vx: cos(angle) * speed,
          vy: sin(angle) * speed,
          size: 4.0 + random.nextDouble() * 5.0,
          color: colors[random.nextInt(colors.length)],
          decay: 0.06 + random.nextDouble() * 0.04,
        ),
      );
    }

    _particles.addAll(newParticles);
    _scorePopups.add(
      BreakoutScorePopup(
        x: x,
        y: y - 0.03,
        text: text,
        color: isTarget ? palette.accent : palette.inkFaint,
      ),
    );
  }

  void _spawnFallingMeaning(double x, double y, String meaning) {
    _fallingMeanings.add(
      BreakoutFallingMeaning(
        x: x,
        y: y,
        meaning: meaning,
      ),
    );
  }

  void _spawnPaddleDeathExplosion(double x, double y) {
    final random = Random();
    final palette = context.palette;
    final deathColors = [
      palette.danger,
      Colors.orangeAccent,
      Colors.yellowAccent,
      palette.accent,
      palette.ink,
      Colors.white,
    ];

    final newParticles = <BreakoutParticle>[];
    const count = 36;
    for (var i = 0; i < count; i++) {
      final angle = (i / count) * 2 * pi + (random.nextDouble() * 0.5 - 0.25);
      final speed = 0.008 + (random.nextDouble() * 0.030);
      newParticles.add(
        BreakoutParticle(
          x: x,
          y: y,
          vx: cos(angle) * speed,
          vy: sin(angle) * speed - 0.005,
          size: 5.0 + random.nextDouble() * 7.0,
          color: deathColors[random.nextInt(deathColors.length)],
          decay: 0.03 + random.nextDouble() * 0.03,
        ),
      );
    }

    _particles.addAll(newParticles);
    _scorePopups.add(
      BreakoutScorePopup(
        x: x,
        y: y - 0.06,
        text: '☠ PADDLE SHATTERED! ☠',
        color: palette.danger,
      ),
    );
  }

  void _tick() {
    if (_isGameOver) return;

    // Decay shake and flash
    if (_screenShakeX.abs() > 0.2) _screenShakeX *= 0.65;
    if (_screenShakeY.abs() > 0.2) _screenShakeY *= 0.65;
    if (_screenFlashOpacity > 0.03) _screenFlashOpacity -= 0.04;

    // Update Particles
    for (final p in _particles) {
      p.x += p.vx;
      p.y += p.vy;
      p.life -= p.decay;
    }
    _particles.removeWhere((p) => p.life <= 0);

    // Update Score Popups
    for (final s in _scorePopups) {
      s.y -= 0.006;
      s.life -= 0.05;
    }
    _scorePopups.removeWhere((s) => s.life <= 0);

    // Update Falling Meanings
    for (final b in _fallingMeanings) {
      b.vy += 0.0012;
      b.y += b.vy;
      b.life -= 0.035;
    }
    _fallingMeanings.removeWhere((b) => b.life <= 0 || b.y > 1.05);

    if (!_ballInPlay || _isPlayerDying) {
      setState(() {});
      return;
    }

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
        _ballVx = paddleDist * 0.12;
      }
    }

    // Ball Drop
    if (_ballY > 0.96) {
      final random = Random();
      _lives--;
      _screenFlashOpacity = 0.45;
      _screenShakeX = (random.nextBool() ? 1 : -1) * 8.0;
      _screenShakeY = (random.nextBool() ? 1 : -1) * 8.0;

      if (_lives > 0) {
        _resetBall();
      } else {
        _isPlayerDying = true;
        _spawnPaddleDeathExplosion(_paddleX, 0.86);

        Future.delayed(const Duration(milliseconds: 1400), () {
          if (mounted) {
            setState(() {
              _isGameOver = true;
              _isPlayerDying = false;
              _gameLoop?.cancel();
            });
          }
        });
      }
      setState(() {});
      return;
    }

    // Brick Collisions
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

        final brickCenterX = (brickLeft + brickRight) / 2;
        final brickCenterY = (brickTop + brickBottom) / 2;

        if (brick.isTarget) {
          _score += 300;
          _boardsCleared++;
          _speakWord(brick.word);
          _spawnBrickDebris(
            brickCenterX,
            brickCenterY,
            isTarget: true,
            text: '+300! 🧱',
          );
          _spawnFallingMeaning(
            brickCenterX,
            brickCenterY,
            _currentTargetWord?.meaning ?? '',
          );
          _spawnBricks();
          return;
        } else {
          _score += 50;
          _spawnBrickDebris(
            brickCenterX,
            brickCenterY,
            isTarget: false,
            text: '+50',
          );
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

        // Breakout Court with Screen Shake
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: PixelMetrics.space3),
            child: Transform.translate(
              offset: Offset(_screenShakeX, _screenShakeY),
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
                        if (!_isPlayerDying) {
                          setState(() {
                            _paddleX = (_paddleX + (details.delta.dx / w)).clamp(0.15, 0.85);
                            if (!_ballInPlay) _ballX = _paddleX;
                          });
                        }
                      },
                      onTapUp: (_) => _launchBall(),
                      child: Stack(
                        children: [
                          // Red Screen Flash
                          if (_screenFlashOpacity > 0.01)
                            Positioned.fill(
                              child: IgnorePointer(
                                child: Container(
                                  color: palette.danger.withValues(
                                    alpha: _screenFlashOpacity.clamp(0.0, 0.5),
                                  ),
                                ),
                              ),
                            ),

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
                          if (!_isPlayerDying)
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
                          if (!_isPlayerDying)
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

                          // Debris Particles
                          for (final p in _particles)
                            Positioned(
                              left: (p.x * w) - (p.size / 2),
                              top: (p.y * h) - (p.size / 2),
                              child: Opacity(
                                opacity: p.life.clamp(0.0, 1.0),
                                child: Container(
                                  width: p.size,
                                  height: p.size,
                                  decoration: BoxDecoration(
                                    color: p.color,
                                    border: Border.all(
                                      color: palette.border.withValues(
                                        alpha: p.life.clamp(0.0, 1.0),
                                      ),
                                      width: 0.5,
                                    ),
                                  ),
                                ),
                              ),
                            ),

                          // Floating Score Popups
                          for (final s in _scorePopups)
                            Positioned(
                              left: ((s.x * w) - 45).clamp(8.0, w - 90.0),
                              top: s.y * h,
                              child: Opacity(
                                opacity: s.life.clamp(0.0, 1.0),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: palette.paper,
                                    border: Border.all(color: s.color, width: 1.5),
                                    boxShadow: [
                                      BoxShadow(
                                        color: palette.border.withValues(alpha: 0.3),
                                        offset: const Offset(1, 1),
                                        blurRadius: 0,
                                      ),
                                    ],
                                  ),
                                  child: Text(
                                    s.text,
                                    style: TextStyle(
                                      fontFamily: 'Handjet',
                                      fontSize: 13,
                                      fontWeight: FontWeight.bold,
                                      color: s.color,
                                      height: 1.0,
                                    ),
                                  ),
                                ),
                              ),
                            ),

                          // Falling Vietnamese Meaning (drops to bottom with gravity)
                          for (final b in _fallingMeanings)
                            Positioned(
                              left: ((b.x * w) - 50).clamp(8.0, w - 100.0),
                              top: b.y * h,
                              child: Opacity(
                                opacity: b.life.clamp(0.0, 1.0),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 3,
                                  ),
                                  decoration: BoxDecoration(
                                    color: palette.paper,
                                    border: Border.all(
                                      color: palette.accent,
                                      width: 1.5,
                                    ),
                                    boxShadow: [
                                      BoxShadow(
                                        color: palette.accent.withValues(alpha: 0.3),
                                        offset: const Offset(1, 2),
                                        blurRadius: 0,
                                      ),
                                    ],
                                  ),
                                  child: Text(
                                    b.meaning,
                                    style: TextStyle(
                                      fontFamily: 'Handjet',
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                      color: palette.ink,
                                      height: 1.0,
                                    ),
                                  ),
                                ),
                              ),
                            ),

                          // Launch Prompt
                          if (!_ballInPlay && !_isPlayerDying)
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
                                    'TAP OR PRESS LAUNCH TO PLAY',
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
        ),

        const SizedBox(height: PixelMetrics.space3),

        // Ergonomic Two-Handed Controls (Guaranteed zero-overflow)
        Padding(
          padding: const EdgeInsets.fromLTRB(
            PixelMetrics.space3,
            0,
            PixelMetrics.space3,
            PixelMetrics.space3,
          ),
          child: Row(
            children: [
              // Left Thumb: Paddle Movement
              _BreakoutTouchButton(
                glyph: PixelGlyph.arrowLeft,
                label: '◀',
                semanticLabel: 'Move Paddle Left',
                onAction: () => _movePaddle(-0.06),
              ),
              const SizedBox(width: PixelMetrics.space2),
              _BreakoutTouchButton(
                glyph: PixelGlyph.arrowRight,
                label: '▶',
                semanticLabel: 'Move Paddle Right',
                onAction: () => _movePaddle(0.06),
              ),

              const Spacer(),

              // Right Thumb: Big Launch Button
              _BreakoutLaunchButton(
                glyph: PixelGlyph.brick,
                label: _ballInPlay ? 'IN PLAY ⚪' : 'LAUNCH ⚪',
                isBallInPlay: _ballInPlay,
                onLaunch: _launchBall,
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

class _BreakoutTouchButton extends StatefulWidget {
  const _BreakoutTouchButton({
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
  State<_BreakoutTouchButton> createState() => _BreakoutTouchButtonState();
}

class _BreakoutTouchButtonState extends State<_BreakoutTouchButton> {
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

class _BreakoutLaunchButton extends StatelessWidget {
  const _BreakoutLaunchButton({
    required this.glyph,
    required this.label,
    required this.isBallInPlay,
    required this.onLaunch,
  });

  final PixelGlyph glyph;
  final String label;
  final bool isBallInPlay;
  final VoidCallback onLaunch;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    return GestureDetector(
      onTap: onLaunch,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        decoration: BoxDecoration(
          color: isBallInPlay ? palette.surface : palette.accent,
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
              color: isBallInPlay ? palette.inkFaint : palette.onAccent,
              scale: 2.0,
            ),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                fontFamily: 'Handjet',
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: isBallInPlay ? palette.inkFaint : palette.onAccent,
                letterSpacing: 0.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
