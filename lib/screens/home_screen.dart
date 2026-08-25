import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/theme/pixel_metrics.dart';
import '../core/theme/pixel_palette.dart';
import '../providers/vocabulary_provider.dart';
import '../widgets/date_bar.dart';
import '../widgets/pixel/pixel_button.dart';
import '../widgets/pixel/pixel_icon.dart';
import '../services/sync_service.dart';
import '../widgets/word_row.dart';
import 'account_screen.dart';
import 'review_screen.dart';
import 'search_screen.dart';
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
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar();

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final provider = context.watch<VocabularyProvider>();

    return Container(
      padding: const EdgeInsets.fromLTRB(
        PixelMetrics.space4,
        PixelMetrics.space2,
        PixelMetrics.space2,
        PixelMetrics.space2,
      ),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: palette.border, width: PixelMetrics.border),
        ),
      ),
      child: Row(
        children: [
          Text('VEEA·EN', style: Theme.of(context).textTheme.titleMedium),
          const Spacer(),
          PixelIconButton(
            glyph: PixelGlyph.cards,
            semanticLabel: provider.dueReviewCount > 0
                ? 'Spaced review, ${provider.dueReviewCount} due'
                : 'Spaced review',
            active: provider.dueReviewCount > 0,
            onPressed: () => _open(context, const ReviewScreen()),
          ),
          const SizedBox(width: PixelMetrics.space1),
          PixelIconButton(
            glyph: PixelGlyph.search,
            semanticLabel: 'Search all words',
            onPressed: () => _open(context, const SearchScreen()),
          ),
          const SizedBox(width: PixelMetrics.space1),
          PixelIconButton(
            glyph: PixelGlyph.plus,
            semanticLabel: 'Add a word',
            onPressed: () => _open(context, const WordEditorScreen()),
          ),
          const SizedBox(width: PixelMetrics.space1),
          const _AccountButton(),
        ],
      ),
    );
  }
}

/// Opens the account screen, marking itself active while changes are waiting
/// to upload — the only sync state worth putting on the main screen.
class _AccountButton extends StatelessWidget {
  const _AccountButton();

  @override
  Widget build(BuildContext context) {
    final sync = context.watch<SyncService>();

    return PixelIconButton(
      glyph: PixelGlyph.cloud,
      semanticLabel: sync.pendingCount > 0
          ? 'Account, ${sync.pendingCount} words waiting to upload'
          : 'Account and sync',
      active: sync.isSyncing,
      onPressed: () => _open(context, const AccountScreen()),
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
