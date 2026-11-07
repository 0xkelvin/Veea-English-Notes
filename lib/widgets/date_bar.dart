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
        horizontal: PixelMetrics.space3,
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
            semanticLabel: 'Previous day',
            onPressed: provider.goToPreviousDay,
          ),
          Expanded(
            child: Semantics(
              button: true,
              label: 'Open calendar',
              excludeSemantics: true,
              onTap: () => _openCalendar(context, provider),
              child: InkWell(
                borderRadius: BorderRadius.circular(PixelMetrics.radiusSm),
                onTap: () => _openCalendar(context, provider),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: PixelMetrics.space2,
                  ),
                  child: Column(
                    children: [
                      Text(
                        _label(selected, provider.isToday),
                        style: theme.textTheme.titleMedium,
                        textAlign: TextAlign.center,
                      ),
                      Text(
                        'View calendar',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: palette.inkMuted,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
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
    if (isToday) return 'Today · ${DateFormat('d MMM').format(date)}';
    return DateFormat('EEE d MMM').format(date);
  }

  Future<void> _openCalendar(
    BuildContext context,
    VocabularyProvider provider,
  ) async {
    await RetroCalendarSheet.show(context: context, provider: provider);
  }
}

/// One-line counters: what is on this day, and the running totals.
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
        color: palette.paper,
        border: Border(
          bottom: BorderSide(color: palette.border, width: PixelMetrics.border),
        ),
      ),
      child: Wrap(
        spacing: PixelMetrics.space3,
        runSpacing: PixelMetrics.space1,
        children:
            [
                  '${provider.words.length} ${provider.words.length == 1 ? 'word' : 'words'}',
                  '${provider.dueReviewCount} due',
                  '${stats.streakDays}-day streak',
                  '${stats.totalWords} total',
                ]
                .map(
                  (label) => Text(
                    label,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: palette.inkMuted,
                    ),
                  ),
                )
                .toList(),
      ),
    );
  }
}
