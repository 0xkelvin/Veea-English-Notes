import '../widgets/pixel/pixel_icon.dart';
import 'part_of_speech.dart';
import 'vocabulary_word.dart';

/// A single specialized technical vocabulary entry in a career cartridge.
class CartridgeWord {
  const CartridgeWord({
    required this.id,
    required this.word,
    required this.pronunciation,
    required this.partOfSpeech,
    required this.meaning,
    required this.module,
    required this.prExample,
    required this.standupExample,
    required this.collocations,
    required this.interviewNuance,
    this.tags = const [],
  });

  final String id;
  final String word;
  final String pronunciation;
  final PartOfSpeech partOfSpeech;
  final String meaning;
  final String module;
  final String prExample;
  final String standupExample;
  final List<String> collocations;
  final String interviewNuance;
  final List<String> tags;

  /// Converts this cartridge entry into a user's persistent VocabularyWord.
  VocabularyWord toVocabularyWord({
    required String date,
    required DateTime now,
    String? cartridgeTitle,
  }) {
    return VocabularyWord.create(
      id: id,
      word: word,
      meaning: meaning,
      date: date,
      now: now,
      pronunciation: pronunciation,
      partOfSpeech: partOfSpeech,
      source: cartridgeTitle ?? 'Silicon Valley Tech Cartridge',
      examples: [
        '[PR Review] $prExample',
        '[Standup] $standupExample',
      ],
      tags: ['tech-career', module.toLowerCase().replaceAll(' ', '-'), ...tags],
    );
  }
}

/// A curated DLC vocabulary expansion cartridge.
class Cartridge {
  const Cartridge({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.description,
    required this.iconGlyph,
    required this.priceLabel,
    required this.badgeLabel,
    required this.modules,
    required this.words,
  });

  final String id;
  final String title;
  final String subtitle;
  final String description;
  final PixelGlyph iconGlyph;
  final String priceLabel;
  final String badgeLabel;
  final List<String> modules;
  final List<CartridgeWord> words;

  int get wordCount => words.length;
}
