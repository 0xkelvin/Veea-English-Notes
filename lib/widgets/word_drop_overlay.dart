import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/theme/pixel_metrics.dart';
import '../core/theme/pixel_palette.dart';
import '../models/word_challenge.dart';
import '../providers/vocabulary_provider.dart';
import '../services/friend_challenge_service.dart';
import '../services/tts_service.dart';
import 'pixel/pixel_button.dart';
import 'pixel/pixel_icon.dart';

/// Modal dialog that presents an instant incoming Word Drop challenge.
class WordDropOverlay extends StatefulWidget {
  const WordDropOverlay({
    super.key,
    required this.challenge,
    this.onRevenge,
  });

  final WordChallenge challenge;
  final VoidCallback? onRevenge;

  /// Shows the dialog over the current Navigator context.
  static Future<void> show(
    BuildContext context, {
    required WordChallenge challenge,
    VoidCallback? onRevenge,
  }) {
    return showDialog(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black.withValues(alpha: 0.75),
      builder: (_) => WordDropOverlay(
        challenge: challenge,
        onRevenge: onRevenge,
      ),
    );
  }

  @override
  State<WordDropOverlay> createState() => _WordDropOverlayState();
}

class _WordDropOverlayState extends State<WordDropOverlay> {
  static const int _totalSeconds = 15;
  int _secondsLeft = _totalSeconds;
  Timer? _countdownTimer;
  final Stopwatch _stopwatch = Stopwatch();

  String? _selectedOption;
  WordChallengeResult? _result;
  bool _isWordSaved = false;

  @override
  void initState() {
    super.initState();
    _stopwatch.start();
    _startTimer();
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _stopwatch.stop();
    super.dispose();
  }

  void _startTimer() {
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_secondsLeft <= 1) {
        timer.cancel();
        if (_selectedOption == null) {
          _handleAnswer(null); // Time out
        }
      } else {
        setState(() {
          _secondsLeft--;
        });
      }
    });
  }

  Future<void> _handleAnswer(String? answer) async {
    _countdownTimer?.cancel();
    _stopwatch.stop();
    final elapsed = _stopwatch.elapsedMilliseconds / 1000.0;

    setState(() {
      _selectedOption = answer ?? '';
    });

    final service = context.read<FriendChallengeService>();
    final res = await service.submitResponse(
      challenge: widget.challenge,
      selectedAnswer: answer ?? '',
      timeTakenSeconds: elapsed,
    );

    if (mounted) {
      setState(() {
        _result = res;
      });
    }
  }

  Future<void> _saveWordToNotebook() async {
    final vocab = context.read<VocabularyProvider>();
    await vocab.addWord(
      word: widget.challenge.targetWord,
      meaning: widget.challenge.targetMeaning,
      source: 'Word Drop from ${widget.challenge.senderName}',
      tags: ['friend-duel'],
    );
    if (mounted) {
      setState(() {
        _isWordSaved = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final theme = Theme.of(context);
    final isAnswered = _result != null;

    return Center(
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: 330,
          margin: const EdgeInsets.symmetric(horizontal: PixelMetrics.space4),
          decoration: BoxDecoration(
            color: palette.surface,
            border: Border.all(
              color: isAnswered
                  ? (_result!.isCorrect ? palette.accent : palette.danger)
                  : palette.border,
              width: PixelMetrics.border * 1.5,
            ),
            boxShadow: [
              BoxShadow(
                color: palette.border.withValues(alpha: 0.6),
                offset: const Offset(4, 4),
                blurRadius: 0,
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Top Banner
              _buildHeader(palette),

              // Countdown timer bar
              if (!isAnswered) _buildTimerBar(palette),

              // Main Challenge Content
              Padding(
                padding: const EdgeInsets.all(PixelMetrics.space4),
                child: isAnswered
                    ? _buildResultView(palette, theme)
                    : _buildQuestionView(palette, theme),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(PixelPalette palette) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: PixelMetrics.space3,
        vertical: PixelMetrics.space2,
      ),
      color: palette.border,
      child: Row(
        children: [
          PixelIcon(PixelGlyph.bolt, color: Colors.amber, scale: 2),
          const SizedBox(width: PixelMetrics.space2),
          Expanded(
            child: Text(
              'INCOMING WORD DROP!',
              style: TextStyle(
                fontFamily: 'Handjet',
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: palette.paper,
                letterSpacing: 1.0,
              ),
            ),
          ),
          Text(
            widget.challenge.senderName.toUpperCase(),
            style: TextStyle(
              fontFamily: 'Handjet',
              fontSize: 12,
              color: palette.accent,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTimerBar(PixelPalette palette) {
    final progress = _secondsLeft / _totalSeconds;
    final barColor = _secondsLeft <= 4 ? palette.danger : palette.accent;

    return Container(
      height: 6,
      width: double.infinity,
      color: palette.border.withValues(alpha: 0.2),
      alignment: Alignment.centerLeft,
      child: FractionallySizedBox(
        widthFactor: progress.clamp(0.0, 1.0),
        child: Container(color: barColor),
      ),
    );
  }

  Widget _buildQuestionView(PixelPalette palette, ThemeData theme) {
    final c = widget.challenge;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Text(
                c.promptTitle,
                style: TextStyle(
                  fontFamily: 'Handjet',
                  fontSize: 12,
                  color: palette.inkFaint,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(width: 6),
            Row(
              children: [
                const Icon(Icons.timer_outlined, size: 14),
                const SizedBox(width: 2),
                Text(
                  '${_secondsLeft}S',
                  style: TextStyle(
                    fontFamily: 'Handjet',
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: _secondsLeft <= 4 ? palette.danger : palette.ink,
                  ),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: PixelMetrics.space2),

        // Big Target Clue Box
        Container(
          padding: const EdgeInsets.symmetric(
            horizontal: PixelMetrics.space3,
            vertical: PixelMetrics.space3,
          ),
          decoration: BoxDecoration(
            color: palette.paper,
            border: Border.all(color: palette.border, width: PixelMetrics.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      c.clue,
                      style: TextStyle(
                        fontFamily: 'Handjet',
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        color: palette.ink,
                        height: 1.1,
                      ),
                    ),
                  ),
                  if (c.mode == ChallengeMode.enToVn)
                    GestureDetector(
                      onTap: () {
                        context.read<TtsService>().speak(c.targetWord);
                      },
                      child: Padding(
                        padding: const EdgeInsets.only(left: 4),
                        child: PixelIcon(PixelGlyph.speaker, color: palette.accent, scale: 2),
                      ),
                    ),
                ],
              ),
              if (c.partOfSpeech.isNotEmpty) ...[
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  color: palette.border,
                  child: Text(
                    c.partOfSpeech,
                    style: TextStyle(
                      fontFamily: 'Handjet',
                      fontSize: 10,
                      color: palette.paper,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),

        const SizedBox(height: PixelMetrics.space3),

        // 4 Options
        for (var i = 0; i < c.options.length; i++) ...[
          Padding(
            padding: const EdgeInsets.only(bottom: PixelMetrics.space2),
            child: _buildOptionButton(
              optionLetter: String.fromCharCode(65 + i), // A, B, C, D
              text: c.options[i],
              palette: palette,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildOptionButton({
    required String optionLetter,
    required String text,
    required PixelPalette palette,
  }) {
    return GestureDetector(
      onTap: () => _handleAnswer(text),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: PixelMetrics.space3,
          vertical: PixelMetrics.space2,
        ),
        decoration: BoxDecoration(
          color: palette.surface,
          border: Border.all(color: palette.border, width: PixelMetrics.border),
          boxShadow: [
            BoxShadow(
              color: palette.border.withValues(alpha: 0.35),
              offset: const Offset(2, 2),
              blurRadius: 0,
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              width: 22,
              height: 22,
              alignment: Alignment.center,
              color: palette.border,
              child: Text(
                optionLetter,
                style: TextStyle(
                  fontFamily: 'Handjet',
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: palette.paper,
                ),
              ),
            ),
            const SizedBox(width: PixelMetrics.space2),
            Expanded(
              child: Text(
                text,
                style: TextStyle(
                  fontFamily: 'Handjet',
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  color: palette.ink,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildResultView(PixelPalette palette, ThemeData theme) {
    final res = _result!;
    final isCorrect = res.isCorrect;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Result Banner
        Container(
          padding: const EdgeInsets.symmetric(vertical: PixelMetrics.space3),
          decoration: BoxDecoration(
            color: isCorrect
                ? palette.accent.withValues(alpha: 0.15)
                : palette.danger.withValues(alpha: 0.15),
            border: Border.all(
              color: isCorrect ? palette.accent : palette.danger,
              width: PixelMetrics.border,
            ),
          ),
          child: Column(
            children: [
              PixelIcon(
                isCorrect ? PixelGlyph.trophy : PixelGlyph.skull,
                color: isCorrect ? palette.accent : palette.danger,
                scale: 3,
              ),
              const SizedBox(height: PixelMetrics.space1),
              Text(
                isCorrect ? '★ CORRECT! ★' : '✖ INCORRECT!',
                style: TextStyle(
                  fontFamily: 'Handjet',
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: isCorrect ? palette.accent : palette.danger,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                isCorrect
                    ? '+${res.xpEarned} XP • ⚡ ${res.timeTakenSeconds.toStringAsFixed(1)}s'
                    : 'TIME OUT OR WRONG ANSWER',
                style: TextStyle(
                  fontFamily: 'Handjet',
                  fontSize: 12,
                  color: palette.inkFaint,
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: PixelMetrics.space3),

        // Full Definition Recall
        Container(
          padding: const EdgeInsets.all(PixelMetrics.space3),
          decoration: BoxDecoration(
            color: palette.paper,
            border: Border.all(color: palette.border, width: PixelMetrics.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'CHALLENGE WORD:',
                style: TextStyle(
                  fontFamily: 'Handjet',
                  fontSize: 11,
                  color: palette.inkFaint,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                widget.challenge.targetWord.toUpperCase(),
                style: TextStyle(
                  fontFamily: 'Handjet',
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: palette.accent,
                ),
              ),
              Text(
                widget.challenge.targetMeaning,
                style: TextStyle(
                  fontFamily: 'Handjet',
                  fontSize: 14,
                  color: palette.ink,
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: PixelMetrics.space3),

        // 1-Tap Save to Notes (especially if incorrect or new)
        if (!_isWordSaved) ...[
          PixelButton(
            label: '+ SAVE TO MY JOURNAL',
            onPressed: _saveWordToNotebook,
          ),
          const SizedBox(height: PixelMetrics.space2),
        ] else ...[
          Container(
            padding: const EdgeInsets.symmetric(vertical: 6),
            alignment: Alignment.center,
            color: palette.accent.withValues(alpha: 0.1),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                PixelIcon(PixelGlyph.check, color: palette.accent, scale: 1.5),
                const SizedBox(width: 4),
                Text(
                  'SAVED TO JOURNAL!',
                  style: TextStyle(
                    fontFamily: 'Handjet',
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: palette.accent,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: PixelMetrics.space2),
        ],

        // Revenge & Close Buttons
        Row(
          children: [
            Expanded(
              child: PixelButton(
                label: 'CHALLENGE BACK ⚡',
                onPressed: () {
                  Navigator.of(context).pop();
                  widget.onRevenge?.call();
                },
              ),
            ),
            const SizedBox(width: PixelMetrics.space2),
            Expanded(
              child: PixelButton(
                label: 'CLOSE',
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
