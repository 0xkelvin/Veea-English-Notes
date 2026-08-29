import 'dart:ui';

/// A single word token detected by the OCR camera.
class DetectedWord {
  const DetectedWord({
    required this.word,
    required this.normalized,
    required this.sentence,
    required this.rect,
    required this.lineNumber,
  });

  /// The raw word token (e.g., 'resilient,').
  final String word;

  /// The clean normalized word (e.g., 'resilient').
  final String normalized;

  /// The surrounding sentence extracted from the text block.
  final String sentence;

  /// Normalized bounding box coordinates (0.0 - 1.0).
  final Rect rect;

  final int lineNumber;
}

/// The result of an OCR scan operation.
class OcrScanResult {
  const OcrScanResult({
    required this.rawText,
    required this.words,
    this.sourceTitle,
  });

  final String rawText;
  final List<DetectedWord> words;
  final String? sourceTitle;
}

/// 100% Offline OCR & Text Extraction Engine.
class OcrService {
  /// Parses raw text into tokenized words, bounding boxes, and surrounding sentences.
  static OcrScanResult processText(String text, {String? sourceTitle}) {
    final cleanText = text.trim();
    if (cleanText.isEmpty) {
      return OcrScanResult(
        rawText: '',
        words: [],
        sourceTitle: sourceTitle,
      );
    }

    final lines = cleanText.split('\n').where((l) => l.trim().isNotEmpty).toList();
    final List<DetectedWord> detectedWords = [];

    final sentences = _splitSentences(cleanText);

    for (var lineIdx = 0; lineIdx < lines.length; lineIdx++) {
      final line = lines[lineIdx].trim();
      final tokens = line.split(RegExp(r'\s+'));
      final lineY = lineIdx / (lines.length.clamp(1, 999));
      final lineHeight = 1.0 / (lines.length.clamp(1, 999));

      double currentX = 0.05;
      final totalChars = line.length.clamp(1, 999);

      for (var token in tokens) {
        if (token.trim().isEmpty) continue;
        final normalized = token
            .replaceAll(RegExp(r'''[^\w\s'-]'''), '')
            .trim()
            .toLowerCase();

        final tokenWidth = (token.length / totalChars).clamp(0.05, 0.4);
        final rect = Rect.fromLTWH(
          currentX.clamp(0.0, 0.95),
          lineY,
          tokenWidth,
          lineHeight,
        );
        currentX += tokenWidth + 0.02;

        final sentence = _findSentenceForWord(sentences, token, line);

        if (normalized.length >= 2) {
          detectedWords.add(
            DetectedWord(
              word: token,
              normalized: normalized,
              sentence: sentence,
              rect: rect,
              lineNumber: lineIdx,
            ),
          );
        }
      }
    }

    return OcrScanResult(
      rawText: cleanText,
      words: detectedWords,
      sourceTitle: sourceTitle,
    );
  }

  static List<String> _splitSentences(String text) {
    return text
        .split(RegExp(r'(?<=[.!?])\s+'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
  }

  static String _findSentenceForWord(
    List<String> sentences,
    String word,
    String fallbackLine,
  ) {
    final cleanWord = word.replaceAll(RegExp(r'[^\w]'), '').toLowerCase();
    for (final s in sentences) {
      if (s.toLowerCase().contains(cleanWord)) {
        return s;
      }
    }
    return fallbackLine;
  }

  /// Built-in curated sample OCR scans for instant hands-on practice.
  static final List<OcrScanResult> sampleScans = [
    processText(
      'Our team completed the database migration without downtime. '
      'The architecture is remarkably resilient under heavy traffic. '
      'We must maintain a tenacious focus on latency.',
      sourceTitle: 'Pull Request Review #402',
    ),
    processText(
      'The keynote speaker gave an eloquent summary of artificial intelligence. '
      'Through a stroke of serendipity, they solved the alignment problem. '
      'Continuous daily learning remains quintessential for modern engineers.',
      sourceTitle: 'Tech Summit Keynote 2026',
    ),
    processText(
      'Books are uniquely portable magic. '
      'Cultivating an inquisitive mindset expands your horizons. '
      'Meticulous practice transforms unfamiliar vocabulary into second nature.',
      sourceTitle: 'Essay on Deep Reading',
    ),
  ];
}
