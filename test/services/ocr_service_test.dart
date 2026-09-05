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
        // All words in the sample scans should be valid English words
        for (final word in sample.words) {
          expect(word.isEnglish, isTrue, reason: '${word.word} should be English');
        }
      }
    });

    test('isEnglishWord identifies valid English words correctly', () {
      expect(OcrService.isEnglishWord('resilient', 'resilient'), isTrue);
      expect(OcrService.isEnglishWord('resilient,', 'resilient'), isTrue);
      expect(OcrService.isEnglishWord('don\'t', 'don\'t'), isTrue);
      expect(OcrService.isEnglishWord('state-of-the-art', 'state-of-the-art'), isTrue);
      expect(OcrService.isEnglishWord('"serendipity"', 'serendipity'), isTrue);
      expect(OcrService.isEnglishWord('DOWNTIME', 'downtime'), isTrue);
      expect(OcrService.isEnglishWord('latency.', 'latency'), isTrue);
    });

    test('isEnglishWord detects Vietnamese words as non-English', () {
      // Accented Vietnamese words
      expect(OcrService.isEnglishWord('tiếng', 'tiếng'), isFalse);
      expect(OcrService.isEnglishWord('Việt', 'việt'), isFalse);
      expect(OcrService.isEnglishWord('chào', 'chào'), isFalse);
      expect(OcrService.isEnglishWord('học', 'học'), isFalse);
      expect(OcrService.isEnglishWord('người', 'người'), isFalse);
      expect(OcrService.isEnglishWord('được', 'được'), isFalse);
      expect(OcrService.isEnglishWord('bài,', 'bài'), isFalse);

      // Unaccented Vietnamese words
      expect(OcrService.isEnglishWord('khong', 'khong'), isFalse);
      expect(OcrService.isEnglishWord('duoc', 'duoc'), isFalse);
      expect(OcrService.isEnglishWord('nguoi', 'nguoi'), isFalse);
      expect(OcrService.isEnglishWord('tieng', 'tieng'), isFalse);
      expect(OcrService.isEnglishWord('chuyen', 'chuyen'), isFalse);

      // Vietnamese phonetics (ngh-, ng+vowel)
      expect(OcrService.isEnglishWord('nghe', 'nghe'), isFalse);
      expect(OcrService.isEnglishWord('nghi', 'nghi'), isFalse);
      expect(OcrService.isEnglishWord('nguyen', 'nguyen'), isFalse);
      expect(OcrService.isEnglishWord('ngay', 'ngay'), isFalse);
    });

    test('isEnglishWord detects special symbols and numbers as non-English', () {
      expect(OcrService.isEnglishWord('#402', '402'), isFalse);
      expect(OcrService.isEnglishWord('100%', '100'), isFalse);
      expect(OcrService.isEnglishWord('\$50', '50'), isFalse);
      expect(OcrService.isEnglishWord('2026', '2026'), isFalse);
      expect(OcrService.isEnglishWord('v1.2', 'v12'), isFalse);
      expect(OcrService.isEnglishWord('foo_bar', 'foo_bar'), isFalse);
      expect(OcrService.isEnglishWord('@kelvin', 'kelvin'), isFalse);
      expect(OcrService.isEnglishWord('c++', 'c'), isFalse);
    });

    test('isEnglishWord detects tokens without vowels as non-English', () {
      expect(OcrService.isEnglishWord('cntt', 'cntt'), isFalse);
      expect(OcrService.isEnglishWord('thcs', 'thcs'), isFalse);
      expect(OcrService.isEnglishWord('clb', 'clb'), isFalse);
      expect(OcrService.isEnglishWord('bds', 'bds'), isFalse);
      expect(OcrService.isEnglishWord('---', '---'), isFalse);
    });

    test('processText flags mixed English and Vietnamese tokens with correct isEnglish', () {
      const mixed = 'Tài liệu hướng dẫn Flutter #402: Build resilient apps with 99% uptime.';
      final result = OcrService.processText(mixed);

      final flutter = result.words.firstWhere((w) => w.normalized == 'flutter');
      expect(flutter.isEnglish, isTrue);

      final resilient = result.words.firstWhere((w) => w.normalized == 'resilient');
      expect(resilient.isEnglish, isTrue);

      final apps = result.words.firstWhere((w) => w.normalized == 'apps');
      expect(apps.isEnglish, isTrue);

      final uptime = result.words.firstWhere((w) => w.normalized == 'uptime');
      expect(uptime.isEnglish, isTrue);

      final tai = result.words.firstWhere((w) => w.word == 'Tài');
      expect(tai.isEnglish, isFalse);

      final lieu = result.words.firstWhere((w) => w.word == 'liệu');
      expect(lieu.isEnglish, isFalse);

      final huong = result.words.firstWhere((w) => w.word == 'hướng');
      expect(huong.isEnglish, isFalse);

      final dan = result.words.firstWhere((w) => w.word == 'dẫn');
      expect(dan.isEnglish, isFalse);
    });
  });
}
