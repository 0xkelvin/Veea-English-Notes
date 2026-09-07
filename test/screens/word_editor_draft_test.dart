import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:veea_english_app/core/theme/pixel_theme.dart';
import 'package:veea_english_app/data/local/sqlite_vocabulary_repository.dart';
import 'package:veea_english_app/models/part_of_speech.dart';
import 'package:veea_english_app/providers/vocabulary_provider.dart';
import 'package:veea_english_app/screens/word_editor_screen.dart';
import 'package:veea_english_app/services/pronunciation_service.dart';
import 'package:veea_english_app/services/tts_service.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  TestWidgetsFlutterBinding.ensureInitialized();

  late SqliteVocabularyRepository repo;
  late VocabularyProvider provider;
  late PronunciationService pronunciation;
  final today = DateTime(2026, 8, 18, 10);

  setUp(() async {
    repo = await SqliteVocabularyRepository.open(
      path: inMemoryDatabasePath,
      now: () => today,
    );
    provider = VocabularyProvider(repo, now: () => today);
    await provider.init();
    pronunciation = PronunciationService(repo.database);
    await pronunciation.importIfNeeded();
  });

  tearDown(() => repo.close());

  Widget wrap(Widget child) => MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: provider),
      ChangeNotifierProvider(create: (_) => TtsService()),
      Provider<PronunciationService>.value(value: pronunciation),
    ],
    child: MaterialApp(theme: PixelTheme.light(), home: child),
  );

  Future<void> settle(WidgetTester tester) async {
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'WordEditorScreen.draft initializes fields and saves as new word',
    (tester) async {
      final draft = WordDraft(
        word: 'resilient',
        meaning: 'kiên cường',
        pronunciation: '/rɪˈzɪljənt/',
        partOfSpeech: PartOfSpeech.adjective,
        examples: const ['Stay resilient.'],
        tags: const ['ocr', 'mindset'],
      );

      await tester.pumpWidget(wrap(WordEditorScreen.draft(draft: draft)));
      await tester.pumpAndSettle();

      // Verify fields populated from draft
      final wordField = tester.widget<TextField>(find.byType(TextField).first);
      expect(wordField.controller?.text, 'resilient');
      final meaningField = tester.widget<TextField>(
        find.byType(TextField).at(1),
      );
      expect(meaningField.controller?.text, 'kiên cường');

      // Verify save button is "SAVE WORD" (not "SAVE CHANGES")
      expect(find.text('SAVE WORD'), findsOneWidget);

      // Tap Save word
      await tester.tap(find.text('SAVE WORD'));
      await settle(tester);

      // Verify word was added to repository with a valid non-empty id
      expect(provider.words.length, 1);
      final saved = provider.words.first;
      expect(saved.word, 'resilient');
      expect(saved.meaning, 'kiên cường');
      expect(saved.id.isNotEmpty, isTrue);
      expect(saved.tags, contains('ocr'));
    },
  );
}
