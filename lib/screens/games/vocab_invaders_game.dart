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

class AlienShip {
  AlienShip({
    required this.x,
    required this.y,
    required this.word,
    required this.isCorrect,
  });

  double x; // 0.0 to 1.0
  double y; // 0.0 (top) to 1.0 (bottom)
  final String word;
  final bool isCorrect;
}

class LaserBeam {
  LaserBeam({required this.x, required this.y});
  double x;
  double y;
}

class ExplosionParticle {
  ExplosionParticle({
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

class ScorePopup {
  ScorePopup({
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

/// 8-Bit Space Invaders / Galaga Arcade Shooter for Vocabulary Practice.
class VocabInvadersGame extends StatefulWidget {
  const VocabInvadersGame({super.key});

  @override
  State<VocabInvadersGame> createState() => _VocabInvadersGameState();
}

class _VocabInvadersGameState extends State<VocabInvadersGame> {
  final FocusNode _focusNode = FocusNode();
  List<VocabularyWord> _deck = [];
  bool _isLoading = true;

  Timer? _gameLoop;
  VocabularyWord? _currentTargetWord;
  List<AlienShip> _aliens = [];
  List<LaserBeam> _lasers = [];
  List<ExplosionParticle> _particles = [];
  List<ScorePopup> _scorePopups = [];

  double _cannonX = 0.5; // 0.0 to 1.0
  int _score = 0;
  int _wave = 1;
  int _shields = 3;
  int _combo = 1;
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
      _wave = 1;
      _shields = 3;
      _combo = 1;
      _isGameOver = false;
      _cannonX = 0.5;
      _lasers = [];
      _particles = [];
      _scorePopups = [];
    });

    _spawnWave();
    _startGameLoop();
  }

  void _startGameLoop() {
    _gameLoop?.cancel();
    _gameLoop = Timer.periodic(const Duration(milliseconds: 50), (_) {
      _tick();
    });
  }

  void _spawnWave() {
    if (_deck.isEmpty) return;
    final random = Random();
    final target = _deck[random.nextInt(_deck.length)];

    final distractors = _deck
        .where((w) => w.id != target.id)
        .map((w) => w.word)
        .toSet()
        .toList()
      ..shuffle();

    final words = <({String word, bool isCorrect})>[
      (word: target.word, isCorrect: true),
    ];
    for (var i = 0; i < 2 && i < distractors.length; i++) {
      words.add((word: distractors[i], isCorrect: false));
    }
    words.shuffle();

    final ships = <AlienShip>[];
    final count = words.length;
    for (var i = 0; i < count; i++) {
      final slotX = (i + 0.5) / count;
      ships.add(
        AlienShip(
          x: slotX,
          y: 0.05 + random.nextDouble() * 0.05,
          word: words[i].word,
          isCorrect: words[i].isCorrect,
        ),
      );
    }

    setState(() {
      _currentTargetWord = target;
      _aliens = ships;
      _lasers.clear();
    });
  }

  void _fireLaser() {
    if (_isGameOver) return;
    setState(() {
      _lasers.add(LaserBeam(x: _cannonX, y: 0.85));
    });
  }

  void _moveCannon(double delta) {
    setState(() {
      _cannonX = (_cannonX + delta).clamp(0.08, 0.92);
    });
  }

  void _spawnExplosion(double x, double y, {required bool isTarget, required String text}) {
    final random = Random();
    final palette = context.palette;
    final colors = isTarget
        ? [palette.accent, palette.danger, Colors.amberAccent, palette.ink]
        : [palette.inkFaint, palette.danger, palette.border];

    final newParticles = <ExplosionParticle>[];
    const count = 20;
    for (var i = 0; i < count; i++) {
      final angle = (i / count) * 2 * pi + (random.nextDouble() * 0.4 - 0.2);
      final speed = 0.008 + (random.nextDouble() * 0.022);
      newParticles.add(
        ExplosionParticle(
          x: x,
          y: y,
          vx: cos(angle) * speed,
          vy: sin(angle) * speed,
          size: 4.0 + random.nextDouble() * 6.0,
          color: colors[random.nextInt(colors.length)],
          decay: 0.06 + random.nextDouble() * 0.05,
        ),
      );
    }

    _particles.addAll(newParticles);
    _scorePopups.add(
      ScorePopup(
        x: x,
        y: y - 0.03,
        text: text,
        color: isTarget ? palette.accent : palette.danger,
      ),
    );
  }

  void _tick() {
    if (_isGameOver) return;

    // Move Lasers Up
    for (final laser in _lasers) {
      laser.y -= 0.06;
    }
    _lasers.removeWhere((l) => l.y < 0.0);

    // Update Particles
    for (final p in _particles) {
      p.x += p.vx;
      p.y += p.vy;
      p.life -= p.decay;
    }
    _particles.removeWhere((p) => p.life <= 0);

    // Update Score Popups
    for (final s in _scorePopups) {
      s.y -= 0.008;
      s.life -= 0.06;
    }
    _scorePopups.removeWhere((s) => s.life <= 0);

    // Move Aliens Down
    final speed = 0.003 + (_wave * 0.0006);
    var breach = false;
    for (final alien in _aliens) {
      alien.y += speed;
      if (alien.y >= 0.85) breach = true;
    }

    if (breach) {
      _handleShieldHit();
      return;
    }

    // Check Laser vs Alien Collisions
    AlienShip? hitAlien;
    LaserBeam? collidingLaser;

    for (final laser in _lasers) {
      for (final alien in _aliens) {
        final dx = (laser.x - alien.x).abs();
        final dy = (laser.y - alien.y).abs();
        if (dx < 0.12 && dy < 0.06) {
          hitAlien = alien;
          collidingLaser = laser;
          break;
        }
      }
      if (hitAlien != null) break;
    }

    if (hitAlien != null && collidingLaser != null) {
      _lasers.remove(collidingLaser);
      _aliens.remove(hitAlien);

      if (hitAlien.isCorrect) {
        final earned = 150 * _combo;
        _score += earned;
        _spawnExplosion(
          hitAlien.x,
          hitAlien.y,
          isTarget: true,
          text: '+$earned! 💥',
        );
        _combo = (_combo + 1).clamp(1, 5);
        _wave++;
        _spawnWave();
      } else {
        _spawnExplosion(
          hitAlien.x,
          hitAlien.y,
          isTarget: false,
          text: 'WRONG! ☠',
        );
        _combo = 1;
        _handleShieldHit();
      }
    }

    setState(() {});
  }

  void _handleShieldHit() {
    setState(() {
      _shields--;
      _combo = 1;
      if (_shields > 0) {
        _spawnWave();
      } else {
        _isGameOver = true;
        _gameLoop?.cancel();
      }
    });
  }

  void _handleKey(KeyEvent event) {
    if (event is! KeyDownEvent) return;
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowLeft:
      case LogicalKeyboardKey.keyA:
        _moveCannon(-0.08);
        break;
      case LogicalKeyboardKey.arrowRight:
      case LogicalKeyboardKey.keyD:
        _moveCannon(0.08);
        break;
      case LogicalKeyboardKey.space:
      case LogicalKeyboardKey.arrowUp:
      case LogicalKeyboardKey.keyW:
        _fireLaser();
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
                    ? const Center(child: Text('LOADING SECTOR…'))
                    : _isGameOver
                    ? _buildGameOver(context)
                    : _buildSpaceArena(context),
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
            semanticLabel: 'Exit Invaders',
            onPressed: () => Navigator.of(context).pop(),
          ),
          const SizedBox(width: PixelMetrics.space2),
          Text('VOCAB INVADERS', style: Theme.of(context).textTheme.titleMedium),
          const Spacer(),
          Row(
            children: List.generate(3, (i) {
              final isFull = i < _shields;
              return Padding(
                padding: const EdgeInsets.only(right: 3),
                child: PixelIcon(
                  PixelGlyph.shield,
                  color: isFull ? palette.accent : palette.inkFaint,
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

  Widget _buildSpaceArena(BuildContext context) {
    final palette = context.palette;
    final theme = Theme.of(context);

    return Column(
      children: [
        // Target HUD Banner
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
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'SHOOT MATCHING ALIEN SHIP:',
                      style: theme.textTheme.labelSmall?.copyWith(fontSize: 10),
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
              if (_combo > 1)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: palette.danger,
                    border: Border.all(color: palette.border, width: 1),
                  ),
                  child: Text(
                    '${_combo}X COMBO',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
            ],
          ),
        ),

        // Space Sector Arena
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
                        _cannonX = (_cannonX + (details.delta.dx / w)).clamp(0.08, 0.92);
                      });
                    },
                    onTapUp: (_) => _fireLaser(),
                    child: Stack(
                      children: [
                        // Descending Alien Ships
                        for (final alien in _aliens)
                          Positioned(
                            left: (alien.x * w) - 45,
                            top: alien.y * h,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                PixelIcon(
                                  PixelGlyph.alien,
                                  color: palette.danger,
                                  scale: 2.4,
                                ),
                                const SizedBox(height: 2),
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
                                    alien.word.toUpperCase(),
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

                        // Laser Beams
                        for (final laser in _lasers)
                          Positioned(
                            left: (laser.x * w) - 2,
                            top: laser.y * h,
                            child: Container(
                              width: 4,
                              height: 12,
                              color: palette.accent,
                            ),
                          ),

                        // Explosion Debris Particles
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
                                    color: palette.border.withValues(alpha: p.life.clamp(0.0, 1.0)),
                                    width: 0.5,
                                  ),
                                ),
                              ),
                            ),
                          ),

                        // Floating Score & Hit Popups
                        for (final s in _scorePopups)
                          Positioned(
                            left: ((s.x * w) - 40).clamp(8.0, w - 80.0),
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

                        // Defense Cannon
                        Positioned(
                          left: (_cannonX * w) - 18,
                          bottom: 12,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 6,
                                height: 8,
                                color: palette.accent,
                              ),
                              Container(
                                width: 36,
                                height: 16,
                                decoration: BoxDecoration(
                                  color: palette.ink,
                                  border: Border.all(
                                    color: palette.border,
                                    width: 1,
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

        // Ergonomic Two-Handed Controls: Left/Right on Left, FIRE on Right
        Padding(
          padding: const EdgeInsets.fromLTRB(
            PixelMetrics.space3,
            0,
            PixelMetrics.space3,
            PixelMetrics.space3,
          ),
          child: Row(
            children: [
              // Left Thumb: Movement Buttons
              _ArcadeTouchButton(
                glyph: PixelGlyph.arrowLeft,
                label: '◀',
                semanticLabel: 'Move Cannon Left',
                onAction: () => _moveCannon(-0.06),
              ),
              const SizedBox(width: PixelMetrics.space2),
              _ArcadeTouchButton(
                glyph: PixelGlyph.arrowRight,
                label: '▶',
                semanticLabel: 'Move Cannon Right',
                onAction: () => _moveCannon(0.06),
              ),

              const Spacer(),

              // Right Thumb: Big Fire Button
              _ArcadeFireButton(
                glyph: PixelGlyph.fire,
                label: 'FIRE ⚡',
                onFire: _fireLaser,
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
                '☠ SECTOR OVERRUN ☠',
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
                  Text('WAVES DEFENDED', style: theme.textTheme.labelSmall),
                  const Spacer(),
                  Text('$_wave', style: theme.textTheme.titleMedium),
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

class _ArcadeTouchButton extends StatefulWidget {
  const _ArcadeTouchButton({
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
  State<_ArcadeTouchButton> createState() => _ArcadeTouchButtonState();
}

class _ArcadeTouchButtonState extends State<_ArcadeTouchButton> {
  Timer? _holdTimer;
  bool _pressed = false;

  void _start() {
    widget.onAction();
    setState(() => _pressed = true);
    _holdTimer?.cancel();
    _holdTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
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

class _ArcadeFireButton extends StatefulWidget {
  const _ArcadeFireButton({
    required this.glyph,
    required this.label,
    required this.onFire,
  });

  final PixelGlyph glyph;
  final String label;
  final VoidCallback onFire;

  @override
  State<_ArcadeFireButton> createState() => _ArcadeFireButtonState();
}

class _ArcadeFireButtonState extends State<_ArcadeFireButton> {
  Timer? _fireTimer;
  bool _pressed = false;

  void _start() {
    widget.onFire();
    setState(() => _pressed = true);
    _fireTimer?.cancel();
    _fireTimer = Timer.periodic(const Duration(milliseconds: 180), (_) {
      widget.onFire();
    });
  }

  void _stop() {
    _fireTimer?.cancel();
    if (mounted) setState(() => _pressed = false);
  }

  @override
  void dispose() {
    _fireTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    return GestureDetector(
      onTapDown: (_) => _start(),
      onTapUp: (_) => _stop(),
      onTapCancel: _stop,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        decoration: BoxDecoration(
          color: _pressed ? palette.ink : palette.danger,
          border: Border.all(color: palette.border, width: PixelMetrics.border),
          boxShadow: _pressed
              ? []
              : [
                  BoxShadow(
                    color: palette.border.withValues(alpha: 0.5),
                    offset: const Offset(2, 2),
                    blurRadius: 0,
                  ),
                ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            PixelIcon(
              widget.glyph,
              color: Colors.white,
              scale: 2.0,
            ),
            const SizedBox(width: 8),
            Text(
              widget.label,
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
