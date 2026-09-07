import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/theme/pixel_metrics.dart';
import '../core/theme/pixel_palette.dart';
import '../providers/vocabulary_provider.dart';
import '../services/clipboard_detector_service.dart';
import '../services/pronunciation_service.dart';
import '../widgets/date_bar.dart';
import '../widgets/pixel/clipboard_detector_toast.dart';
import '../widgets/pixel/pixel_box.dart';
import '../widgets/pixel/pixel_button.dart';
import '../widgets/pixel/pixel_icon.dart';
import '../widgets/word_row.dart';
import 'arcade_screen.dart';
import 'audio_commute_screen.dart';
import 'pixel_lens_screen.dart';
import 'review_screen.dart';
import 'search_screen.dart';
import 'settings_screen.dart';
import 'word_editor_screen.dart';

/// The daily journal.
///
/// Chrome is held to two short bars so the words start near the top of the
/// screen; the previous layout spent roughly 280px on a greeting, two stat
/// cards, a date row and a section heading before the first word appeared.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, this.clipboardReader});

  /// Optional clipboard reader override (primarily for automated testing).
  final Future<String?> Function()? clipboardReader;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  String? _detectedWord;
  bool _isAdding = false;
  final Set<String> _dismissedWords = {};
  Timer? _autoDismissTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkClipboard());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _autoDismissTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkClipboard();
    }
  }

  Future<void> _checkClipboard() async {
    if (!mounted) return;
    final provider = context.read<VocabularyProvider>();
    final candidate = await ClipboardDetectorService.detectCandidate(
      dismissedWords: _dismissedWords,
      existingWords: provider.words.map((w) => w.word).toList(),
      clipboardReader: widget.clipboardReader,
    );

    if (!mounted) return;
    if (candidate != null && candidate != _detectedWord) {
      setState(() {
        _detectedWord = candidate;
      });
      _autoDismissTimer?.cancel();
      _autoDismissTimer = Timer(const Duration(seconds: 8), () {
        if (mounted && _detectedWord == candidate) {
          setState(() {
            _dismissedWords.add(candidate.toLowerCase());
            _detectedWord = null;
          });
        }
      });
    }
  }

  void _dismissDetectedWord(String word) {
    _autoDismissTimer?.cancel();
    setState(() {
      _dismissedWords.add(word.toLowerCase());
      _detectedWord = null;
    });
  }

  Future<void> _addDetectedWord(String word) async {
    _autoDismissTimer?.cancel();
    setState(() => _isAdding = true);

    PronunciationService? pronService;
    try {
      pronService = context.read<PronunciationService>();
    } catch (_) {
      pronService = null;
    }

    final provider = context.read<VocabularyProvider>();
    await ClipboardDetectorService.quickCapture(
      word: word,
      provider: provider,
      pronunciationService: pronService,
    );

    if (!mounted) return;
    setState(() {
      _dismissedWords.add(word.toLowerCase());
      _detectedWord = null;
      _isAdding = false;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('ADDED "$word" TO TODAY'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<VocabularyProvider>();

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            const _TopBar(),
            const DateBar(),
            const StatusLine(),
            if (_detectedWord != null)
              ClipboardDetectorToast(
                word: _detectedWord!,
                isAdding: _isAdding,
                onAdd: () => _addDetectedWord(_detectedWord!),
                onDismiss: () => _dismissDetectedWord(_detectedWord!),
              ),
            Expanded(child: _Body(provider: provider)),
            const _UndoBar(),
          ],
        ),
      ),
      bottomNavigationBar: const _BottomDock(),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar();

  @override
  Widget build(BuildContext context) {
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
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Row(
              children: [
                PixelIcon(PixelGlyph.star, color: palette.accent, scale: 1.5),
                const SizedBox(width: PixelMetrics.space2),
                Flexible(
                  child: Text(
                    'VEEA // JOURNAL',
                    style: TextStyle(
                      fontFamily: 'Handjet',
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: palette.ink,
                      letterSpacing: 1.0,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          Row(
            children: [
              PixelIconButton(
                glyph: PixelGlyph.search,
                semanticLabel: 'Search all words',
                onPressed: () => _open(context, const SearchScreen()),
              ),
              const SizedBox(width: PixelMetrics.space2),
              PixelIconButton(
                glyph: PixelGlyph.camera,
                semanticLabel: 'Pixel Lens OCR Scanner',
                onPressed: () => _open(context, const PixelLensScreen()),
              ),
              const SizedBox(width: PixelMetrics.space2),
              PixelIconButton(
                glyph: PixelGlyph.gear,
                semanticLabel: 'Settings',
                onPressed: () => _open(context, const SettingsScreen()),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _BottomDock extends StatelessWidget {
  const _BottomDock();

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final provider = context.watch<VocabularyProvider>();
    final dueCount = provider.dueReviewCount;

    return Container(
      decoration: BoxDecoration(
        color: palette.surface,
        border: Border(
          top: BorderSide(color: palette.border, width: PixelMetrics.border),
        ),
        boxShadow: [
          BoxShadow(
            color: palette.border.withValues(alpha: 0.12),
            offset: const Offset(0, -2),
            blurRadius: 0,
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: PixelMetrics.space2,
            vertical: PixelMetrics.space2,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _DockItem(
                glyph: PixelGlyph.headphones,
                label: 'AUDIO',
                semanticLabel: 'Commute Audio Player',
                onTap: () => _open(context, const AudioCommuteScreen()),
              ),
              _DockItem(
                glyph: PixelGlyph.gamepad,
                label: 'ARCADE',
                semanticLabel: 'Arcade Mini-Games and Duels',
                onTap: () => _open(context, const ArcadeScreen()),
              ),
              _HeroAddButton(
                onTap: () => _open(context, const WordEditorScreen()),
              ),
              _DockItem(
                glyph: PixelGlyph.cards,
                label: 'REVIEW',
                semanticLabel: 'Spaced repetition review',
                badgeCount: dueCount > 0 ? dueCount : null,
                onTap: () => _open(context, const ReviewScreen()),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HeroAddButton extends StatelessWidget {
  const _HeroAddButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: PixelMetrics.space3,
          vertical: 6,
        ),
        decoration: BoxDecoration(
          color: palette.accent,
          border: Border.all(color: palette.border, width: PixelMetrics.border),
          boxShadow: [
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
            PixelIcon(PixelGlyph.plus, color: palette.onAccent, scale: 1.6),
            const SizedBox(width: 5),
            Text(
              'ADD',
              style: TextStyle(
                fontFamily: 'Handjet',
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: palette.onAccent,
                letterSpacing: 0.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DockItem extends StatelessWidget {
  const _DockItem({
    required this.glyph,
    required this.label,
    required this.semanticLabel,
    required this.onTap,
    this.badgeCount,
  });

  final PixelGlyph glyph;
  final String label;
  final String semanticLabel;
  final VoidCallback onTap;
  final int? badgeCount;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Semantics(
      label: semanticLabel,
      button: true,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  PixelIcon(glyph, color: palette.ink, scale: 1.8),
                  const SizedBox(height: 3),
                  Text(
                    label,
                    style: TextStyle(
                      fontFamily: 'Handjet',
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: palette.inkMuted,
                      letterSpacing: 0.5,
                    ),
                  ),
                ],
              ),
            ),
            if (badgeCount != null)
              Positioned(
                right: 2,
                top: -2,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: palette.danger,
                    border: Border.all(color: palette.paper, width: 1),
                  ),
                  child: Text(
                    '$badgeCount',
                    style: TextStyle(
                      fontFamily: 'Handjet',
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: palette.paper,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.provider});

  final VocabularyProvider provider;

  @override
  Widget build(BuildContext context) {
    if (provider.isLoading) {
      return const _Notice(lines: ['LOADING…']);
    }
    if (provider.status == LoadStatus.failed) {
      return const _Notice(
        lines: ['COULD NOT OPEN YOUR NOTES', 'RESTART THE APP TO RETRY'],
      );
    }
    if (provider.words.isEmpty) {
      if (provider.stats.totalWords == 0) {
        return const _FirstRunStarterBanner();
      }
      return _EmptyDay(isToday: provider.isToday);
    }

    return ListView.builder(
      padding: const EdgeInsets.only(bottom: PixelMetrics.space12),
      itemCount: provider.words.length,
      itemBuilder: (context, index) {
        final word = provider.words[index];
        return WordRow(
          word: word,
          onTap: () => _open(context, WordEditorScreen(existing: word)),
        );
      },
    );
  }
}

class _FirstRunStarterBanner extends StatefulWidget {
  const _FirstRunStarterBanner();

  @override
  State<_FirstRunStarterBanner> createState() => _FirstRunStarterBannerState();
}

class _FirstRunStarterBannerState extends State<_FirstRunStarterBanner> {
  bool _loading = false;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final theme = Theme.of(context);

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(
          horizontal: PixelMetrics.space5,
          vertical: PixelMetrics.space6,
        ),
        child: PixelBox(
          raised: true,
          padding: const EdgeInsets.all(PixelMetrics.space5),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  PixelIcon(PixelGlyph.star, color: palette.accent, scale: 2.2),
                  const SizedBox(width: PixelMetrics.space3),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'WELCOME TO VEEA',
                          style: TextStyle(
                            fontFamily: 'Handjet',
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                            color: palette.ink,
                            letterSpacing: 1.0,
                          ),
                        ),
                        Text(
                          'RETRO VOCABULARY JOURNAL',
                          style: TextStyle(
                            fontFamily: 'Handjet',
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: palette.inkMuted,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: PixelMetrics.space4),
              Container(height: 2, color: palette.border),
              const SizedBox(height: PixelMetrics.space4),
              Text(
                'Notes for the English words you meet each day. Your notebook is empty right now. Load 5 curated starter words to immediately activate:',
                style: theme.textTheme.bodyMedium?.copyWith(
                  height: 1.3,
                  color: palette.ink,
                ),
              ),
              const SizedBox(height: PixelMetrics.space3),
              const _FeatureBullet(
                glyph: PixelGlyph.gamepad,
                label: '4 Arcade Games (Snake, Invaders, Rush, Typer)',
              ),
              const SizedBox(height: PixelMetrics.space2),
              const _FeatureBullet(
                glyph: PixelGlyph.headphones,
                label: 'Commute Audio Cassette Player',
              ),
              const SizedBox(height: PixelMetrics.space2),
              const _FeatureBullet(
                glyph: PixelGlyph.cards,
                label: 'Spaced Repetition (SM-2) Review Queue',
              ),
              const SizedBox(height: PixelMetrics.space4),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: PixelMetrics.space3,
                  vertical: PixelMetrics.space2,
                ),
                decoration: BoxDecoration(
                  color: palette.border.withValues(alpha: 0.08),
                  border: Border.all(
                    color: palette.border.withValues(alpha: 0.3),
                    width: 1,
                  ),
                ),
                child: Text(
                  'Starter Pack: resilient • bottleneck • trade-off • serendipity • pragmatic',
                  style: TextStyle(
                    fontFamily: 'Handjet',
                    fontSize: 14,
                    color: palette.inkMuted,
                    fontWeight: FontWeight.w600,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: PixelMetrics.space5),
              PixelButton(
                label: _loading ? 'LOADING WORDS…' : 'LOAD 5 STARTER WORDS',
                glyph: PixelGlyph.star,
                filled: true,
                expand: true,
                onPressed: _loading
                    ? null
                    : () async {
                        setState(() => _loading = true);
                        try {
                          await context
                              .read<VocabularyProvider>()
                              .loadStarterPack();
                        } finally {
                          if (mounted) setState(() => _loading = false);
                        }
                      },
              ),
              const SizedBox(height: PixelMetrics.space3),
              PixelButton(
                label: 'Add custom word instead',
                glyph: PixelGlyph.plus,
                expand: true,
                onPressed: () => _open(context, const WordEditorScreen()),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FeatureBullet extends StatelessWidget {
  const _FeatureBullet({required this.glyph, required this.label});

  final PixelGlyph glyph;
  final String label;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Row(
      children: [
        PixelIcon(glyph, color: palette.accent, scale: 1.4),
        const SizedBox(width: PixelMetrics.space2),
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              fontFamily: 'Handjet',
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: palette.ink,
            ),
          ),
        ),
      ],
    );
  }
}

class _EmptyDay extends StatelessWidget {
  const _EmptyDay({required this.isToday});

  final bool isToday;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(PixelMetrics.space6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              isToday ? 'NO WORDS YET TODAY' : 'NOTHING ON THIS DAY',
              style: Theme.of(context).textTheme.labelSmall,
            ),
            const SizedBox(height: PixelMetrics.space4),
            PixelButton(
              label: 'Add a word',
              glyph: PixelGlyph.plus,
              filled: true,
              onPressed: () => _open(context, const WordEditorScreen()),
            ),
          ],
        ),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.lines});

  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final line in lines)
            Padding(
              padding: const EdgeInsets.only(bottom: PixelMetrics.space1),
              child: Text(
                line,
                style: Theme.of(context).textTheme.labelSmall,
                textAlign: TextAlign.center,
              ),
            ),
        ],
      ),
    );
  }
}

/// Offers to restore the word just deleted.
///
/// Deleting is a soft delete, so undo is a real restore rather than a
/// re-insert, and the row keeps its original id and creation time.
class _UndoBar extends StatelessWidget {
  const _UndoBar();

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<VocabularyProvider>();
    if (provider.undoableDeletionId == null) return const SizedBox.shrink();

    final palette = context.palette;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: PixelMetrics.space4,
        vertical: PixelMetrics.space2,
      ),
      decoration: BoxDecoration(
        color: palette.surface,
        border: Border(
          top: BorderSide(color: palette.border, width: PixelMetrics.border),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'WORD DELETED',
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ),
          PixelButton(label: 'Undo', onPressed: provider.undoDelete),
          const SizedBox(width: PixelMetrics.space2),
          PixelIconButton(
            glyph: PixelGlyph.close,
            semanticLabel: 'Dismiss',
            onPressed: provider.dismissUndo,
          ),
        ],
      ),
    );
  }
}

/// Pushes a route without the platform slide/fade, which would look out of
/// place against hard-edged blocks.
void _open(BuildContext context, Widget screen) {
  Navigator.of(context).push(
    PageRouteBuilder<void>(
      pageBuilder: (_, _, _) => screen,
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
    ),
  );
}
