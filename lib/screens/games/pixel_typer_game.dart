import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/theme/pixel_metrics.dart';
import '../../core/theme/pixel_palette.dart';
import '../../models/srs_review.dart';
import '../../models/vocabulary_word.dart';
import '../../providers/vocabulary_provider.dart';
import '../../services/tts_service.dart';
import '../../widgets/pixel/pixel_box.dart';
import '../../widgets/pixel/pixel_button.dart';
import '../../widgets/pixel/pixel_icon.dart';

/// The typing form of a word: lowercase, letters and digits only.
///
/// Spaces, hyphens and apostrophes are stripped so a learner types
/// `stateoftheart` for "state-of-the-art" — punctuation is a keyboard chore,
/// not vocabulary, and making it typeable would cost three more keys on a
/// screen that has none to spare. [typerDisplaySlots] puts the punctuation
/// back for display.
String typerCanonical(String word) {
  final buffer = StringBuffer();
  for (final rune in word.toLowerCase().runes) {
    final char = String.fromCharCode(rune);
    if (RegExp(r'[a-z0-9]').hasMatch(char)) buffer.write(char);
  }
  return buffer.toString();
}

/// One rendered character of a target word.
class TyperSlot {
  const TyperSlot({
    required this.char,
    required this.isTypeable,
    required this.isRevealed,
  });

  /// The character as it appears in the original word.
  final String char;

  /// Whether the player has to press a key for this slot. Punctuation does not
  /// count — it is shown from the start.
  final bool isTypeable;

  /// Whether the player has typed this far.
  final bool isRevealed;
}

/// Expands [word] into display slots, revealing the first [typedLength]
/// typeable characters.
///
/// Punctuation is always revealed, so "state-of-the-art" shows its hyphens as
/// structure while the letters stay hidden.
List<TyperSlot> typerDisplaySlots(String word, int typedLength) {
  final slots = <TyperSlot>[];
  var typeableSeen = 0;

  for (final rune in word.runes) {
    final char = String.fromCharCode(rune);
    final isTypeable = RegExp(r'[a-zA-Z0-9]').hasMatch(char);
    if (isTypeable) {
      slots.add(
        TyperSlot(
          char: char,
          isTypeable: true,
          isRevealed: typeableSeen < typedLength,
        ),
      );
      typeableSeen++;
    } else {
      slots.add(TyperSlot(char: char, isTypeable: false, isRevealed: true));
    }
  }

  return slots;
}

/// A descending word to be destroyed by typing.
class TyperTarget {
  TyperTarget({
    required this.word,
    required this.x,
    required this.y,
    required this.speed,
  }) : canonical = typerCanonical(word.word);

  final VocabularyWord word;

  /// Pre-computed typing form, so the game loop never re-scans the string.
  final String canonical;

  /// Horizontal position, 0.0 to 1.0.
  double x;

  /// Vertical position, 0.0 (top) to 1.0 (bottom).
  double y;

  /// Descent per tick, in screen fractions.
  double speed;

  /// Whether the player spent a hint or a pronunciation on this word. Assisted
  /// kills are still worth points, but they do not earn a full SRS rating.
  bool wasAssisted = false;
}

class TyperParticle {
  TyperParticle({
    required this.x,
    required this.y,
    required this.vx,
    required this.vy,
    required this.size,
    required this.color,
    this.life = 1.0,
    this.decay = 0.06,
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

class TyperPopup {
  TyperPopup({
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

/// Typing-of-the-Dead style recall drill.
///
/// Vietnamese meanings descend; the player types the English word from memory.
/// Every other arcade game in the app asks the player to *recognise* a meaning
/// among four options. This one asks them to *produce* the word, letter by
/// letter, which is the retrieval that actually moves a word into long-term
/// memory — and the only game here that can catch a spelling the player has
/// never really learned.
class PixelTyperGame extends StatefulWidget {
  const PixelTyperGame({super.key});

  @override
  State<PixelTyperGame> createState() => _PixelTyperGameState();
}

class _PixelTyperGameState extends State<PixelTyperGame> {
  /// Fractional y at which a target has broken through and costs a shield.
  static const double _breachLine = 0.86;

  static const int _startingShields = 3;
  static const int _soundCost = 25;
  static const int _hintCost = 50;

  /// Words cleared before the wave — and so the descent speed — steps up.
  static const int _wordsPerWave = 5;

  static const List<String> _keyboardRows = [
    'qwertyuiop',
    'asdfghjkl',
    'zxcvbnm',
  ];

  final FocusNode _focusNode = FocusNode();
  final Random _random = Random();

  List<VocabularyWord> _deck = [];
  bool _isLoading = true;

  Timer? _gameLoop;
  List<TyperTarget> _targets = [];
  List<TyperParticle> _particles = [];
  List<TyperPopup> _popups = [];

  /// Letters typed so far, in canonical form.
  String _typed = '';

  int _score = 0;
  int _wave = 1;
  int _shields = _startingShields;
  int _combo = 1;
  int _maxCombo = 1;
  int _wordsCleared = 0;
  int _goodKeystrokes = 0;
  int _typoKeystrokes = 0;
  int _ticksSinceSpawn = 0;
  bool _isGameOver = false;

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

  /// Feeds the result back into the SM-2 schedule.
  ///
  /// Playing is a real review, so a word cleared here should not come up again
  /// tomorrow, and a word that broke through should come up soon.
  void _recordSrs(VocabularyWord word, SrsRating rating) {
    try {
      // Deliberately not awaited: the game loop must not stall on a write, and
      // a lost rating is not worth interrupting play over.
      context.read<VocabularyProvider>().recordSrsReview(
        wordId: word.id,
        rating: rating,
      );
    } catch (_) {}
  }

  Future<void> _initGame() async {
    final provider = context.read<VocabularyProvider>();
    var words = await provider.wordsDueForReview(limit: 60);
    if (words.length < 3) words = provider.words;

    // A word with no typeable characters can never be cleared, and one with a
    // blank meaning gives the player nothing to recall from.
    words = words
        .where((w) => typerCanonical(w.word).isNotEmpty && w.meaning.isNotEmpty)
        .toList();

    if (!mounted) return;
    setState(() {
      _deck = List.of(words)..shuffle();
      _isLoading = false;
      _targets = [];
      _particles = [];
      _popups = [];
      _typed = '';
      _score = 0;
      _wave = 1;
      _shields = _startingShields;
      _combo = 1;
      _maxCombo = 1;
      _wordsCleared = 0;
      _goodKeystrokes = 0;
      _typoKeystrokes = 0;
      _ticksSinceSpawn = 0;
      _isGameOver = false;
      _screenShakeX = 0.0;
      _screenShakeY = 0.0;
      _screenFlashOpacity = 0.0;
    });

    if (_deck.isNotEmpty) _spawnTarget();
    _startGameLoop();
  }

  void _startGameLoop() {
    _gameLoop?.cancel();
    _gameLoop = Timer.periodic(const Duration(milliseconds: 50), (_) => _tick());
  }

  /// How many targets may descend at once, and how fast, at the current wave.
  int get _maxConcurrentTargets => (1 + _wave ~/ 2).clamp(1, 4);

  double get _descentSpeed => 0.0016 + (_wave - 1) * 0.00028;

  /// Ticks between spawns, shrinking as the waves climb.
  int get _spawnInterval => max(24, 60 - _wave * 4);

  void _spawnTarget() {
    if (_deck.isEmpty) return;

    // Never show two targets whose words start with the same letter: the
    // player would type a letter that locks onto neither, or onto the wrong
    // one, and the game would feel broken rather than hard.
    final liveInitials = _targets.map((t) => t.canonical[0]).toSet();
    final liveIds = _targets.map((t) => t.word.id).toSet();

    final candidates = _deck
        .where(
          (w) =>
              !liveIds.contains(w.id) &&
              !liveInitials.contains(typerCanonical(w.word)[0]),
        )
        .toList();
    if (candidates.isEmpty) return;

    final word = candidates[_random.nextInt(candidates.length)];

    // Spread spawns across the width, biased away from whichever columns are
    // already occupied, so badges do not overlap on the way down.
    final occupied = _targets.map((t) => t.x).toList();
    var x = 0.2 + _random.nextDouble() * 0.6;
    for (var attempt = 0; attempt < 4; attempt++) {
      if (occupied.every((other) => (other - x).abs() > 0.25)) break;
      x = 0.2 + _random.nextDouble() * 0.6;
    }

    _targets.add(
      TyperTarget(
        word: word,
        x: x,
        y: 0.06,
        speed: _descentSpeed * (0.85 + _random.nextDouble() * 0.3),
      ),
    );
    _ticksSinceSpawn = 0;
  }

  /// Targets the current buffer could still be completing.
  List<TyperTarget> get _matchingTargets {
    if (_typed.isEmpty) return const [];
    return _targets.where((t) => t.canonical.startsWith(_typed)).toList();
  }

  /// The target the player is committed to, or the most urgent one when the
  /// buffer is empty — that is the one an assist should act on.
  TyperTarget? get _primaryTarget {
    final matches = _matchingTargets;
    final pool = matches.isNotEmpty ? matches : _targets;
    if (pool.isEmpty) return null;
    return pool.reduce((a, b) => a.y >= b.y ? a : b);
  }

  void _spawnBurst(
    double x,
    double y, {
    required List<Color> colors,
    int count = 20,
    double speedScale = 1.0,
  }) {
    for (var i = 0; i < count; i++) {
      final angle = (i / count) * 2 * pi + (_random.nextDouble() * 0.4 - 0.2);
      final speed = (0.008 + _random.nextDouble() * 0.022) * speedScale;
      _particles.add(
        TyperParticle(
          x: x,
          y: y,
          vx: cos(angle) * speed,
          vy: sin(angle) * speed,
          size: 4.0 + _random.nextDouble() * 6.0,
          color: colors[_random.nextInt(colors.length)],
          decay: 0.05 + _random.nextDouble() * 0.05,
        ),
      );
    }
  }

  void _typeLetter(String letter) {
    if (_isGameOver || _isLoading) return;

    final attempt = _typed + letter;
    final matches = _targets.where((t) => t.canonical.startsWith(attempt));

    if (matches.isEmpty) {
      // Classic typing-arcade rule: a key that fits no target is rejected
      // rather than absorbed, so a typo never strands the player mid-word.
      setState(() {
        _typoKeystrokes++;
        _combo = 1;
        _screenShakeX = (_random.nextBool() ? 1 : -1) * 5.0;
      });
      return;
    }

    setState(() {
      _typed = attempt;
      _goodKeystrokes++;
    });

    final completed = matches.where((t) => t.canonical == attempt).toList();
    if (completed.isNotEmpty) _destroyTarget(completed.first);
  }

  void _backspace() {
    if (_isGameOver || _typed.isEmpty) return;
    setState(() {
      _typed = _typed.substring(0, _typed.length - 1);
    });
  }

  void _clearBuffer() {
    if (_typed.isEmpty) return;
    setState(() => _typed = '');
  }

  void _destroyTarget(TyperTarget target) {
    final palette = context.palette;
    final letters = target.canonical.length;

    // Long words are worth more, because they are more to hold in memory.
    final earned = (100 + letters * 10) * _combo;

    setState(() {
      _targets.remove(target);
      _typed = '';
      _score += earned;
      _wordsCleared++;
      _combo = (_combo + 1).clamp(1, 5);
      if (_combo > _maxCombo) _maxCombo = _combo;
      _wave = 1 + _wordsCleared ~/ _wordsPerWave;

      _spawnBurst(
        target.x,
        target.y,
        colors: [palette.accent, Colors.amberAccent, palette.ink],
      );
      _popups.add(
        TyperPopup(
          x: target.x,
          y: target.y - 0.03,
          text: '+$earned ${target.word.word.toUpperCase()}',
          color: palette.accent,
        ),
      );
    });

    _speakWord(target.word.word);

    // An assisted word was recalled with help, so it is scheduled tighter than
    // one produced cold.
    _recordSrs(
      target.word,
      target.wasAssisted ? SrsRating.hard : SrsRating.good,
    );
  }

  void _handleBreach(TyperTarget target) {
    final palette = context.palette;

    setState(() {
      _targets.remove(target);
      if (_typed.isNotEmpty && target.canonical.startsWith(_typed)) _typed = '';
      _shields--;
      _combo = 1;
      _screenFlashOpacity = 0.45;
      _screenShakeX = (_random.nextBool() ? 1 : -1) * 8.0;
      _screenShakeY = (_random.nextBool() ? 1 : -1) * 8.0;

      _spawnBurst(
        target.x,
        _breachLine,
        colors: [palette.danger, Colors.orangeAccent, palette.ink],
        count: 26,
      );
      // The answer is shown on a miss: a word you could not recall is worth
      // more seen than left blank.
      _popups.add(
        TyperPopup(
          x: target.x,
          y: _breachLine - 0.04,
          text: '☠ ${target.word.word.toUpperCase()}',
          color: palette.danger,
        ),
      );
    });

    _speakWord(target.word.word);
    _recordSrs(target.word, SrsRating.again);

    if (_shields <= 0) _endGame();
  }

  void _endGame() {
    _gameLoop?.cancel();
    setState(() {
      _isGameOver = true;
      _targets = [];
      _typed = '';
    });
  }

  /// Plays the word behind the current target, for a small score fee.
  void _useSound() {
    final target = _primaryTarget;
    if (target == null || _isGameOver) return;
    setState(() {
      _score = max(0, _score - _soundCost);
      target.wasAssisted = true;
    });
    _speakWord(target.word.word);
  }

  /// Reveals the next letter of the current target, for a larger fee.
  void _useHint() {
    final target = _primaryTarget;
    if (target == null || _isGameOver) return;
    if (_typed.isNotEmpty && !target.canonical.startsWith(_typed)) return;

    final next = target.canonical[_typed.length];
    setState(() {
      _score = max(0, _score - _hintCost);
      target.wasAssisted = true;
      _combo = 1;
    });
    _typeLetter(next);
  }

  void _tick() {
    if (_isGameOver || _isLoading) return;

    if (_screenShakeX.abs() > 0.2) _screenShakeX *= 0.65;
    if (_screenShakeY.abs() > 0.2) _screenShakeY *= 0.65;
    if (_screenFlashOpacity > 0.03) _screenFlashOpacity -= 0.04;

    for (final p in _particles) {
      p.x += p.vx;
      p.y += p.vy;
      p.life -= p.decay;
    }
    _particles.removeWhere((p) => p.life <= 0);

    for (final p in _popups) {
      p.y -= 0.006;
      p.life -= 0.02;
    }
    _popups.removeWhere((p) => p.life <= 0);

    for (final target in _targets) {
      target.y += target.speed;
    }

    final breached = _targets.where((t) => t.y >= _breachLine).toList();
    if (breached.isNotEmpty) {
      // One shield per tick, so a pile-up cannot end the run in a single frame
      // before the player sees what hit them.
      _handleBreach(breached.first);
      return;
    }

    _ticksSinceSpawn++;
    if (_targets.length < _maxConcurrentTargets &&
        _ticksSinceSpawn >= _spawnInterval) {
      _spawnTarget();
    }
    // Never leave the arena empty: with a deck this small a stall reads as the
    // game having frozen.
    if (_targets.isEmpty) _spawnTarget();

    setState(() {});
  }

  void _handleKey(KeyEvent event) {
    if (event is! KeyDownEvent || _isGameOver) return;

    if (event.logicalKey == LogicalKeyboardKey.backspace) {
      _backspace();
      return;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      _clearBuffer();
      return;
    }

    final char = event.character?.toLowerCase();
    if (char != null && char.length == 1 && RegExp(r'[a-z0-9]').hasMatch(char)) {
      _typeLetter(char);
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
                    ? const Center(child: Text('LOADING WORD BANK…'))
                    : _deck.isEmpty
                    ? _buildEmptyDeck(context)
                    : _isGameOver
                    ? _buildGameOver(context)
                    : _buildArena(context),
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
            semanticLabel: 'Exit Pixel Typer',
            onPressed: () => Navigator.of(context).pop(),
          ),
          const SizedBox(width: PixelMetrics.space2),
          Flexible(
            child: Text(
              'PIXEL TYPER',
              style: Theme.of(context).textTheme.titleMedium,
              overflow: TextOverflow.ellipsis,
              softWrap: false,
            ),
          ),
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: _combo >= 3 ? palette.accent : palette.surface,
              border: Border.all(color: palette.border, width: 1),
            ),
            child: Text(
              _combo >= 5 ? '🔥 ${_combo}X' : '${_combo}X',
              style: TextStyle(
                fontFamily: 'Handjet',
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: _combo >= 3 ? palette.onAccent : palette.inkMuted,
              ),
            ),
          ),
          const SizedBox(width: PixelMetrics.space2),
          Row(
            children: List.generate(_startingShields, (i) {
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
        ],
      ),
    );
  }

  Widget _buildEmptyDeck(BuildContext context) {
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
              Text('NO WORDS YET', style: theme.textTheme.titleMedium),
              const SizedBox(height: PixelMetrics.space3),
              Text(
                'Capture a few words in your notebook first — Pixel Typer '
                'drills the ones you have written down.',
                style: theme.textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: PixelMetrics.space5),
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

  Widget _buildArena(BuildContext context) {
    final palette = context.palette;
    final theme = Theme.of(context);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: PixelMetrics.space4,
            vertical: PixelMetrics.space2,
          ),
          child: Row(
            children: [
              Flexible(
                child: Text(
                  'TYPE THE ENGLISH WORD:',
                  style: theme.textTheme.labelSmall,
                  overflow: TextOverflow.ellipsis,
                  softWrap: false,
                ),
              ),
              const Spacer(),
              Text(
                'WAVE $_wave',
                style: theme.textTheme.labelSmall?.copyWith(fontSize: 10),
              ),
            ],
          ),
        ),

        // Descent field
        Expanded(
          child: Transform.translate(
            offset: Offset(_screenShakeX, _screenShakeY),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth;
                final height = constraints.maxHeight;

                return Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFF0F110C),
                    border: Border.all(
                      color: palette.border,
                      width: PixelMetrics.border,
                    ),
                  ),
                  child: Stack(
                    children: [
                      CustomPaint(
                        size: Size(width, height),
                        painter: _TyperFieldPainter(
                          particles: _particles,
                          breachLine: _breachLine,
                          gridColor: palette.inkFaint.withValues(alpha: 0.10),
                          breachColor: palette.danger,
                        ),
                      ),

                      for (final target in _targets)
                        _buildTargetBadge(context, target, width, height),

                      for (final popup in _popups)
                        Positioned(
                          left: 0,
                          right: 0,
                          top: popup.y * height,
                          child: Center(
                            child: Opacity(
                              opacity: popup.life.clamp(0.0, 1.0),
                              child: Text(
                                popup.text,
                                style: TextStyle(
                                  fontFamily: 'Handjet',
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  color: popup.color,
                                ),
                              ),
                            ),
                          ),
                        ),

                      if (_screenFlashOpacity > 0.02)
                        Positioned.fill(
                          child: IgnorePointer(
                            child: Container(
                              color: palette.danger.withValues(
                                alpha: _screenFlashOpacity.clamp(0.0, 1.0),
                              ),
                            ),
                          ),
                        ),

                      Positioned(
                        top: 8,
                        left: 12,
                        child: Text(
                          'SCORE: $_score',
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: palette.accent,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
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

        _buildKeyboard(context),
      ],
    );
  }

  Widget _buildTargetBadge(
    BuildContext context,
    TyperTarget target,
    double width,
    double height,
  ) {
    final palette = context.palette;
    final isPrimary = identical(target, _primaryTarget) && _typed.isNotEmpty;
    final typedLength = target.canonical.startsWith(_typed) ? _typed.length : 0;
    final slots = typerDisplaySlots(target.word.word, typedLength);
    final pos = target.word.partOfSpeech?.short;

    // Urgency is what the player reads first, so the border does the work of a
    // health bar: calm at the top, danger red as it nears the line.
    final urgency = (target.y / _breachLine).clamp(0.0, 1.0);
    final borderColor = isPrimary
        ? palette.accent
        : urgency > 0.7
        ? palette.danger
        : palette.border;

    return Positioned(
      left: 0,
      right: 0,
      top: target.y * height,
      child: Align(
        alignment: Alignment(target.x * 2 - 1, 0),
        child: FractionallySizedBox(
          widthFactor: 0.78,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFF1A1D16),
              border: Border.all(color: borderColor, width: 2),
              boxShadow: [
                BoxShadow(
                  color: borderColor.withValues(alpha: 0.35),
                  offset: const Offset(2, 3),
                  blurRadius: 0,
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  pos == null
                      ? target.word.meaning
                      : '${target.word.meaning} · $pos',
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: 'Handjet',
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFFE0DFD5),
                    height: 1.1,
                  ),
                ),
                const SizedBox(height: 4),
                _buildSlotRow(context, slots, borderColor),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Renders the answer as filled and empty slots.
  ///
  /// The slot count leaks the word's length on purpose — it is the scaffold
  /// that keeps a recall drill playable at arcade speed.
  Widget _buildSlotRow(
    BuildContext context,
    List<TyperSlot> slots,
    Color accentColor,
  ) {
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 2,
      runSpacing: 2,
      children: slots.map((slot) {
        if (!slot.isTypeable) {
          return Text(
            slot.char,
            style: const TextStyle(
              fontFamily: 'Handjet',
              fontSize: 16,
              color: Color(0xFF6B6F63),
            ),
          );
        }

        return Container(
          width: 13,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: slot.isRevealed ? accentColor : const Color(0xFF4A4E43),
                width: 2,
              ),
            ),
          ),
          child: Text(
            slot.isRevealed ? slot.char.toUpperCase() : ' ',
            style: TextStyle(
              fontFamily: 'Handjet',
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: slot.isRevealed ? accentColor : Colors.transparent,
              height: 1.1,
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildKeyboard(BuildContext context) {
    final palette = context.palette;
    final theme = Theme.of(context);
    final matchCount = _matchingTargets.length;

    return Container(
      padding: const EdgeInsets.fromLTRB(
        PixelMetrics.space2,
        PixelMetrics.space2,
        PixelMetrics.space2,
        PixelMetrics.space3,
      ),
      decoration: BoxDecoration(
        color: palette.surface,
        border: Border(
          top: BorderSide(color: palette.border, width: PixelMetrics.border),
        ),
      ),
      child: Column(
        children: [
          // Typed buffer readout
          Row(
            children: [
              Expanded(
                child: Text(
                  _typed.isEmpty ? '▌' : '${_typed.toUpperCase()}▌',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontFamily: 'Handjet',
                    fontSize: 20,
                    letterSpacing: 2,
                    color: matchCount == 0 && _typed.isNotEmpty
                        ? palette.danger
                        : palette.accent,
                  ),
                ),
              ),
              _AssistKey(
                key: const ValueKey('typer_key_sound'),
                label: '🔊 $_soundCost',
                onPressed: _useSound,
                semanticLabel: 'Hear the word',
              ),
              const SizedBox(width: PixelMetrics.space1),
              _AssistKey(
                key: const ValueKey('typer_key_hint'),
                label: '💡 $_hintCost',
                onPressed: _useHint,
                semanticLabel: 'Reveal next letter',
              ),
            ],
          ),
          const SizedBox(height: PixelMetrics.space2),

          for (final row in _keyboardRows) ...[
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: row
                  .split('')
                  .map(
                    (letter) => _TyperKey(
                      key: ValueKey('typer_key_$letter'),
                      label: letter.toUpperCase(),
                      onPressed: () => _typeLetter(letter),
                    ),
                  )
                  .toList(),
            ),
            const SizedBox(height: PixelMetrics.space1),
          ],

          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _TyperKey(
                key: const ValueKey('typer_key_clear'),
                label: 'CLR',
                flex: 2,
                onPressed: _clearBuffer,
              ),
              _TyperKey(
                key: const ValueKey('typer_key_delete'),
                label: '⌫ DEL',
                flex: 3,
                onPressed: _backspace,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildGameOver(BuildContext context) {
    final palette = context.palette;
    final theme = Theme.of(context);
    final totalKeystrokes = _goodKeystrokes + _typoKeystrokes;
    final accuracy = totalKeystrokes > 0
        ? ((_goodKeystrokes / totalKeystrokes) * 100).toStringAsFixed(0)
        : '0';

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
                'BREACHED!',
                style: theme.textTheme.headlineSmall?.copyWith(
                  color: palette.danger,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: PixelMetrics.space4),
              _StatRow(label: 'FINAL SCORE', value: '$_score'),
              const SizedBox(height: PixelMetrics.space2),
              _StatRow(label: 'WORDS TYPED', value: '$_wordsCleared'),
              const SizedBox(height: PixelMetrics.space2),
              _StatRow(label: 'KEY ACCURACY', value: '$accuracy%'),
              const SizedBox(height: PixelMetrics.space2),
              _StatRow(label: 'MAX COMBO', value: '${_maxCombo}X'),
              const SizedBox(height: PixelMetrics.space2),
              _StatRow(label: 'WAVE REACHED', value: '$_wave'),
              const SizedBox(height: PixelMetrics.space5),
              PixelButton(
                label: 'Play Again',
                glyph: PixelGlyph.bolt,
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

class _StatRow extends StatelessWidget {
  const _StatRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      children: [
        Text(label, style: theme.textTheme.labelSmall),
        const Spacer(),
        Text(
          value,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }
}

/// One key of the on-screen pixel keyboard.
///
/// The game ships its own keyboard rather than a [TextField]: the system
/// keyboard would cover the descent field, resize the arena mid-run, and drop
/// the retro frame the rest of the arcade is built in.
class _TyperKey extends StatelessWidget {
  const _TyperKey({
    super.key,
    required this.label,
    required this.onPressed,
    this.flex = 1,
  });

  final String label;
  final VoidCallback onPressed;
  final int flex;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    return Expanded(
      flex: flex,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 1.5),
        child: GestureDetector(
          onTap: onPressed,
          child: Container(
            height: 38,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: palette.paper,
              border: Border.all(color: palette.border, width: 1),
            ),
            child: Text(
              label,
              style: TextStyle(
                fontFamily: 'Handjet',
                fontSize: 15,
                fontWeight: FontWeight.bold,
                color: palette.ink,
                height: 1.0,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AssistKey extends StatelessWidget {
  const _AssistKey({
    super.key,
    required this.label,
    required this.onPressed,
    required this.semanticLabel,
  });

  final String label;
  final VoidCallback onPressed;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    return Semantics(
      button: true,
      label: semanticLabel,
      child: GestureDetector(
        onTap: onPressed,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          decoration: BoxDecoration(
            color: palette.paper,
            border: Border.all(color: palette.border, width: 1),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontFamily: 'Handjet',
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: palette.inkMuted,
              height: 1.0,
            ),
          ),
        ),
      ),
    );
  }
}

/// Paints the descent field: grid, breach line, and explosion particles.
class _TyperFieldPainter extends CustomPainter {
  const _TyperFieldPainter({
    required this.particles,
    required this.breachLine,
    required this.gridColor,
    required this.breachColor,
  });

  final List<TyperParticle> particles;
  final double breachLine;
  final Color gridColor;
  final Color breachColor;

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = gridColor
      ..strokeWidth = 1.0;
    for (double y = 0; y < size.height; y += 24) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }

    // Breach line, drawn as dashes so it reads as a warning strip.
    final warn = Paint()
      ..color = breachColor.withValues(alpha: 0.7)
      ..strokeWidth = 2.0;
    final lineY = size.height * breachLine;
    for (double x = 0; x < size.width; x += 14) {
      canvas.drawLine(Offset(x, lineY), Offset(x + 7, lineY), warn);
    }

    for (final p in particles) {
      if (p.life <= 0) continue;
      final paint = Paint()
        ..color = p.color.withValues(alpha: p.life.clamp(0.0, 1.0))
        ..style = PaintingStyle.fill;
      canvas.drawRect(
        Rect.fromCenter(
          center: Offset(p.x * size.width, p.y * size.height),
          width: p.size,
          height: p.size,
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _TyperFieldPainter oldDelegate) => true;
}
