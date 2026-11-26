import 'part_of_speech.dart';

/// A suggested meaning, never a change to the user's notebook.
class WordSuggestion {
  const WordSuggestion({
    required this.word,
    this.meaning,
    this.partOfSpeech,
    this.source,
    this.sourceUrl,
  });

  final String word;
  final String? meaning;
  final PartOfSpeech? partOfSpeech;
  final String? source;
  final String? sourceUrl;
}
