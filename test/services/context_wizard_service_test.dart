import 'package:flutter_test/flutter_test.dart';
import 'package:veea_english_app/models/part_of_speech.dart';
import 'package:veea_english_app/services/context_wizard_service.dart';

void main() {
  group('ContextWizardService', () {
    test('handles empty input gracefully', () {
      final result = ContextWizardService.generate('');
      expect(result.word, isEmpty);
      expect(result.sentences, isEmpty);
      expect(result.collocations, isEmpty);
    });

    test('generates curated specialized output for resilient', () {
      final result = ContextWizardService.generate('resilient');
      expect(result.word, 'resilient');
      expect(result.sentences.length, 3);
      expect(result.collocations, isNotEmpty);
      expect(result.nuances, isNotEmpty);
      expect(
        result.sentences.any((s) => s.sentence.contains('resilient')),
        isTrue,
      );
      expect(
        result.collocations.contains('resilient infrastructure'),
        isTrue,
      );
      expect(
        result.nuances.any((n) => n.synonym == 'tough'),
        isTrue,
      );
    });

    test('generates specialized output for career cartridge terms', () {
      final result = ContextWizardService.generate('idempotent');
      expect(result.word, 'idempotent');
      expect(result.sentences.length, greaterThanOrEqualTo(2));
      expect(
        result.sentences.any((s) => s.domain.contains('PR & CODE REVIEW')),
        isTrue,
      );
      expect(
        result.sentences.any((s) => s.sentence.toLowerCase().contains('idempotent')),
        isTrue,
      );
      expect(
        result.collocations.any((c) => c.contains('idempotent')),
        isTrue,
      );
      expect(
        result.nuances.any((n) => n.synonym == 'Interview Context'),
        isTrue,
      );
    });

    test('generates grammatically appropriate noun sentences and collocations', () {
      final result = ContextWizardService.generate('database');
      expect(result.word, 'database');
      expect(result.partOfSpeech, PartOfSpeech.noun);
      expect(result.sentences.length, 3);

      // Sentences must NOT use the old broken adjective template "designed to be highly database"
      for (final s in result.sentences) {
        expect(s.sentence.contains('highly database'), isFalse);
        expect(s.sentence.contains('database mindset'), isFalse);
        expect(s.sentence.toLowerCase().contains('database'), isTrue);
        expect(s.structureType, isNotNull);
      }

      // Collocations must be noun-tailored, NOT "deeply database"
      expect(result.collocations.contains('deeply database'), isFalse);
      expect(result.collocations.any((c) => c.contains('database')), isTrue);
      expect(
        result.collocations.any((c) => c.contains('robust') || c.contains('architecture') || c.contains('lifecycle')),
        isTrue,
      );

      // Nuances must NOT compare "database" to "persistent" or "tenacious"
      expect(result.nuances.any((n) => n.synonym == 'persistent'), isFalse);
      expect(result.nuances.any((n) => n.synonym == 'tenacious'), isFalse);
    });

    test('generates grammatically appropriate verb sentences and collocations', () {
      final result = ContextWizardService.generate(
        'optimize',
        partOfSpeech: PartOfSpeech.verb,
      );
      expect(result.word, 'optimize');
      expect(result.partOfSpeech, PartOfSpeech.verb);
      expect(result.sentences.length, 3);

      // Sentences must use natural verb slots
      for (final s in result.sentences) {
        expect(s.sentence.contains('highly optimize'), isFalse);
        expect(s.sentence.toLowerCase().contains('optimize'), isTrue);
      }

      // Collocations must be verb-tailored
      expect(result.collocations.contains('deeply optimize'), isFalse);
      expect(
        result.collocations.any((c) => c.contains('actively') || c.contains('efficiently') || c.contains('aim to')),
        isTrue,
      );
    });

    test('generates adverb-appropriate structures for adverbs', () {
      final result = ContextWizardService.generate('seamlessly');
      expect(result.word, 'seamlessly');
      expect(result.partOfSpeech, PartOfSpeech.adverb);
      expect(result.sentences.length, 3);

      for (final s in result.sentences) {
        expect(s.sentence.contains('seamlessly mindset'), isFalse);
        expect(s.sentence.toLowerCase().contains('seamlessly'), isTrue);
      }

      expect(
        result.collocations.any((c) => c.contains('executed') || c.contains('operate') || c.contains('designed')),
        isTrue,
      );
    });

    test('generates natural sentences for idioms and phrases', () {
      final result = ContextWizardService.generate('bite the bullet');
      expect(result.word, 'bite the bullet');
      expect(result.partOfSpeech, PartOfSpeech.idiom);
      expect(result.sentences.length, 3);

      for (final s in result.sentences) {
        expect(s.sentence.toLowerCase().contains('bite the bullet'), isTrue);
      }

      expect(
        result.collocations.any((c) => c.contains('time to') || c.contains('decided to')),
        isTrue,
      );
    });

    test('different words produce distinct sentence structures', () {
      final resultA = ContextWizardService.generate('database');
      final resultB = ContextWizardService.generate('compiler');

      // The sentences should not be identical
      final sentencesA = resultA.sentences.map((s) => s.sentence).toList();
      final sentencesB = resultB.sentences.map((s) => s.sentence).toList();

      expect(sentencesA, isNot(equals(sentencesB)));
    });

    test('variation shuffling produces different sentence structures for the same word', () {
      final roll0 = ContextWizardService.generate('database', variation: 0);
      final roll1 = ContextWizardService.generate('database', variation: 1);

      final sentences0 = roll0.sentences.map((s) => s.sentence).toList();
      final sentences1 = roll1.sentences.map((s) => s.sentence).toList();

      expect(sentences0, isNot(equals(sentences1)));
    });

    test('supports ubiquitous and other expanded curated vocabulary', () {
      final result = ContextWizardService.generate('ubiquitous');
      expect(result.word, 'ubiquitous');
      expect(result.sentences.length, 3);
      expect(result.collocations, isNotEmpty);
      expect(
        result.sentences.any((s) => s.sentence.contains('ubiquitous')),
        isTrue,
      );
      expect(
        result.nuances.any((n) => n.synonym == 'common'),
        isTrue,
      );
    });
  });
}
