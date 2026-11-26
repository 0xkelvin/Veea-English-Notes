import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../core/theme/pixel_metrics.dart';
import '../core/theme/pixel_palette.dart';
import '../models/commute_playlist.dart';
import '../models/vocabulary_word.dart';
import '../services/audio_commute_service.dart';
import '../services/commute_playlist_service.dart';

enum _ChooserSection { words, savedLists }

sealed class _WordListEntry {
  const _WordListEntry();
}

final class _DateHeaderEntry extends _WordListEntry {
  const _DateHeaderEntry(this.dateKey, this.words);

  final String dateKey;
  final List<VocabularyWord> words;
}

final class _WordRowEntry extends _WordListEntry {
  const _WordRowEntry(this.word);

  final VocabularyWord word;
}

class CommuteTapeSelectorSheet extends StatefulWidget {
  const CommuteTapeSelectorSheet({
    super.key,
    required this.allWords,
    required this.commuteService,
  });

  final List<VocabularyWord> allWords;
  final AudioCommuteService commuteService;

  static Future<void> show(
    BuildContext context, {
    required List<VocabularyWord> allWords,
    required AudioCommuteService commuteService,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => CommuteTapeSelectorSheet(
        allWords: allWords,
        commuteService: commuteService,
      ),
    );
  }

  @override
  State<CommuteTapeSelectorSheet> createState() =>
      _CommuteTapeSelectorSheetState();
}

class _CommuteTapeSelectorSheetState extends State<CommuteTapeSelectorSheet> {
  _ChooserSection _section = _ChooserSection.words;
  bool _showCalendar = false;

  final Set<String> _selectedWordIds = {};
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  Map<String, List<VocabularyWord>> _wordsByDate = const {};
  Map<String, String> _searchIndex = const {};
  DateTime _calendarMonth = DateTime(
    DateTime.now().year,
    DateTime.now().month,
    1,
  );

  @override
  void initState() {
    super.initState();
    _rebuildWordIndex();
    _initCalendarMonth();

    final availableIds = widget.allWords.map((w) => w.id).toSet();
    if (widget.commuteService.playlist.isNotEmpty) {
      for (final word in widget.commuteService.playlist) {
        if (availableIds.contains(word.id)) {
          _selectedWordIds.add(word.id);
        }
      }
    }
    if (_selectedWordIds.isEmpty && _wordsByDate.isNotEmpty) {
      final newestDate = _wordsByDate.keys.first;
      for (final word in _wordsByDate[newestDate]!) {
        _selectedWordIds.add(word.id);
      }
    }
  }

  @override
  void didUpdateWidget(covariant CommuteTapeSelectorSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.allWords != widget.allWords) {
      setState(() {
        _rebuildWordIndex();
        final availableIds = widget.allWords.map((w) => w.id).toSet();
        _selectedWordIds.retainAll(availableIds);
      });
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _rebuildWordIndex() {
    _wordsByDate = CommutePlaylistService.groupWordsByDate(widget.allWords);
    _searchIndex = {
      for (final word in widget.allWords)
        word.id:
            '${word.word} ${word.meaning} ${word.date} ${word.tags.join(' ')}'
                .toLowerCase(),
    };
  }

  void _initCalendarMonth() {
    var initialMonth = DateTime.now();
    if (_wordsByDate.isNotEmpty) {
      final newestDate = DateTime.tryParse(_wordsByDate.keys.first);
      if (newestDate != null) {
        initialMonth = newestDate;
      }
    }
    _calendarMonth = DateTime(initialMonth.year, initialMonth.month, 1);
  }

  static String _dateKey(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';

  static String _formatDateLabel(String dateKey) {
    final parsed = DateTime.tryParse(dateKey);
    if (parsed == null) return dateKey;
    final now = DateTime.now();
    final todayKey = _dateKey(now);
    final yesterdayKey = _dateKey(now.subtract(const Duration(days: 1)));
    if (dateKey == todayKey) {
      return 'Today · ${DateFormat.MMMd().format(parsed)}';
    }
    if (dateKey == yesterdayKey) {
      return 'Yesterday · ${DateFormat.MMMd().format(parsed)}';
    }
    return DateFormat.yMMMd().format(parsed);
  }

  static String _wordCountLabel(int count) =>
      count == 1 ? '1 word' : '$count words';

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
    final today = DateTime.now();
    final todayKey = _dateKey(today);
    final todayWords = _wordsByDate[todayKey];
    setState(() {
      _calendarMonth = DateTime(today.year, today.month, 1);
      if (todayWords != null && todayWords.isNotEmpty) {
        _selectedWordIds
          ..clear()
          ..addAll(todayWords.map((w) => w.id));
      }
    });
    if (todayWords == null || todayWords.isEmpty) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('No words saved for today.')),
      );
    }
  }

  void _selectWords(Iterable<VocabularyWord> words) {
    setState(() {
      for (final word in words) {
        _selectedWordIds.add(word.id);
      }
    });
  }

  void _clearSelection() {
    setState(() => _selectedWordIds.clear());
  }

  void _toggleDate(String dateKey) {
    final wordsOnDate = _wordsByDate[dateKey] ?? const [];
    if (wordsOnDate.isEmpty) return;
    final allSelected = wordsOnDate.every(
      (w) => _selectedWordIds.contains(w.id),
    );
    setState(() {
      if (allSelected) {
        for (final word in wordsOnDate) {
          _selectedWordIds.remove(word.id);
        }
      } else {
        for (final word in wordsOnDate) {
          _selectedWordIds.add(word.id);
        }
      }
    });
  }

  void _toggleWord(String wordId) {
    setState(() {
      if (_selectedWordIds.contains(wordId)) {
        _selectedWordIds.remove(wordId);
      } else {
        _selectedWordIds.add(wordId);
      }
    });
  }

  void _playSelection({String? customTitle}) {
    final selectedWords = widget.allWords
        .where((w) => _selectedWordIds.contains(w.id))
        .toList();

    if (selectedWords.isEmpty) return;

    var title = customTitle?.trim() ?? '';
    if (title.isEmpty) {
      final selectedDates = _wordsByDate.keys
          .where(
            (d) => (_wordsByDate[d] ?? const []).any(
              (w) => _selectedWordIds.contains(w.id),
            ),
          )
          .toList();
      if (selectedDates.length == 1) {
        title =
            '${_formatDateLabel(selectedDates.first)} · ${_wordCountLabel(selectedWords.length)}';
      } else if (selectedWords.length == widget.allWords.length) {
        title = 'All saved words · ${selectedWords.length}';
      } else {
        title =
            '${selectedDates.length} days · ${_wordCountLabel(selectedWords.length)}';
      }
    }

    widget.commuteService.startPlayback(selectedWords, playlistTitle: title);
    Navigator.of(context).pop();
  }

  Future<void> _saveAsCustomPlaylist() async {
    if (_selectedWordIds.isEmpty) return;

    final enteredName = await showDialog<String>(
      context: context,
      builder: (_) => _SaveListDialog(wordCount: _selectedWordIds.length),
    );

    if (enteredName == null || !mounted) return;
    final trimmed = enteredName.trim();
    final resolvedName = trimmed.isEmpty
        ? 'Saved list (${_selectedWordIds.length})'
        : trimmed;
    final playlistService = context.read<CommutePlaylistService>();
    await playlistService.createPlaylist(
      resolvedName,
      _selectedWordIds.toList(),
    );

    if (!mounted) return;
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text('Saved "$resolvedName"')));
    setState(() => _section = _ChooserSection.savedLists);
  }

  void _openCreateOrEditPlaylist({CommutePlaylist? existing}) {
    final playlistService = context.read<CommutePlaylistService>();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _PlaylistEditorSheet(
        allWords: widget.allWords,
        playlistService: playlistService,
        existing: existing,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_wordsByDate.isEmpty && widget.allWords.isNotEmpty) {
      _rebuildWordIndex();
      _initCalendarMonth();
    }

    final palette = context.palette;
    final viewInsetsBottom = MediaQuery.viewInsetsOf(context).bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: viewInsetsBottom),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final maxHeight = constraints.maxHeight;
          final targetHeight = constraints.isTight
              ? maxHeight
              : (maxHeight < 520 ? maxHeight : maxHeight * 0.92);

          return Material(
            key: const Key('listen_word_chooser_sheet'),
            color: palette.surface,
            borderRadius: constraints.isTight
                ? BorderRadius.zero
                : const BorderRadius.vertical(top: Radius.circular(24)),
            clipBehavior: Clip.antiAlias,
            child: SizedBox(
              height: targetHeight,
              width: double.infinity,
              child: SafeArea(
                top: false,
                child: Column(
                  children: [
                    if (!constraints.isTight) _buildDragHandle(palette),
                    _buildHeader(context, palette),
                    _buildSectionSwitcher(context, palette),
                    Divider(height: 1, color: palette.border),
                    Expanded(
                      child: _section == _ChooserSection.words
                          ? _buildWordsSection(context, palette)
                          : _buildSavedListsSection(context, palette),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildDragHandle(PixelPalette palette) {
    return ExcludeSemantics(
      child: Padding(
        padding: const EdgeInsets.only(top: PixelMetrics.space2),
        child: Container(
          width: 36,
          height: 4,
          decoration: BoxDecoration(
            color: palette.border,
            borderRadius: BorderRadius.circular(PixelMetrics.radiusPill),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, PixelPalette palette) {
    final theme = Theme.of(context);
    final largeText = MediaQuery.textScalerOf(context).scale(1) > 1.4;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        PixelMetrics.space4,
        PixelMetrics.space2,
        PixelMetrics.space2,
        PixelMetrics.space2,
      ),
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              header: true,
              child: Text(
                'Choose words',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style:
                    (largeText
                            ? theme.textTheme.titleMedium
                            : theme.textTheme.titleLarge)
                        ?.copyWith(color: palette.ink),
              ),
            ),
          ),
          IconButton(
            key: const Key('listen_chooser_close'),
            tooltip: 'Close',
            onPressed: () => Navigator.of(context).pop(),
            icon: Icon(Icons.close_rounded, color: palette.inkMuted),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionSwitcher(BuildContext context, PixelPalette palette) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        PixelMetrics.space4,
        0,
        PixelMetrics.space4,
        PixelMetrics.space3,
      ),
      child: Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: palette.paper,
          borderRadius: BorderRadius.circular(PixelMetrics.radius),
          border: Border.all(color: palette.border, width: PixelMetrics.border),
        ),
        child: Row(
          children: [
            Expanded(
              child: _SegmentButton(
                key: const Key('listen_tab_words'),
                label: 'Words',
                selected: _section == _ChooserSection.words,
                onTap: () => setState(() => _section = _ChooserSection.words),
              ),
            ),
            const SizedBox(width: 3),
            Expanded(
              child: _SegmentButton(
                key: const Key('listen_tab_saved_lists'),
                label: MediaQuery.textScalerOf(context).scale(1) > 1.4
                    ? 'Saved'
                    : 'Saved lists',
                selected: _section == _ChooserSection.savedLists,
                onTap: () {
                  FocusScope.of(context).unfocus();
                  setState(() => _section = _ChooserSection.savedLists);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWordsSection(BuildContext context, PixelPalette palette) {
    final theme = Theme.of(context);
    final query = _searchQuery.trim().toLowerCase();

    final entries = <_WordListEntry>[];
    final matchingWords = <VocabularyWord>[];
    for (final entry in _wordsByDate.entries) {
      final wordsOnDate = query.isEmpty
          ? entry.value
          : entry.value
                .where((w) => (_searchIndex[w.id] ?? '').contains(query))
                .toList();
      if (wordsOnDate.isEmpty) continue;
      entries.add(_DateHeaderEntry(entry.key, wordsOnDate));
      for (final word in wordsOnDate) {
        entries.add(_WordRowEntry(word));
        matchingWords.add(word);
      }
    }

    final selectTargetWords = query.isEmpty ? widget.allWords : matchingWords;
    final canSelectAll =
        selectTargetWords.isNotEmpty &&
        selectTargetWords.any((w) => !_selectedWordIds.contains(w.id));

    return Column(
      children: [
        Expanded(
          child: widget.allWords.isEmpty
              ? Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(PixelMetrics.space6),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.headphones_rounded,
                          size: 36,
                          color: palette.inkFaint,
                        ),
                        const SizedBox(height: PixelMetrics.space3),
                        Text(
                          'No saved words yet',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: palette.ink,
                          ),
                        ),
                        const SizedBox(height: PixelMetrics.space1),
                        Text(
                          'Save words in your notebook to listen to them here.',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: palette.inkMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              : CustomScrollView(
                  key: const Key('listen_words_scroll'),
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  slivers: [
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(
                          PixelMetrics.space4,
                          PixelMetrics.space3,
                          PixelMetrics.space4,
                          PixelMetrics.space2,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            TextField(
                              key: const Key('listen_word_search'),
                              controller: _searchController,
                              onChanged: (value) =>
                                  setState(() => _searchQuery = value),
                              decoration: InputDecoration(
                                isDense: true,
                                fillColor: palette.paper,
                                prefixIcon: const Icon(Icons.search_rounded),
                                hintText: 'Search words or meanings',
                                suffixIcon: _searchQuery.isEmpty
                                    ? null
                                    : IconButton(
                                        tooltip: 'Clear search',
                                        onPressed: () {
                                          _searchController.clear();
                                          setState(() => _searchQuery = '');
                                        },
                                        icon: const Icon(Icons.close_rounded),
                                      ),
                              ),
                            ),
                            const SizedBox(height: PixelMetrics.space2),
                            Wrap(
                              spacing: PixelMetrics.space2,
                              runSpacing: PixelMetrics.space2,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                _ActionPillButton(
                                  key: const Key('listen_calendar_toggle'),
                                  label: 'Calendar',
                                  leadingIcon: Icons.calendar_month_rounded,
                                  trailingIcon: _showCalendar
                                      ? Icons.keyboard_arrow_up_rounded
                                      : Icons.keyboard_arrow_down_rounded,
                                  active: _showCalendar,
                                  onPressed: () {
                                    FocusScope.of(context).unfocus();
                                    setState(
                                      () => _showCalendar = !_showCalendar,
                                    );
                                  },
                                ),
                                _ActionPillButton(
                                  key: const Key('listen_select_all'),
                                  label: query.isEmpty
                                      ? 'Select all'
                                      : 'Select matches',
                                  onPressed: canSelectAll
                                      ? () => _selectWords(selectTargetWords)
                                      : null,
                                ),
                                _ActionPillButton(
                                  key: const Key('listen_clear_selection'),
                                  label: 'Clear',
                                  onPressed: _selectedWordIds.isNotEmpty
                                      ? _clearSelection
                                      : null,
                                ),
                              ],
                            ),
                            if (_showCalendar) ...[
                              const SizedBox(height: PixelMetrics.space3),
                              _buildCalendarCard(context, palette),
                            ],
                          ],
                        ),
                      ),
                    ),
                    if (entries.isEmpty)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.all(PixelMetrics.space6),
                          child: Column(
                            children: [
                              Text(
                                'No matching words',
                                textAlign: TextAlign.center,
                                style: theme.textTheme.titleSmall?.copyWith(
                                  color: palette.ink,
                                ),
                              ),
                              const SizedBox(height: PixelMetrics.space1),
                              Text(
                                'Try another search term or clear the filter.',
                                textAlign: TextAlign.center,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: palette.inkMuted,
                                ),
                              ),
                              const SizedBox(height: PixelMetrics.space2),
                              TextButton(
                                onPressed: () {
                                  _searchController.clear();
                                  setState(() => _searchQuery = '');
                                },
                                child: const Text('Clear search'),
                              ),
                            ],
                          ),
                        ),
                      )
                    else
                      SliverPadding(
                        padding: const EdgeInsets.only(
                          bottom: PixelMetrics.space4,
                        ),
                        sliver: SliverList.builder(
                          itemCount: entries.length,
                          itemBuilder: (context, index) {
                            final item = entries[index];
                            return switch (item) {
                              _DateHeaderEntry() => _buildDateHeaderRow(
                                context,
                                item.dateKey,
                                item.words,
                                palette,
                              ),
                              _WordRowEntry() => _buildWordRow(
                                context,
                                item.word,
                                palette,
                              ),
                            };
                          },
                        ),
                      ),
                  ],
                ),
        ),
        _buildSelectionFooter(context, palette),
      ],
    );
  }

  Widget _buildCalendarCard(BuildContext context, PixelPalette palette) {
    final theme = Theme.of(context);
    final textScale = MediaQuery.textScalerOf(context).scale(1);
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
    final leadingBlanks = firstDayOfMonth.weekday - 1;
    final totalCells = leadingBlanks + daysInMonth;
    final rowCount = (totalCells / 7).ceil();
    final monthTitle = DateFormat.yMMMM().format(_calendarMonth);

    final isLargeText = textScale > 1.35;

    return Container(
      key: const Key('listen_calendar_card'),
      padding: EdgeInsets.all(
        isLargeText ? PixelMetrics.space2 : PixelMetrics.space3,
      ),
      decoration: BoxDecoration(
        color: palette.paper,
        borderRadius: BorderRadius.circular(PixelMetrics.radius),
        border: Border.all(color: palette.border, width: PixelMetrics.border),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final isCompact = constraints.maxWidth < 300 || isLargeText;
          final dayNames = isCompact
              ? const ['M', 'T', 'W', 'T', 'F', 'S', 'S']
              : const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
          final prevButton = IconButton(
            key: const Key('listen_calendar_prev_month'),
            tooltip: 'Previous month',
            onPressed: _goToPreviousMonth,
            icon: Icon(Icons.chevron_left_rounded, color: palette.ink),
          );
          final nextButton = IconButton(
            key: const Key('listen_calendar_next_month'),
            tooltip: 'Next month',
            onPressed: _goToNextMonth,
            icon: Icon(Icons.chevron_right_rounded, color: palette.ink),
          );
          final todayButton = TextButton(
            key: const Key('listen_calendar_today'),
            onPressed: _selectToday,
            child: const Text('Today'),
          );

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (isCompact) ...[
                Row(
                  children: [
                    prevButton,
                    Expanded(
                      child: Text(
                        monthTitle,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: palette.ink,
                        ),
                      ),
                    ),
                    nextButton,
                  ],
                ),
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: todayButton,
                ),
              ] else ...[
                Row(
                  children: [
                    prevButton,
                    Expanded(
                      child: Text(
                        monthTitle,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: palette.ink,
                        ),
                      ),
                    ),
                    nextButton,
                    todayButton,
                  ],
                ),
              ],
              const SizedBox(height: PixelMetrics.space1),
              Text(
                'Tap highlighted days to select or deselect their words.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: palette.inkMuted,
                ),
              ),
              const SizedBox(height: PixelMetrics.space2),
              Row(
                children: [
                  for (final dayName in dayNames)
                    Expanded(
                      child: Center(
                        child: Text(
                          dayName,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: palette.inkMuted,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: PixelMetrics.space1),
              for (var r = 0; r < rowCount; r++) ...[
                Row(
                  children: [
                    for (var c = 0; c < 7; c++)
                      Expanded(
                        child: _buildCalendarDayCell(
                          context,
                          r * 7 + c,
                          leadingBlanks,
                          daysInMonth,
                          palette,
                          isCompact: isCompact,
                        ),
                      ),
                  ],
                ),
                if (r < rowCount - 1) const SizedBox(height: 4),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _buildCalendarDayCell(
    BuildContext context,
    int cellIndex,
    int leadingBlanks,
    int daysInMonth,
    PixelPalette palette, {
    required bool isCompact,
  }) {
    final day = cellIndex - leadingBlanks + 1;
    if (day < 1 || day > daysInMonth) {
      return const SizedBox(height: 40);
    }

    final theme = Theme.of(context);
    final textScale = MediaQuery.textScalerOf(context).scale(1);
    final dayFontSize = textScale > 1.4 ? 11.0 : 13.0;
    final cellMargin = isCompact ? 1.0 : 2.0;
    final cellDate = DateTime(_calendarMonth.year, _calendarMonth.month, day);
    final dateKey = _dateKey(cellDate);
    final words = _wordsByDate[dateKey] ?? const [];
    final hasWords = words.isNotEmpty;

    if (!hasWords) {
      return Padding(
        padding: EdgeInsets.symmetric(horizontal: cellMargin),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 40),
          child: Center(
            child: Text(
              '$day',
              style: theme.textTheme.bodySmall?.copyWith(
                fontSize: dayFontSize,
                color: palette.inkFaint.withValues(alpha: 0.45),
              ),
            ),
          ),
        ),
      );
    }

    final selectedCount = words
        .where((w) => _selectedWordIds.contains(w.id))
        .length;
    final isFull = selectedCount == words.length;
    final isPartial = selectedCount > 0 && selectedCount < words.length;

    final Color bgColor;
    final Color borderColor;
    final Color textColor;
    final Color badgeColor;
    final String badgeText;

    if (isFull) {
      bgColor = palette.accent;
      borderColor = palette.accent;
      textColor = palette.onAccent;
      badgeColor = palette.onAccent.withValues(alpha: 0.9);
      badgeText = '${words.length}';
    } else if (isPartial) {
      bgColor = palette.accent.withValues(alpha: 0.16);
      borderColor = palette.accent;
      textColor = palette.ink;
      badgeColor = palette.accent;
      badgeText = '$selectedCount/${words.length}';
    } else {
      bgColor = palette.surface;
      borderColor = palette.border;
      textColor = palette.ink;
      badgeColor = palette.inkMuted;
      badgeText = '${words.length}';
    }

    final semanticLabel =
        '${DateFormat.yMMMd().format(cellDate)}, $selectedCount of ${_wordCountLabel(words.length)} selected';

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: cellMargin),
      child: Semantics(
        button: true,
        selected: isFull,
        label: semanticLabel,
        child: Material(
          color: bgColor,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(PixelMetrics.radiusSm),
            side: BorderSide(color: borderColor, width: PixelMetrics.border),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => _toggleDate(dateKey),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 40),
              child: Padding(
                padding: EdgeInsets.symmetric(
                  vertical: 4,
                  horizontal: isCompact ? 0 : 2,
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      '$day',
                      style: theme.textTheme.labelMedium?.copyWith(
                        fontSize: dayFontSize,
                        color: textColor,
                        fontWeight: FontWeight.w600,
                        height: 1.1,
                      ),
                    ),
                    const SizedBox(height: 2),
                    if (isCompact)
                      Container(
                        width: 5,
                        height: 5,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: isFull
                              ? palette.onAccent
                              : (isPartial ? palette.accent : palette.inkFaint),
                        ),
                      )
                    else
                      Text(
                        badgeText,
                        style: theme.textTheme.labelSmall?.copyWith(
                          fontSize: 10,
                          color: badgeColor,
                          height: 1.0,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDateHeaderRow(
    BuildContext context,
    String dateKey,
    List<VocabularyWord> visibleWordsOnDate,
    PixelPalette palette,
  ) {
    final theme = Theme.of(context);
    final allWordsOnDate = _wordsByDate[dateKey] ?? visibleWordsOnDate;
    final selectedCount = allWordsOnDate
        .where((w) => _selectedWordIds.contains(w.id))
        .length;
    final bool? checkboxValue = selectedCount == 0
        ? false
        : (selectedCount == allWordsOnDate.length ? true : null);

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        PixelMetrics.space2,
        PixelMetrics.space3,
        PixelMetrics.space2,
        PixelMetrics.space1,
      ),
      child: InkWell(
        key: ValueKey('listen_date_$dateKey'),
        borderRadius: BorderRadius.circular(PixelMetrics.radiusSm),
        onTap: () => _toggleDate(dateKey),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: PixelMetrics.tapTarget),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: PixelMetrics.space2,
              vertical: PixelMetrics.space1,
            ),
            child: Row(
              children: [
                Checkbox(
                  tristate: true,
                  value: checkboxValue,
                  activeColor: palette.accent,
                  checkColor: palette.onAccent,
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  onChanged: (_) => _toggleDate(dateKey),
                ),
                const SizedBox(width: PixelMetrics.space2),
                Expanded(
                  child: Text(
                    _formatDateLabel(dateKey),
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: palette.ink,
                    ),
                  ),
                ),
                const SizedBox(width: PixelMetrics.space2),
                Text(
                  '$selectedCount/${allWordsOnDate.length}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: selectedCount > 0
                        ? palette.accent
                        : palette.inkFaint,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildWordRow(
    BuildContext context,
    VocabularyWord word,
    PixelPalette palette,
  ) {
    final theme = Theme.of(context);
    final isSelected = _selectedWordIds.contains(word.id);
    final pronunciation = word.pronunciation?.trim() ?? '';

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: PixelMetrics.space2,
        vertical: 1,
      ),
      child: Material(
        color: isSelected
            ? palette.accent.withValues(alpha: 0.08)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(PixelMetrics.radiusSm),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: ValueKey('listen_word_${word.id}'),
          onTap: () => _toggleWord(word.id),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: PixelMetrics.space2,
                vertical: PixelMetrics.space2,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Checkbox(
                    value: isSelected,
                    activeColor: palette.accent,
                    checkColor: palette.onAccent,
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    onChanged: (_) => _toggleWord(word.id),
                  ),
                  const SizedBox(width: PixelMetrics.space2),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Wrap(
                          spacing: PixelMetrics.space2,
                          runSpacing: 2,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(
                              word.word,
                              style: theme.textTheme.bodyLarge?.copyWith(
                                fontWeight: FontWeight.w600,
                                color: isSelected
                                    ? palette.accent
                                    : palette.ink,
                              ),
                            ),
                            if (pronunciation.isNotEmpty)
                              Text(
                                pronunciation,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: palette.inkFaint,
                                ),
                              ),
                          ],
                        ),
                        if (word.meaning.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            word.meaning,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: palette.inkMuted,
                            ),
                          ),
                        ],
                      ],
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

  Widget _buildSelectionFooter(BuildContext context, PixelPalette palette) {
    final theme = Theme.of(context);
    final textScale = MediaQuery.textScalerOf(context).scale(1);
    final selectedCount = _selectedWordIds.length;
    final hasSelection = selectedCount > 0;
    final countText = textScale > 1.4
        ? '$selectedCount selected'
        : '${_wordCountLabel(selectedCount)} selected';

    final countLabel = Semantics(
      liveRegion: true,
      child: Text(
        countText,
        key: const Key('listen_selected_count'),
        style: theme.textTheme.titleSmall?.copyWith(
          color: hasSelection ? palette.ink : palette.inkMuted,
        ),
      ),
    );

    final saveListButton = TextButton(
      key: const Key('listen_save_as_list'),
      onPressed: hasSelection ? _saveAsCustomPlaylist : null,
      child: const Text('Save list'),
    );

    final playButton = FilledButton.icon(
      key: const Key('listen_play_selection'),
      onPressed: hasSelection ? _playSelection : null,
      icon: const Icon(Icons.play_arrow_rounded),
      label: const Text('Play selection'),
    );

    return Container(
      key: const Key('listen_selection_footer'),
      padding: const EdgeInsets.fromLTRB(
        PixelMetrics.space4,
        PixelMetrics.space3,
        PixelMetrics.space4,
        PixelMetrics.space3,
      ),
      decoration: BoxDecoration(
        color: palette.surface,
        border: Border(
          top: BorderSide(color: palette.border, width: PixelMetrics.border),
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final singleRow = constraints.maxWidth >= 460 && textScale <= 1.35;
          if (singleRow) {
            return Row(
              children: [
                Expanded(child: countLabel),
                saveListButton,
                const SizedBox(width: PixelMetrics.space2),
                playButton,
              ],
            );
          }

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (textScale > 1.4)
                Row(
                  children: [
                    Expanded(child: countLabel),
                    IconButton(
                      key: const Key('listen_save_as_list'),
                      tooltip: 'Save list',
                      onPressed: hasSelection ? _saveAsCustomPlaylist : null,
                      icon: const Icon(Icons.bookmark_add_outlined),
                    ),
                  ],
                )
              else
                Wrap(
                  spacing: PixelMetrics.space2,
                  runSpacing: PixelMetrics.space1,
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [countLabel, saveListButton],
                ),
              const SizedBox(height: PixelMetrics.space2),
              playButton,
            ],
          );
        },
      ),
    );
  }

  Widget _buildSavedListsSection(BuildContext context, PixelPalette palette) {
    final theme = Theme.of(context);
    final playlistService = context.watch<CommutePlaylistService>();
    final playlists = playlistService.playlists;

    return CustomScrollView(
      key: const Key('listen_saved_lists_scroll'),
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              PixelMetrics.space4,
              PixelMetrics.space3,
              PixelMetrics.space4,
              PixelMetrics.space2,
            ),
            child: Wrap(
              spacing: PixelMetrics.space2,
              runSpacing: PixelMetrics.space2,
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  playlists.isEmpty
                      ? 'Saved word lists'
                      : '${playlists.length} saved ${playlists.length == 1 ? 'list' : 'lists'}',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: palette.inkMuted,
                  ),
                ),
                FilledButton.tonalIcon(
                  key: const Key('listen_new_list_button'),
                  onPressed: widget.allWords.isEmpty
                      ? null
                      : () => _openCreateOrEditPlaylist(),
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('New list'),
                ),
              ],
            ),
          ),
        ),
        if (playlists.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(PixelMetrics.space6),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.playlist_play_rounded,
                      size: 40,
                      color: palette.inkFaint,
                    ),
                    const SizedBox(height: PixelMetrics.space3),
                    Text(
                      'No saved lists yet',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: palette.ink,
                      ),
                    ),
                    const SizedBox(height: PixelMetrics.space1),
                    Text(
                      'Save a selection from Words or create a new list to replay anytime.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: palette.inkMuted,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(
              PixelMetrics.space4,
              PixelMetrics.space1,
              PixelMetrics.space4,
              PixelMetrics.space4,
            ),
            sliver: SliverList.builder(
              itemCount: playlists.length,
              itemBuilder: (context, index) => _buildSavedListCard(
                context,
                playlists[index],
                playlistService,
                palette,
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildSavedListCard(
    BuildContext context,
    CommutePlaylist playlist,
    CommutePlaylistService playlistService,
    PixelPalette palette,
  ) {
    final theme = Theme.of(context);
    final idSet = playlist.wordIds.toSet();
    final matchingWords = widget.allWords
        .where((w) => idSet.contains(w.id))
        .toList();
    final createdDate = DateFormat.yMMMd().format(playlist.createdAt);
    final preview = matchingWords.isEmpty
        ? 'No matching words in your notebook'
        : matchingWords.map((w) => w.word).take(6).join(', ') +
              (matchingWords.length > 6 ? '…' : '');

    return Container(
      key: ValueKey('listen_saved_list_${playlist.id}'),
      margin: const EdgeInsets.only(bottom: PixelMetrics.space3),
      padding: const EdgeInsets.all(PixelMetrics.space4),
      decoration: BoxDecoration(
        color: palette.paper,
        borderRadius: BorderRadius.circular(PixelMetrics.radius),
        border: Border.all(color: palette.border, width: PixelMetrics.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            playlist.name,
            style: theme.textTheme.titleMedium?.copyWith(color: palette.ink),
          ),
          const SizedBox(height: 2),
          Text(
            '${_wordCountLabel(matchingWords.length)} · Created $createdDate',
            style: theme.textTheme.bodySmall?.copyWith(color: palette.inkMuted),
          ),
          const SizedBox(height: PixelMetrics.space2),
          Text(
            preview,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: palette.inkMuted,
            ),
          ),
          const SizedBox(height: PixelMetrics.space3),
          Wrap(
            spacing: PixelMetrics.space2,
            runSpacing: PixelMetrics.space2,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilledButton.icon(
                onPressed: matchingWords.isNotEmpty
                    ? () {
                        widget.commuteService.startPlayback(
                          matchingWords,
                          playlistTitle: playlist.name,
                        );
                        Navigator.of(context).pop();
                      }
                    : null,
                icon: const Icon(Icons.play_arrow_rounded),
                label: Text('Play (${matchingWords.length})'),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: 'Edit list',
                    onPressed: () =>
                        _openCreateOrEditPlaylist(existing: playlist),
                    icon: Icon(Icons.edit_outlined, color: palette.inkMuted),
                  ),
                  IconButton(
                    tooltip: 'Delete list',
                    onPressed: () async {
                      await playlistService.deletePlaylist(playlist.id);
                    },
                    icon: Icon(Icons.delete_outline, color: palette.danger),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SegmentButton extends StatelessWidget {
  const _SegmentButton({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final theme = Theme.of(context);

    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: selected ? palette.surface : Colors.transparent,
        borderRadius: BorderRadius.circular(PixelMetrics.radiusSm),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minHeight: 40),
            padding: const EdgeInsets.symmetric(
              horizontal: PixelMetrics.space3,
              vertical: PixelMetrics.space2,
            ),
            decoration: selected
                ? BoxDecoration(
                    borderRadius: BorderRadius.circular(PixelMetrics.radiusSm),
                    border: Border.all(
                      color: palette.border,
                      width: PixelMetrics.border,
                    ),
                  )
                : null,
            alignment: Alignment.center,
            child: Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelMedium?.copyWith(
                color: selected ? palette.ink : palette.inkMuted,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ActionPillButton extends StatelessWidget {
  const _ActionPillButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.leadingIcon,
    this.trailingIcon,
    this.active = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? leadingIcon;
  final IconData? trailingIcon;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final theme = Theme.of(context);
    final enabled = onPressed != null;

    final Color bgColor;
    final Color borderColor;
    final Color fgColor;

    if (!enabled) {
      bgColor = palette.paper.withValues(alpha: 0.6);
      borderColor = palette.border.withValues(alpha: 0.6);
      fgColor = palette.inkFaint;
    } else if (active) {
      bgColor = palette.accent.withValues(alpha: 0.12);
      borderColor = palette.accent.withValues(alpha: 0.4);
      fgColor = palette.accent;
    } else {
      bgColor = palette.paper;
      borderColor = palette.border;
      fgColor = palette.ink;
    }

    return Semantics(
      button: true,
      enabled: enabled,
      toggled: active,
      child: Material(
        color: bgColor,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(PixelMetrics.radiusPill),
          side: BorderSide(color: borderColor, width: PixelMetrics.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 40),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: PixelMetrics.space3,
                vertical: PixelMetrics.space2,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (leadingIcon != null) ...[
                    Icon(leadingIcon, size: 18, color: fgColor),
                    const SizedBox(width: PixelMetrics.space1),
                  ],
                  Flexible(
                    child: Text(
                      label,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: fgColor,
                      ),
                    ),
                  ),
                  if (trailingIcon != null) ...[
                    const SizedBox(width: 2),
                    Icon(trailingIcon, size: 18, color: fgColor),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SaveListDialog extends StatefulWidget {
  const _SaveListDialog({required this.wordCount});

  final int wordCount;

  @override
  State<_SaveListDialog> createState() => _SaveListDialogState();
}

class _SaveListDialogState extends State<_SaveListDialog> {
  final TextEditingController _nameController = TextEditingController();

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  void _submit() {
    Navigator.of(context).pop(_nameController.text);
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final theme = Theme.of(context);
    final countLabel = widget.wordCount == 1
        ? '1 word'
        : '${widget.wordCount} words';

    return AlertDialog(
      scrollable: true,
      title: Text(
        'Save as list',
        style: theme.textTheme.titleLarge?.copyWith(color: palette.ink),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Save $countLabel for quick listening later.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: palette.inkMuted,
            ),
          ),
          const SizedBox(height: PixelMetrics.space3),
          TextField(
            key: const Key('listen_save_list_name_field'),
            controller: _nameController,
            autofocus: true,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _submit(),
            decoration: const InputDecoration(
              labelText: 'List name',
              hintText: 'e.g. Morning review',
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Save')),
      ],
    );
  }
}

class _PlaylistEditorSheet extends StatefulWidget {
  const _PlaylistEditorSheet({
    required this.allWords,
    required this.playlistService,
    this.existing,
  });

  final List<VocabularyWord> allWords;
  final CommutePlaylistService playlistService;
  final CommutePlaylist? existing;

  @override
  State<_PlaylistEditorSheet> createState() => _PlaylistEditorSheetState();
}

class _PlaylistEditorSheetState extends State<_PlaylistEditorSheet> {
  late final TextEditingController _nameController;
  final TextEditingController _searchController = TextEditingController();
  final Set<String> _selectedIds = {};
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.existing?.name ?? '');
    if (widget.existing != null) {
      final availableIds = widget.allWords.map((w) => w.id).toSet();
      _selectedIds.addAll(
        widget.existing!.wordIds.where(availableIds.contains),
      );
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  bool get _canSave =>
      _selectedIds.isNotEmpty && _nameController.text.trim().isNotEmpty;

  Future<void> _save() async {
    final name = _nameController.text.trim();
    if (name.isEmpty || _selectedIds.isEmpty) return;

    if (widget.existing != null) {
      await widget.playlistService.updatePlaylist(
        widget.existing!.copyWith(name: name, wordIds: _selectedIds.toList()),
      );
    } else {
      await widget.playlistService.createPlaylist(name, _selectedIds.toList());
    }

    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final theme = Theme.of(context);
    final query = _searchQuery.trim().toLowerCase();
    final filteredWords = query.isEmpty
        ? widget.allWords
        : widget.allWords.where((w) {
            return w.word.toLowerCase().contains(query) ||
                w.meaning.toLowerCase().contains(query);
          }).toList();
    final allSelected =
        widget.allWords.isNotEmpty &&
        _selectedIds.length == widget.allWords.length;
    final viewInsetsBottom = MediaQuery.viewInsetsOf(context).bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: viewInsetsBottom),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final maxHeight = constraints.maxHeight;
          final targetHeight = constraints.isTight
              ? maxHeight
              : (maxHeight < 520 ? maxHeight : maxHeight * 0.90);

          return Material(
            key: const Key('listen_list_editor_sheet'),
            color: palette.surface,
            borderRadius: constraints.isTight
                ? BorderRadius.zero
                : const BorderRadius.vertical(top: Radius.circular(24)),
            clipBehavior: Clip.antiAlias,
            child: SizedBox(
              height: targetHeight,
              width: double.infinity,
              child: SafeArea(
                top: false,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        PixelMetrics.space4,
                        PixelMetrics.space3,
                        PixelMetrics.space2,
                        PixelMetrics.space2,
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Semantics(
                              header: true,
                              child: Text(
                                widget.existing != null
                                    ? 'Edit list'
                                    : 'New list',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.titleLarge?.copyWith(
                                  color: palette.ink,
                                ),
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: 'Close',
                            onPressed: () => Navigator.of(context).pop(),
                            icon: Icon(
                              Icons.close_rounded,
                              color: palette.inkMuted,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Divider(height: 1, color: palette.border),
                    Expanded(
                      child: CustomScrollView(
                        key: const Key('listen_list_editor_scroll'),
                        keyboardDismissBehavior:
                            ScrollViewKeyboardDismissBehavior.onDrag,
                        slivers: [
                          SliverToBoxAdapter(
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(
                                PixelMetrics.space4,
                                PixelMetrics.space3,
                                PixelMetrics.space4,
                                PixelMetrics.space2,
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  TextField(
                                    key: const Key('listen_list_name_field'),
                                    controller: _nameController,
                                    onChanged: (_) => setState(() {}),
                                    textInputAction: TextInputAction.next,
                                    decoration: InputDecoration(
                                      labelText: 'List name',
                                      hintText: 'e.g. Morning review',
                                      fillColor: palette.paper,
                                    ),
                                  ),
                                  const SizedBox(height: PixelMetrics.space3),
                                  TextField(
                                    key: const Key('listen_list_search_field'),
                                    controller: _searchController,
                                    onChanged: (v) =>
                                        setState(() => _searchQuery = v),
                                    decoration: InputDecoration(
                                      hintText: 'Search words or meanings',
                                      prefixIcon: const Icon(
                                        Icons.search_rounded,
                                      ),
                                      fillColor: palette.paper,
                                      isDense: true,
                                      suffixIcon: _searchQuery.isEmpty
                                          ? null
                                          : IconButton(
                                              tooltip: 'Clear search',
                                              onPressed: () {
                                                _searchController.clear();
                                                setState(
                                                  () => _searchQuery = '',
                                                );
                                              },
                                              icon: const Icon(
                                                Icons.close_rounded,
                                              ),
                                            ),
                                    ),
                                  ),
                                  const SizedBox(height: PixelMetrics.space2),
                                  Wrap(
                                    spacing: PixelMetrics.space2,
                                    runSpacing: PixelMetrics.space1,
                                    alignment: WrapAlignment.spaceBetween,
                                    crossAxisAlignment:
                                        WrapCrossAlignment.center,
                                    children: [
                                      Text(
                                        '${_selectedIds.length} ${_selectedIds.length == 1 ? 'word' : 'words'} selected',
                                        style: theme.textTheme.bodySmall
                                            ?.copyWith(color: palette.inkMuted),
                                      ),
                                      TextButton(
                                        onPressed: widget.allWords.isEmpty
                                            ? null
                                            : () {
                                                setState(() {
                                                  if (allSelected) {
                                                    _selectedIds.clear();
                                                  } else {
                                                    _selectedIds.addAll(
                                                      widget.allWords.map(
                                                        (w) => w.id,
                                                      ),
                                                    );
                                                  }
                                                });
                                              },
                                        child: Text(
                                          allSelected
                                              ? 'Clear all'
                                              : 'Select all',
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ),
                          if (filteredWords.isEmpty)
                            SliverToBoxAdapter(
                              child: Padding(
                                padding: const EdgeInsets.all(
                                  PixelMetrics.space6,
                                ),
                                child: Text(
                                  'No matching words',
                                  textAlign: TextAlign.center,
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    color: palette.inkMuted,
                                  ),
                                ),
                              ),
                            )
                          else
                            SliverList.builder(
                              itemCount: filteredWords.length,
                              itemBuilder: (context, index) {
                                final word = filteredWords[index];
                                final isSelected = _selectedIds.contains(
                                  word.id,
                                );
                                return CheckboxListTile(
                                  controlAffinity:
                                      ListTileControlAffinity.leading,
                                  dense: true,
                                  value: isSelected,
                                  activeColor: palette.accent,
                                  checkColor: palette.onAccent,
                                  title: Text(
                                    word.word,
                                    style: theme.textTheme.bodyLarge?.copyWith(
                                      fontWeight: FontWeight.w600,
                                      color: isSelected
                                          ? palette.accent
                                          : palette.ink,
                                    ),
                                  ),
                                  subtitle: word.meaning.isNotEmpty
                                      ? Text(
                                          word.meaning,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: theme.textTheme.bodySmall
                                              ?.copyWith(
                                                color: palette.inkMuted,
                                              ),
                                        )
                                      : null,
                                  onChanged: (val) {
                                    setState(() {
                                      if (val == true) {
                                        _selectedIds.add(word.id);
                                      } else {
                                        _selectedIds.remove(word.id);
                                      }
                                    });
                                  },
                                );
                              },
                            ),
                        ],
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.fromLTRB(
                        PixelMetrics.space4,
                        PixelMetrics.space3,
                        PixelMetrics.space4,
                        PixelMetrics.space3,
                      ),
                      decoration: BoxDecoration(
                        color: palette.surface,
                        border: Border(
                          top: BorderSide(
                            color: palette.border,
                            width: PixelMetrics.border,
                          ),
                        ),
                      ),
                      child: FilledButton(
                        key: const Key('listen_list_save_button'),
                        onPressed: _canSave ? _save : null,
                        child: const Text('Save list'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
