import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
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
  bool _isScanning = false;
  String? _errorMessage;
  String? _scannedImagePath;
  final ImagePicker _picker = ImagePicker();

  @override
  void initState() {
    super.initState();
    _currentResult = OcrService.sampleScans[_selectedSampleIndex];
    if (_currentResult.words.isNotEmpty) {
      _selectedWord = _currentResult.words.firstWhere(
        (w) => w.isEnglish,
        orElse: () => _currentResult.words.first,
      );
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
      _errorMessage = null;
      _scannedImagePath = null;
      _selectedSampleIndex = index;
      _currentResult = OcrService.sampleScans[index];
      _selectedWord = _currentResult.words.isNotEmpty
          ? _currentResult.words.firstWhere(
              (w) => w.isEnglish,
              orElse: () => _currentResult.words.first,
            )
          : null;
    });
  }

  void _processCustomText() {
    final text = _customTextController.text.trim();
    if (text.isEmpty) return;
    setState(() {
      _isCustomInput = true;
      _errorMessage = null;
      _scannedImagePath = null;
      _selectedSampleIndex = -1;
      _currentResult = OcrService.processText(text, sourceTitle: 'Pasted Text');
      _selectedWord = _currentResult.words.isNotEmpty
          ? _currentResult.words.firstWhere(
              (w) => w.isEnglish,
              orElse: () => _currentResult.words.first,
            )
          : null;
    });
  }

  Future<void> _captureFromCamera() async {
    try {
      final XFile? photo = await _picker.pickImage(
        source: ImageSource.camera,
        maxWidth: 1920,
        maxHeight: 1920,
        imageQuality: 90,
      );
      if (photo == null) return;
      await _processImageFile(photo.path, sourceTitle: 'Camera Scan');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Could not access camera: $e';
        _isScanning = false;
      });
    }
  }

  Future<void> _pickFromGallery() async {
    try {
      final XFile? image = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1920,
        maxHeight: 1920,
        imageQuality: 90,
      );
      if (image == null) return;
      await _processImageFile(image.path, sourceTitle: 'Photo / Screenshot');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Could not pick image: $e';
        _isScanning = false;
      });
    }
  }

  Future<void> _processImageFile(String path, {required String sourceTitle}) async {
    setState(() {
      _isScanning = true;
      _errorMessage = null;
      _scannedImagePath = path;
      _isCustomInput = true;
      _selectedSampleIndex = -1;
    });

    try {
      final result = await OcrService.scanImageFile(path, sourceTitle: sourceTitle);
      if (!mounted) return;
      setState(() {
        _isScanning = false;
        if (result.words.isEmpty) {
          _errorMessage =
              'No English words detected in image. Please ensure clear focus, good lighting, and avoid heavy glare.';
        } else {
          _currentResult = result;
          _selectedWord = result.words.firstWhere(
            (w) => w.isEnglish,
            orElse: () => result.words.first,
          );
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isScanning = false;
        _errorMessage = 'OCR scanning failed: $e';
      });
    }
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
    if (_selectedWord == null || !_selectedWord!.isEnglish) return;
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
                  PixelIcon(PixelGlyph.camera, color: palette.accent, scale: 2),
                  const SizedBox(width: PixelMetrics.space2),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'PIXEL LENS OCR',
                          style: theme.textTheme.titleMedium,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          'SNAP CAMERA • SNIFF VOCABULARY',
                          style: TextStyle(
                            fontFamily: 'Handjet',
                            fontSize: 10,
                            color: palette.inkMuted,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: PixelMetrics.space2),
                  PixelIconButton(
                    glyph: PixelGlyph.close,
                    semanticLabel: 'Close Lens',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),

            // Camera & Input Action Bar
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: PixelMetrics.space4,
                vertical: PixelMetrics.space2,
              ),
              decoration: BoxDecoration(
                color: palette.surface,
                border: Border(
                  bottom: BorderSide(color: palette.border, width: 1),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: PixelButton(
                      label: 'SNAP CAMERA',
                      glyph: PixelGlyph.camera,
                      filled: true,
                      onPressed: _isScanning ? null : _captureFromCamera,
                    ),
                  ),
                  const SizedBox(width: PixelMetrics.space2),
                  Expanded(
                    child: PixelButton(
                      label: 'PHOTO ALBUM',
                      glyph: PixelGlyph.cards,
                      onPressed: _isScanning ? null : _pickFromGallery,
                    ),
                  ),
                  const SizedBox(width: PixelMetrics.space2),
                  PixelIconButton(
                    glyph: PixelGlyph.pencil,
                    semanticLabel: 'Paste text snippet',
                    onPressed: _isScanning ? null : _showPasteDialog,
                  ),
                ],
              ),
            ),

            // Demo Presets Ribbon
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: PixelMetrics.space4,
                vertical: 4,
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
                    Text(
                      'SAMPLES:',
                      style: TextStyle(
                        fontFamily: 'Handjet',
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: palette.inkMuted,
                      ),
                    ),
                    const SizedBox(width: 6),
                    _sourceTab(0, 'PR REVIEW', palette),
                    const SizedBox(width: 4),
                    _sourceTab(1, 'TECH NEWS', palette),
                    const SizedBox(width: 4),
                    _sourceTab(2, 'ESSAY', palette),
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
                          Expanded(
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: palette.accent,
                                  border: Border.all(color: palette.border, width: 1),
                                ),
                                child: Text(
                                  _isScanning
                                      ? 'SCANNING IN PROGRESS...'
                                      : 'HUD: ${_currentResult.words.length} TOKENS • ${_currentResult.sourceTitle ?? "OCR"}',
                                  style: TextStyle(
                                    fontFamily: 'Handjet',
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                    color: palette.onAccent,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
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

                      const SizedBox(height: PixelMetrics.space2),

                      // If scanning:
                      if (_isScanning)
                        Expanded(
                          child: Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                SizedBox(
                                  width: 32,
                                  height: 32,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 3,
                                    color: palette.accent,
                                  ),
                                ),
                                const SizedBox(height: PixelMetrics.space3),
                                Text(
                                  'ANALYZING PHOTO WITH ON-DEVICE OCR...',
                                  style: TextStyle(
                                    fontFamily: 'Handjet',
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                    color: palette.accent,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'HOLD STEADY • EXTRACTING WORDS & EXAMPLES',
                                  style: TextStyle(
                                    fontFamily: 'Handjet',
                                    fontSize: 12,
                                    color: palette.inkMuted,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        )
                      // If error:
                      else if (_errorMessage != null)
                        Expanded(
                          child: Center(
                            child: Padding(
                              padding: const EdgeInsets.all(PixelMetrics.space3),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  PixelIcon(PixelGlyph.bolt, color: palette.danger, scale: 3),
                                  const SizedBox(height: PixelMetrics.space2),
                                  Text(
                                    'SCAN WARNING',
                                    style: TextStyle(
                                      fontFamily: 'Handjet',
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold,
                                      color: palette.danger,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    _errorMessage!,
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      fontFamily: 'Handjet',
                                      fontSize: 13,
                                      color: palette.ink,
                                    ),
                                  ),
                                  const SizedBox(height: PixelMetrics.space3),
                                  PixelButton(
                                    label: 'Snap Camera Again',
                                    glyph: PixelGlyph.camera,
                                    filled: true,
                                    onPressed: _captureFromCamera,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        )
                      // Otherwise, show content:
                      else ...[
                        // Optional image thumbnail banner if scanned from photo
                        if (_scannedImagePath != null && File(_scannedImagePath!).existsSync())
                          Container(
                            height: 52,
                            margin: const EdgeInsets.only(bottom: PixelMetrics.space2),
                            decoration: BoxDecoration(
                              border: Border.all(color: palette.border, width: 1),
                              color: palette.paper,
                            ),
                            child: Row(
                              children: [
                                Image.file(
                                  File(_scannedImagePath!),
                                  width: 52,
                                  height: 52,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, _, _) => const SizedBox(width: 52),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Text(
                                        _currentResult.sourceTitle ?? 'Camera Scan',
                                        style: TextStyle(
                                          fontFamily: 'Handjet',
                                          fontSize: 12,
                                          fontWeight: FontWeight.bold,
                                          color: palette.ink,
                                        ),
                                      ),
                                      Text(
                                        _currentResult.words.any((w) => !w.isEnglish)
                                            ? '${_currentResult.words.where((w) => w.isEnglish).length} English words (${_currentResult.words.where((w) => !w.isEnglish).length} dimmed)'
                                            : '${_currentResult.words.length} vocabulary words extracted',
                                        style: TextStyle(
                                          fontFamily: 'Handjet',
                                          fontSize: 10,
                                          color: palette.inkMuted,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                PixelIconButton(
                                  glyph: PixelGlyph.camera,
                                  semanticLabel: 'Retake',
                                  onPressed: _captureFromCamera,
                                ),
                                const SizedBox(width: 4),
                              ],
                            ),
                          ),

                        // Interactive Token Cloud
                        Expanded(
                          child: SingleChildScrollView(
                            child: Wrap(
                              spacing: 4,
                              runSpacing: 6,
                              children: _currentResult.words.map((dw) {
                                final isSelected = _selectedWord == dw;
                                final isEnglish = dw.isEnglish;

                                final Color bgColor;
                                final Color borderColor;
                                final Color textColor;
                                final FontWeight fontWeight;

                                if (isSelected) {
                                  if (isEnglish) {
                                    bgColor = palette.accent;
                                    borderColor = palette.border;
                                    textColor = palette.onAccent;
                                    fontWeight = FontWeight.bold;
                                  } else {
                                    bgColor = palette.paper;
                                    borderColor = palette.inkFaint;
                                    textColor = palette.inkMuted;
                                    fontWeight = FontWeight.bold;
                                  }
                                } else {
                                  if (isEnglish) {
                                    bgColor = palette.paper;
                                    borderColor = palette.border.withValues(alpha: 0.4);
                                    textColor = palette.ink;
                                    fontWeight = FontWeight.normal;
                                  } else {
                                    // Gray down if it is not an English word (Vietnamese, special symbols, etc.)
                                    bgColor = palette.surface.withValues(alpha: 0.35);
                                    borderColor = palette.border.withValues(alpha: 0.15);
                                    textColor = palette.inkFaint.withValues(alpha: 0.45);
                                    fontWeight = FontWeight.normal;
                                  }
                                }

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
                                      color: bgColor,
                                      border: Border.all(
                                        color: borderColor,
                                        width: isSelected ? 1.5 : 1.0,
                                      ),
                                    ),
                                    child: Text(
                                      dw.word,
                                      style: TextStyle(
                                        fontFamily: 'Handjet',
                                        fontSize: 13,
                                        fontWeight: fontWeight,
                                        color: textColor,
                                      ),
                                    ),
                                  ),
                                );
                              }).toList(),
                            ),
                          ),
                        ),
                      ],

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
            if (_selectedWord != null && !_isScanning)
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
                        Flexible(
                          child: Text(
                            _selectedWord!.normalized.toUpperCase(),
                            style: TextStyle(
                              fontFamily: 'Handjet',
                              fontSize: 22,
                              fontWeight: FontWeight.bold,
                              color: _selectedWord!.isEnglish
                                  ? palette.accent
                                  : palette.inkMuted,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (!_selectedWord!.isEnglish) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: palette.paper,
                              border: Border.all(
                                color: palette.border.withValues(alpha: 0.3),
                                width: 1,
                              ),
                            ),
                            child: Text(
                              'NOT ENGLISH WORD',
                              style: TextStyle(
                                fontFamily: 'Handjet',
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                color: palette.inkFaint,
                              ),
                            ),
                          ),
                        ],
                        const Spacer(),
                        if (_selectedWord!.isEnglish)
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
                        color: _selectedWord!.isEnglish ? null : palette.inkMuted,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: PixelMetrics.space3),
                    if (_selectedWord!.isEnglish)
                      PixelButton(
                        label: 'Capture "${_selectedWord!.normalized}" to Notebook',
                        glyph: PixelGlyph.plus,
                        filled: true,
                        expand: true,
                        onPressed: _captureSelectedWord,
                      )
                    else
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                          vertical: PixelMetrics.space2,
                          horizontal: PixelMetrics.space3,
                        ),
                        decoration: BoxDecoration(
                          color: palette.paper.withValues(alpha: 0.6),
                          border: Border.all(
                            color: palette.border.withValues(alpha: 0.2),
                            width: 1,
                          ),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Flexible(
                              child: Text(
                                'NON-ENGLISH TOKEN • CAPTURE DISABLED',
                                style: TextStyle(
                                  fontFamily: 'Handjet',
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                  color: palette.inkFaint,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
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
