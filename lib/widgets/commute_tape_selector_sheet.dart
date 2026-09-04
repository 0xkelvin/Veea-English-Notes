import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/theme/pixel_metrics.dart';
import '../core/theme/pixel_palette.dart';
import '../models/commute_playlist.dart';
import '../models/vocabulary_word.dart';
import '../services/audio_commute_service.dart';
import '../services/commute_playlist_service.dart';
import 'pixel/pixel_button.dart';
import 'pixel/pixel_icon.dart';

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
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
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

class _CommuteTapeSelectorSheetState extends State<CommuteTapeSelectorSheet>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final Set<String> _selectedWordIds = {};
  final Set<String> _expandedDates = {};

  Map<String, List<VocabularyWord>> _wordsByDate = const {};
  DateTime _calendarMonth = DateTime(DateTime.now().year, DateTime.now().month, 1);

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _wordsByDate = CommutePlaylistService.groupWordsByDate(widget.allWords);
    _initCalendarMonth();

    // Default selection: words currently in player, or the newest date's words
    if (widget.commuteService.playlist.isNotEmpty) {
      for (final w in widget.commuteService.playlist) {
        _selectedWordIds.add(w.id);
      }
    } else if (_wordsByDate.isNotEmpty) {
      final newestDate = _wordsByDate.keys.first;
      for (final w in _wordsByDate[newestDate]!) {
        _selectedWordIds.add(w.id);
      }
    }

    // Auto-expand newest date
    if (_wordsByDate.isNotEmpty) {
      _expandedDates.add(_wordsByDate.keys.first);
    }
  }

  void _initCalendarMonth() {
    DateTime initialMonth = DateTime.now();
    if (_wordsByDate.isNotEmpty) {
      final newestDateStr = _wordsByDate.keys.first;
      final parts = newestDateStr.split('-');
      if (parts.length == 3) {
        final y = int.tryParse(parts[0]);
        final m = int.tryParse(parts[1]);
        if (y != null && m != null) {
          initialMonth = DateTime(y, m, 1);
        }
      }
    }
    _calendarMonth = DateTime(initialMonth.year, initialMonth.month, 1);
  }

  @override
  void didUpdateWidget(covariant CommuteTapeSelectorSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.allWords != widget.allWords) {
      setState(() {
        _wordsByDate = CommutePlaylistService.groupWordsByDate(widget.allWords);
      });
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  void _goToPreviousMonth() {
    setState(() {
      _calendarMonth = DateTime(_calendarMonth.year, _calendarMonth.month - 1, 1);
    });
  }

  void _goToNextMonth() {
    setState(() {
      _calendarMonth = DateTime(_calendarMonth.year, _calendarMonth.month + 1, 1);
    });
  }

  void _selectToday() {
    final today = DateTime.now();
    final todayKey = _dateKey(today);
    setState(() {
      _calendarMonth = DateTime(today.year, today.month, 1);
      _selectedWordIds.clear();
      if (_wordsByDate.containsKey(todayKey)) {
        for (final w in _wordsByDate[todayKey]!) {
          _selectedWordIds.add(w.id);
        }
        _expandedDates.add(todayKey);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Hôm nay chưa có từ vựng nào!')),
        );
      }
    });
  }

  static String _dateKey(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';

  void _selectPreset({bool all = false}) {
    setState(() {
      _selectedWordIds.clear();
      if (all) {
        for (final w in widget.allWords) {
          _selectedWordIds.add(w.id);
        }
      }
    });
  }

  void _toggleDate(String date) {
    final wordsOnDate = _wordsByDate[date] ?? [];
    final allSelected = wordsOnDate.every((w) => _selectedWordIds.contains(w.id));

    setState(() {
      if (allSelected) {
        for (final w in wordsOnDate) {
          _selectedWordIds.remove(w.id);
        }
      } else {
        for (final w in wordsOnDate) {
          _selectedWordIds.add(w.id);
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

    if (selectedWords.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Vui lòng chọn ít nhất 1 từ để phát!')),
      );
      return;
    }

    String title = customTitle ?? '';
    if (title.isEmpty) {
      final selectedDates = _wordsByDate.keys.where(
        (d) => (_wordsByDate[d] ?? []).any((w) => _selectedWordIds.contains(w.id)),
      );
      if (selectedDates.length == 1) {
        title = 'NGÀY ${selectedDates.first}';
      } else {
        title = '${selectedDates.length} NGÀY (${selectedWords.length} TỪ)';
      }
    }

    widget.commuteService.startPlayback(
      selectedWords,
      playlistTitle: title,
    );
    Navigator.of(context).pop();
  }

  Future<void> _saveAsCustomPlaylist() async {
    if (_selectedWordIds.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Chưa chọn từ nào để lưu!')),
      );
      return;
    }

    final nameController = TextEditingController(
      text: 'Băng Cassette ${_selectedWordIds.length} từ',
    );

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) {
        final palette = dialogCtx.palette;
        return AlertDialog(
          backgroundColor: palette.surface,
          shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
          title: Text(
            'LƯU THÀNH PLAYLIST TỰ TẠO',
            style: TextStyle(
              fontFamily: 'Handjet',
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: palette.ink,
            ),
          ),
          content: TextField(
            controller: nameController,
            autofocus: true,
            decoration: InputDecoration(
              labelText: 'Tên danh sách',
              labelStyle: TextStyle(fontFamily: 'Handjet', color: palette.inkFaint),
              filled: true,
              fillColor: palette.paper,
              border: OutlineInputBorder(
                borderSide: BorderSide(
                  color: palette.border,
                  width: PixelMetrics.border,
                ),
              ),
            ),
            style: TextStyle(
              fontFamily: 'Handjet',
              fontSize: 18,
              color: palette.ink,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogCtx).pop(false),
              child: Text(
                'HỦY',
                style: TextStyle(fontFamily: 'Handjet', color: palette.inkFaint),
              ),
            ),
            PixelButton(
              label: 'LƯU 💾',
              onPressed: () => Navigator.of(dialogCtx).pop(true),
            ),
          ],
        );
      },
    );

    if (confirmed == true && mounted) {
      final name = nameController.text.trim();
      final playlistService = context.read<CommutePlaylistService>();
      await playlistService.createPlaylist(
        name.isEmpty ? 'Băng tự chọn' : name,
        _selectedWordIds.toList(),
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Đã lưu playlist "$name"!')),
        );
        _tabController.animateTo(1);
      }
    }
  }

  void _openCreateOrEditPlaylist({CommutePlaylist? existing}) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _PlaylistEditorSheet(
        allWords: widget.allWords,
        existing: existing,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_wordsByDate.isEmpty && widget.allWords.isNotEmpty) {
      _wordsByDate = CommutePlaylistService.groupWordsByDate(widget.allWords);
      _initCalendarMonth();
    }
    final palette = context.palette;

    return Material(
      color: Colors.transparent,
      child: Container(
        height: MediaQuery.of(context).size.height * 0.88,
        decoration: BoxDecoration(
          color: palette.surface,
          border: Border(
            top: BorderSide(color: palette.border, width: PixelMetrics.border * 2),
          ),
          boxShadow: [
            BoxShadow(
              color: palette.border.withValues(alpha: 0.5),
              offset: const Offset(0, -4),
              blurRadius: 0,
            ),
          ],
        ),
        child: SafeArea(
          child: Column(
          children: [
            // Top Bar of Sheet
            _buildTopBar(palette),

            // Tab Bar
            Container(
              color: palette.paper,
              child: TabBar(
                controller: _tabController,
                indicatorColor: palette.accent,
                indicatorWeight: 3,
                labelColor: palette.ink,
                unselectedLabelColor: palette.inkFaint,
                labelStyle: const TextStyle(
                  fontFamily: 'Handjet',
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
                tabs: const [
                  Tab(text: '📅 THEO NGÀY (MULTI-DAY)'),
                  Tab(text: '📼 DANH SÁCH TỰ TẠO'),
                ],
              ),
            ),

            // Tab Views
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  _buildByDateTab(palette),
                  _buildCustomPlaylistsTab(palette),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
    );
  }

  Widget _buildTopBar(PixelPalette palette) {
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
              PixelIcon(PixelGlyph.headphones, color: palette.accent, scale: 1.8),
              const SizedBox(width: PixelMetrics.space2),
              Text(
                'COMMUTE TAPE SELECTOR ⏏️',
                style: TextStyle(
                  fontFamily: 'Handjet',
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: palette.ink,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
          IconButton(
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  Widget _buildByDateTab(PixelPalette palette) {
    if (_wordsByDate.isEmpty) {
      return Center(
        child: Text(
          'CHƯA CÓ TỪ VỰNG NÀO ĐỂ PHÁT',
          style: TextStyle(
            fontFamily: 'Handjet',
            fontSize: 16,
            color: palette.inkFaint,
          ),
        ),
      );
    }

    final monthPrefix =
        '${_calendarMonth.year.toString().padLeft(4, '0')}-${_calendarMonth.month.toString().padLeft(2, '0')}';

    // Show dates from the currently viewed calendar month,
    // plus any other dates that have active selected words
    final datesToShow = _wordsByDate.keys.where((date) {
      final inCurrentMonth = date.startsWith(monthPrefix);
      final hasSelectedWords =
          _wordsByDate[date]!.any((w) => _selectedWordIds.contains(w.id));
      return inCurrentMonth || hasSelectedWords;
    }).toList();

    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(
              horizontal: PixelMetrics.space3,
              vertical: PixelMetrics.space2,
            ),
            children: [
              // Retro Pixel Calendar
              _buildCalendar(palette),
              const SizedBox(height: PixelMetrics.space3),

              // Section Header
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'DANH SÁCH TỪ VỰNG (${datesToShow.length} NGÀY)',
                    style: TextStyle(
                      fontFamily: 'Handjet',
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      color: palette.ink,
                    ),
                  ),
                  Text(
                    'ĐÃ CHỌN: ${_selectedWordIds.length} TỪ',
                    style: TextStyle(
                      fontFamily: 'Handjet',
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: _selectedWordIds.isNotEmpty
                          ? palette.accent
                          : palette.inkFaint,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: PixelMetrics.space2),

              // Date Group Cards
              if (datesToShow.isEmpty)
                Container(
                  padding: const EdgeInsets.all(PixelMetrics.space4),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: palette.paper,
                    border: Border.all(color: palette.border, width: 1),
                  ),
                  child: Text(
                    'THÁNG NÀY CHƯA CÓ TỪ NÀO\nCHẠM VÀO MŨI TÊN ĐỔI THÁNG HOẶC BẤM "TẤT CẢ TỪ"',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontFamily: 'Handjet',
                      fontSize: 14,
                      color: palette.inkFaint,
                    ),
                  ),
                )
              else
                for (final date in datesToShow)
                  _buildDateGroupTile(date, _wordsByDate[date]!, palette),
            ],
          ),
        ),

        // Bottom Action Bar
        _buildBottomActionBar(palette),
      ],
    );
  }

  Widget _buildCalendar(PixelPalette palette) {
    final firstDayOfMonth =
        DateTime(_calendarMonth.year, _calendarMonth.month, 1);
    final daysInMonth =
        DateTime(_calendarMonth.year, _calendarMonth.month + 1, 0).day;
    // Monday = 1, Sunday = 7
    final leadingBlanks = firstDayOfMonth.weekday - 1;
    final totalCells = leadingBlanks + daysInMonth;
    final rowCount = (totalCells / 7).ceil();

    final dayNames = ['T2', 'T3', 'T4', 'T5', 'T6', 'T7', 'CN'];

    return Container(
      padding: const EdgeInsets.all(PixelMetrics.space2),
      decoration: BoxDecoration(
        color: palette.surface,
        border: Border.all(color: palette.border, width: PixelMetrics.border),
        boxShadow: [
          BoxShadow(
            color: palette.border.withValues(alpha: 0.15),
            offset: const Offset(2, 2),
            blurRadius: 0,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Month navigation & action pills
          Row(
            children: [
              _buildMonthNavButton(
                Icons.chevron_left,
                _goToPreviousMonth,
                palette,
              ),
              const SizedBox(width: 4),
              Text(
                'THÁNG ${_calendarMonth.month} / ${_calendarMonth.year}',
                style: TextStyle(
                  fontFamily: 'Handjet',
                  fontSize: 17,
                  fontWeight: FontWeight.bold,
                  color: palette.ink,
                ),
              ),
              const SizedBox(width: 4),
              _buildMonthNavButton(
                Icons.chevron_right,
                _goToNextMonth,
                palette,
              ),
              const Spacer(),
              _buildFilterPill('HÔM NAY', _selectToday, palette),
              const SizedBox(width: 4),
              _buildFilterPill('TẤT CẢ TỪ', () => _selectPreset(all: true), palette),
              const SizedBox(width: 4),
              _buildFilterPill(
                'BỎ CHỌN',
                () => setState(() => _selectedWordIds.clear()),
                palette,
              ),
            ],
          ),
          const SizedBox(height: PixelMetrics.space2),

          // Weekday header
          Row(
            children: [
              for (final dayName in dayNames)
                Expanded(
                  child: Center(
                    child: Text(
                      dayName,
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

          // Days Grid
          for (var r = 0; r < rowCount; r++) ...[
            Row(
              children: [
                for (var c = 0; c < 7; c++) ...[
                  Expanded(
                    child: _buildCalendarDayCell(
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

  Widget _buildCalendarDayCell(
    int cellIndex,
    int leadingBlanks,
    int daysInMonth,
    PixelPalette palette,
  ) {
    final day = cellIndex - leadingBlanks + 1;
    if (day < 1 || day > daysInMonth) {
      return const SizedBox(height: 38);
    }

    final cellDate = DateTime(_calendarMonth.year, _calendarMonth.month, day);
    final dateKey = _dateKey(cellDate);
    final words = _wordsByDate[dateKey] ?? [];
    final hasWords = words.isNotEmpty;

    // Days without words are grayed down
    if (!hasWords) {
      return Container(
        height: 38,
        margin: const EdgeInsets.symmetric(horizontal: 1.5),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: palette.paper.withValues(alpha: 0.25),
          border: Border.all(
            color: palette.border.withValues(alpha: 0.12),
            width: 1,
          ),
        ),
        child: Text(
          '$day',
          style: TextStyle(
            fontFamily: 'Handjet',
            fontSize: 14,
            color: palette.inkFaint.withValues(alpha: 0.3),
          ),
        ),
      );
    }

    // Days with words: interactive & selectable
    final selectedCount =
        words.where((w) => _selectedWordIds.contains(w.id)).length;
    final isFull = selectedCount == words.length;
    final isPartial = selectedCount > 0 && selectedCount < words.length;

    Color bgColor;
    Color borderColor;
    Color textColor;
    Color badgeColor;
    String badgeText;

    if (isFull) {
      bgColor = palette.accent;
      borderColor = palette.border;
      textColor = palette.onAccent;
      badgeColor = palette.onAccent;
      badgeText = '${words.length}';
    } else if (isPartial) {
      bgColor = palette.accent.withValues(alpha: 0.25);
      borderColor = palette.accent;
      textColor = palette.ink;
      badgeColor = palette.accent;
      badgeText = '$selectedCount/${words.length}';
    } else {
      bgColor = palette.paper;
      borderColor = palette.border;
      textColor = palette.ink;
      badgeColor = palette.accent;
      badgeText = '${words.length}';
    }

    return InkWell(
      onTap: () {
        _toggleDate(dateKey);
        setState(() {
          if (!_expandedDates.contains(dateKey)) {
            _expandedDates.add(dateKey);
          }
        });
      },
      child: Container(
        height: 38,
        margin: const EdgeInsets.symmetric(horizontal: 1.5),
        decoration: BoxDecoration(
          color: bgColor,
          border: Border.all(
            color: borderColor,
            width: isFull || isPartial ? PixelMetrics.border : 1.5,
          ),
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
            const SizedBox(height: 1),
            Text(
              badgeText,
              style: TextStyle(
                fontFamily: 'Handjet',
                fontSize: 10,
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

  Widget _buildMonthNavButton(
    IconData icon,
    VoidCallback onPressed,
    PixelPalette palette,
  ) {
    return InkWell(
      onTap: onPressed,
      child: Container(
        width: 26,
        height: 26,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: palette.paper,
          border: Border.all(color: palette.border, width: 1.5),
        ),
        child: Icon(icon, size: 16, color: palette.ink),
      ),
    );
  }

  Widget _buildFilterPill(String label, VoidCallback onTap, PixelPalette palette) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
        decoration: BoxDecoration(
          color: palette.paper,
          border: Border.all(color: palette.border, width: 1),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontFamily: 'Handjet',
            fontSize: 12,
            fontWeight: FontWeight.bold,
            color: palette.ink,
          ),
        ),
      ),
    );
  }

  Widget _buildDateGroupTile(
    String date,
    List<VocabularyWord> words,
    PixelPalette palette,
  ) {
    final selectedCount = words.where((w) => _selectedWordIds.contains(w.id)).length;
    final isAllSelected = selectedCount == words.length;
    final isPartiallySelected = selectedCount > 0 && selectedCount < words.length;
    final isExpanded = _expandedDates.contains(date);

    return Container(
      margin: const EdgeInsets.only(bottom: PixelMetrics.space2),
      decoration: BoxDecoration(
        color: palette.paper,
        border: Border.all(color: palette.border, width: PixelMetrics.border),
      ),
      child: Column(
        children: [
          // Day Header
          InkWell(
            onTap: () {
              setState(() {
                if (isExpanded) {
                  _expandedDates.remove(date);
                } else {
                  _expandedDates.add(date);
                }
              });
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: Row(
                children: [
                  // Select all words on this date checkbox
                  GestureDetector(
                    onTap: () => _toggleDate(date),
                    child: Container(
                      width: 24,
                      height: 24,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: isAllSelected
                            ? palette.accent
                            : (isPartiallySelected
                                ? palette.accent.withValues(alpha: 0.3)
                                : palette.surface),
                        border: Border.all(
                          color: palette.border,
                          width: PixelMetrics.border,
                        ),
                      ),
                      child: isAllSelected
                          ? Text(
                              '✓',
                              style: TextStyle(
                                color: palette.onAccent,
                                fontWeight: FontWeight.bold,
                              ),
                            )
                          : (isPartiallySelected
                              ? Text(
                                  '-',
                                  style: TextStyle(
                                    color: palette.ink,
                                    fontWeight: FontWeight.bold,
                                  ),
                                )
                              : null),
                    ),
                  ),
                  const SizedBox(width: PixelMetrics.space2),
                  Expanded(
                    child: Text(
                      'NGÀY $date',
                      style: TextStyle(
                        fontFamily: 'Handjet',
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: palette.ink,
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    color: palette.surface,
                    child: Text(
                      '$selectedCount / ${words.length} TỪ',
                      style: TextStyle(
                        fontFamily: 'Handjet',
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: selectedCount > 0 ? palette.accent : palette.inkFaint,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    isExpanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                    color: palette.inkMuted,
                  ),
                ],
              ),
            ),
          ),

          // Expanded individual words list
          if (isExpanded) ...[
            Divider(height: 1, color: palette.border),
            for (final word in words) ...[
              _buildWordRow(word, palette),
            ],
          ],
        ],
      ),
    );
  }

  Widget _buildWordRow(VocabularyWord word, PixelPalette palette) {
    final isSelected = _selectedWordIds.contains(word.id);

    return InkWell(
      onTap: () => _toggleWord(word.id),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        color: isSelected ? palette.accent.withValues(alpha: 0.08) : Colors.transparent,
        child: Row(
          children: [
            Container(
              width: 18,
              height: 18,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: isSelected ? palette.accent : palette.surface,
                border: Border.all(color: palette.border, width: 1),
              ),
              child: isSelected
                  ? Text(
                      '✓',
                      style: TextStyle(
                        fontSize: 12,
                        color: palette.onAccent,
                        fontWeight: FontWeight.bold,
                      ),
                    )
                  : null,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    word.word,
                    style: TextStyle(
                      fontFamily: 'Handjet',
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: isSelected ? palette.accent : palette.ink,
                    ),
                  ),
                  Text(
                    word.meaning,
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
            if (word.pronunciation != null)
              Text(
                '/${word.pronunciation}/',
                style: TextStyle(
                  fontSize: 11,
                  color: palette.inkFaint,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomActionBar(PixelPalette palette) {
    return Container(
      padding: const EdgeInsets.all(PixelMetrics.space3),
      decoration: BoxDecoration(
        color: palette.surface,
        border: Border(
          top: BorderSide(color: palette.border, width: PixelMetrics.border),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'ĐÃ CHỌN: ${_selectedWordIds.length} TỪ',
                  style: TextStyle(
                    fontFamily: 'Handjet',
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: palette.accent,
                  ),
                ),
                GestureDetector(
                  onTap: _saveAsCustomPlaylist,
                  child: Text(
                    '💾 Lưu thành playlist tự tạo',
                    style: TextStyle(
                      fontFamily: 'Handjet',
                      fontSize: 13,
                      color: palette.inkMuted,
                      decoration: TextDecoration.underline,
                    ),
                  ),
                ),
              ],
            ),
          ),
          PixelButton(
            label: '▶ PHÁT NGAY',
            onPressed: _selectedWordIds.isNotEmpty ? _playSelection : null,
          ),
        ],
      ),
    );
  }

  Widget _buildCustomPlaylistsTab(PixelPalette palette) {
    final playlistService = context.watch<CommutePlaylistService>();
    final playlists = playlistService.playlists;

    return Column(
      children: [
        // Create Playlist Banner
        Padding(
          padding: const EdgeInsets.all(PixelMetrics.space3),
          child: GestureDetector(
            onTap: () => _openCreateOrEditPlaylist(),
            child: Container(
              padding: const EdgeInsets.all(PixelMetrics.space3),
              decoration: BoxDecoration(
                color: palette.paper,
                border: Border.all(color: palette.border, width: PixelMetrics.border),
                boxShadow: [
                  BoxShadow(
                    color: palette.border.withValues(alpha: 0.3),
                    offset: const Offset(2, 2),
                    blurRadius: 0,
                  ),
                ],
              ),
              child: Row(
                children: [
                  PixelIcon(PixelGlyph.plus, color: palette.accent, scale: 2),
                  const SizedBox(width: PixelMetrics.space2),
                  Expanded(
                    child: Text(
                      'TẠO BĂNG CASSETTE MỚI (PLAYLIST TỰ CHỌN)',
                      style: TextStyle(
                        fontFamily: 'Handjet',
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        color: palette.ink,
                      ),
                    ),
                  ),
                  PixelButton(
                    label: 'TẠO +',
                    onPressed: () => _openCreateOrEditPlaylist(),
                  ),
                ],
              ),
            ),
          ),
        ),

        // Playlists List
        Expanded(
          child: playlists.isEmpty
              ? Center(
                  child: Text(
                    'CHƯA CÓ DANH SÁCH TỰ TẠO NÀO\nBẤM "+ TẠO" HOẶC LƯU TỪ TAB THEO NGÀY',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontFamily: 'Handjet',
                      fontSize: 15,
                      color: palette.inkFaint,
                    ),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: PixelMetrics.space3),
                  itemCount: playlists.length,
                  itemBuilder: (context, index) {
                    final playlist = playlists[index];
                    return _buildPlaylistCard(playlist, playlistService, palette);
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildPlaylistCard(
    CommutePlaylist playlist,
    CommutePlaylistService playlistService,
    PixelPalette palette,
  ) {
    // Resolve matching words
    final matchingWords = widget.allWords
        .where((w) => playlist.wordIds.contains(w.id))
        .toList();

    return Container(
      margin: const EdgeInsets.only(bottom: PixelMetrics.space3),
      padding: const EdgeInsets.all(PixelMetrics.space3),
      decoration: BoxDecoration(
        color: palette.paper,
        border: Border.all(color: palette.border, width: PixelMetrics.border),
        boxShadow: [
          BoxShadow(
            color: palette.border.withValues(alpha: 0.4),
            offset: const Offset(3, 3),
            blurRadius: 0,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              PixelIcon(PixelGlyph.headphones, color: palette.accent, scale: 2),
              const SizedBox(width: PixelMetrics.space2),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      playlist.name.toUpperCase(),
                      style: TextStyle(
                        fontFamily: 'Handjet',
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: palette.ink,
                      ),
                    ),
                    Text(
                      '${matchingWords.length} TỪ • TẠO NGÀY ${playlist.createdAt.toString().split(' ').first}',
                      style: TextStyle(
                        fontFamily: 'Handjet',
                        fontSize: 12,
                        color: palette.inkFaint,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.edit_outlined, size: 18),
                onPressed: () => _openCreateOrEditPlaylist(existing: playlist),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline, size: 18),
                onPressed: () async {
                  await playlistService.deletePlaylist(playlist.id);
                  if (mounted) setState(() {});
                },
              ),
            ],
          ),
          const SizedBox(height: PixelMetrics.space2),
          Text(
            matchingWords.map((w) => w.word).take(6).join(', ') +
                (matchingWords.length > 6 ? '...' : ''),
            style: TextStyle(
              fontFamily: 'Handjet',
              fontSize: 13,
              color: palette.inkMuted,
            ),
          ),
          const SizedBox(height: PixelMetrics.space2),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              PixelButton(
                label: '▶ PHÁT BĂNG NÀY (${matchingWords.length} TỪ)',
                onPressed: matchingWords.isNotEmpty
                    ? () {
                        widget.commuteService.startPlayback(
                          matchingWords,
                          playlistTitle: playlist.name.toUpperCase(),
                        );
                        Navigator.of(context).pop();
                      }
                    : null,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PlaylistEditorSheet extends StatefulWidget {
  const _PlaylistEditorSheet({
    required this.allWords,
    this.existing,
  });

  final List<VocabularyWord> allWords;
  final CommutePlaylist? existing;

  @override
  State<_PlaylistEditorSheet> createState() => _PlaylistEditorSheetState();
}

class _PlaylistEditorSheetState extends State<_PlaylistEditorSheet> {
  late final TextEditingController _nameController;
  final Set<String> _selectedIds = {};
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(
      text: widget.existing?.name ?? 'Băng Cassette mới',
    );
    if (widget.existing != null) {
      _selectedIds.addAll(widget.existing!.wordIds);
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;

    final service = context.read<CommutePlaylistService>();
    if (widget.existing != null) {
      await service.updatePlaylist(
        widget.existing!.copyWith(
          name: name,
          wordIds: _selectedIds.toList(),
        ),
      );
    } else {
      await service.createPlaylist(name, _selectedIds.toList());
    }

    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final filteredWords = widget.allWords.where((w) {
      if (_searchQuery.isEmpty) return true;
      final q = _searchQuery.toLowerCase();
      return w.word.toLowerCase().contains(q) ||
          w.meaning.toLowerCase().contains(q);
    }).toList();

    return Material(
      color: Colors.transparent,
      child: Container(
        height: MediaQuery.of(context).size.height * 0.85,
        padding: const EdgeInsets.all(PixelMetrics.space4),
        decoration: BoxDecoration(
          color: palette.surface,
          border: Border(
            top: BorderSide(color: palette.border, width: PixelMetrics.border * 2),
          ),
        ),
        child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                widget.existing != null ? 'CHỈNH SỬA PLAYLIST' : 'TẠO PLAYLIST MỚI',
                style: TextStyle(
                  fontFamily: 'Handjet',
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: palette.ink,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
          const SizedBox(height: PixelMetrics.space2),
          TextField(
            controller: _nameController,
            decoration: InputDecoration(
              labelText: 'Tên danh sách',
              filled: true,
              fillColor: palette.paper,
              border: OutlineInputBorder(
                borderSide: BorderSide(
                  color: palette.border,
                  width: PixelMetrics.border,
                ),
              ),
            ),
            style: TextStyle(
              fontFamily: 'Handjet',
              fontSize: 18,
              color: palette.ink,
            ),
          ),
          const SizedBox(height: PixelMetrics.space2),
          TextField(
            onChanged: (v) => setState(() => _searchQuery = v),
            decoration: InputDecoration(
              hintText: 'Tìm kiếm từ vựng...',
              prefixIcon: const Icon(Icons.search),
              filled: true,
              fillColor: palette.paper,
              isDense: true,
              border: OutlineInputBorder(
                borderSide: BorderSide(color: palette.border, width: 1),
              ),
            ),
            style: const TextStyle(fontFamily: 'Handjet', fontSize: 16),
          ),
          const SizedBox(height: PixelMetrics.space2),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'CHỌN TỪ (${_selectedIds.length} ĐÃ CHỌN)',
                style: TextStyle(
                  fontFamily: 'Handjet',
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: palette.inkFaint,
                ),
              ),
              GestureDetector(
                onTap: () {
                  setState(() {
                    if (_selectedIds.length == widget.allWords.length) {
                      _selectedIds.clear();
                    } else {
                      _selectedIds.addAll(widget.allWords.map((w) => w.id));
                    }
                  });
                },
                child: Text(
                  _selectedIds.length == widget.allWords.length
                      ? 'BỎ CHỌN TẤT CẢ'
                      : 'CHỌN TẤT CẢ',
                  style: TextStyle(
                    fontFamily: 'Handjet',
                    fontSize: 12,
                    color: palette.accent,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: PixelMetrics.space2),
          Expanded(
            child: ListView.builder(
              itemCount: filteredWords.length,
              itemBuilder: (context, i) {
                final w = filteredWords[i];
                final isSelected = _selectedIds.contains(w.id);
                return Material(
                  color: Colors.transparent,
                  child: CheckboxListTile(
                    dense: true,
                    value: isSelected,
                    activeColor: palette.accent,
                    title: Text(
                      w.word,
                      style: TextStyle(
                        fontFamily: 'Handjet',
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: isSelected ? palette.accent : palette.ink,
                      ),
                    ),
                    subtitle: Text(
                      w.meaning,
                      style: TextStyle(
                        fontFamily: 'Handjet',
                        fontSize: 12,
                        color: palette.inkMuted,
                      ),
                    ),
                    onChanged: (val) {
                      setState(() {
                        if (val == true) {
                          _selectedIds.add(w.id);
                        } else {
                          _selectedIds.remove(w.id);
                        }
                      });
                    },
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: PixelMetrics.space2),
          PixelButton(
            label: 'LƯU DANH SÁCH 💾',
            onPressed: _selectedIds.isNotEmpty ? _save : null,
          ),
        ],
      ),
    ),
    );
  }
}
