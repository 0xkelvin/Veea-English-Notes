import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../core/theme/pixel_metrics.dart';
import '../core/theme/pixel_palette.dart';
import '../models/vocabulary_word.dart';
import '../services/ocr_service.dart';
import '../services/pronunciation_service.dart';
import '../widgets/pixel/pixel_box.dart';
import '../widgets/pixel/pixel_button.dart';
import '../widgets/pixel/pixel_icon.dart';
import 'word_editor_screen.dart';

/// 8-Bit Retro "Pixel Lens" Smart OCR Camera & Screenshot Sniffer.
class PixelLensScreen extends StatefulWidget {
  const PixelLensScreen({super.key});

  @override
  State<PixelLensScreen> createState() => _PixelLensScreenState();
}

class _PixelLensScreenState extends State<PixelLensScreen> {
  int _selectedSampleIndex = 0;
  late OcrScanResult _currentResult;
  DetectedWord? _selectedWord;
  final TextEditingController _customTextController = TextEditingController();
  bool _isCustomInput = false;

  @override
  void initState() {
    super.initState();
    _currentResult = OcrService.sampleScans[_selectedSampleIndex];
    if (_currentResult.words.isNotEmpty) {
      _selectedWord = _currentResult.words.first;
    }
  }

  @override
  void dispose() {
    _customTextController.dispose();
    super.dispose();
  }

  void _switchSample(int index) {
    setState(() {
      _isCustomInput = false;
      _selectedSampleIndex = index;
      _currentResult = OcrService.sampleScans[index];
      _selectedWord =
          _currentResult.words.isNotEmpty ? _currentResult.words.first : null;
    });
  }

  void _processCustomText() {
    final text = _customTextController.text.trim();
    if (text.isEmpty) return;
    setState(() {
      _isCustomInput = true;
      _currentResult = OcrService.processText(text, sourceTitle: 'Pasted / OCR Text');
      _selectedWord =
          _currentResult.words.isNotEmpty ? _currentResult.words.first : null;
    });
  }

  void _showPasteDialog() {
    final palette = context.palette;
    showDialog<void>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: palette.paper,
        shape: const RoundedRectangleBorder(),
        title: const Text(
          'PASTE TEXT OR OCR SNIPPET',
          style: TextStyle(fontFamily: 'Handjet', fontWeight: FontWeight.bold),
        ),
        content: TextField(
          controller: _customTextController,
          maxLines: 5,
          style: const TextStyle(fontFamily: 'Handjet', fontSize: 14),
          decoration: InputDecoration(
            hintText: 'Paste any English paragraph, article, or PR comment...',
            filled: true,
            fillColor: palette.surface,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.zero,
              borderSide: BorderSide(color: palette.border),
            ),
          ),
        ),
        actions: [
          PixelButton(
            label: 'Cancel',
            onPressed: () => Navigator.of(dialogCtx).pop(),
          ),
          PixelButton(
            label: 'Scan Words',
            filled: true,
            onPressed: () {
              Navigator.of(dialogCtx).pop();
              _processCustomText();
            },
          ),
        ],
      ),
    );
  }

  void _captureSelectedWord() {
    if (_selectedWord == null) return;
    final word = _selectedWord!;

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => WordEditorScreen(
          existing: VocabularyWord.create(
            id: '',
            word: word.normalized,
            meaning: '',
            date: DateFormat('yyyy-MM-dd').format(DateTime.now()),
            source: _currentResult.sourceTitle ?? 'Pixel Lens OCR',
            examples: [word.sentence],
            now: DateTime.now(),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final theme = Theme.of(context);
    final pronunciation = context.read<PronunciationService>();

    return Scaffold(
      backgroundColor: palette.paper,
      body: SafeArea(
        child: Column(
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
                  PixelIcon(PixelGlyph.scan, color: palette.accent, scale: 2),
                  const SizedBox(width: PixelMetrics.space2),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'PIXEL LENS OCR',
                        style: theme.textTheme.titleMedium,
                      ),
                      Text(
                        'TAP ANY WORD TO SNIFF & CAPTURE',
                        style: TextStyle(
                          fontFamily: 'Handjet',
                          fontSize: 10,
                          color: palette.inkMuted,
                        ),
                      ),
                    ],
                  ),
                  const Spacer(),
                  PixelIconButton(
                    glyph: PixelGlyph.close,
                    semanticLabel: 'Close Lens',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),

            // Source Selector Tabs
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: PixelMetrics.space4,
                vertical: PixelMetrics.space2,
              ),
              decoration: BoxDecoration(
                color: palette.paper,
                border: Border(
                  bottom: BorderSide(color: palette.border, width: 1),
                ),
              ),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    _sourceTab(0, 'PR REVIEW', palette),
                    const SizedBox(width: 4),
                    _sourceTab(1, 'TECH NEWS', palette),
                    const SizedBox(width: 4),
                    _sourceTab(2, 'ESSAY', palette),
                    const SizedBox(width: 4),
                    GestureDetector(
                      onTap: _showPasteDialog,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: _isCustomInput ? palette.accent : palette.surface,
                          border: Border.all(color: palette.border, width: 1),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '+ PASTE OCR',
                              style: TextStyle(
                                fontFamily: 'Handjet',
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: _isCustomInput
                                    ? palette.onAccent
                                    : palette.ink,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // Viewfinder HUD Container
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(PixelMetrics.space4),
                child: PixelBox(
                  raised: true,
                  color: palette.surface,
                  padding: const EdgeInsets.all(PixelMetrics.space3),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // HUD Header
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: palette.accent,
                              border: Border.all(color: palette.border, width: 1),
                            ),
                            child: Text(
                              'SCANNER HUD: ${_currentResult.words.length} TOKENS',
                              style: TextStyle(
                                fontFamily: 'Handjet',
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                color: palette.onAccent,
                              ),
                            ),
                          ),
                          const Spacer(),
                          Text(
                            '┏ ━ ┓',
                            style: TextStyle(
                              fontFamily: 'Handjet',
                              fontSize: 12,
                              color: palette.accent,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),

                      const SizedBox(height: PixelMetrics.space3),

                      // Interactive Token Cloud
                      Expanded(
                        child: SingleChildScrollView(
                          child: Wrap(
                            spacing: 4,
                            runSpacing: 6,
                            children: _currentResult.words.map((dw) {
                              final isSelected = _selectedWord == dw;
                              return GestureDetector(
                                onTap: () {
                                  setState(() {
                                    _selectedWord = dw;
                                  });
                                },
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 5,
                                    vertical: 3,
                                  ),
                                  decoration: BoxDecoration(
                                    color: isSelected
                                        ? palette.accent
                                        : palette.paper,
                                    border: Border.all(
                                      color: isSelected
                                          ? palette.border
                                          : palette.border.withValues(alpha: 0.4),
                                      width: isSelected ? 1.5 : 1.0,
                                    ),
                                  ),
                                  child: Text(
                                    dw.word,
                                    style: TextStyle(
                                      fontFamily: 'Handjet',
                                      fontSize: 13,
                                      fontWeight: isSelected
                                          ? FontWeight.bold
                                          : FontWeight.normal,
                                      color: isSelected
                                          ? palette.onAccent
                                          : palette.ink,
                                    ),
                                  ),
                                ),
                              );
                            }).toList(),
                          ),
                        ),
                      ),

                      // HUD Bottom bracket
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          Text(
                            '┗ ━ ┛',
                            style: TextStyle(
                              fontFamily: 'Handjet',
                              fontSize: 12,
                              color: palette.accent,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),

            // Quick-Capture Inspection Dock
            if (_selectedWord != null)
              Container(
                padding: const EdgeInsets.all(PixelMetrics.space4),
                decoration: BoxDecoration(
                  color: palette.surface,
                  border: Border(
                    top: BorderSide(
                      color: palette.border,
                      width: PixelMetrics.border,
                    ),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          _selectedWord!.normalized.toUpperCase(),
                          style: TextStyle(
                            fontFamily: 'Handjet',
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                            color: palette.accent,
                          ),
                        ),
                        const Spacer(),
                        FutureBuilder<String?>(
                          future: pronunciation.lookup(_selectedWord!.normalized),
                          builder: (context, snapshot) {
                            if (snapshot.hasData && snapshot.data != null) {
                              return Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: palette.paper,
                                  border: Border.all(
                                    color: palette.border,
                                    width: 1,
                                  ),
                                ),
                                child: Text(
                                  snapshot.data!,
                                  style: TextStyle(
                                    fontFamily: 'Handjet',
                                    fontSize: 12,
                                    color: palette.ink,
                                  ),
                                ),
                              );
                            }
                            return const SizedBox.shrink();
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '“${_selectedWord!.sentence}”',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontStyle: FontStyle.italic,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: PixelMetrics.space3),
                    PixelButton(
                      label: 'Capture "${_selectedWord!.normalized}" to Notebook',
                      glyph: PixelGlyph.plus,
                      filled: true,
                      expand: true,
                      onPressed: _captureSelectedWord,
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _sourceTab(int index, String title, PixelPalette palette) {
    final active = !_isCustomInput && _selectedSampleIndex == index;
    return GestureDetector(
      onTap: () => _switchSample(index),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: active ? palette.accent : palette.surface,
          border: Border.all(color: palette.border, width: 1),
        ),
        child: Text(
          title,
          style: TextStyle(
            fontFamily: 'Handjet',
            fontSize: 11,
            fontWeight: FontWeight.bold,
            color: active ? palette.onAccent : palette.ink,
          ),
        ),
      ),
    );
  }
}
