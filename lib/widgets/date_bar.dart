import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../core/theme/pixel_metrics.dart';
import '../core/theme/pixel_palette.dart';
import '../providers/vocabulary_provider.dart';
import 'pixel/pixel_button.dart';
import 'pixel/pixel_icon.dart';

/// Day navigation: previous, the day itself, next.
///
/// Tapping the label opens a picker. A marker under the label shows whether
/// the day already holds words, so scrubbing back through empty days is
/// visible rather than guesswork.
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
              onTap: () => _pickDate(context, provider),
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

  Future<void> _pickDate(
    BuildContext context,
    VocabularyProvider provider,
  ) async {
    final palette = context.palette;
    final picked = await showDatePicker(
      context: context,
      initialDate: provider.selectedDate,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 365)),
      builder: (context, child) => Theme(
        // The platform picker is a Material component; it is themed to match
        // rather than reimplemented, since a hand-built calendar would be a
        // lot of surface area for a rarely-used control.
        data: Theme.of(context).copyWith(
          colorScheme: Theme.of(context).colorScheme.copyWith(
            surface: palette.surface,
            onSurface: palette.ink,
            primary: palette.accent,
            onPrimary: palette.onAccent,
          ),
          dialogTheme: const DialogThemeData(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.zero),
          ),
        ),
        child: child!,
      ),
    );
    if (picked != null) await provider.selectDate(picked);
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
        'WEEK ${stats.wordsThisWeek}   '
        'ALL ${stats.totalWords}',
        style: theme.textTheme.labelSmall?.copyWith(color: palette.inkMuted),
      ),
    );
  }
}
