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
        source: 'A podcast',
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
      expect(find.text('Save word'), findsOneWidget);

      // Tap Save word
      await tester.tap(find.text('Save word'));
      await settle(tester);

      // Verify word was added to repository with a valid non-empty id
      expect(provider.words.length, 1);
      final saved = provider.words.first;
      expect(saved.word, 'resilient');
      expect(saved.meaning, 'kiên cường');
      expect(saved.id.isNotEmpty, isTrue);
      expect(saved.tags, contains('ocr'));
      expect(saved.source, 'A podcast');
    },
  );

  testWidgets('Manually added word has no automatic source', (tester) async {
    await tester.pumpWidget(wrap(const WordEditorScreen()));
    await settle(tester);
    await tester.enterText(
      find.descendant(
        of: find.byKey(const Key('word_editor_word')),
        matching: find.byType(TextField),
      ),
      'resilient',
    );
    await tester.enterText(
      find.descendant(
        of: find.byKey(const Key('word_editor_meaning')),
        matching: find.byType(TextField),
      ),
      'kiên cường',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save word'));
    await settle(tester);
    expect(provider.words.single.source, isNull);
  });

  testWidgets('Clearing a draft source keeps it cleared when saving', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        const WordEditorScreen.draft(
          draft: WordDraft(
            word: 'resilient',
            meaning: 'kiên cường',
            source: 'Camera Scan',
          ),
        ),
      ),
    );
    await settle(tester);
    final source = find.descendant(
      of: find.byKey(const Key('word_editor_source')),
      matching: find.byType(TextField),
    );
    await tester.scrollUntilVisible(
      source,
      150,
      scrollable: find.byType(Scrollable).first,
    );
    expect(tester.widget<TextField>(source).controller!.text, 'Camera Scan');
    await tester.enterText(source, '   ');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save word'));
    await settle(tester);
    expect(provider.words.single.source, isNull);
  });
}
