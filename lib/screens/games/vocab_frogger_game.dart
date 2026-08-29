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

class RiverLog {
  RiverLog({
    required this.x,
    required this.lane,
    required this.width,
    required this.speed,
    required this.word,
    required this.isTarget,
  });

  double x; // 0.0 to 1.0
  final int lane; // 0 or 1
  final double width;
  final double speed;
  final String word;
  final bool isTarget;
}

class RoadCar {
  RoadCar({
    required this.x,
    required this.lane,
    required this.speed,
  });

  double x;
  final int lane;
  final double speed;
}

/// 8-Bit Frogger / Traffic & River Crossing for Vocabulary Practice.
class VocabFroggerGame extends StatefulWidget {
  const VocabFroggerGame({super.key});

  @override
  State<VocabFroggerGame> createState() => _VocabFroggerGameState();
}

class _VocabFroggerGameState extends State<VocabFroggerGame> {
  final FocusNode _focusNode = FocusNode();
  List<VocabularyWord> _deck = [];
  bool _isLoading = true;

  Timer? _gameLoop;
  VocabularyWord? _currentTargetWord;

  // Frog position: lane 0 = Goal (top), 1 & 2 = River, 3 = Median, 4 & 5 = Road, 6 = Start (bottom)
  int _frogLane = 6;
  double _frogX = 0.5; // 0.0 to 1.0

  List<RiverLog> _logs = [];
  List<RoadCar> _cars = [];

  int _score = 0;
  int _crossings = 0;
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
      _crossings = 0;
      _lives = 3;
      _isGameOver = false;
      _frogLane = 6;
      _frogX = 0.5;
    });

    _spawnLevel();
    _startGameLoop();
  }

  void _startGameLoop() {
    _gameLoop?.cancel();
    _gameLoop = Timer.periodic(const Duration(milliseconds: 50), (_) {
      _tick();
    });
  }

  void _spawnLevel() {
    if (_deck.isEmpty) return;
    final random = Random();
    final target = _deck[random.nextInt(_deck.length)];

    final distractors = _deck
        .where((w) => w.id != target.id)
        .map((w) => w.word)
        .toSet()
        .toList()
      ..shuffle();

    final targetLane = random.nextInt(2); // 0 or 1
    final logs = <RiverLog>[];

    // Lane 1 logs (top river lane)
    logs.add(
      RiverLog(
        x: 0.2,
        lane: 1,
        width: 0.35,
        speed: 0.008,
        word: targetLane == 0 ? target.word : (distractors.isNotEmpty ? distractors[0] : target.word),
        isTarget: targetLane == 0,
      ),
    );
    logs.add(
      RiverLog(
        x: 0.7,
        lane: 1,
        width: 0.35,
        speed: 0.008,
        word: targetLane == 0 && distractors.isNotEmpty ? distractors[0] : target.word,
        isTarget: targetLane != 0,
      ),
    );

    // Lane 2 logs (bottom river lane)
    logs.add(
      RiverLog(
        x: 0.3,
        lane: 2,
        width: 0.35,
        speed: -0.010,
        word: targetLane == 1 ? target.word : (distractors.length > 1 ? distractors[1] : target.word),
        isTarget: targetLane == 1,
      ),
    );
    logs.add(
      RiverLog(
        x: 0.8,
        lane: 2,
        width: 0.35,
        speed: -0.010,
        word: targetLane == 1 && distractors.length > 1 ? distractors[1] : target.word,
        isTarget: targetLane != 1,
      ),
    );

    // Road Cars
    final cars = <RoadCar>[
      RoadCar(x: 0.1, lane: 4, speed: 0.014),
      RoadCar(x: 0.6, lane: 4, speed: 0.014),
      RoadCar(x: 0.3, lane: 5, speed: -0.016),
      RoadCar(x: 0.8, lane: 5, speed: -0.016),
    ];

    setState(() {
      _currentTargetWord = target;
      _logs = logs;
      _cars = cars;
      _frogLane = 6;
      _frogX = 0.5;
    });
  }

  void _hop(int dLane, double dX) {
    if (_isGameOver) return;
    setState(() {
      _frogLane = (_frogLane + dLane).clamp(0, 6);
      _frogX = (_frogX + dX).clamp(0.08, 0.92);
    });

    // Check if reached Goal
    if (_frogLane == 0) {
      _score += 250;
      _crossings++;
      _spawnLevel();
    }
  }

  void _tick() {
    if (_isGameOver) return;

    // Move Logs
    for (final log in _logs) {
      log.x += log.speed;
      if (log.x > 1.2) log.x = -0.3;
      if (log.x < -0.3) log.x = 1.2;
    }

    // Move Cars
    for (final car in _cars) {
      car.x += car.speed;
      if (car.x > 1.2) car.x = -0.2;
      if (car.x < -0.2) car.x = 1.2;
    }

    // If frog is on River (lanes 1 or 2): must be standing on a log!
    if (_frogLane == 1 || _frogLane == 2) {
      RiverLog? standingOn;
      for (final log in _logs) {
        if (log.lane == _frogLane) {
          if (_frogX >= log.x && _frogX <= (log.x + log.width)) {
            standingOn = log;
            break;
          }
        }
      }

      if (standingOn != null) {
        // Frog drifts with log
        _frogX += standingOn.speed;
        if (_frogX < 0.04 || _frogX > 0.96) {
          _handleDrown();
          return;
        }
      } else {
        // Fell in river
        _handleDrown();
        return;
      }
    }

    // If frog is on Road (lanes 4 or 5): check car collision
    if (_frogLane == 4 || _frogLane == 5) {
      for (final car in _cars) {
        if (car.lane == _frogLane) {
          if ((_frogX - car.x).abs() < 0.09) {
            _handleCrash();
            return;
          }
        }
      }
    }

    setState(() {});
  }

  void _handleDrown() {
    setState(() {
      _lives--;
      if (_lives > 0) {
        _frogLane = 6;
        _frogX = 0.5;
      } else {
        _isGameOver = true;
        _gameLoop?.cancel();
      }
    });
  }

  void _handleCrash() {
    setState(() {
      _lives--;
      if (_lives > 0) {
        _frogLane = 6;
        _frogX = 0.5;
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
        _hop(-1, 0);
        break;
      case LogicalKeyboardKey.arrowDown:
      case LogicalKeyboardKey.keyS:
        _hop(1, 0);
        break;
      case LogicalKeyboardKey.arrowLeft:
      case LogicalKeyboardKey.keyA:
        _hop(0, -0.1);
        break;
      case LogicalKeyboardKey.arrowRight:
      case LogicalKeyboardKey.keyD:
        _hop(0, 0.1);
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
                    ? const Center(child: Text('LOADING CROSSING…'))
                    : _isGameOver
                    ? _buildGameOver(context)
                    : _buildLanes(context),
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
            semanticLabel: 'Exit Frogger',
            onPressed: () => Navigator.of(context).pop(),
          ),
          const SizedBox(width: PixelMetrics.space2),
          Text('VOCAB FROGGER', style: Theme.of(context).textTheme.titleMedium),
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

  Widget _buildLanes(BuildContext context) {
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
                'HOP ACROSS TARGET WORD LOGS:',
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

        // Traffic & River Crossing Board
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
                    if (v < -60) _hop(-1, 0);
                    if (v > 60) _hop(1, 0);
                  }
                },
                onHorizontalDragEnd: (details) {
                  final v = details.primaryVelocity;
                  if (v != null) {
                    if (v < -60) _hop(0, -0.12);
                    if (v > 60) _hop(0, 0.12);
                  }
                },
                child: Container(
                  decoration: BoxDecoration(
                    color: palette.surface,
                    border: Border.all(color: palette.border, width: PixelMetrics.border),
                  ),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final w = constraints.maxWidth;
                      final laneHeight = constraints.maxHeight / 7;

                      return Stack(
                        children: [
                          // Lane 0: Goal Dock (Grass)
                          Positioned(
                            top: 0,
                            left: 0,
                            right: 0,
                            height: laneHeight,
                            child: Container(
                              color: palette.accent.withValues(alpha: 0.3),
                              child: const Center(
                                child: Text(
                                  '⭐ SAFE ZONE ⭐',
                                  style: TextStyle(
                                    fontFamily: 'Handjet',
                                    fontWeight: FontWeight.bold,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                            ),
                          ),

                          // Lanes 1 & 2: River
                          Positioned(
                            top: laneHeight,
                            left: 0,
                            right: 0,
                            height: laneHeight * 2,
                            child: Container(
                              color: palette.inkFaint.withValues(alpha: 0.15),
                            ),
                          ),

                          // Lane 3: Median Sidewalk
                          Positioned(
                            top: laneHeight * 3,
                            left: 0,
                            right: 0,
                            height: laneHeight,
                            child: Container(
                              decoration: BoxDecoration(
                                color: palette.surface,
                                border: Border.symmetric(
                                  horizontal: BorderSide(
                                    color: palette.border,
                                    width: 1,
                                  ),
                                ),
                              ),
                            ),
                          ),

                          // Lanes 4 & 5: Highway
                          Positioned(
                            top: laneHeight * 4,
                            left: 0,
                            right: 0,
                            height: laneHeight * 2,
                            child: Container(
                              color: palette.ink.withValues(alpha: 0.1),
                            ),
                          ),

                          // Lane 6: Start Sidewalk
                          Positioned(
                            top: laneHeight * 6,
                            left: 0,
                            right: 0,
                            height: laneHeight,
                            child: Container(color: palette.surface),
                          ),

                          // River Logs
                          for (final log in _logs)
                            Positioned(
                              left: log.x * w,
                              top: log.lane * laneHeight + 4,
                              width: log.width * w,
                              height: laneHeight - 8,
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 4),
                                decoration: BoxDecoration(
                                  color: log.isTarget
                                      ? palette.accent
                                      : palette.surface,
                                  border: Border.all(
                                    color: palette.border,
                                    width: 1.5,
                                  ),
                                ),
                                child: Center(
                                  child: Text(
                                    log.word.toUpperCase(),
                                    style: TextStyle(
                                      fontFamily: 'Handjet',
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                      color: log.isTarget
                                          ? palette.onAccent
                                          : palette.ink,
                                      height: 1.0,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ),
                            ),

                          // Road Cars
                          for (final car in _cars)
                            Positioned(
                              left: car.x * w,
                              top: car.lane * laneHeight + 8,
                              width: 32,
                              height: laneHeight - 16,
                              child: Container(
                                decoration: BoxDecoration(
                                  color: palette.danger,
                                  border: Border.all(
                                    color: palette.border,
                                    width: 1,
                                  ),
                                ),
                              ),
                            ),

                          // Frog
                          Positioned(
                            left: (_frogX * w) - 12,
                            top: _frogLane * laneHeight + (laneHeight - 24) / 2,
                            width: 24,
                            height: 24,
                            child: Center(
                              child: PixelIcon(
                                PixelGlyph.frog,
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
              child: _dPadBtn(PixelGlyph.arrowLeft, () => _hop(-1, 0), isUp: true),
            ),
            Positioned(
              bottom: 0,
              child: _dPadBtn(PixelGlyph.arrowRight, () => _hop(1, 0), isDown: true),
            ),
            Positioned(
              left: 0,
              child: _dPadBtn(PixelGlyph.arrowLeft, () => _hop(0, -0.12)),
            ),
            Positioned(
              right: 0,
              child: _dPadBtn(PixelGlyph.arrowRight, () => _hop(0, 0.12)),
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
                '☠ HOP OVER ☠',
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
                  Text('CROSSINGS', style: theme.textTheme.labelSmall),
                  const Spacer(),
                  Text('$_crossings', style: theme.textTheme.titleMedium),
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
