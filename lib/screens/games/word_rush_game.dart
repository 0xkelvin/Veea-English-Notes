import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/pixel_metrics.dart';
import '../../core/theme/pixel_palette.dart';
import '../../models/vocabulary_word.dart';
import '../../providers/vocabulary_provider.dart';
import '../../widgets/pixel/pixel_box.dart';
import '../../widgets/pixel/pixel_button.dart';
import '../../widgets/pixel/pixel_icon.dart';

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
  int _score = 0;
  int _combo = 1;
  int _maxCombo = 1;
  int _correctCount = 0;
  int _totalAnswered = 0;

  VocabularyWord? _currentWord;
  List<String> _options = [];
  bool _isGameOver = false;

  @override
  void initState() {
    super.initState();
    _initGame();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
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
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: isTimeLow ? palette.danger : palette.surface,
              border: Border.all(
                color: isTimeLow ? palette.border : palette.inkFaint,
                width: 1,
              ),
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

    return Padding(
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
                    const SizedBox(height: PixelMetrics.space2),
                    Text(
                      word.pronunciation ?? '/pronounce/',
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: palette.accent,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          const SizedBox(height: PixelMetrics.space4),

          // 4 Options Grid (2x2)
          Expanded(
            flex: 5,
            child: Column(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      Expanded(
                        child: _RushOptionButton(
                          label: _options[0],
                          onPressed: () => _submitAnswer(_options[0]),
                        ),
                      ),
                      const SizedBox(width: PixelMetrics.space2),
                      Expanded(
                        child: _RushOptionButton(
                          label: _options[1],
                          onPressed: () => _submitAnswer(_options[1]),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: PixelMetrics.space2),
                Expanded(
                  child: Row(
                    children: [
                      Expanded(
                        child: _RushOptionButton(
                          label: _options[2],
                          onPressed: () => _submitAnswer(_options[2]),
                        ),
                      ),
                      const SizedBox(width: PixelMetrics.space2),
                      Expanded(
                        child: _RushOptionButton(
                          label: _options[3],
                          onPressed: () => _submitAnswer(_options[3]),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGameOverScreen(BuildContext context) {
    final palette = context.palette;
    final theme = Theme.of(context);
    final accuracy = _totalAnswered > 0
        ? ((_correctCount / _totalAnswered) * 100).round()
        : 0;

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
                '★ TIME UP! ★',
                style: theme.textTheme.headlineSmall?.copyWith(
                  color: palette.accent,
                  fontFamily: 'Handjet',
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: PixelMetrics.space4),
              _buildStatLine('FINAL SCORE', '$_score'),
              const SizedBox(height: PixelMetrics.space2),
              _buildStatLine('WORDS MATCHED', '$_correctCount'),
              const SizedBox(height: PixelMetrics.space2),
              _buildStatLine('ACCURACY RATE', '$accuracy%'),
              const SizedBox(height: PixelMetrics.space2),
              _buildStatLine('MAX COMBO', '$_maxCombo X'),
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

  Widget _buildStatLine(String label, String value) {
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

class _RushOptionButton extends StatelessWidget {
  const _RushOptionButton({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    return GestureDetector(
      onTap: onPressed,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.all(PixelMetrics.space3),
        decoration: BoxDecoration(
          color: palette.surface,
          border: Border.all(color: palette.border, width: PixelMetrics.border),
        ),
        child: Center(
          child: Text(
            label,
            style: const TextStyle(
              fontFamily: 'Handjet',
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
            textAlign: TextAlign.center,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    );
  }
}
