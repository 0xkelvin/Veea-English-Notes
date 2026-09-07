import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:veea_english_app/data/local/sqlite_vocabulary_repository.dart';
import 'package:veea_english_app/providers/vocabulary_provider.dart';
import 'package:veea_english_app/services/clipboard_detector_service.dart';
import 'package:veea_english_app/services/word_suggestion_service.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    WordSuggestionService.allowOnlineTranslation = false;
  });

  group('ClipboardDetectorService.sanitizeCandidate', () {
    test('strips leading/trailing quotes and punctuation', () {
      expect(ClipboardDetectorService.sanitizeCandidate('"resilient"'), 'resilient');
      expect(ClipboardDetectorService.sanitizeCandidate('“bottleneck”'), 'bottleneck');
      expect(ClipboardDetectorService.sanitizeCandidate('trade-off,'), 'trade-off');
      expect(ClipboardDetectorService.sanitizeCandidate('(touch base)!'), 'touch base');
      expect(ClipboardDetectorService.sanitizeCandidate('   serendipity…  '), 'serendipity');
      expect(ClipboardDetectorService.sanitizeCandidate(''), isNull);
      expect(ClipboardDetectorService.sanitizeCandidate('   "   '), isNull);
    });

    test('collapses multiple internal whitespace characters', () {
      expect(
        ClipboardDetectorService.sanitizeCandidate('cut    corners'),
        'cut corners',
      );
    });
  });

  group('ClipboardDetectorService.isValidVocabularyCandidate', () {
    test('accepts 1 to 3 word English phrases', () {
      expect(ClipboardDetectorService.isValidVocabularyCandidate('resilient'), isTrue);
      expect(ClipboardDetectorService.isValidVocabularyCandidate('bottleneck'), isTrue);
      expect(ClipboardDetectorService.isValidVocabularyCandidate('trade-off'), isTrue);
      expect(ClipboardDetectorService.isValidVocabularyCandidate('touch base'), isTrue);
      expect(ClipboardDetectorService.isValidVocabularyCandidate('rule of thumb'), isTrue);
      expect(ClipboardDetectorService.isValidVocabularyCandidate('state-of-the-art'), isTrue);
      expect(ClipboardDetectorService.isValidVocabularyCandidate("cat's cradle"), isTrue);
    });

    test('rejects 4 or more words', () {
      expect(
        ClipboardDetectorService.isValidVocabularyCandidate('this is too many words to learn'),
        isFalse,
      );
      expect(
        ClipboardDetectorService.isValidVocabularyCandidate('one two three four'),
        isFalse,
      );
    });

    test('rejects URLs, domains, and emails', () {
      expect(
        ClipboardDetectorService.isValidVocabularyCandidate('https://flutter.dev'),
        isFalse,
      );
      expect(
        ClipboardDetectorService.isValidVocabularyCandidate('www.google.com'),
        isFalse,
      );
      expect(
        ClipboardDetectorService.isValidVocabularyCandidate('dev@example.com'),
        isFalse,
      );
      expect(
        ClipboardDetectorService.isValidVocabularyCandidate('docs.flutter.io'),
        isFalse,
      );
    });

    test('rejects numbers, code syntax, and symbols', () {
      expect(ClipboardDetectorService.isValidVocabularyCandidate('12345'), isFalse);
      expect(ClipboardDetectorService.isValidVocabularyCandidate('resilient 2'), isFalse);
      expect(ClipboardDetectorService.isValidVocabularyCandidate('const x = 10;'), isFalse);
      expect(ClipboardDetectorService.isValidVocabularyCandidate('func()'), isFalse);
      expect(ClipboardDetectorService.isValidVocabularyCandidate('{json}'), isFalse);
      expect(ClipboardDetectorService.isValidVocabularyCandidate('hello #world'), isFalse);
    });

    test('rejects single letters or overly long strings', () {
      expect(ClipboardDetectorService.isValidVocabularyCandidate('a'), isFalse);
      expect(
        ClipboardDetectorService.isValidVocabularyCandidate(
          'supercalifragilisticexpialidociousincrediblysuperlongword',
        ),
        isFalse,
      );
    });
  });

  group('ClipboardDetectorService.detectCandidate', () {
    test('detects valid candidate when not dismissed or already recorded', () async {
      final detected = await ClipboardDetectorService.detectCandidate(
        clipboardReader: () async => ' "resilient" ',
        dismissedWords: {'bottleneck'},
        existingWords: ['trade-off'],
      );
      expect(detected, 'resilient');
    });

    test('returns null if candidate was already dismissed in session', () async {
      final detected = await ClipboardDetectorService.detectCandidate(
        clipboardReader: () async => 'resilient',
        dismissedWords: {'resilient'},
        existingWords: [],
      );
      expect(detected, isNull);
    });

    test('returns null if candidate already exists in user notebook', () async {
      final detected = await ClipboardDetectorService.detectCandidate(
        clipboardReader: () async => 'Resilient',
        dismissedWords: {},
        existingWords: ['resilient'],
      );
      expect(detected, isNull);
    });

    test('returns null for invalid clipboard content', () async {
      final detected = await ClipboardDetectorService.detectCandidate(
        clipboardReader: () async => 'https://news.ycombinator.com',
      );
      expect(detected, isNull);
    });
  });

  group('ClipboardDetectorService.quickCapture', () {
    late SqliteVocabularyRepository repo;
    late VocabularyProvider provider;
    final today = DateTime(2026, 8, 18, 10);

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      repo = await SqliteVocabularyRepository.open(
        path: inMemoryDatabasePath,
        now: () => today,
      );
      provider = VocabularyProvider(repo, now: () => today);
      await provider.init();
    });

    tearDown(() => repo.close());

    test('saves word into today with automated meaning and source', () async {
      expect(provider.words, isEmpty);

      final success = await ClipboardDetectorService.quickCapture(
        word: 'resilient',
        provider: provider,
      );

      expect(success, isTrue);
      expect(provider.words.length, 1);
      final word = provider.words.first;
      expect(word.word, 'resilient');
      // resilient is in built-in offline dictionary: "kiên cường, có khả năng phục hồi nhanh"
      expect(word.meaning.isNotEmpty, isTrue);
      expect(word.source, 'Clipboard');
    });
  });
}
