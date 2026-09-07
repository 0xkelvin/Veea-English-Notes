import 'package:flutter/services.dart';

import '../providers/vocabulary_provider.dart';
import 'pronunciation_service.dart';
import 'word_suggestion_service.dart';

/// Service that inspects the system clipboard on app launch or resume,
/// detects valid 1–3 word English vocabulary candidates, and performs
/// frictionless one-tap capture into today's journal with automated
/// Vietnamese definition and IPA pronunciation.
class ClipboardDetectorService {
  /// Regular expression matching English words and phrases with hyphens,
  /// apostrophes, and spaces (1 to 3 words).
  static final RegExp _englishPhrasePattern = RegExp(
    r"^[a-zA-Z]+([-' ][a-zA-Z]+)*$",
  );

  /// Strips leading/trailing quotes, punctuation, brackets, and collapses
  /// internal whitespace so strings copied from articles or chats are clean.
  static String? sanitizeCandidate(String? raw) {
    if (raw == null) return null;
    var trimmed = raw.trim();
    if (trimmed.isEmpty) return null;

    // Strip leading and trailing quotes, punctuation, brackets, ellipses
    trimmed = trimmed.replaceAll(
      RegExp(r'''^["'“‘\s\.,;:!?\(\)\[\]\{\}<>…]+|["'”’\s\.,;:!?\(\)\[\]\{\}<>…]+$'''),
      '',
    );

    // Collapse multiple internal whitespaces to a single space
    trimmed = trimmed.replaceAll(RegExp(r'\s+'), ' ').trim();

    return trimmed.isEmpty ? null : trimmed;
  }

  /// Determines if a string qualifies as a valid vocabulary candidate (1–3 words).
  ///
  /// Rejects URLs, digits, code snippets, special characters, and long sentences.
  static bool isValidVocabularyCandidate(String? candidate) {
    if (candidate == null) return false;
    final text = candidate.trim();
    if (text.length < 2 || text.length > 45) return false;

    // Reject URLs and domains
    final lower = text.toLowerCase();
    if (lower.contains('://') ||
        lower.startsWith('www.') ||
        lower.endsWith('.com') ||
        lower.endsWith('.org') ||
        lower.endsWith('.net') ||
        lower.endsWith('.io') ||
        lower.endsWith('.vn') ||
        lower.endsWith('.html') ||
        lower.contains('@')) {
      return false;
    }

    // Reject code syntax, brackets, math symbols, numbers
    if (text.contains(RegExp(r'[0-9{}()\[\];:=><_#$*+/\\|^~`]'))) {
      return false;
    }

    // Count words (separated by spaces)
    final words = text.split(RegExp(r'\s+'));
    if (words.isEmpty || words.length > 3) {
      return false;
    }

    // Ensure English phrase pattern matches
    if (!_englishPhrasePattern.hasMatch(text)) {
      return false;
    }

    return true;
  }

  /// Reads plain text from the system clipboard safely.
  static Future<String?> getClipboardText() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      return data?.text;
    } catch (_) {
      return null;
    }
  }

  /// Detects whether the clipboard holds a new, valid vocabulary candidate.
  ///
  /// Returns the sanitized candidate string if it passes validation and
  /// has not been dismissed or already recorded.
  static Future<String?> detectCandidate({
    Set<String>? dismissedWords,
    List<String>? existingWords,
    Future<String?> Function()? clipboardReader,
  }) async {
    final reader = clipboardReader ?? getClipboardText;
    final rawText = await reader();
    final sanitized = sanitizeCandidate(rawText);

    if (sanitized == null || !isValidVocabularyCandidate(sanitized)) {
      return null;
    }

    final lower = sanitized.toLowerCase();

    // Check if dismissed during current session
    if (dismissedWords != null &&
        dismissedWords.map((w) => w.toLowerCase()).contains(lower)) {
      return null;
    }

    // Check if already captured in today's notes
    if (existingWords != null &&
        existingWords.map((w) => w.toLowerCase()).contains(lower)) {
      return null;
    }

    return sanitized;
  }

  /// One-tap frictionless capture:
  /// 1. Queries [WordSuggestionService] for automated Vietnamese meaning and POS.
  /// 2. Queries [PronunciationService] for IPA transcription.
  /// 3. Navigates to today's date and inserts the word into [VocabularyProvider].
  static Future<bool> quickCapture({
    required String word,
    required VocabularyProvider provider,
    PronunciationService? pronunciationService,
    String? customMeaning,
  }) async {
    final cleanWord = word.trim();
    if (cleanWord.isEmpty) return false;

    // 1. Automatic Vietnamese meaning & POS via WordSuggestionService
    final suggestion = await WordSuggestionService.suggest(cleanWord);

    // 2. Automated IPA pronunciation lookup
    String? pronunciation;
    if (pronunciationService != null) {
      pronunciation = await pronunciationService.lookup(cleanWord);
    }

    // 3. Meaning resolution
    final meaning = customMeaning ??
        ((suggestion?.meaning != null && suggestion!.meaning!.isNotEmpty)
            ? suggestion.meaning!
            : (suggestion?.partOfSpeech != null
                ? '[${suggestion!.partOfSpeech!.label}] Nghĩa mới'
                : 'Nghĩa mới'));

    final pos = suggestion?.partOfSpeech ??
        WordSuggestionService.detectPartOfSpeech(cleanWord);

    // 4. Ensure current view is on today
    if (!provider.isToday) {
      await provider.goToToday();
    }

    // 5. Insert word into today's journal
    await provider.addWord(
      word: cleanWord,
      meaning: meaning,
      pronunciation: pronunciation,
      partOfSpeech: pos,
      source: 'Clipboard',
    );

    return true;
  }
}
