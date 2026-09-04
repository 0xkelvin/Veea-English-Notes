import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/theme/pixel_metrics.dart';
import '../core/theme/pixel_palette.dart';
import '../providers/vocabulary_provider.dart';
import '../widgets/date_bar.dart';
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
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

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
          Row(
            children: [
              PixelIcon(PixelGlyph.star, color: palette.accent, scale: 1.5),
              const SizedBox(width: PixelMetrics.space2),
              Text(
                'VEEA // JOURNAL',
                style: TextStyle(
                  fontFamily: 'Handjet',
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: palette.ink,
                  letterSpacing: 1.0,
                ),
              ),
            ],
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
              'THÊM TỪ',
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
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
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
