import 'dart:async';

import 'package:flutter/material.dart';
import '../providers/app_gate_provider.dart';
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
// import 'arcade_screen.dart'; // Arcade / games hidden
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
            Expanded(
              child: _Body(
                provider: provider,
                header: Column(
                  children: [
                    const DateBar(),
                    const StatusLine(),
                    const _DailyWordGoal(),
                    if (_detectedWord != null)
                      ClipboardDetectorToast(
                        word: _detectedWord!,
                        isAdding: _isAdding,
                        onAdd: () => _addDetectedWord(_detectedWord!),
                        onDismiss: () => _dismissDetectedWord(_detectedWord!),
                      ),
                  ],
                ),
              ),
            ),
            const _UndoBar(),
          ],
        ),
      ),
      bottomNavigationBar: const _BottomDock(),
    );
  }
}

class _DailyWordGoal extends StatelessWidget {
  const _DailyWordGoal();
  @override
  Widget build(BuildContext context) {
    AppGateProvider? gate;
    try {
      gate = context.watch<AppGateProvider>();
    } catch (_) {
      return const SizedBox.shrink();
    }
    if (!gate.config.dailyWordGoal) return const SizedBox.shrink();
    final vocabulary = context.watch<VocabularyProvider>();
    final done = vocabulary.todayWordCount > 0;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Icon(done ? Icons.check_circle_outline : Icons.flag_outlined),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              done
                  ? "Today's word goal is complete"
                  : 'Optional goal: add one new word today',
            ),
          ),
          if (!done)
            TextButton(
              onPressed: () async {
                await vocabulary.goToToday();
                if (context.mounted) _open(context, const WordEditorScreen());
              },
              child: const Text('Add word'),
            ),
        ],
      ),
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
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Expanded(
            child: Text(
              'Notebook',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          PixelIconButton(
            glyph: PixelGlyph.shield,
            semanticLabel: 'App protection',
            onPressed: () => _open(context, const AppProtectionScreen()),
          ),
          const SizedBox(width: PixelMetrics.space1),
          PixelIconButton(
            glyph: PixelGlyph.search,
            semanticLabel: 'Search all words',
            onPressed: () => _open(context, const SearchScreen()),
          ),
          const SizedBox(width: PixelMetrics.space2),
          PixelIconButton(
            glyph: PixelGlyph.camera,
            semanticLabel: 'Scan words with camera',
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
            color: Colors.black.withValues(alpha: 0.04),
            offset: const Offset(0, -4),
            blurRadius: 16,
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: PixelMetrics.space3,
            vertical: PixelMetrics.space2 + 2,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              Expanded(
                child: _DockItem(
                  glyph: PixelGlyph.headphones,
                  label: 'Listen',
                  semanticLabel: 'Commute Audio Player',
                  onTap: () => _open(context, const AudioCommuteScreen()),
                ),
              ),
              // Arcade games hidden per user feedback:
              // _DockItem(
              //   glyph: PixelGlyph.gamepad,
              //   label: 'ARCADE',
              //   semanticLabel: 'Arcade Mini-Games and Duels',
              //   onTap: () => _open(context, const ArcadeScreen()),
              // ),
              Expanded(
                child: _HeroAddButton(
                  onTap: () => _open(context, const WordEditorScreen()),
                ),
              ),
              Expanded(
                child: _DockItem(
                  glyph: PixelGlyph.cards,
                  label: 'Review',
                  semanticLabel: 'Spaced repetition review',
                  badgeCount: dueCount > 0 ? dueCount : null,
                  onTap: () => _open(context, const ReviewScreen()),
                ),
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
          horizontal: PixelMetrics.space2,
          vertical: PixelMetrics.space2,
        ),
        decoration: BoxDecoration(
          color: palette.accent,
          borderRadius: BorderRadius.circular(PixelMetrics.radiusPill),
          boxShadow: [
            BoxShadow(
              color: palette.accent.withValues(alpha: 0.28),
              offset: const Offset(0, 4),
              blurRadius: 12,
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            PixelIcon(PixelGlyph.plus, color: palette.onAccent, scale: 1.8),
            const SizedBox(height: PixelMetrics.space1),
            Text(
              'Add word',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: palette.onAccent,
                letterSpacing: 0.4,
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
      value: badgeCount == null ? null : '$badgeCount words due',
      button: true,
      excludeSemantics: true,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Badge(
                isLabelVisible: badgeCount != null,
                backgroundColor: palette.danger,
                textColor: palette.onAccent,
                label: Text(
                  badgeCount != null && badgeCount! > 99
                      ? '99+'
                      : '$badgeCount',
                ),
                child: PixelIcon(glyph, color: palette.ink, scale: 2.0),
              ),
              const SizedBox(height: 4),
              Text(
                label,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: palette.inkMuted,
                  letterSpacing: 0.3,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.provider, required this.header});
  final VocabularyProvider provider;
  final Widget header;

  @override
  Widget build(BuildContext context) {
    Widget? empty;
    if (provider.isLoading) {
      empty = const _Notice(lines: ['Loading your words…']);
    } else if (provider.status == LoadStatus.failed) {
      empty = Center(
        child: Padding(
          padding: const EdgeInsets.all(PixelMetrics.space6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Could not load your words. Please try again.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: PixelMetrics.space3),
              PixelButton(label: 'Try again', onPressed: provider.init),
            ],
          ),
        ),
      );
    } else if (provider.words.isEmpty) {
      empty = provider.stats.totalWords == 0
          ? const _FirstRunStarterBanner()
          : _EmptyDay(isToday: provider.isToday);
    }
    return CustomScrollView(
      key: const Key('notebook_scroll'),
      slivers: [
        SliverToBoxAdapter(child: header),
        if (empty != null)
          SliverFillRemaining(hasScrollBody: false, child: empty)
        else
          SliverPadding(
            padding: const EdgeInsets.only(bottom: PixelMetrics.space6),
            sliver: SliverList.builder(
              itemCount: provider.words.length,
              itemBuilder: (context, index) => WordRow(
                word: provider.words[index],
                onTap: () => _open(
                  context,
                  WordEditorScreen(existing: provider.words[index]),
                ),
              ),
            ),
          ),
      ],
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
                          'Welcome to Veea',
                          style: TextStyle(
                            fontSize: 21,
                            fontWeight: FontWeight.w700,
                            color: palette.ink,
                            letterSpacing: 0.2,
                          ),
                        ),
                        Text(
                          'Your English notebook',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: palette.inkMuted,
                            letterSpacing: 0.2,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: PixelMetrics.space4),
              Container(height: 1, color: palette.border),
              const SizedBox(height: PixelMetrics.space4),
              Text(
                'Save words you want to remember. Review them at your own pace, or practice to earn time in your favorite apps.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  height: 1.4,
                  color: palette.ink,
                ),
              ),
              const SizedBox(height: PixelMetrics.space3),
              // const _FeatureBullet(
              //   glyph: PixelGlyph.gamepad,
              //   label: '4 Arcade Games (Snake, Invaders, Rush, Typer)',
              // ),
              // const SizedBox(height: PixelMetrics.space2),
              const _FeatureBullet(
                glyph: PixelGlyph.headphones,
                label: 'Listen and practice on the go',
              ),
              const SizedBox(height: PixelMetrics.space2),
              const _FeatureBullet(
                glyph: PixelGlyph.cards,
                label: 'Quick reviews that help words stick',
              ),
              const SizedBox(height: PixelMetrics.space4),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: PixelMetrics.space3,
                  vertical: PixelMetrics.space2 + 2,
                ),
                decoration: BoxDecoration(
                  color: palette.accent.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(PixelMetrics.radiusSm),
                  border: Border.all(
                    color: palette.accent.withValues(alpha: 0.18),
                    width: 1,
                  ),
                ),
                child: Text(
                  'Starter Pack: resilient • bottleneck • trade-off • serendipity • pragmatic',
                  style: TextStyle(
                    fontSize: 13.5,
                    color: palette.inkMuted,
                    fontWeight: FontWeight.w600,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: PixelMetrics.space5),
              PixelButton(
                label: _loading ? 'Adding words…' : 'Try 5 starter words',
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
                label: 'Add my own word',
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
              isToday ? 'No words saved today' : 'No words saved on this day',
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
