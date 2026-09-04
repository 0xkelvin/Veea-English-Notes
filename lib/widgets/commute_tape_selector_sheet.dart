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

  late Map<String, List<VocabularyWord>> _wordsByDate;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _wordsByDate = CommutePlaylistService.groupWordsByDate(widget.allWords);

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

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  void _selectPreset({int? lastNDays, bool all = false}) {
    setState(() {
      _selectedWordIds.clear();
      final dates = _wordsByDate.keys.toList();

      if (all) {
        for (final w in widget.allWords) {
          _selectedWordIds.add(w.id);
        }
      } else if (lastNDays != null) {
        final targetDates = dates.take(lastNDays);
        for (final d in targetDates) {
          for (final w in _wordsByDate[d]!) {
            _selectedWordIds.add(w.id);
          }
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
    final palette = context.palette;

    return Container(
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
    return Column(
      children: [
        // Quick Selection Preset Pills
        Container(
          padding: const EdgeInsets.symmetric(
            horizontal: PixelMetrics.space3,
            vertical: PixelMetrics.space2,
          ),
          decoration: BoxDecoration(
            color: palette.surface,
            border: Border(
              bottom: BorderSide(color: palette.border, width: 1),
            ),
          ),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _buildFilterPill('HÔM NAY', () => _selectPreset(lastNDays: 1), palette),
                const SizedBox(width: 6),
                _buildFilterPill('3 NGÀY GẦN ĐÂY', () => _selectPreset(lastNDays: 3), palette),
                const SizedBox(width: 6),
                _buildFilterPill('7 NGÀY', () => _selectPreset(lastNDays: 7), palette),
                const SizedBox(width: 6),
                _buildFilterPill('TẤT CẢ TỪ', () => _selectPreset(all: true), palette),
                const SizedBox(width: 6),
                _buildFilterPill('BỎ CHỌN', () => setState(() => _selectedWordIds.clear()), palette),
              ],
            ),
          ),
        ),

        // Date groups & words list
        Expanded(
          child: _wordsByDate.isEmpty
              ? Center(
                  child: Text(
                    'CHƯA CÓ TỪ VỰNG NÀO ĐỂ PHÁT',
                    style: TextStyle(
                      fontFamily: 'Handjet',
                      fontSize: 16,
                      color: palette.inkFaint,
                    ),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(PixelMetrics.space3),
                  itemCount: _wordsByDate.length,
                  itemBuilder: (context, index) {
                    final date = _wordsByDate.keys.elementAt(index);
                    final words = _wordsByDate[date]!;
                    return _buildDateGroupTile(date, words, palette);
                  },
                ),
        ),

        // Bottom Action Bar
        _buildBottomActionBar(palette),
      ],
    );
  }

  Widget _buildFilterPill(String label, VoidCallback onTap, PixelPalette palette) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
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

    return Container(
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
                return CheckboxListTile(
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
    );
  }
}
