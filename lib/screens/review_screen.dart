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
import '../services/pronunciation_service.dart';
import '../widgets/highlighted_text.dart';
import '../widgets/pixel/pixel_box.dart';
import '../widgets/pixel/pixel_button.dart';
import '../widgets/pixel/pixel_icon.dart';
import '../widgets/practice_word_picker.dart';
import 'audio_commute_screen.dart';
import 'word_editor_screen.dart';

/// Spaced Repetition (SM-2) Flashcard Review Screen.
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
    final theme = Theme.of(context);
    final showProgress = !_isLoading && _queue.isNotEmpty && !_isComplete;

    return Container(
      decoration: BoxDecoration(
        color: palette.surface,
        border: Border(
          bottom: BorderSide(color: palette.border, width: PixelMetrics.border),
        ),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              PixelMetrics.space3,
              PixelMetrics.space2,
              PixelMetrics.space3,
              0,
            ),
            child: Row(
              children: [
                PixelIconButton(
                  glyph: PixelGlyph.arrowLeft,
                  semanticLabel: 'Exit review',
                  onPressed: () => Navigator.of(context).pop(),
                ),
                const SizedBox(width: PixelMetrics.space2),
                Expanded(
                  child: Text('Review', style: theme.textTheme.titleMedium),
                ),
                const SizedBox(width: PixelMetrics.space2),
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
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(
              PixelMetrics.space4,
              PixelMetrics.space1,
              PixelMetrics.space3,
              showProgress ? PixelMetrics.space1 : PixelMetrics.space2,
            ),
            child: SizedBox(
              width: double.infinity,
              child: Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: PixelMetrics.space2,
                runSpacing: PixelMetrics.space1,
                children: [
                  Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: PixelMetrics.space2,
                    runSpacing: 2,
                    children: [
                      Text(
                        _selectionLabel ??
                            (widget.practiceAll ? 'Recent words' : 'Due words'),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: palette.inkMuted,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      if (showProgress) ...[
                        Text(
                          '·',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: palette.inkFaint,
                          ),
                        ),
                        Text(
                          'Word ${_currentIndex + 1} of ${_queue.length}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: palette.inkMuted,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ],
                  ),
                  TextButton.icon(
                    key: const Key('choose_review_words'),
                    style: TextButton.styleFrom(
                      foregroundColor: palette.accent,
                      padding: const EdgeInsets.symmetric(
                        horizontal: PixelMetrics.space2,
                        vertical: PixelMetrics.space1,
                      ),
                      minimumSize: const Size(0, PixelMetrics.tapTarget),
                      tapTargetSize: MaterialTapTargetSize.padded,
                    ),
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
                    icon: const Icon(Icons.checklist_rounded, size: 18),
                    label: Text(_isChoosingWords ? 'Loading…' : 'Choose words'),
                  ),
                ],
              ),
            ),
          ),
          if (showProgress)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                PixelMetrics.space4,
                0,
                PixelMetrics.space4,
                PixelMetrics.space2,
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(PixelMetrics.radiusPill),
                child: LinearProgressIndicator(
                  value: _currentIndex / _queue.length,
                  minHeight: 4,
                  backgroundColor: palette.border.withValues(alpha: 0.7),
                  color: palette.accent,
                  semanticsLabel: 'Review progress',
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildLoading() {
    final palette = context.palette;
    return Center(
      child: Text(
        'Loading your words…',
        style: Theme.of(
          context,
        ).textTheme.bodyMedium?.copyWith(color: palette.inkMuted),
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    final palette = context.palette;
    final theme = Theme.of(context);
    final totalWords = context.watch<VocabularyProvider>().stats.totalWords;

    return Center(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(PixelMetrics.space6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              PixelBox(
                raised: true,
                padding: const EdgeInsets.all(PixelMetrics.space5),
                child: Column(
                  children: [
                    Text(
                      'All caught up',
                      style: theme.textTheme.titleLarge?.copyWith(
                        color: palette.accent,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: PixelMetrics.space3),
                    Text(
                      totalWords == 0
                          ? 'Save your first word to start reviewing.'
                          : 'No words are due right now. Come back later or practice your recent words.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: palette.inkMuted,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: PixelMetrics.space5),
              PixelButton(
                label: totalWords == 0 ? 'Add a word' : 'Practice recent words',
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
    final rawIpa = PronunciationService.normalise(word.pronunciation ?? '');
    final ipa = rawIpa.isEmpty ? null : PronunciationService.format(rawIpa);

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
        PixelMetrics.space4,
        PixelMetrics.space5,
        PixelMetrics.space4,
        PixelMetrics.space6,
      ),
      child: Column(
        children: [
          // Clean Word-Centered Flashcard
          PixelBox(
            raised: true,
            padding: EdgeInsets.zero,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Front of Card Content
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: PixelMetrics.space5,
                    vertical: PixelMetrics.space6,
                  ),
                  child: Column(
                    children: [
                      if (word.partOfSpeech != null) ...[
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: palette.accent.withValues(alpha: 0.10),
                            borderRadius: BorderRadius.circular(
                              PixelMetrics.radiusPill,
                            ),
                          ),
                          child: Text(
                            word.partOfSpeech!.short,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: palette.accent,
                            ),
                          ),
                        ),
                        const SizedBox(height: PixelMetrics.space3),
                      ],
                      Text(
                        word.word,
                        style: theme.textTheme.displaySmall?.copyWith(
                          fontSize: 34,
                          fontWeight: FontWeight.w700,
                          color: palette.ink,
                          height: 1.2,
                          letterSpacing: -0.4,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: PixelMetrics.space3),

                      // Audio / IPA Pill Button
                      Semantics(
                        button: true,
                        label: ipa != null
                            ? 'Hear pronunciation $ipa'
                            : 'Hear word',
                        excludeSemantics: true,
                        onTap: _playCurrentWordAudio,
                        child: Material(
                          color: palette.paper,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(
                              PixelMetrics.radiusPill,
                            ),
                            side: BorderSide(
                              color: palette.border,
                              width: PixelMetrics.border,
                            ),
                          ),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(
                              PixelMetrics.radiusPill,
                            ),
                            onTap: _playCurrentWordAudio,
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(
                                minHeight: PixelMetrics.tapTarget,
                              ),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: PixelMetrics.space4,
                                  vertical: PixelMetrics.space2,
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
                                        ipa ?? 'Hear word',
                                        style: theme.textTheme.bodyLarge
                                            ?.copyWith(color: palette.inkMuted),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),

                      if (word.displaySource != null) ...[
                        const SizedBox(height: PixelMetrics.space4),
                        Text(
                          'From “${word.displaySource}”',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: palette.inkMuted,
                            fontStyle: FontStyle.italic,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],

                      if (word.tags.isNotEmpty) ...[
                        const SizedBox(height: PixelMetrics.space2),
                        Wrap(
                          alignment: WrapAlignment.center,
                          spacing: PixelMetrics.space2,
                          runSpacing: PixelMetrics.space1,
                          children: word.tags
                              .map(
                                (t) => Text(
                                  '#$t',
                                  style: theme.textTheme.bodySmall?.copyWith(
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
                  Divider(height: 1, color: palette.border),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(PixelMetrics.space5),
                    decoration: BoxDecoration(
                      color: palette.paper.withValues(alpha: 0.55),
                      borderRadius: const BorderRadius.vertical(
                        bottom: Radius.circular(PixelMetrics.radiusLg - 1),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Meaning',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: palette.inkMuted,
                          ),
                        ),
                        const SizedBox(height: PixelMetrics.space1),
                        Text(
                          word.meaning,
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: palette.ink,
                            fontWeight: FontWeight.w600,
                            fontSize: 19,
                            height: 1.4,
                          ),
                        ),
                        if (word.examples.isNotEmpty) ...[
                          const SizedBox(height: PixelMetrics.space4),
                          Text(
                            word.examples.length == 1 ? 'Example' : 'Examples',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: palette.inkMuted,
                            ),
                          ),
                          const SizedBox(height: PixelMetrics.space2),
                          for (final ex in word.examples)
                            Padding(
                              padding: const EdgeInsets.only(
                                bottom: PixelMetrics.space2,
                              ),
                              child: HighlightedText(
                                text: '“$ex”',
                                targetWord: word.word,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: palette.ink,
                                  fontStyle: FontStyle.italic,
                                  height: 1.4,
                                ),
                                highlightStyle: theme.textTheme.bodyMedium
                                    ?.copyWith(
                                      color: palette.accent,
                                      fontWeight: FontWeight.w600,
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
              'How well did you recall this?',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: palette.inkMuted,
                fontWeight: FontWeight.w500,
              ),
              textAlign: TextAlign.center,
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
    final stackVertically = MediaQuery.textScalerOf(context).scale(1) > 1.5;

    final againButton = _RatingCardButton(
      keyLabel: '1',
      title: 'Again',
      subtitle: 'Forgot it',
      borderColor: palette.danger.withValues(alpha: 0.45),
      textColor: palette.danger,
      onPressed: _isSubmitting ? null : () => _rateCard(SrsRating.again),
    );
    final hardButton = _RatingCardButton(
      keyLabel: '2',
      title: 'Hard',
      subtitle: 'Needed a hint',
      borderColor: palette.border,
      textColor: palette.ink,
      onPressed: _isSubmitting ? null : () => _rateCard(SrsRating.hard),
    );
    final goodButton = _RatingCardButton(
      keyLabel: '3',
      title: 'Good',
      subtitle: 'Remembered',
      borderColor: palette.border,
      textColor: palette.ink,
      onPressed: _isSubmitting ? null : () => _rateCard(SrsRating.good),
    );
    final easyButton = _RatingCardButton(
      keyLabel: '4',
      title: 'Easy',
      subtitle: 'Knew it quickly',
      borderColor: palette.accent.withValues(alpha: 0.45),
      textColor: palette.accent,
      onPressed: _isSubmitting ? null : () => _rateCard(SrsRating.easy),
    );

    if (stackVertically) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          againButton,
          const SizedBox(height: PixelMetrics.space2),
          hardButton,
          const SizedBox(height: PixelMetrics.space2),
          goodButton,
          const SizedBox(height: PixelMetrics.space2),
          easyButton,
        ],
      );
    }

    return Column(
      children: [
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: againButton),
              const SizedBox(width: PixelMetrics.space2),
              Expanded(child: hardButton),
            ],
          ),
        ),
        const SizedBox(height: PixelMetrics.space2),
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: goodButton),
              const SizedBox(width: PixelMetrics.space2),
              Expanded(child: easyButton),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildVictoryScreen(BuildContext context) {
    final palette = context.palette;
    final theme = Theme.of(context);
    final total = _queue.length;
    final correct = _goodCount + _easyCount;

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
                      style: theme.textTheme.headlineMedium?.copyWith(
                        color: palette.accent,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: PixelMetrics.space5),
                    _buildStatRow(context, 'Words reviewed', '$total'),
                    Divider(height: PixelMetrics.space5, color: palette.border),
                    _buildStatRow(
                      context,
                      'Comfortable recall',
                      '$correct / $total',
                    ),
                    Divider(height: PixelMetrics.space5, color: palette.border),
                    _buildStatRow(
                      context,
                      'Needs practice',
                      '${_againCount + _hardCount}',
                    ),
                    const SizedBox(height: PixelMetrics.space5),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(PixelMetrics.space3),
                      decoration: BoxDecoration(
                        color: palette.paper,
                        borderRadius: BorderRadius.circular(
                          PixelMetrics.radiusSm,
                        ),
                      ),
                      child: Text(
                        'Your next reviews are scheduled automatically.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: palette.inkMuted,
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
    final palette = context.palette;
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: palette.inkMuted,
            ),
          ),
        ),
        const SizedBox(width: PixelMetrics.space2),
        Text(
          value,
          style: theme.textTheme.titleMedium?.copyWith(
            color: palette.ink,
            fontWeight: FontWeight.w700,
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
    this.onPressed,
  });

  final String keyLabel;
  final String title;
  final String subtitle;
  final Color borderColor;
  final Color textColor;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final theme = Theme.of(context);

    return Semantics(
      button: true,
      enabled: onPressed != null,
      label: '$title, $subtitle',
      excludeSemantics: true,
      onTap: onPressed,
      child: Material(
        color: palette.surface,
        borderRadius: BorderRadius.circular(PixelMetrics.radius),
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(PixelMetrics.radius),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 56),
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: PixelMetrics.space3,
                vertical: PixelMetrics.space3,
              ),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(PixelMetrics.radius),
                border: Border.all(
                  color: borderColor,
                  width: PixelMetrics.border,
                ),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: palette.paper,
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: palette.border, width: 1),
                        ),
                        child: Text(
                          keyLabel,
                          style: theme.textTheme.labelSmall?.copyWith(
                            fontSize: 11,
                            color: palette.inkMuted,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          title,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.labelMedium?.copyWith(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: textColor,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontSize: 12,
                      color: palette.inkMuted,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
