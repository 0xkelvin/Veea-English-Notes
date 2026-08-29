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

class WordPellet {
  const WordPellet({
    required this.x,
    required this.y,
    required this.word,
    required this.isTarget,
  });

  final int x;
  final int y;
  final String word;
  final bool isTarget;
}

class GhostMonster {
  GhostMonster({
    required this.x,
    required this.y,
    required this.color,
  });

  int x;
  int y;
  final Color color;
}

/// 8-Bit Pac-Man / Maze Chomp Game for Vocabulary Practice.
class VocabChompGame extends StatefulWidget {
  const VocabChompGame({super.key});

  @override
  State<VocabChompGame> createState() => _VocabChompGameState();
}

class _VocabChompGameState extends State<VocabChompGame> {
  static const int _gridSize = 13;
  final FocusNode _focusNode = FocusNode();
  List<VocabularyWord> _deck = [];
  bool _isLoading = true;

  Timer? _gameLoop;
  VocabularyWord? _currentTargetWord;

  // Maze layout (1 = Wall, 0 = Corridor)
  static const List<List<int>> _maze = [
    [1,1,1,1,1,1,1,1,1,1,1,1,1],
    [1,0,0,0,0,0,1,0,0,0,0,0,1],
    [1,0,1,1,0,1,1,1,0,1,1,0,1],
    [1,0,1,1,0,0,0,0,0,1,1,0,1],
    [1,0,0,0,0,1,1,1,0,0,0,0,1],
    [1,1,0,1,0,0,0,0,0,1,0,1,1],
    [0,0,0,1,0,1,0,1,0,1,0,0,0],
    [1,1,0,1,0,0,0,0,0,1,0,1,1],
    [1,0,0,0,0,1,1,1,0,0,0,0,1],
    [1,0,1,1,0,0,0,0,0,1,1,0,1],
    [1,0,1,1,0,1,1,1,0,1,1,0,1],
    [1,0,0,0,0,0,1,0,0,0,0,0,1],
    [1,1,1,1,1,1,1,1,1,1,1,1,1],
  ];

  int _playerX = 6;
  int _playerY = 9;
  int _dirX = 1;
  int _dirY = 0;
  int _nextDirX = 1;
  int _nextDirY = 0;

  List<WordPellet> _wordPellets = [];
  List<GhostMonster> _ghosts = [];
  Set<Point<int>> _pacDots = {};
  Point<int>? _powerPellet;
  int _powerTimer = 0;

  int _score = 0;
  int _mazesCleared = 0;
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
      _mazesCleared = 0;
      _lives = 3;
      _isGameOver = false;
    });

    _spawnMaze();
    _startGameLoop();
  }

  void _startGameLoop() {
    _gameLoop?.cancel();
    _gameLoop = Timer.periodic(const Duration(milliseconds: 220), (_) {
      _tick();
    });
  }

  void _spawnMaze() {
    if (_deck.isEmpty) return;
    final random = Random();
    final target = _deck[random.nextInt(_deck.length)];

    final distractors = _deck
        .where((w) => w.id != target.id)
        .map((w) => w.word)
        .toSet()
        .toList()
      ..shuffle();

    // Populate pac-dots in corridors
    final dots = <Point<int>>{};
    for (var r = 0; r < _gridSize; r++) {
      for (var c = 0; c < _gridSize; c++) {
        if (_maze[r][c] == 0) dots.add(Point(c, r));
      }
    }

    // 3 Word Pellets in open nodes
    final corners = [
      const Point(1, 1),
      const Point(11, 1),
      const Point(1, 11),
    ];
    final words = <({String word, bool isTarget})>[
      (word: target.word, isTarget: true),
      (word: distractors.isNotEmpty ? distractors[0] : target.word, isTarget: false),
      (word: distractors.length > 1 ? distractors[1] : target.word, isTarget: false),
    ]..shuffle();

    final pellets = <WordPellet>[];
    for (var i = 0; i < 3; i++) {
      final p = corners[i];
      dots.remove(p);
      pellets.add(
        WordPellet(
          x: p.x,
          y: p.y,
          word: words[i].word,
          isTarget: words[i].isTarget,
        ),
      );
    }

    // Power Pellet at (11, 11)
    const pPower = Point(11, 11);
    dots.remove(pPower);

    setState(() {
      _currentTargetWord = target;
      _pacDots = dots;
      _wordPellets = pellets;
      _powerPellet = pPower;
      _powerTimer = 0;
      _playerX = 6;
      _playerY = 9;
      _dirX = 1;
      _dirY = 0;
      _nextDirX = 1;
      _nextDirY = 0;
      _ghosts = [
        GhostMonster(x: 5, y: 5, color: Colors.redAccent),
        GhostMonster(x: 7, y: 5, color: Colors.pinkAccent),
      ];
    });
  }

  void _setDirection(int dx, int dy) {
    _nextDirX = dx;
    _nextDirY = dy;
  }

  void _tick() {
    if (_isGameOver) return;

    if (_powerTimer > 0) _powerTimer--;

    // Try next direction
    final nextX = (_playerX + _nextDirX) % _gridSize;
    final nextY = (_playerY + _nextDirY) % _gridSize;
    if (_isWalkable(nextX, nextY)) {
      _dirX = _nextDirX;
      _dirY = _nextDirY;
    }

    // Move Player
    final pX = (_playerX + _dirX) % _gridSize;
    final pY = (_playerY + _dirY) % _gridSize;
    if (_isWalkable(pX, pY)) {
      _playerX = pX;
      _playerY = pY;
    }

    // Eat Pac-Dot
    final playerPoint = Point(_playerX, _playerY);
    if (_pacDots.remove(playerPoint)) {
      _score += 10;
    }

    // Eat Power Pellet
    if (_powerPellet == playerPoint) {
      _powerPellet = null;
      _powerTimer = 25; // ~5.5 seconds
      _score += 50;
    }

    // Eat Word Pellet
    WordPellet? eatenPellet;
    for (final p in _wordPellets) {
      if (p.x == _playerX && p.y == _playerY) {
        eatenPellet = p;
        break;
      }
    }

    if (eatenPellet != null) {
      if (eatenPellet.isTarget) {
        _score += 300;
        _mazesCleared++;
        _spawnMaze();
        return;
      } else {
        _handleGhostCatch();
        return;
      }
    }

    // Move Ghosts
    final random = Random();
    for (final ghost in _ghosts) {
      final validMoves = <Point<int>>[];
      const dirs = [Point(0, -1), Point(0, 1), Point(-1, 0), Point(1, 0)];
      for (final d in dirs) {
        final gx = (ghost.x + d.x) % _gridSize;
        final gy = (ghost.y + d.y) % _gridSize;
        if (_isWalkable(gx, gy)) validMoves.add(Point(gx, gy));
      }

      if (validMoves.isNotEmpty) {
        final next = validMoves[random.nextInt(validMoves.length)];
        ghost.x = next.x;
        ghost.y = next.y;
      }

      // Check Ghost Collision
      if (ghost.x == _playerX && ghost.y == _playerY) {
        if (_powerTimer > 0) {
          // Eat Ghost!
          _score += 200;
          ghost.x = 6;
          ghost.y = 5;
        } else {
          _handleGhostCatch();
          return;
        }
      }
    }

    setState(() {});
  }

  bool _isWalkable(int x, int y) {
    if (x < 0 || x >= _gridSize || y < 0 || y >= _gridSize) return true;
    return _maze[y][x] == 0;
  }

  void _handleGhostCatch() {
    setState(() {
      _lives--;
      if (_lives > 0) {
        _playerX = 6;
        _playerY = 9;
        _dirX = 1;
        _dirY = 0;
        _ghosts = [
          GhostMonster(x: 5, y: 5, color: Colors.redAccent),
          GhostMonster(x: 7, y: 5, color: Colors.pinkAccent),
        ];
      } else {
        _isGameOver = true;
        _gameLoop?.cancel();
      }
    });
  }

  void _handleKey(KeyEvent event) {
    if (event is! KeyDownEvent) return;
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowUp:
      case LogicalKeyboardKey.keyW:
        _setDirection(0, -1);
        break;
      case LogicalKeyboardKey.arrowDown:
      case LogicalKeyboardKey.keyS:
        _setDirection(0, 1);
        break;
      case LogicalKeyboardKey.arrowLeft:
      case LogicalKeyboardKey.keyA:
        _setDirection(-1, 0);
        break;
      case LogicalKeyboardKey.arrowRight:
      case LogicalKeyboardKey.keyD:
        _setDirection(1, 0);
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
                    ? const Center(child: Text('LOADING MAZE…'))
                    : _isGameOver
                    ? _buildGameOver(context)
                    : _buildMaze(context),
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
            semanticLabel: 'Exit Chomp',
            onPressed: () => Navigator.of(context).pop(),
          ),
          const SizedBox(width: PixelMetrics.space2),
          Text('VOCAB CHOMP', style: Theme.of(context).textTheme.titleMedium),
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

  Widget _buildMaze(BuildContext context) {
    final palette = context.palette;
    final theme = Theme.of(context);

    return Column(
      children: [
        // Target Meaning HUD
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
                'CHOMP MATCHING ENGLISH WORD PELLET:',
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

        // 13x13 Maze Board
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
                    if (v < -60) _setDirection(0, -1);
                    if (v > 60) _setDirection(0, 1);
                  }
                },
                onHorizontalDragEnd: (details) {
                  final v = details.primaryVelocity;
                  if (v != null) {
                    if (v < -60) _setDirection(-1, 0);
                    if (v > 60) _setDirection(1, 0);
                  }
                },
                child: Container(
                  decoration: BoxDecoration(
                    color: palette.surface,
                    border: Border.all(color: palette.border, width: PixelMetrics.border),
                  ),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final cell = constraints.maxWidth / _gridSize;

                      return Stack(
                        clipBehavior: Clip.none,
                        children: [
                          // Walls
                          for (var r = 0; r < _gridSize; r++)
                            for (var c = 0; c < _gridSize; c++)
                              if (_maze[r][c] == 1)
                                Positioned(
                                  left: c * cell,
                                  top: r * cell,
                                  width: cell,
                                  height: cell,
                                  child: Container(
                                    decoration: BoxDecoration(
                                      color: palette.ink,
                                      border: Border.all(
                                        color: palette.border,
                                        width: 0.5,
                                      ),
                                    ),
                                  ),
                                ),

                          // Pac-Dots
                          for (final dot in _pacDots)
                            Positioned(
                              left: (dot.x * cell) + (cell / 2) - 2,
                              top: (dot.y * cell) + (cell / 2) - 2,
                              width: 4,
                              height: 4,
                              child: Container(
                                decoration: BoxDecoration(
                                  color: palette.inkFaint,
                                  shape: BoxShape.circle,
                                ),
                              ),
                            ),

                          // Power Pellet (Flashing IPA Gem)
                          if (_powerPellet != null)
                            Positioned(
                              left: (_powerPellet!.x * cell) + (cell / 2) - 5,
                              top: (_powerPellet!.y * cell) + (cell / 2) - 5,
                              width: 10,
                              height: 10,
                              child: Container(
                                decoration: BoxDecoration(
                                  color: palette.accent,
                                  shape: BoxShape.circle,
                                ),
                              ),
                            ),

                          // Word Pellets with attached floating labels
                          for (final p in _wordPellets) ...[
                            Positioned(
                              left: (p.x * cell) + 2,
                              top: (p.y * cell) + 2,
                              width: cell - 4,
                              height: cell - 4,
                              child: Container(
                                decoration: BoxDecoration(
                                  color: palette.danger,
                                  border: Border.all(color: palette.border, width: 1),
                                ),
                              ),
                            ),
                            Positioned(
                              left: ((p.x + 0.5) * cell).clamp(32.0, constraints.maxWidth - 32.0),
                              top: p.y >= 2 ? (p.y * cell) - 18 : ((p.y + 1) * cell) + 2,
                              child: FractionalTranslation(
                                translation: const Offset(-0.5, 0),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
                                  decoration: BoxDecoration(
                                    color: palette.paper,
                                    border: Border.all(color: palette.border, width: 1),
                                  ),
                                  child: Text(
                                    p.word.toUpperCase(),
                                    style: const TextStyle(
                                      fontFamily: 'Handjet',
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                      height: 1.0,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],

                          // Ghosts
                          for (final g in _ghosts)
                            Positioned(
                              left: g.x * cell,
                              top: g.y * cell,
                              width: cell,
                              height: cell,
                              child: Center(
                                child: PixelIcon(
                                  PixelGlyph.skull,
                                  color: _powerTimer > 0 ? Colors.blueAccent : g.color,
                                  scale: 2.0,
                                ),
                              ),
                            ),

                          // Player Chomp
                          Positioned(
                            left: _playerX * cell,
                            top: _playerY * cell,
                            width: cell,
                            height: cell,
                            child: Center(
                              child: PixelIcon(
                                PixelGlyph.pacman,
                                color: palette.accent,
                                scale: 2.2,
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

        // D-Pad Controller
        _buildDPad(context),
      ],
    );
  }

  Widget _buildDPad(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: PixelMetrics.space3),
      child: SizedBox(
        width: 200,
        height: 140,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Positioned(
              top: 0,
              child: _dPadBtn(PixelGlyph.arrowLeft, () => _setDirection(0, -1), isUp: true),
            ),
            Positioned(
              bottom: 0,
              child: _dPadBtn(PixelGlyph.arrowRight, () => _setDirection(0, 1), isDown: true),
            ),
            Positioned(
              left: 0,
              child: _dPadBtn(PixelGlyph.arrowLeft, () => _setDirection(-1, 0)),
            ),
            Positioned(
              right: 0,
              child: _dPadBtn(PixelGlyph.arrowRight, () => _setDirection(1, 0)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _dPadBtn(PixelGlyph glyph, VoidCallback onTap, {bool isUp = false, bool isDown = false}) {
    final palette = context.palette;
    return GestureDetector(
      onTapDown: (_) => onTap(),
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 58,
        height: 44,
        decoration: BoxDecoration(
          color: palette.surface,
          border: Border.all(color: palette.border, width: PixelMetrics.border),
          boxShadow: [
            BoxShadow(
              color: palette.border.withValues(alpha: 0.4),
              offset: const Offset(1, 1),
              blurRadius: 0,
            ),
          ],
        ),
        child: Center(
          child: RotatedBox(
            quarterTurns: isUp ? 1 : (isDown ? 3 : 0),
            child: PixelIcon(glyph, color: palette.ink, scale: 2.2),
          ),
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
                '☠ CHOMPED OUT ☠',
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
                  Text('MAZES CLEARED', style: theme.textTheme.labelSmall),
                  const Spacer(),
                  Text('$_mazesCleared', style: theme.textTheme.titleMedium),
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
