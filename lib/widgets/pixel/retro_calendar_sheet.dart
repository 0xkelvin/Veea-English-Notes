import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/theme/pixel_metrics.dart';
import '../../core/theme/pixel_palette.dart';
import '../../models/vocabulary_word.dart';
import '../../providers/vocabulary_provider.dart';
import '../../services/commute_playlist_service.dart';
import 'pixel_box.dart';
import 'pixel_button.dart';
import 'pixel_icon.dart';

/// 8-Bit Retro Pixel Calendar Modal Sheet for the Home Screen journal.
///
/// Highlights active study days with exact word counts, and grays down days
/// without words so users immediately perceive their learning consistency.
class RetroCalendarSheet extends StatefulWidget {
  const RetroCalendarSheet({
    super.key,
    required this.provider,
    this.allWords,
  });

  final VocabularyProvider provider;
  final List<VocabularyWord>? allWords;

  static Future<DateTime?> show({
    required BuildContext context,
    required VocabularyProvider provider,
    List<VocabularyWord>? allWords,
  }) {
    return showModalBottomSheet<DateTime>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => RetroCalendarSheet(
        provider: provider,
        allWords: allWords,
      ),
    );
  }

  @override
  State<RetroCalendarSheet> createState() => _RetroCalendarSheetState();
}

class _RetroCalendarSheetState extends State<RetroCalendarSheet> {
  late DateTime _calendarMonth;
  late DateTime _selectedDate;
  Map<String, List<VocabularyWord>> _wordsByDate = {};
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    final initial = widget.provider.selectedDate;
    _selectedDate = DateTime(initial.year, initial.month, initial.day);
    _calendarMonth = DateTime(initial.year, initial.month, 1);
    if (widget.allWords != null) {
      _wordsByDate = CommutePlaylistService.groupWordsByDate(widget.allWords!);
      _isLoading = false;
    } else {
      _loadWords();
    }
  }

  Future<void> _loadWords() async {
    final words = await widget.provider.allWords();
    if (!mounted) return;
    setState(() {
      _wordsByDate = CommutePlaylistService.groupWordsByDate(words);
      _isLoading = false;
    });
  }

  static String _dateKey(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';

  void _goToPreviousMonth() {
    setState(() {
      _calendarMonth = DateTime(
        _calendarMonth.year,
        _calendarMonth.month - 1,
        1,
      );
    });
  }

  void _goToNextMonth() {
    setState(() {
      _calendarMonth = DateTime(
        _calendarMonth.year,
        _calendarMonth.month + 1,
        1,
      );
    });
  }

  void _selectToday() {
    final now = widget.provider.today;
    setState(() {
      _calendarMonth = DateTime(now.year, now.month, 1);
      _selectedDate = DateTime(now.year, now.month, now.day);
    });
  }

  void _onTapDay(DateTime date) {
    if (_dateKey(_selectedDate) == _dateKey(date)) {
      _jumpToDate(date);
    } else {
      setState(() {
        _selectedDate = date;
      });
    }
  }

  Future<void> _jumpToDate(DateTime date) async {
    await widget.provider.selectDate(date);
    if (mounted) {
      Navigator.of(context).pop(date);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final theme = Theme.of(context);

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.90,
      ),
      decoration: BoxDecoration(
        color: palette.paper,
        border: Border(
          top: BorderSide(color: palette.border, width: PixelMetrics.border),
        ),
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Top Bar
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: PixelMetrics.space4,
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
                  PixelIcon(PixelGlyph.calendar, color: palette.accent, scale: 2),
                  const SizedBox(width: PixelMetrics.space2),
                  Text('VOCABULARY CALENDAR', style: theme.textTheme.titleMedium),
                  const Spacer(),
                  PixelIconButton(
                    glyph: PixelGlyph.close,
                    semanticLabel: 'Close Calendar',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),

            // Scrollable Content
            Expanded(
              child: _isLoading
                  ? Center(
                      child: Text(
                        'LOADING CALENDAR…',
                        style: TextStyle(
                          fontFamily: 'Handjet',
                          fontSize: 16,
                          color: palette.inkMuted,
                        ),
                      ),
                    )
                  : ListView(
                      padding: const EdgeInsets.all(PixelMetrics.space4),
                      children: [
                        _buildCalendarCard(palette, theme),
                        const SizedBox(height: PixelMetrics.space4),
                        _buildSelectedDateDetails(palette, theme),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCalendarCard(PixelPalette palette, ThemeData theme) {
    final firstDayOfMonth = DateTime(
      _calendarMonth.year,
      _calendarMonth.month,
      1,
    );
    final daysInMonth = DateTime(
      _calendarMonth.year,
      _calendarMonth.month + 1,
      0,
    ).day;
    // Monday = 1, Sunday = 7
    final leadingBlanks = firstDayOfMonth.weekday - 1;
    final totalCells = leadingBlanks + daysInMonth;
    final rowCount = (totalCells / 7).ceil();

    final dayNames = ['MO', 'TU', 'WE', 'TH', 'FR', 'SA', 'SU'];

    // Month summary statistics
    final monthPrefix =
        '${_calendarMonth.year.toString().padLeft(4, '0')}-${_calendarMonth.month.toString().padLeft(2, '0')}';
    int monthWordCount = 0;
    int monthActiveDays = 0;
    for (final entry in _wordsByDate.entries) {
      if (entry.key.startsWith(monthPrefix) && entry.value.isNotEmpty) {
        monthWordCount += entry.value.length;
        monthActiveDays++;
      }
    }

    return PixelBox(
      raised: true,
      color: palette.surface,
      padding: const EdgeInsets.all(PixelMetrics.space3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Month Header & Navigation
          Row(
            children: [
              PixelIconButton(
                glyph: PixelGlyph.arrowLeft,
                semanticLabel: 'Previous month',
                onPressed: _goToPreviousMonth,
              ),
              const SizedBox(width: PixelMetrics.space2),
              Text(
                'MONTH ${_calendarMonth.month} / ${_calendarMonth.year}',
                style: TextStyle(
                  fontFamily: 'Handjet',
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: palette.ink,
                ),
              ),
              const SizedBox(width: PixelMetrics.space2),
              PixelIconButton(
                glyph: PixelGlyph.arrowRight,
                semanticLabel: 'Next month',
                onPressed: _goToNextMonth,
              ),
              const Spacer(),
              GestureDetector(
                onTap: _selectToday,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: PixelMetrics.space2,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: palette.paper,
                    border: Border.all(color: palette.border, width: 1),
                  ),
                  child: Text(
                    'TODAY',
                    style: TextStyle(
                      fontFamily: 'Handjet',
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: palette.accent,
                    ),
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: PixelMetrics.space2),

          // Month Active Summary Bar
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: PixelMetrics.space2,
              vertical: 3,
            ),
            decoration: BoxDecoration(
              color: palette.paper.withValues(alpha: 0.5),
              border: Border.all(
                color: palette.border.withValues(alpha: 0.2),
                width: 1,
              ),
            ),
            child: Text(
              'MONTH ACTIVITY: $monthWordCount WORDS · $monthActiveDays DAYS LEARNED',
              style: TextStyle(
                fontFamily: 'Handjet',
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: palette.inkMuted,
              ),
              textAlign: TextAlign.center,
            ),
          ),

          const SizedBox(height: PixelMetrics.space3),

          // Weekday Labels
          Row(
            children: [
              for (final d in dayNames)
                Expanded(
                  child: Center(
                    child: Text(
                      d,
                      style: TextStyle(
                        fontFamily: 'Handjet',
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: palette.inkMuted,
                      ),
                    ),
                  ),
                ),
            ],
          ),

          const SizedBox(height: 4),

          // Calendar Grid
          for (var r = 0; r < rowCount; r++) ...[
            Row(
              children: [
                for (var c = 0; c < 7; c++) ...[
                  Expanded(
                    child: _buildDayCell(
                      r * 7 + c,
                      leadingBlanks,
                      daysInMonth,
                      palette,
                    ),
                  ),
                ],
              ],
            ),
            if (r < rowCount - 1) const SizedBox(height: 3),
          ],
        ],
      ),
    );
  }

  Widget _buildDayCell(
    int cellIndex,
    int leadingBlanks,
    int daysInMonth,
    PixelPalette palette,
  ) {
    final day = cellIndex - leadingBlanks + 1;
    if (day < 1 || day > daysInMonth) {
      return const SizedBox(height: 40);
    }

    final cellDate = DateTime(_calendarMonth.year, _calendarMonth.month, day);
    final dateKeyStr = _dateKey(cellDate);
    final words = _wordsByDate[dateKeyStr] ?? [];
    final count = words.length;
    final hasWords = count > 0;
    final isSelected = _dateKey(_selectedDate) == dateKeyStr;
    final now = widget.provider.today;
    final isToday = _dateKey(now) == dateKeyStr;

    // 1. DAYS WITHOUT WORDS: Grayed down so user instantly sees inactive days
    if (!hasWords) {
      return GestureDetector(
        onTap: () => _onTapDay(cellDate),
        behavior: HitTestBehavior.opaque,
        child: Container(
          height: 40,
          margin: const EdgeInsets.symmetric(horizontal: 1.5),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: isSelected
                ? palette.accent.withValues(alpha: 0.15)
                : palette.paper.withValues(alpha: 0.25),
            border: Border.all(
              color: isSelected
                  ? palette.accent
                  : isToday
                      ? palette.border
                      : palette.border.withValues(alpha: 0.12),
              width: isSelected ? PixelMetrics.border : 1,
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                '$day',
                style: TextStyle(
                  fontFamily: 'Handjet',
                  fontSize: 14,
                  color: isSelected
                      ? palette.ink
                      : palette.inkFaint.withValues(alpha: 0.35),
                ),
              ),
              if (isToday)
                Container(
                  width: 4,
                  height: 3,
                  margin: const EdgeInsets.only(top: 1),
                  decoration: BoxDecoration(
                    color: palette.accent,
                    border: Border.all(color: palette.border, width: 0.5),
                  ),
                ),
            ],
          ),
        ),
      );
    }

    // 2. DAYS WITH WORDS: Active, solid retro tile with word count badge
    final Color bgColor;
    final Color borderColor;
    final Color textColor;
    final Color badgeColor;

    if (isSelected) {
      bgColor = palette.accent;
      borderColor = palette.border;
      textColor = palette.onAccent;
      badgeColor = palette.onAccent;
    } else {
      bgColor = palette.surface;
      borderColor = isToday ? palette.accent : palette.border;
      textColor = palette.ink;
      badgeColor = palette.accent;
    }

    return GestureDetector(
      onTap: () => _onTapDay(cellDate),
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 40,
        margin: const EdgeInsets.symmetric(horizontal: 1.5),
        decoration: BoxDecoration(
          color: bgColor,
          border: Border.all(
            color: borderColor,
            width: isSelected ? PixelMetrics.border : 1.5,
          ),
          boxShadow: isSelected
              ? null
              : [
                  BoxShadow(
                    color: palette.border.withValues(alpha: 0.12),
                    offset: const Offset(1, 1),
                    blurRadius: 0,
                  ),
                ],
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              '$day',
              style: TextStyle(
                fontFamily: 'Handjet',
                fontSize: 15,
                fontWeight: FontWeight.bold,
                color: textColor,
                height: 1.0,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              '$count',
              style: TextStyle(
                fontFamily: 'Handjet',
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: badgeColor,
                height: 1.0,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSelectedDateDetails(PixelPalette palette, ThemeData theme) {
    final selectedKey = _dateKey(_selectedDate);
    final words = _wordsByDate[selectedKey] ?? [];
    final formattedDate =
        DateFormat('EEEE, d MMMM yyyy').format(_selectedDate).toUpperCase();
    final isToday = _dateKey(widget.provider.today) == selectedKey;

    return PixelBox(
      raised: true,
      color: palette.surface,
      padding: const EdgeInsets.all(PixelMetrics.space3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              PixelIcon(PixelGlyph.cards, color: palette.accent, scale: 1.5),
              const SizedBox(width: PixelMetrics.space2),
              Expanded(
                child: Text(
                  formattedDate,
                  style: TextStyle(
                    fontFamily: 'Handjet',
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: palette.ink,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: words.isNotEmpty ? palette.accent : palette.paper,
                  border: Border.all(color: palette.border, width: 1),
                ),
                child: Text(
                  words.isNotEmpty
                      ? '${words.length} ${words.length == 1 ? 'WORD' : 'WORDS'}'
                      : 'EMPTY',
                  style: TextStyle(
                    fontFamily: 'Handjet',
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: words.isNotEmpty ? palette.onAccent : palette.inkMuted,
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: PixelMetrics.space3),

          if (words.isNotEmpty) ...[
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: words.take(12).map((w) {
                return Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: palette.paper,
                    border: Border.all(color: palette.border, width: 1),
                  ),
                  child: Text(
                    w.word,
                    style: TextStyle(
                      fontFamily: 'Handjet',
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: palette.ink,
                    ),
                  ),
                );
              }).toList(),
            ),
            if (words.length > 12) ...[
              const SizedBox(height: 4),
              Text(
                '+ ${words.length - 12} more words',
                style: TextStyle(
                  fontFamily: 'Handjet',
                  fontSize: 11,
                  color: palette.inkMuted,
                ),
              ),
            ],
          ] else ...[
            Text(
              isToday
                  ? 'No words captured today yet. Tap below to start capturing!'
                  : 'No words were recorded on this day.',
              style: TextStyle(
                fontFamily: 'Handjet',
                fontSize: 13,
                color: palette.inkMuted,
              ),
            ),
          ],

          const SizedBox(height: PixelMetrics.space4),

          PixelButton(
            label: 'JUMP TO THIS DAY’S JOURNAL',
            glyph: PixelGlyph.calendar,
            filled: true,
            expand: true,
            onPressed: () => _jumpToDate(_selectedDate),
          ),
        ],
      ),
    );
  }
}
