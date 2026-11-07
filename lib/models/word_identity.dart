import 'vocabulary_word.dart';
import 'part_of_speech.dart';

/// Spelling identity for duplicate checks, separate from accent-insensitive search.
/// Different inflections and accented spellings remain distinct words.
class WordIdentity {
  WordIdentity._();
  static String key(String value) => value
      .trim()
      .toLowerCase()
      .replaceAll(RegExp('[\u2018\u2019]'), "'")
      .replaceAll(RegExp(r'\s+'), ' ');

  /// A broad search candidate; the complete spelling is always checked in Dart.
  /// Using a first token also finds phrases saved with repeated whitespace.
  static String candidate(String value) =>
      key(value).split(' ').first.split("'").first;

  static bool sameSense(VocabularyWord a, VocabularyWord b) =>
      sameDefinition(a.meaning, a.partOfSpeech, b);
  static bool sameDefinition(
    String meaning,
    PartOfSpeech? partOfSpeech,
    VocabularyWord saved,
  ) =>
      key(meaning) == key(saved.meaning) &&
      !(partOfSpeech != null &&
          saved.partOfSpeech != null &&
          partOfSpeech != saved.partOfSpeech);
}

class DuplicateWordException implements Exception {
  DuplicateWordException(List<VocabularyWord> matches)
    : matches = List.unmodifiable(matches);
  final List<VocabularyWord> matches;
}
