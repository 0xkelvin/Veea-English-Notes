import 'package:flutter_test/flutter_test.dart';
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
    });

    test('generates dynamic context for custom unknown vocabulary words', () {
      final result = ContextWizardService.generate('ubiquitous');
      expect(result.word, 'ubiquitous');
      expect(result.sentences.length, 3);
      expect(result.collocations, isNotEmpty);
      expect(
        result.sentences.any((s) => s.sentence.contains('ubiquitous')),
        isTrue,
      );
    });
  });
}
