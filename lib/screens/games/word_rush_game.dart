import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/pixel_metrics.dart';
import '../../core/theme/pixel_palette.dart';
import '../../models/vocabulary_word.dart';
import '../../providers/vocabulary_provider.dart';
import '../../services/tts_service.dart';
import '../../widgets/pixel/pixel_box.dart';
import '../../widgets/pixel/pixel_button.dart';
import '../../widgets/pixel/pixel_icon.dart';

class RushFallingMeaning {
  RushFallingMeaning({
    required this.meaning,
    this.y = 0.35,
    this.vy = 0.008,
    this.life = 1.0,
  });

  final String meaning;
  double y;
  double vy;
  double life;
}

/// 60-Second Fast-Paced Arcade Speed Match Mini-Game.
class WordRushGame extends StatefulWidget {
  const WordRushGame({super.key});

  @override
  State<WordRushGame> createState() => _WordRushGameState();
}

class _WordRushGameState extends State<WordRushGame> {
  static const int _gameDurationSeconds = 60;

  List<VocabularyWord> _deck = [];
  bool _isLoading = true;

  int _secondsLeft = _gameDurationSeconds;
  Timer? _timer;
  Timer? _animTimer;
  int _score = 0;
  int _combo = 1;
  int _maxCombo = 1;
  int _correctCount = 0;
  int _totalAnswered = 0;

  VocabularyWord? _currentWord;
  List<String> _options = [];
  List<RushFallingMeaning> _fallingMeanings = [];
  bool _isGameOver = false;

  @override
  void initState() {
    super.initState();
    _initGame();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _animTimer?.cancel();
    super.dispose();
  }

  void _speakWord(String text) {
    try {
      context.read<TtsService>().speak(text);
    } catch (_) {}
  }

  Future<void> _initGame() async {
    final provider = context.read<VocabularyProvider>();
    var words = await provider.wordsDueForReview(limit: 60);
    if (words.length < 4) {
      words = provider.words;
    }

    if (!mounted) return;
    setState(() {
      _deck = List.of(words)..shuffle();
      _isLoading = false;
      _secondsLeft = _gameDurationSeconds;
      _score = 0;
      _combo = 1;
      _maxCombo = 1;
      _correctCount = 0;
      _totalAnswered = 0;
      _fallingMeanings = [];
      _isGameOver = false;
    });

    _nextQuestion();
    _startTimer();
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (_secondsLeft > 1) {
        setState(() {
          _secondsLeft--;
        });
      } else {
        _timer?.cancel();
        setState(() {
          _secondsLeft = 0;
          _isGameOver = true;
        });
      }
    });

    _animTimer?.cancel();
    _animTimer = Timer.periodic(const Duration(milliseconds: 40), (_) {
      if (_fallingMeanings.isNotEmpty) {
        setState(() {
          for (final b in _fallingMeanings) {
            b.vy += 0.002;
            b.y += b.vy;
            b.life -= 0.045;
          }
          _fallingMeanings.removeWhere((b) => b.life <= 0 || b.y > 1.05);
        });
      }
    });
  }

  void _nextQuestion() {
    if (_deck.isEmpty) return;
    final random = math.Random();
    final target = _deck[random.nextInt(_deck.length)];

    final distractors = _deck
        .where((w) => w.id != target.id)
        .map((w) => w.meaning)
        .toSet()
        .toList()
      ..shuffle();

    final choices = <String>[target.meaning];
    for (var i = 0; i < 3 && i < distractors.length; i++) {
      choices.add(distractors[i]);
    }
    choices.shuffle();

    setState(() {
      _currentWord = target;
      _options = choices;
    });
  }

  void _submitAnswer(String selectedMeaning) {
    if (_isGameOver || _currentWord == null) return;

    _totalAnswered++;
    final isCorrect = selectedMeaning == _currentWord!.meaning;

    if (isCorrect) {
      _correctCount++;
      _score += 100 * _combo;
      _combo++;
      if (_combo > _maxCombo) _maxCombo = _combo;

      _speakWord(_currentWord!.word);
      _fallingMeanings.add(
        RushFallingMeaning(
          meaning: _currentWord!.meaning,
          y: 0.35,
        ),
      );
    } else {
      _combo = 1;
      // Penalty: deduct 2 seconds from clock
      _secondsLeft = math.max(0, _secondsLeft - 2);
      if (_secondsLeft == 0) {
        _timer?.cancel();
        _isGameOver = true;
      }
    }

    _nextQuestion();
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
                  ? const Center(child: Text('PREPARING SPEED DECK…'))
                  : _isGameOver
                  ? _buildGameOverScreen(context)
                  : _buildGameArena(context),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar(BuildContext context) {
    final palette = context.palette;
    final isTimeLow = _secondsLeft <= 10;

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
            semanticLabel: 'Exit Word Rush',
            onPressed: () => Navigator.of(context).pop(),
          ),
          const SizedBox(width: PixelMetrics.space2),
          Text('WORD RUSH 60S', style: Theme.of(context).textTheme.titleMedium),
          const Spacer(),
          // Timer Box
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: isTimeLow ? palette.danger : palette.surface,
              border: Border.all(color: palette.border, width: 1),
            ),
            child: Text(
              '⏱ ${_secondsLeft}s',
              style: TextStyle(
                fontFamily: 'Handjet',
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: isTimeLow ? palette.onAccent : palette.ink,
              ),
            ),
          ),
          const SizedBox(width: PixelMetrics.space2),
          // Combo Box
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: _combo >= 3 ? palette.accent : palette.surface,
              border: Border.all(color: palette.border, width: 1),
            ),
            child: Text(
              _combo >= 5 ? '🔥 ${_combo}X FEVER!' : '${_combo}X',
              style: TextStyle(
                fontFamily: 'Handjet',
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: _combo >= 3 ? palette.onAccent : palette.inkMuted,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGameArena(BuildContext context) {
    final palette = context.palette;
    final theme = Theme.of(context);
    final word = _currentWord!;

    return Stack(
      children: [
        Padding(
          padding: const EdgeInsets.all(PixelMetrics.space4),
          child: Column(
            children: [
              // Score Readout
              Row(
                children: [
                  Text('SCORE: ', style: theme.textTheme.labelSmall),
                  Text(
                    '$_score',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: palette.accent,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    'MATCHED: $_correctCount / $_totalAnswered',
                    style: theme.textTheme.labelSmall?.copyWith(fontSize: 10),
                  ),
                ],
              ),
              const SizedBox(height: PixelMetrics.space3),

              // Main Word Prompt Box
              Expanded(
                flex: 4,
                child: PixelBox(
                  raised: true,
                  color: palette.surface,
                  padding: const EdgeInsets.all(PixelMetrics.space4),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          word.word,
                          style: theme.textTheme.headlineMedium?.copyWith(
                            fontFamily: 'Handjet',
                            fontWeight: FontWeight.bold,
                            fontSize: 40,
                            letterSpacing: 1.5,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        if (word.pronunciation != null &&
                            word.pronunciation!.isNotEmpty) ...[
                          const SizedBox(height: PixelMetrics.space2),
                          Text(
                            word.pronunciation!,
                            style: theme.textTheme.titleSmall?.copyWith(
                              color: palette.inkMuted,
                              fontStyle: FontStyle.italic,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),

              const SizedBox(height: PixelMetrics.space3),

              // 4 Fast Choice Buttons (2x2 Grid)
              Expanded(
                flex: 5,
                child: GridView.count(
                  crossAxisCount: 2,
                  childAspectRatio: 1.8,
                  crossAxisSpacing: PixelMetrics.space3,
                  mainAxisSpacing: PixelMetrics.space3,
                  physics: const NeverScrollableScrollPhysics(),
                  children: _options.map((option) {
                    return PixelButton(
                      label: option,
                      expand: true,
                      onPressed: () => _submitAnswer(option),
                    );
                  }).toList(),
                ),
              ),
            ],
          ),
        ),

        // Falling Vietnamese Meanings Overlay (drops to bottom with gravity)
        for (final b in _fallingMeanings)
          Positioned(
            left: 0,
            right: 0,
            top: MediaQuery.of(context).size.height * b.y,
            child: Center(
              child: Opacity(
                opacity: b.life.clamp(0.0, 1.0),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: palette.paper,
                    border: Border.all(
                      color: palette.accent,
                      width: 2,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: palette.accent.withValues(alpha: 0.4),
                        offset: const Offset(2, 3),
                        blurRadius: 0,
                      ),
                    ],
                  ),
                  child: Text(
                    b.meaning,
                    style: TextStyle(
                      fontFamily: 'Handjet',
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: palette.ink,
                      height: 1.0,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildGameOverScreen(BuildContext context) {
    final palette = context.palette;
    final theme = Theme.of(context);
    final accuracy = _totalAnswered > 0
        ? ((_correctCount / _totalAnswered) * 100).toStringAsFixed(0)
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
                'TIME OVER!',
                style: theme.textTheme.headlineSmall?.copyWith(
                  color: palette.accent,
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
                  Text('ACCURACY', style: theme.textTheme.labelSmall),
                  const Spacer(),
                  Text('$accuracy% ($_correctCount/$_totalAnswered)',
                      style: theme.textTheme.titleMedium),
                ],
              ),
              const SizedBox(height: PixelMetrics.space2),
              Row(
                children: [
                  Text('MAX COMBO', style: theme.textTheme.labelSmall),
                  const Spacer(),
                  Text('${_maxCombo}X', style: theme.textTheme.titleMedium),
                ],
              ),
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
