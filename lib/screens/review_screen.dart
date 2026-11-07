import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../core/theme/pixel_metrics.dart';
import '../core/theme/pixel_palette.dart';
import '../models/srs_review.dart';
import '../models/vocabulary_word.dart';
import '../providers/vocabulary_provider.dart';
import '../services/tts_service.dart';
import '../widgets/highlighted_text.dart';
import '../widgets/pixel/pixel_box.dart';
import '../widgets/pixel/pixel_button.dart';
import '../widgets/pixel/pixel_icon.dart';
import '../widgets/practice_word_picker.dart';
import 'audio_commute_screen.dart';
import 'word_editor_screen.dart';

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
  String? _loadError;
  int _currentIndex = 0;
  bool _isFlipped = false;
  bool _isComplete = false;
  bool _isChoosingWords = false;
  Set<String>? _selectedReviewIds;
  String? _selectionLabel;

  // Session stats
  int _againCount = 0;
  int _hardCount = 0;
  int _goodCount = 0;
  int _easyCount = 0;
  bool _isSubmitting = false;

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
    setState(() {
      _isLoading = true;
      _loadError = null;
    });
    try {
      final provider = context.read<VocabularyProvider>();
      final words = widget.practiceAll
          ? await provider.allWords(limit: 50)
          : await provider.wordsDueForReview(limit: 20);
      if (!mounted) return;
      _startSession(words);
    } catch (_) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _loadError = 'Could not load your review. Please try again.';
        });
      }
    }
  }

  void _startSession(List<VocabularyWord> words) {
    setState(() {
      _queue = words;
      _isLoading = false;
      _loadError = null;
      _currentIndex = 0;
      _isFlipped = false;
      _isComplete = false;
      _againCount = 0;
      _hardCount = 0;
      _goodCount = 0;
      _easyCount = 0;
    });
    _playCurrentWordAudio();
  }

  Future<void> _chooseWords() async {
    if (_isLoading || _isSubmitting || _isChoosingWords) return;
    setState(() => _isChoosingWords = true);
    final provider = context.read<VocabularyProvider>();
    final tts = context.read<TtsService>();
    try {
      final words = await provider.allWords();
      if (!mounted) return;
      await tts.stop();
      if (!mounted) return;
      final result = await Navigator.of(context).push<PracticePoolSelection>(
        MaterialPageRoute(
          fullscreenDialog: true,
          builder: (_) => PracticeWordPicker(
            words: words,
            selectedIds: (_selectedReviewIds ?? _queue.map((w) => w.id).toSet())
                .toList(),
            title: 'Review words',
            confirmLabel: 'Start review',
            allowFutureWords: false,
            confirmAtBottom: true,
          ),
        ),
      );
      if (!mounted || result == null) return;
      final latestWords = await provider.allWords();
      if (!mounted) return;
      final ids = (result.wordIds ?? words.map((w) => w.id).toList()).toSet();
      final selected = latestWords.where((w) => ids.contains(w.id)).toList();
      if (selected.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Those words are no longer available. Please choose again.',
            ),
          ),
        );
        return;
      }
      final dates = selected.map((word) => word.date).toSet();
      final date = dates.length == 1 ? DateTime.tryParse(dates.single) : null;
      _selectedReviewIds = selected.map((w) => w.id).toSet();
      _selectionLabel = selected.length == latestWords.length
          ? 'All words'
          : date != null
          ? DateFormat.yMMMd().format(date)
          : '${dates.length} days';
      _startSession(selected);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Could not load your words. Please try choosing again.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isChoosingWords = false);
        _focusNode.requestFocus();
      }
    }
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
    if (!_isFlipped || _currentWord == null || _isSubmitting) return;
    setState(() => _isSubmitting = true);

    final word = _currentWord!;
    final provider = context.read<VocabularyProvider>();

    try {
      await provider.recordSrsReview(wordId: word.id, rating: rating);
      if (!mounted) return;
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
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Your review was not saved. Please try rating this word again.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSubmitting = false);
      }
    }
  }

  void _handleKeyEvent(KeyEvent event) {
    if (_isChoosingWords || _isLoading || _isSubmitting) return;
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
      if (key == LogicalKeyboardKey.digit1 ||
          key == LogicalKeyboardKey.numpad1) {
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
                    : _loadError != null
                    ? Center(
                        child: SingleChildScrollView(
                          child: Padding(
                            padding: const EdgeInsets.all(PixelMetrics.space6),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(_loadError!, textAlign: TextAlign.center),
                                const SizedBox(height: PixelMetrics.space3),
                                PixelButton(
                                  label: 'Try again',
                                  onPressed: _loadReviewQueue,
                                ),
                              ],
                            ),
                          ),
                        ),
                      )
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
    return Container(
      padding: const EdgeInsets.all(PixelMetrics.space2),
      color: palette.surface,
      child: Column(
        children: [
          Row(
            children: [
              PixelIconButton(
                glyph: PixelGlyph.arrowLeft,
                semanticLabel: 'Exit review',
                onPressed: () => Navigator.of(context).pop(),
              ),
              const SizedBox(width: PixelMetrics.space2),
              Expanded(
                child: Text(
                  'Review',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              PixelIconButton(
                glyph: PixelGlyph.headphones,
                semanticLabel: 'Hands-Free Audio Review',
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const AudioCommuteScreen(),
                  ),
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: PixelMetrics.space2,
            ),
            child: SizedBox(
              width: double.infinity,
              child: Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: PixelMetrics.space2,
                children: [
                  Text(
                    _selectionLabel ??
                        (widget.practiceAll ? 'Recent words' : 'Due words'),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  TextButton.icon(
                    key: const Key('choose_review_words'),
                    onPressed:
                        _isLoading ||
                            _isSubmitting ||
                            _isChoosingWords ||
                            context
                                    .watch<VocabularyProvider>()
                                    .stats
                                    .totalWords ==
                                0
                        ? null
                        : _chooseWords,
                    icon: const Icon(Icons.checklist, size: 20),
                    label: Text(_isChoosingWords ? 'Loading…' : 'Choose words'),
                  ),
                ],
              ),
            ),
          ),
          if (!_isLoading && _queue.isNotEmpty && !_isComplete)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                PixelMetrics.space2,
                0,
                PixelMetrics.space2,
                PixelMetrics.space2,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Word ${_currentIndex + 1} of ${_queue.length}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: PixelMetrics.space1),
                  LinearProgressIndicator(
                    value: _currentIndex / _queue.length,
                    backgroundColor: palette.border,
                    color: palette.accent,
                    semanticsLabel: 'Review progress',
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildLoading() {
    return Center(
      child: Text(
        'Loading your words…',
        style: Theme.of(context).textTheme.labelSmall,
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    final palette = context.palette;

    return Center(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(PixelMetrics.space6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(PixelMetrics.space4),
                decoration: BoxDecoration(
                  color: palette.surface,
                  border: Border.all(
                    color: palette.border,
                    width: PixelMetrics.border,
                  ),
                ),
                child: Column(
                  children: [
                    Text(
                      'All caught up',
                      style: Theme.of(
                        context,
                      ).textTheme.titleMedium?.copyWith(color: palette.accent),
                    ),
                    const SizedBox(height: PixelMetrics.space3),
                    Text(
                      context.watch<VocabularyProvider>().stats.totalWords == 0
                          ? 'Save your first word to start reviewing.'
                          : 'No words are due right now. Come back later or practice your recent words.',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: PixelMetrics.space5),
              PixelButton(
                label: context.watch<VocabularyProvider>().stats.totalWords == 0
                    ? 'Add a word'
                    : 'Practice recent words',
                glyph: PixelGlyph.cards,
                filled: true,
                expand: true,
                onPressed: () {
                  Navigator.of(context).pushReplacement(
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          context.read<VocabularyProvider>().stats.totalWords ==
                              0
                          ? const WordEditorScreen()
                          : const ReviewScreen(practiceAll: true),
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
                      Expanded(
                        child: Text(
                          'ROUND ${_currentIndex + 1} OF ${_queue.length}',
                          style: theme.textTheme.labelSmall?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      if (word.partOfSpeech != null)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: palette.paper,
                            border: Border.all(color: palette.border, width: 1),
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
                              Flexible(
                                child: Text(
                                  word.pronunciation ?? 'Hear word',
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    color: palette.accent,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),

                      if (word.displaySource != null) ...[
                        const SizedBox(height: PixelMetrics.space4),
                        Text(
                          'ENCOUNTERED: "${word.displaySource}"',
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
                          style: theme.textTheme.bodyLarge?.copyWith(
                            color: palette.ink,
                            fontWeight: FontWeight.bold,
                            fontSize: 18,
                            height: 1.35,
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
                              padding: const EdgeInsets.only(bottom: 6),
                              child: HighlightedText(
                                text: '• “$ex”',
                                targetWord: word.word,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: palette.ink,
                                  fontStyle: FontStyle.italic,
                                  height: 1.35,
                                ),
                                highlightStyle: theme.textTheme.bodyMedium
                                    ?.copyWith(
                                      color: palette.accent,
                                      fontWeight: FontWeight.bold,
                                      fontStyle: FontStyle.italic,
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
              label: 'Show meaning',
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
                title: 'Again',
                subtitle: 'Forgot it',
                borderColor: palette.danger,
                textColor: palette.danger,
                onPressed: _isSubmitting
                    ? null
                    : () => _rateCard(SrsRating.again),
              ),
            ),
            const SizedBox(width: PixelMetrics.space2),
            Expanded(
              child: _RatingCardButton(
                keyLabel: '2',
                title: 'Hard',
                subtitle: 'Needed a hint',
                borderColor: palette.inkFaint,
                textColor: palette.inkMuted,
                onPressed: _isSubmitting
                    ? null
                    : () => _rateCard(SrsRating.hard),
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
                title: 'Good',
                subtitle: 'Remembered',
                borderColor: palette.border,
                textColor: palette.ink,
                onPressed: _isSubmitting
                    ? null
                    : () => _rateCard(SrsRating.good),
              ),
            ),
            const SizedBox(width: PixelMetrics.space2),
            Expanded(
              child: _RatingCardButton(
                keyLabel: '4',
                title: 'Easy',
                subtitle: 'Knew it quickly',
                borderColor: palette.accent,
                textColor: palette.onAccent,
                fillColor: palette.accent,
                onPressed: _isSubmitting
                    ? null
                    : () => _rateCard(SrsRating.easy),
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
      child: SingleChildScrollView(
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
                      'Review complete',
                      style: theme.textTheme.headlineSmall?.copyWith(
                        color: palette.accent,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.2,
                      ),
                    ),
                    const SizedBox(height: PixelMetrics.space4),
                    _buildStatRow(context, 'WORDS REVIEWED', '$total'),
                    const SizedBox(height: PixelMetrics.space2),
                    _buildStatRow(context, 'COMFORTABLE RECALL', '$accuracy%'),
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
                        'Your next reviews are scheduled automatically.',
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
      ),
    );
  }

  Widget _buildStatRow(BuildContext context, String label, String value) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(child: Text(label, style: theme.textTheme.labelSmall)),
        const SizedBox(width: PixelMetrics.space2),
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
    this.onPressed,
  });

  final String keyLabel;
  final String title;
  final String subtitle;
  final Color borderColor;
  final Color textColor;
  final Color? fillColor;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final bg = fillColor ?? palette.surface;

    return Semantics(
      button: true,
      enabled: onPressed != null,
      label: '$title, $subtitle',
      excludeSemantics: true,
      onTap: onPressed,
      child: GestureDetector(
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
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: palette.paper,
                      border: Border.all(color: borderColor, width: 1),
                    ),
                    child: Text(
                      keyLabel,
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: textColor,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      title,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: textColor,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: TextStyle(
                  fontSize: 11,
                  color: fillColor != null ? textColor : palette.inkMuted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
