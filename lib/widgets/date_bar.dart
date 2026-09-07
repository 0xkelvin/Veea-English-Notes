import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../core/theme/pixel_metrics.dart';
import '../core/theme/pixel_palette.dart';
import '../providers/vocabulary_provider.dart';
import 'pixel/pixel_button.dart';
import 'pixel/pixel_icon.dart';
import 'pixel/retro_calendar_sheet.dart';

/// Day navigation: previous, the day itself, next.
///
/// Tapping the label or the calendar icon opens a retro pixel calendar.
/// Days holding words show word counts and active styling, while empty days
/// are grayed down so learning consistency is immediately visible.
class DateBar extends StatelessWidget {
  const DateBar({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<VocabularyProvider>();
    final palette = context.palette;
    final theme = Theme.of(context);
    final selected = provider.selectedDate;

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: PixelMetrics.space2,
        vertical: PixelMetrics.space2,
      ),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: palette.border, width: PixelMetrics.border),
        ),
      ),
      child: Row(
        children: [
          PixelIconButton(
            glyph: PixelGlyph.arrowLeft,
            semanticLabel: 'Previous day',
            onPressed: provider.goToPreviousDay,
          ),
          Expanded(
            child: GestureDetector(
              onTap: () => _openCalendar(context, provider),
              behavior: HitTestBehavior.opaque,
              child: Column(
                children: [
                  Text(
                    _label(selected, provider.isToday),
                    style: theme.textTheme.titleMedium,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    provider.markedDates.contains(provider.selectedDateKey)
                        ? '· · ·'
                        : 'EMPTY',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color:
                          provider.markedDates.contains(
                            provider.selectedDateKey,
                          )
                          ? palette.accent
                          : palette.inkFaint,
                    ),
                  ),
                ],
              ),
            ),
          ),
          PixelIconButton(
            glyph: PixelGlyph.calendar,
            semanticLabel: 'Open calendar',
            onPressed: () => _openCalendar(context, provider),
          ),
          const SizedBox(width: PixelMetrics.space1),
          PixelIconButton(
            glyph: PixelGlyph.arrowRight,
            semanticLabel: 'Next day',
            onPressed: provider.goToNextDay,
          ),
        ],
      ),
    );
  }

  static String _label(DateTime date, bool isToday) {
    if (isToday) return 'TODAY · ${DateFormat('d MMM').format(date)}';
    return DateFormat('EEE d MMM').format(date).toUpperCase();
  }

  Future<void> _openCalendar(
    BuildContext context,
    VocabularyProvider provider,
  ) async {
    await RetroCalendarSheet.show(context: context, provider: provider);
  }
}

/// One-line counters: what is on this day, and the running totals.
///
/// This replaces the two gradient stat cards, which took roughly a sixth of
/// the screen to show numbers you rarely act on.
class StatusLine extends StatelessWidget {
  const StatusLine({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<VocabularyProvider>();
    final palette = context.palette;
    final theme = Theme.of(context);
    final stats = provider.stats;

    return Container(
      width: double.infinity,
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
      child: Text(
        '${provider.words.length} HERE   '
        'STREAK ${stats.streakDays}   '
        'DUE ${provider.dueReviewCount}   '
        'ALL ${stats.totalWords}',
        style: theme.textTheme.labelSmall?.copyWith(color: palette.inkMuted),
      ),
    );
  }
}
