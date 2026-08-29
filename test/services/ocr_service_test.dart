import 'package:flutter_test/flutter_test.dart';
import 'package:veea_english_app/services/ocr_service.dart';

void main() {
  group('OcrService', () {
    test('processes empty text cleanly', () {
      final result = OcrService.processText('');
      expect(result.rawText, isEmpty);
      expect(result.words, isEmpty);
    });

    test('extracts words, bounding boxes, and sentences from raw text', () {
      const sample =
          'The architecture is remarkably resilient under heavy traffic. '
          'We must maintain focus.';
      final result = OcrService.processText(sample, sourceTitle: 'Test Source');

      expect(result.rawText, sample);
      expect(result.sourceTitle, 'Test Source');
      expect(result.words, isNotEmpty);

      final resilient = result.words.firstWhere((w) => w.normalized == 'resilient');
      expect(resilient.word, 'resilient');
      expect(
        resilient.sentence,
        'The architecture is remarkably resilient under heavy traffic.',
      );
      expect(resilient.rect.width, greaterThan(0));
    });

    test('sample scans are loaded with valid tokens', () {
      expect(OcrService.sampleScans.length, greaterThanOrEqualTo(3));
      for (final sample in OcrService.sampleScans) {
        expect(sample.words, isNotEmpty);
        expect(sample.sourceTitle, isNotNull);
      }
    });
  });
}
