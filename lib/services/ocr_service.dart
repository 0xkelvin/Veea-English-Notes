import 'package:flutter/services.dart';

/// A single word token detected by the OCR camera.
class DetectedWord {
  const DetectedWord({
    required this.word,
    required this.normalized,
    required this.sentence,
    required this.rect,
    required this.lineNumber,
    this.isEnglish = true,
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

  /// Whether this token is a valid English word (vs. Vietnamese, numbers, symbols, noise).
  final bool isEnglish;
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
  static const MethodChannel _channel = MethodChannel('com.veea.english/ocr');

  static final RegExp _vietnameseDiacriticsRegex = RegExp(
    r'[àáảãạăằắẳẵặâầấẩẫậèéẻẽẹêềếểễệìíỉĩịòóỏõọôồốổỗộơờớởỡợùúủũụưừứửữựỳýỷỹỵđ'
    r'ÀÁẢÃẠĂẰẮẲẴẶÂẦẤẨẪẬÈÉẺẼẸÊỀẾỂỄỆÌÍỈĨỊÒÓỎÕỌÔỒỐỔỖỘƠỜỚỞỠỢÙÚỦŨỤƯỪỨỬỮỰỲÝỶỸỴĐ]',
  );

  static final RegExp _specialSymbolsOrDigitsRegex = RegExp(
    r'[@#$%&*+=<>/\\|~^_`0-9]',
  );

  static final RegExp _englishPattern = RegExp(
    r"^[a-zA-Z]+(?:['\-][a-zA-Z]+)*$",
  );

  static final RegExp _vowelRegex = RegExp(r'[aeiouyAEIOUY]');

  static const Set<String> _vietnameseUnaccentedWords = {
    'khong', 'duoc', 'nguoi', 'nhung', 'nhieu', 'chuyen', 'nghiep', 'phuong',
    'huong', 'truong', 'truoc', 'tieng', 'chao', 'biet', 'chua', 'xuat',
    'chieu', 'muon', 'thoi', 'chung', 'buoi', 'buoc', 'vuot', 'nuoc',
    'luon', 'duong', 'luong', 'tuong', 'cuoc', 'luat', 'toan', 'khoan',
    'hoan', 'doan', 'ngoan', 'khoang', 'thoang', 'hoang', 'quyen', 'quyet',
    'tuyen', 'khuyen', 'thuyen', 'duyet', 'tuyet', 'nguyet', 'huyet',
    'khuyet', 'huynh', 'quynh', 'giang', 'rieng', 'sieng', 'mieng',
    'chieng', 'gieng', 'duoi', 'cuoi', 'muoi', 'tuoi', 'chuoi', 'ruoi',
    'suoi', 'xau', 'dau', 'cau', 'mau', 'tau', 'lau', 'trai', 'phai',
    'ngoai', 'thoai', 'khoai', 'doai', 'choi', 'troi', 'khoi', 'nhom',
    'trong', 'vong', 'xong', 'meo', 'deo', 'reo', 'gieo', 'giup', 'nhanh',
    'manh', 'thieu', 'hieu', 'bieu', 'kieu', 'mieu', 'nieu', 'tieu',
    'xieu', 'phong', 'tranh', 'gianh', 'lanh', 'sanh', 'danh', 'ganh',
    'nganh', 'viet', 'tiengviet', 'vietnam', 'thanh', 'chinh', 'thang',
    'ngay', 'tuan', 'giay', 'phut', 'gio', 'buon', 'vui', 'khoc',
    'tiep', 'xuc', 'kiem', 'phat', 'trien', 'pham', 'dich',
    'khach', 'doanh', 'anh', 'xin', 'loi', 'viec', 'hien', 'tai',
    'lai',
  };

  /// Determines whether a token is an English word, or a non-English word
  /// (e.g. Vietnamese words, special symbols, code tokens, numbers).
  static bool isEnglishWord(String rawToken, String normalized) {
    if (normalized.length < 2) return false;

    // Reject tokens containing Vietnamese diacritics in raw or normalized form
    if (_vietnameseDiacriticsRegex.hasMatch(rawToken) ||
        _vietnameseDiacriticsRegex.hasMatch(normalized)) {
      return false;
    }

    // Reject tokens containing code symbols, currency, handles, math, or digits
    if (_specialSymbolsOrDigitsRegex.hasMatch(rawToken) ||
        _specialSymbolsOrDigitsRegex.hasMatch(normalized)) {
      return false;
    }

    // Must match English word morphology: pure ASCII letters with optional internal hyphen/apostrophe
    if (!_englishPattern.hasMatch(normalized)) {
      return false;
    }

    // Must contain at least one English vowel sound (a, e, i, o, u, y)
    if (!_vowelRegex.hasMatch(normalized)) {
      return false;
    }

    // Reject distinct Vietnamese unaccented syllable patterns impossible in English
    final lower = normalized.toLowerCase();
    if (lower.startsWith('ngh') || RegExp(r'^ng[aeiou]').hasMatch(lower)) {
      return false;
    }

    // Reject common unaccented Vietnamese vocabulary words
    if (_vietnameseUnaccentedWords.contains(lower)) {
      return false;
    }

    return true;
  }

  /// Extracts text and tokens from an image file using hardware-accelerated Apple Vision on-device OCR.
  static Future<OcrScanResult> scanImageFile(
    String filePath, {
    String? sourceTitle,
  }) async {
    try {
      final String? recognizedText = await _channel.invokeMethod<String>(
        'recognizeText',
        {'path': filePath},
      );
      return processText(
        recognizedText ?? '',
        sourceTitle: sourceTitle ?? 'Camera OCR Scan',
      );
    } catch (_) {
      return processText(
        '',
        sourceTitle: sourceTitle ?? 'Camera OCR Scan',
      );
    }
  }

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
            .replaceAll(RegExp(r'''[^\p{L}\p{N}\s'-]''', unicode: true), '')
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
          final isEnglish = isEnglishWord(token, normalized);
          detectedWords.add(
            DetectedWord(
              word: token,
              normalized: normalized,
              sentence: sentence,
              rect: rect,
              lineNumber: lineIdx,
              isEnglish: isEnglish,
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
