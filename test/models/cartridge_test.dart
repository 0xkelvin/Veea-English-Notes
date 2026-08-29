import 'package:flutter_test/flutter_test.dart';
import 'package:veea_english_app/data/cartridges_data.dart';
import 'package:veea_english_app/models/part_of_speech.dart';

void main() {
  group('Cartridge Data & Models', () {
    test('Silicon Valley Tech Cartridge contains curated modules and words', () {
      final cartridge = CartridgesData.siliconValleyTech;

      expect(cartridge.id, 'silicon_valley_tech_vol1');
      expect(cartridge.title, contains('SILICON VALLEY'));
      expect(cartridge.words, isNotEmpty);
      expect(cartridge.modules.length, 6);

      // Verify word structure
      final idempotent = cartridge.words.firstWhere((w) => w.word == 'idempotent');
      expect(idempotent.partOfSpeech, PartOfSpeech.adjective);
      expect(idempotent.prExample, contains('idempotent'));
      expect(idempotent.standupExample, isNotEmpty);
      expect(idempotent.collocations, isNotEmpty);
      expect(idempotent.interviewNuance, isNotEmpty);
    });

    test('CartridgeWord converts to VocabularyWord correctly', () {
      final cartridge = CartridgesData.siliconValleyTech;
      final word = cartridge.words.first;

      final now = DateTime(2026, 8, 29);
      final vocabWord = word.toVocabularyWord(
        date: '2026-08-29',
        now: now,
        cartridgeTitle: cartridge.title,
      );

      expect(vocabWord.id, word.id);
      expect(vocabWord.word, word.word);
      expect(vocabWord.meaning, word.meaning);
      expect(vocabWord.source, cartridge.title);
      expect(vocabWord.examples.length, 2);
      expect(vocabWord.tags, contains('tech-career'));
    });
  });
}
