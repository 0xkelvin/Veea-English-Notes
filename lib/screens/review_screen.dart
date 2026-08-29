import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/theme/pixel_metrics.dart';
import '../core/theme/pixel_palette.dart';
import '../models/srs_review.dart';
import '../models/vocabulary_word.dart';
import '../providers/vocabulary_provider.dart';
import '../services/tts_service.dart';
import '../widgets/pixel/pixel_box.dart';
import '../widgets/pixel/pixel_button.dart';
import '../widgets/pixel/pixel_icon.dart';
import 'audio_commute_screen.dart';

/// 8-bit Spaced Repetition (SM-2) Flashcard Review Screen.
class ReviewScreen extends StatefulWidget {
  const ReviewScreen({super.key, this.practiceAll = false});

  /// If true, review recent words even if none are technically due yet.
  final bool practiceAll;

  @override
  State<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends State<ReviewScreen> {
  final FocusNode _focusNode = FocusNode();
  List<VocabularyWord> _queue = [];
  bool _isLoading = true;
  int _currentIndex = 0;
  bool _isFlipped = false;
  bool _isComplete = false;

  // Session stats
  int _againCount = 0;
  int _hardCount = 0;
  int _goodCount = 0;
  int _easyCount = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadReviewQueue();
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _loadReviewQueue() async {
    final provider = context.read<VocabularyProvider>();
    List<VocabularyWord> words;

    if (widget.practiceAll) {
      words = await provider.wordsDueForReview(limit: 50);
      if (words.isEmpty) {
        // Fallback to recent words for free practice
        words = provider.words;
      }
    } else {
      words = await provider.wordsDueForReview(limit: 20);
    }

    if (!mounted) return;
    setState(() {
      _queue = words;
      _isLoading = false;
      _currentIndex = 0;
      _isFlipped = false;
      _isComplete = false;
    });

    _playCurrentWordAudio();
  }

  VocabularyWord? get _currentWord =>
      (_currentIndex < _queue.length) ? _queue[_currentIndex] : null;

  void _flipCard() {
    if (_isFlipped || _isComplete || _currentWord == null) return;
    setState(() {
      _isFlipped = true;
    });
  }

  void _playCurrentWordAudio() {
    final word = _currentWord;
    if (word != null) {
      context.read<TtsService>().speak(word.word);
    }
  }

  Future<void> _rateCard(SrsRating rating) async {
    if (!_isFlipped || _currentWord == null) return;

    final word = _currentWord!;
    final provider = context.read<VocabularyProvider>();

    // Update session metrics
    switch (rating) {
      case SrsRating.again:
        _againCount++;
        break;
      case SrsRating.hard:
        _hardCount++;
        break;
      case SrsRating.good:
        _goodCount++;
        break;
      case SrsRating.easy:
        _easyCount++;
        break;
    }

    // Persist SM-2 schedule
    await provider.recordSrsReview(wordId: word.id, rating: rating);

    if (!mounted) return;

    if (_currentIndex + 1 < _queue.length) {
      setState(() {
        _currentIndex++;
        _isFlipped = false;
      });
      _playCurrentWordAudio();
    } else {
      setState(() {
        _isComplete = true;
      });
    }
  }

  void _handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return;

    final key = event.logicalKey;
    if (!_isFlipped) {
      if (key == LogicalKeyboardKey.space ||
          key == LogicalKeyboardKey.enter ||
          key == LogicalKeyboardKey.arrowDown) {
        _flipCard();
      } else if (key == LogicalKeyboardKey.keyA) {
        _playCurrentWordAudio();
      }
    } else {
      if (key == LogicalKeyboardKey.digit1 || key == LogicalKeyboardKey.numpad1) {
        _rateCard(SrsRating.again);
      } else if (key == LogicalKeyboardKey.digit2 ||
          key == LogicalKeyboardKey.numpad2) {
        _rateCard(SrsRating.hard);
      } else if (key == LogicalKeyboardKey.digit3 ||
          key == LogicalKeyboardKey.numpad3) {
        _rateCard(SrsRating.good);
      } else if (key == LogicalKeyboardKey.digit4 ||
          key == LogicalKeyboardKey.numpad4) {
        _rateCard(SrsRating.easy);
      } else if (key == LogicalKeyboardKey.keyA) {
        _playCurrentWordAudio();
      }
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
                    ? _buildLoading()
                    : _queue.isEmpty
                    ? _buildEmptyState(context)
                    : _isComplete
                    ? _buildVictoryScreen(context)
                    : _buildReviewCard(context),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTopBar(BuildContext context) {
    final palette = context.palette;
    final streak = context.watch<VocabularyProvider>().stats.streakDays;

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
            semanticLabel: 'Exit review',
            onPressed: () => Navigator.of(context).pop(),
          ),
          const SizedBox(width: PixelMetrics.space2),
          Text(
            'SPACED REVIEW',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const Spacer(),
          if (!_isLoading && _queue.isNotEmpty && !_isComplete) ...[
            _buildProgressBar(context),
            const SizedBox(width: PixelMetrics.space2),
          ],
          PixelIconButton(
            glyph: PixelGlyph.headphones,
            semanticLabel: 'Hands-Free Audio Review',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const AudioCommuteScreen(),
              ),
            ),
          ),
          const SizedBox(width: PixelMetrics.space2),
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: PixelMetrics.space2,
              vertical: 2,
            ),
            decoration: BoxDecoration(
              border: Border.all(color: palette.border, width: PixelMetrics.border),
            ),
            child: Text(
              '🔥$streak',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProgressBar(BuildContext context) {
    final palette = context.palette;
    final total = _queue.length;
    final current = _currentIndex + 1;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$current/$total',
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            fontFamily: 'Handjet',
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(width: PixelMetrics.space2),
        // Segmented 8-bit health / XP bar (max 10 blocks)
        Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(
            total.clamp(1, 10),
            (i) {
              final stepRatio = i / total.clamp(1, 10);
              final progressRatio = current / total;
              final isFilled = stepRatio < progressRatio;

              return Container(
                width: 6,
                height: 10,
                margin: const EdgeInsets.only(right: 2),
                decoration: BoxDecoration(
                  color: isFilled ? palette.accent : palette.paper,
                  border: Border.all(
                    color: palette.border,
                    width: 1,
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildLoading() {
    return Center(
      child: Text(
        'LOADING BATTLE DECK…',
        style: Theme.of(context).textTheme.labelSmall,
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    final palette = context.palette;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(PixelMetrics.space6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(PixelMetrics.space4),
              decoration: BoxDecoration(
                color: palette.surface,
                border: Border.all(color: palette.border, width: PixelMetrics.border),
              ),
              child: Column(
                children: [
                  Text(
                    '★ ALL CAUGHT UP! ★',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: palette.accent,
                    ),
                  ),
                  const SizedBox(height: PixelMetrics.space3),
                  Text(
                    'No words are currently due for review today.\nCapture new words or practice with your full deck!',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ],
              ),
            ),
            const SizedBox(height: PixelMetrics.space5),
            PixelButton(
              label: 'Practice full deck',
              glyph: PixelGlyph.cards,
              filled: true,
              expand: true,
              onPressed: () {
                Navigator.of(context).pushReplacement(
                  PageRouteBuilder<void>(
                    pageBuilder: (_, _, _) => const ReviewScreen(practiceAll: true),
                    transitionDuration: Duration.zero,
                  ),
                );
              },
            ),
            const SizedBox(height: PixelMetrics.space3),
            PixelButton(
              label: 'Return to journal',
              expand: true,
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildReviewCard(BuildContext context) {
    final word = _currentWord!;
    final palette = context.palette;
    final theme = Theme.of(context);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(PixelMetrics.space4),
      child: Column(
        children: [
          // 8-bit RPG Battle / Dialogue Window
          PixelBox(
            raised: true,
            padding: EdgeInsets.zero,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Dialogue Header Bar
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: PixelMetrics.space3,
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
                      Text(
                        'ROUND ${_currentIndex + 1} OF ${_queue.length}',
                        style: theme.textTheme.labelSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const Spacer(),
                      if (word.partOfSpeech != null)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: palette.paper,
                            border: Border.all(
                              color: palette.border,
                              width: 1,
                            ),
                          ),
                          child: Text(
                            word.partOfSpeech!.short.toUpperCase(),
                            style: theme.textTheme.labelSmall?.copyWith(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),

                // Front of Card Content
                Padding(
                  padding: const EdgeInsets.all(PixelMetrics.space5),
                  child: Column(
                    children: [
                      const SizedBox(height: PixelMetrics.space2),
                      Text(
                        word.word,
                        style: theme.textTheme.headlineMedium?.copyWith(
                          fontFamily: 'Handjet',
                          fontWeight: FontWeight.bold,
                          fontSize: 36,
                          letterSpacing: 1.5,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: PixelMetrics.space2),

                      // Audio / IPA Button
                      GestureDetector(
                        onTap: _playCurrentWordAudio,
                        behavior: HitTestBehavior.opaque,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: PixelMetrics.space3,
                            vertical: PixelMetrics.space1,
                          ),
                          decoration: BoxDecoration(
                            color: palette.paper,
                            border: Border.all(
                              color: palette.border,
                              width: PixelMetrics.border,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              PixelIcon(
                                PixelGlyph.speaker,
                                color: palette.accent,
                                scale: 2,
                              ),
                              const SizedBox(width: PixelMetrics.space2),
                              Text(
                                word.pronunciation ?? '/pronounce/',
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: palette.accent,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),

                      if (word.source != null && word.source!.isNotEmpty) ...[
                        const SizedBox(height: PixelMetrics.space4),
                        Text(
                          'ENCOUNTERED: "${word.source}"',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: palette.inkMuted,
                            fontStyle: FontStyle.italic,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],

                      if (word.tags.isNotEmpty) ...[
                        const SizedBox(height: PixelMetrics.space2),
                        Wrap(
                          spacing: 4,
                          children: word.tags
                              .map(
                                (t) => Text(
                                  '#$t',
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: palette.inkFaint,
                                  ),
                                ),
                              )
                              .toList(),
                        ),
                      ],
                    ],
                  ),
                ),

                // Back of Card (Revealed Meaning & Examples)
                if (_isFlipped) ...[
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(PixelMetrics.space4),
                    decoration: BoxDecoration(
                      color: palette.paper,
                      border: Border(
                        top: BorderSide(
                          color: palette.border,
                          width: PixelMetrics.border,
                        ),
                        bottom: BorderSide(
                          color: palette.border,
                          width: PixelMetrics.border,
                        ),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'VIETNAMESE MEANING',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: palette.inkMuted,
                          ),
                        ),
                        const SizedBox(height: PixelMetrics.space1),
                        Text(
                          word.meaning,
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: palette.ink,
                            fontWeight: FontWeight.bold,
                            fontSize: 20,
                          ),
                        ),
                        if (word.examples.isNotEmpty) ...[
                          const SizedBox(height: PixelMetrics.space3),
                          Text(
                            'EXAMPLE CONTEXT',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: palette.inkMuted,
                            ),
                          ),
                          const SizedBox(height: PixelMetrics.space1),
                          for (final ex in word.examples)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 2),
                              child: Text(
                                '• "$ex"',
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: palette.inkMuted,
                                ),
                              ),
                            ),
                        ],
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),

          const SizedBox(height: PixelMetrics.space5),

          // Action Area
          if (!_isFlipped)
            PixelButton(
              label: 'Reveal Meaning  [ SPACE ]',
              glyph: PixelGlyph.arrowRight,
              filled: true,
              expand: true,
              onPressed: _flipCard,
            )
          else ...[
            Text(
              'HOW WELL DID YOU RECALL THIS?',
              style: theme.textTheme.labelSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: PixelMetrics.space3),
            _buildRatingButtons(context),
          ],
        ],
      ),
    );
  }

  Widget _buildRatingButtons(BuildContext context) {
    final palette = context.palette;

    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: _RatingCardButton(
                keyLabel: '1',
                title: SrsRating.again.label,
                subtitle: SrsRating.again.estimatedInterval,
                borderColor: palette.danger,
                textColor: palette.danger,
                onPressed: () => _rateCard(SrsRating.again),
              ),
            ),
            const SizedBox(width: PixelMetrics.space2),
            Expanded(
              child: _RatingCardButton(
                keyLabel: '2',
                title: SrsRating.hard.label,
                subtitle: SrsRating.hard.estimatedInterval,
                borderColor: palette.inkFaint,
                textColor: palette.inkMuted,
                onPressed: () => _rateCard(SrsRating.hard),
              ),
            ),
          ],
        ),
        const SizedBox(height: PixelMetrics.space2),
        Row(
          children: [
            Expanded(
              child: _RatingCardButton(
                keyLabel: '3',
                title: SrsRating.good.label,
                subtitle: SrsRating.good.estimatedInterval,
                borderColor: palette.border,
                textColor: palette.ink,
                onPressed: () => _rateCard(SrsRating.good),
              ),
            ),
            const SizedBox(width: PixelMetrics.space2),
            Expanded(
              child: _RatingCardButton(
                keyLabel: '4',
                title: SrsRating.easy.label,
                subtitle: SrsRating.easy.estimatedInterval,
                borderColor: palette.accent,
                textColor: palette.onAccent,
                fillColor: palette.accent,
                onPressed: () => _rateCard(SrsRating.easy),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildVictoryScreen(BuildContext context) {
    final palette = context.palette;
    final theme = Theme.of(context);
    final total = _queue.length;
    final correct = _goodCount + _easyCount;
    final accuracy = total > 0 ? ((correct / total) * 100).round() : 100;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(PixelMetrics.space5),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            PixelBox(
              raised: true,
              padding: const EdgeInsets.all(PixelMetrics.space5),
              child: Column(
                children: [
                  Text(
                    '★ STAGE CLEARED! ★',
                    style: theme.textTheme.headlineSmall?.copyWith(
                      color: palette.accent,
                      fontFamily: 'Handjet',
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.2,
                    ),
                  ),
                  const SizedBox(height: PixelMetrics.space4),
                  _buildStatRow(context, 'WORDS REVIEWED', '$total'),
                  const SizedBox(height: PixelMetrics.space2),
                  _buildStatRow(context, 'ACCURACY RATE', '$accuracy%'),
                  const SizedBox(height: PixelMetrics.space2),
                  _buildStatRow(
                    context,
                    'PERFECT RECALL',
                    '$correct / $total',
                  ),
                  const SizedBox(height: PixelMetrics.space2),
                  _buildStatRow(
                    context,
                    'NEEDS PRACTICE',
                    '${_againCount + _hardCount}',
                  ),
                  const SizedBox(height: PixelMetrics.space4),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(PixelMetrics.space2),
                    color: palette.paper,
                    child: Text(
                      'NEXT REVIEWS SCHEDULED VIA SM-2 ALGORITHM',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: palette.inkMuted,
                        fontSize: 10,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: PixelMetrics.space5),
            PixelButton(
              label: 'Return to journal',
              glyph: PixelGlyph.check,
              filled: true,
              expand: true,
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatRow(BuildContext context, String label, String value) {
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

class _RatingCardButton extends StatelessWidget {
  const _RatingCardButton({
    required this.keyLabel,
    required this.title,
    required this.subtitle,
    required this.borderColor,
    required this.textColor,
    this.fillColor,
    required this.onPressed,
  });

  final String keyLabel;
  final String title;
  final String subtitle;
  final Color borderColor;
  final Color textColor;
  final Color? fillColor;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final bg = fillColor ?? palette.surface;

    return GestureDetector(
      onTap: onPressed,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: PixelMetrics.space3,
          vertical: PixelMetrics.space2,
        ),
        decoration: BoxDecoration(
          color: bg,
          border: Border.all(color: borderColor, width: PixelMetrics.border),
        ),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  decoration: BoxDecoration(
                    color: palette.paper,
                    border: Border.all(color: borderColor, width: 1),
                  ),
                  child: Text(
                    keyLabel,
                    style: TextStyle(
                      fontFamily: 'Handjet',
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: textColor,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Text(
                  title,
                  style: TextStyle(
                    fontFamily: 'Handjet',
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: textColor,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              subtitle,
              style: TextStyle(
                fontFamily: 'Handjet',
                fontSize: 11,
                color: fillColor != null ? textColor : palette.inkMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
