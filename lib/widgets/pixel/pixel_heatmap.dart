import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/theme/pixel_metrics.dart';
import '../../core/theme/pixel_palette.dart';
import 'pixel_box.dart';

/// An 8-bit GitHub-style contribution activity heatmap showing daily word capture density.
class PixelHeatmap extends StatefulWidget {
  const PixelHeatmap({
    super.key,
    required this.dailyCounts,
    this.weeks = 16,
    this.now,
  });

  /// Map of `YYYY-MM-DD` -> number of words recorded.
  final Map<String, int> dailyCounts;

  /// Number of weeks to display initially.
  final int weeks;

  final DateTime? now;

  @override
  State<PixelHeatmap> createState() => _PixelHeatmapState();
}

class _PixelHeatmapState extends State<PixelHeatmap> {
  DateTime? _selectedDate;
  late int _selectedWeeks;
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _selectedWeeks = widget.weeks;
    _scrollToEnd();
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final theme = Theme.of(context);
    final today = widget.now ?? DateTime.now();
    final todayOnly = DateTime(today.year, today.month, today.day);

    // Calculate grid starting from (weeks * 7) days ago aligned to Monday
    final daysTotal = _selectedWeeks * 7;
    final startOfGrid = todayOnly
        .subtract(Duration(days: daysTotal - 1))
        .subtract(Duration(days: (todayOnly.weekday - DateTime.monday) % 7));

    final selected = _selectedDate ?? todayOnly;
    final selectedKey = _dateKey(selected);
    final selectedCount = widget.dailyCounts[selectedKey] ?? 0;

    // Calculate period statistics
    int totalWordsInPeriod = 0;
    int activeDaysInPeriod = 0;
    int maxWordsInDay = 0;

    for (var d = 0; d < daysTotal; d++) {
      final curDate = startOfGrid.add(Duration(days: d));
      if (curDate.isAfter(todayOnly)) continue;
      final count = widget.dailyCounts[_dateKey(curDate)] ?? 0;
      if (count > 0) {
        totalWordsInPeriod += count;
        activeDaysInPeriod++;
        if (count > maxWordsInDay) maxWordsInDay = count;
      }
    }

    return PixelBox(
      raised: true,
      color: palette.surface,
      padding: const EdgeInsets.all(PixelMetrics.space4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header & Range Selector (GitHub style)
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'ACTIVITY HEATMAP',
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '$totalWordsInPeriod words captured across $activeDaysInPeriod active days',
                      style: TextStyle(
                        fontFamily: 'Handjet',
                        fontSize: 12,
                        color: palette.inkMuted,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              // Week range selector pills
              Row(
                children: [16, 26, 52].map((w) {
                  final active = _selectedWeeks == w;
                  return Padding(
                    padding: const EdgeInsets.only(left: 3),
                    child: GestureDetector(
                      onTap: () {
                        setState(() {
                          _selectedWeeks = w;
                        });
                        _scrollToEnd();
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: active ? palette.accent : palette.paper,
                          border: Border.all(
                            color: palette.border,
                            width: 1,
                          ),
                        ),
                        child: Text(
                          '${w}W',
                          style: TextStyle(
                            fontFamily: 'Handjet',
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: active ? palette.onAccent : palette.ink,
                          ),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ],
          ),

          const SizedBox(height: PixelMetrics.space3),

          // Scrollable Grid (like GitHub contributions)
          SingleChildScrollView(
            controller: _scrollController,
            scrollDirection: Axis.horizontal,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Day of week labels (M, W, F)
                Padding(
                  padding: const EdgeInsets.only(right: 6, top: 16),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      _dayLabel('M', theme, palette),
                      const SizedBox(height: 12),
                      _dayLabel('W', theme, palette),
                      const SizedBox(height: 12),
                      _dayLabel('F', theme, palette),
                    ],
                  ),
                ),

                // Columns of weeks
                for (var w = 0; w < _selectedWeeks; w++) ...[
                  _buildWeekColumn(
                    weekIndex: w,
                    startOfGrid: startOfGrid,
                    today: todayOnly,
                    palette: palette,
                  ),
                  const SizedBox(width: 3),
                ],
              ],
            ),
          ),

          const SizedBox(height: PixelMetrics.space3),

          // Selected cell inspector card + Legend
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              color: palette.paper,
              border: Border.all(color: palette.border, width: 1),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${DateFormat('EEEE, d MMM yyyy').format(selected).toUpperCase()} : $selectedCount WORD${selectedCount == 1 ? '' : 'S'}',
                    style: TextStyle(
                      fontFamily: 'Handjet',
                      fontSize: 12,
                      color: selectedCount > 0 ? palette.accent : palette.inkMuted,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                _buildLegend(palette, theme),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _dayLabel(String label, ThemeData theme, PixelPalette palette) {
    return SizedBox(
      height: 11,
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          fontSize: 9,
          color: palette.inkFaint,
          height: 1.0,
        ),
      ),
    );
  }

  Widget _buildWeekColumn({
    required int weekIndex,
    required DateTime startOfGrid,
    required DateTime today,
    required PixelPalette palette,
  }) {
    final firstDayOfWeek = startOfGrid.add(Duration(days: weekIndex * 7));
    final showMonth = firstDayOfWeek.day <= 7;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Month Header
        SizedBox(
          height: 14,
          child: showMonth
              ? Text(
                  DateFormat('MMM').format(firstDayOfWeek).toUpperCase(),
                  style: TextStyle(
                    fontFamily: 'Handjet',
                    fontSize: 9,
                    color: palette.inkFaint,
                    fontWeight: FontWeight.bold,
                  ),
                )
              : const SizedBox.shrink(),
        ),
        const SizedBox(height: 2),

        // 7 Days (Mon -> Sun)
        for (var d = 0; d < 7; d++) ...[
          _buildDayCell(
            date: firstDayOfWeek.add(Duration(days: d)),
            today: today,
            palette: palette,
          ),
          const SizedBox(height: 3),
        ],
      ],
    );
  }

  Widget _buildDayCell({
    required DateTime date,
    required DateTime today,
    required PixelPalette palette,
  }) {
    final isFuture = date.isAfter(today);
    final dateKey = _dateKey(date);
    final count = widget.dailyCounts[dateKey] ?? 0;
    final isSelected = _selectedDate != null && _dateKey(_selectedDate!) == dateKey;

    Color cellColor;
    Color borderColor;

    if (isFuture) {
      cellColor = Colors.transparent;
      borderColor = Colors.transparent;
    } else if (count == 0) {
      cellColor = palette.paper;
      borderColor = palette.border.withValues(alpha: 0.2);
    } else if (count <= 2) {
      cellColor = palette.accent.withValues(alpha: 0.35);
      borderColor = palette.accent.withValues(alpha: 0.5);
    } else if (count <= 4) {
      cellColor = palette.accent.withValues(alpha: 0.70);
      borderColor = palette.accent;
    } else {
      cellColor = palette.accent;
      borderColor = palette.border;
    }

    if (isSelected) {
      borderColor = palette.ink;
    }

    return GestureDetector(
      onTap: isFuture
          ? null
          : () {
              setState(() {
                _selectedDate = date;
              });
            },
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 11,
        height: 11,
        decoration: BoxDecoration(
          color: cellColor,
          border: Border.all(
            color: borderColor,
            width: isSelected ? 1.5 : 1.0,
          ),
        ),
      ),
    );
  }

  Widget _buildLegend(PixelPalette palette, ThemeData theme) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'LESS',
          style: theme.textTheme.labelSmall?.copyWith(
            fontSize: 9,
            color: palette.inkFaint,
          ),
        ),
        const SizedBox(width: 4),
        _legendBox(palette.paper, palette.border.withValues(alpha: 0.2)),
        const SizedBox(width: 2),
        _legendBox(
          palette.accent.withValues(alpha: 0.35),
          palette.accent.withValues(alpha: 0.5),
        ),
        const SizedBox(width: 2),
        _legendBox(palette.accent.withValues(alpha: 0.70), palette.accent),
        const SizedBox(width: 2),
        _legendBox(palette.accent, palette.border),
        const SizedBox(width: 4),
        Text(
          'MORE',
          style: theme.textTheme.labelSmall?.copyWith(
            fontSize: 9,
            color: palette.inkFaint,
          ),
        ),
      ],
    );
  }

  Widget _legendBox(Color fill, Color border) {
    return Container(
      width: 9,
      height: 9,
      decoration: BoxDecoration(
        color: fill,
        border: Border.all(color: border, width: 1),
      ),
    );
  }

  static String _dateKey(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';
}
