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

enum Direction { up, down, left, right }

class FoodPellet {
  const FoodPellet({
    required this.position,
    required this.word,
    required this.isCorrect,
  });

  final Point<int> position;
  final String word;
  final bool isCorrect;
}

class SnakeFallingMeaning {
  SnakeFallingMeaning({
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

/// 8-Bit Vocab Snake / Nibbler Game.
class VocabSnakeGame extends StatefulWidget {
  const VocabSnakeGame({super.key});

  @override
  State<VocabSnakeGame> createState() => _VocabSnakeGameState();
}

class _VocabSnakeGameState extends State<VocabSnakeGame> {
  static const int _gridSize = 16;
  final FocusNode _focusNode = FocusNode();

  List<VocabularyWord> _deck = [];
  bool _isLoading = true;

  List<Point<int>> _snake = [];
  int _pendingGrowth = 0;
  Direction _direction = Direction.right;
  Direction _nextDirection = Direction.right;
  Timer? _gameLoop;

  VocabularyWord? _currentTargetWord;
  List<FoodPellet> _foodPellets = [];
  List<SnakeFallingMeaning> _fallingMeanings = [];

  int _score = 0;
  int _wordsEaten = 0;
  int _hearts = 3;
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
      _wordsEaten = 0;
      _hearts = 3;
      _pendingGrowth = 0;
      _isGameOver = false;
      _direction = Direction.right;
      _nextDirection = Direction.right;
      _fallingMeanings = [];
      _snake = [
        const Point(5, 8),
        const Point(4, 8),
        const Point(3, 8),
      ];
    });

    _spawnNewTargetAndPellets();
    _startGameLoop();
  }

  void _startGameLoop() {
    _gameLoop?.cancel();
    _gameLoop = Timer.periodic(const Duration(milliseconds: 230), (_) {
      _tick();
    });
  }

  void _spawnNewTargetAndPellets() {
    if (_deck.isEmpty) return;
    final random = Random();
    final target = _deck[random.nextInt(_deck.length)];

    final distractors = _deck
        .where((w) => w.id != target.id)
        .map((w) => w.word)
        .toSet()
        .toList()
      ..shuffle();

    final pelletWords = <({String word, bool isCorrect})>[
      (word: target.word, isCorrect: true),
    ];
    for (var i = 0; i < 2 && i < distractors.length; i++) {
      pelletWords.add((word: distractors[i], isCorrect: false));
    }
    pelletWords.shuffle();

    final occupied = Set<Point<int>>.from(_snake);
    final chosenPositions = <Point<int>>[];

    for (var i = 0; i < pelletWords.length; i++) {
      Point<int> pos;
      var attempts = 0;
      do {
        pos = Point(
          1 + random.nextInt(_gridSize - 2),
          1 + random.nextInt(_gridSize - 2),
        );
        attempts++;
      } while ((occupied.contains(pos) ||
              chosenPositions.any((p) => (p.x - pos.x).abs() < 3 && (p.y - pos.y).abs() < 3)) &&
          attempts < 100);

      chosenPositions.add(pos);
      occupied.add(pos);
    }

    final newPellets = <FoodPellet>[];
    for (var i = 0; i < pelletWords.length; i++) {
      newPellets.add(
        FoodPellet(
          position: chosenPositions[i],
          word: pelletWords[i].word,
          isCorrect: pelletWords[i].isCorrect,
        ),
      );
    }

    setState(() {
      _currentTargetWord = target;
      _foodPellets = newPellets;
    });
  }

  void _changeDirection(Direction newDir) {
    if (_direction == Direction.up && newDir == Direction.down) return;
    if (_direction == Direction.down && newDir == Direction.up) return;
    if (_direction == Direction.left && newDir == Direction.right) return;
    if (_direction == Direction.right && newDir == Direction.left) return;
    _nextDirection = newDir;
  }

  void _tick() {
    if (_isGameOver || _snake.isEmpty) return;

    _direction = _nextDirection;
    final head = _snake.first;
    Point<int> newHead;

    switch (_direction) {
      case Direction.up:
        newHead = Point(head.x, head.y - 1);
        break;
      case Direction.down:
        newHead = Point(head.x, head.y + 1);
        break;
      case Direction.left:
        newHead = Point(head.x - 1, head.y);
        break;
      case Direction.right:
        newHead = Point(head.x + 1, head.y);
        break;
    }

    // Update Falling Vietnamese Meanings
    for (final b in _fallingMeanings) {
      b.vy += 0.0012;
      b.y += b.vy;
      b.life -= 0.035;
    }
    _fallingMeanings.removeWhere((b) => b.life <= 0 || b.y > 1.05);

    // Wall Collision
    if (newHead.x < 0 ||
        newHead.x >= _gridSize ||
        newHead.y < 0 ||
        newHead.y >= _gridSize) {
      _handleCollision();
      return;
    }

    // Self Collision
    if (_snake.contains(newHead)) {
      _handleCollision();
      return;
    }

    // Food Collision
    FoodPellet? eatenPellet;
    for (final pellet in _foodPellets) {
      if (pellet.position == newHead) {
        eatenPellet = pellet;
        break;
      }
    }

    if (eatenPellet != null) {
      if (eatenPellet.isCorrect) {
        _wordsEaten++;
        _score += 150;
        _pendingGrowth += 2;
        _snake.insert(0, newHead);

        _speakWord(eatenPellet.word);
        _fallingMeanings.add(
          SnakeFallingMeaning(
            x: (eatenPellet.position.x + 0.5) / _gridSize,
            y: (eatenPellet.position.y + 0.5) / _gridSize,
            meaning: _currentTargetWord?.meaning ?? '',
          ),
        );

        _spawnNewTargetAndPellets();
      } else {
        _handleCollision();
      }
    } else {
      _snake.insert(0, newHead);
      if (_pendingGrowth > 0) {
        _pendingGrowth--;
      } else {
        _snake.removeLast();
      }
    }

    setState(() {});
  }

  void _handleCollision() {
    setState(() {
      _hearts--;
      _pendingGrowth = 0;
      if (_hearts > 0) {
        _snake = [
          const Point(5, 8),
          const Point(4, 8),
          const Point(3, 8),
        ];
        _direction = Direction.right;
        _nextDirection = Direction.right;
        _spawnNewTargetAndPellets();
      } else {
        _isGameOver = true;
        _gameLoop?.cancel();
      }
    });
  }

  void _handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return;
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowUp:
      case LogicalKeyboardKey.keyW:
        _changeDirection(Direction.up);
        break;
      case LogicalKeyboardKey.arrowDown:
      case LogicalKeyboardKey.keyS:
        _changeDirection(Direction.down);
        break;
      case LogicalKeyboardKey.arrowLeft:
      case LogicalKeyboardKey.keyA:
        _changeDirection(Direction.left);
        break;
      case LogicalKeyboardKey.arrowRight:
      case LogicalKeyboardKey.keyD:
        _changeDirection(Direction.right);
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    return KeyboardListener(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
      child: Scaffold(
        backgroundColor: palette.paper,
        body: SafeArea(
          child: Column(
            children: [
              _buildTopBar(context),
              Expanded(
                child: _isLoading
                    ? const Center(child: Text('PREPARING ARENA…'))
                    : _isGameOver
                    ? _buildGameOver(context)
                    : _buildGameBoard(context),
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
            semanticLabel: 'Exit Snake',
            onPressed: () => Navigator.of(context).pop(),
          ),
          const SizedBox(width: PixelMetrics.space2),
          Text(
            'VOCAB SNAKE',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const Spacer(),
          Row(
            children: List.generate(3, (i) {
              final isFull = i < _hearts;
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

  Widget _buildGameBoard(BuildContext context) {
    final palette = context.palette;
    final theme = Theme.of(context);

    return Column(
      children: [
        // Target Meaning HUD Banner
        Container(
          width: double.infinity,
          margin: const EdgeInsets.all(PixelMetrics.space3),
          padding: const EdgeInsets.symmetric(
            horizontal: PixelMetrics.space3,
            vertical: PixelMetrics.space2,
          ),
          decoration: BoxDecoration(
            color: palette.surface,
            border: Border.all(
              color: palette.border,
              width: PixelMetrics.border,
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'STEER SNAKE TO EAT:',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: palette.inkFaint,
                        fontSize: 10,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '"${_currentTargetWord?.meaning ?? ''}"',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: palette.accent,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: palette.paper,
                  border: Border.all(color: palette.border, width: 1),
                ),
                child: Text(
                  'LEN: ${_snake.length}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
        ),

        // 16x16 Game Board
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: PixelMetrics.space3),
            child: AspectRatio(
              aspectRatio: 1.0,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onVerticalDragEnd: (details) {
                  final v = details.primaryVelocity;
                  if (v != null) {
                    if (v < -60) _changeDirection(Direction.up);
                    if (v > 60) _changeDirection(Direction.down);
                  }
                },
                onHorizontalDragEnd: (details) {
                  final v = details.primaryVelocity;
                  if (v != null) {
                    if (v < -60) _changeDirection(Direction.left);
                    if (v > 60) _changeDirection(Direction.right);
                  }
                },
                child: Container(
                  decoration: BoxDecoration(
                    color: palette.surface,
                    border: Border.all(
                      color: palette.border,
                      width: PixelMetrics.border,
                    ),
                  ),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final cellSize = constraints.maxWidth / _gridSize;
                      final w = constraints.maxWidth;
                      final h = constraints.maxHeight;

                      return Stack(
                        clipBehavior: Clip.none,
                        children: [
                          // Snake Body & Head
                          for (var i = 0; i < _snake.length; i++)
                            Positioned(
                              left: _snake[i].x * cellSize,
                              top: _snake[i].y * cellSize,
                              width: cellSize,
                              height: cellSize,
                              child: Container(
                                margin: const EdgeInsets.all(1),
                                decoration: BoxDecoration(
                                  color: i == 0 ? palette.accent : palette.ink,
                                  border: Border.all(color: palette.border, width: 0.5),
                                ),
                              ),
                            ),

                          // Food Pellets (Red Dots)
                          for (final pellet in _foodPellets)
                            Positioned(
                              left: pellet.position.x * cellSize,
                              top: pellet.position.y * cellSize,
                              width: cellSize,
                              height: cellSize,
                              child: Center(
                                child: Container(
                                  width: cellSize * 0.75,
                                  height: cellSize * 0.75,
                                  decoration: BoxDecoration(
                                    color: palette.danger,
                                    border: Border.all(color: palette.border, width: 1),
                                  ),
                                  child: Center(
                                    child: Container(
                                      width: 3,
                                      height: 3,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                              ),
                            ),

                          // English Word Labels
                          for (final pellet in _foodPellets)
                            Positioned(
                              left: ((pellet.position.x + 0.5) * cellSize)
                                  .clamp(36.0, constraints.maxWidth - 36.0),
                              top: pellet.position.y >= 2
                                  ? (pellet.position.y * cellSize) - 18
                                  : ((pellet.position.y + 1) * cellSize) + 2,
                              child: FractionalTranslation(
                                translation: const Offset(-0.5, 0),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 4,
                                    vertical: 1,
                                  ),
                                  decoration: BoxDecoration(
                                    color: palette.paper,
                                    border: Border.all(
                                      color: palette.border,
                                      width: 1,
                                    ),
                                    boxShadow: [
                                      BoxShadow(
                                        color: palette.border.withValues(alpha: 0.5),
                                        offset: const Offset(1, 1),
                                        blurRadius: 0,
                                      ),
                                    ],
                                  ),
                                  child: Text(
                                    pellet.word.toUpperCase(),
                                    style: TextStyle(
                                      fontFamily: 'Handjet',
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                      color: palette.ink,
                                      height: 1.0,
                                    ),
                                  ),
                                ),
                              ),
                            ),

                          // Falling Vietnamese Meanings
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
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ),

        const SizedBox(height: PixelMetrics.space2),

        // Spacious D-Pad Controls
        _buildDPad(context),
      ],
    );
  }

  Widget _buildDPad(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: PixelMetrics.space3),
      child: SizedBox(
        width: 220,
        height: 150,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Positioned(
              top: 0,
              child: _dPadButton(Direction.up, PixelGlyph.arrowUp),
            ),
            Positioned(
              bottom: 0,
              child: _dPadButton(Direction.down, PixelGlyph.arrowDown),
            ),
            Positioned(
              left: 0,
              child: _dPadButton(Direction.left, PixelGlyph.arrowLeft),
            ),
            Positioned(
              right: 0,
              child: _dPadButton(Direction.right, PixelGlyph.arrowRight),
            ),
          ],
        ),
      ),
    );
  }

  Widget _dPadButton(Direction dir, PixelGlyph glyph) {
    final palette = context.palette;
    return GestureDetector(
      onTapDown: (_) => _changeDirection(dir),
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 64,
        height: 48,
        decoration: BoxDecoration(
          color: palette.surface,
          border: Border.all(color: palette.border, width: PixelMetrics.border),
          boxShadow: [
            BoxShadow(
              color: palette.border.withValues(alpha: 0.5),
              offset: const Offset(1, 2),
              blurRadius: 0,
            ),
          ],
        ),
        child: Center(
          child: PixelIcon(glyph, color: palette.ink, scale: 2.4),
        ),
      ),
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
                '☠ GAME OVER ☠',
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
                  Text('WORDS EATEN', style: theme.textTheme.labelSmall),
                  const Spacer(),
                  Text('$_wordsEaten', style: theme.textTheme.titleMedium),
                ],
              ),
              const SizedBox(height: PixelMetrics.space2),
              Row(
                children: [
                  Text('SNAKE LENGTH', style: theme.textTheme.labelSmall),
                  const Spacer(),
                  Text('${_snake.length}', style: theme.textTheme.titleMedium),
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
