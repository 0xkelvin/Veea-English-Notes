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

  testWidgets('Typing "solution" suggests "giải pháp" and NOUN without showing "kiên cường"', (tester) async {
    await tester.pumpWidget(wrap(const WordEditorScreen()));
    await settle(tester);

    // Initial empty state has "kiên cường" as subtle default hint
    expect(find.text('kiên cường'), findsOneWidget);

    // Type "solution" into the word field
    await tester.enterText(find.byType(TextField).first, 'solution');
    await settle(tester);

    // "kiên cường" must NOT be displayed anymore
    expect(find.text('kiên cường'), findsNothing);

    // Should display suggested meaning with "giải pháp"
    expect(find.textContaining('giải pháp'), findsWidgets);

    // Part of speech header should display suggested NOUN
    expect(find.text('GỢI Ý: NOUN'), findsOneWidget);

    // Tapping the suggestion pill fills the meaning field
    await tester.tap(find.text('[ÁP DỤNG]'));
    await settle(tester);

    final meaningField = tester.widget<TextField>(find.byType(TextField).at(1));
    expect(meaningField.controller?.text, contains('giải pháp'));
  });

  testWidgets('Typing English word suggests Vietnamese meaning and PartOfSpeech', (tester) async {
    await tester.pumpWidget(wrap(const WordEditorScreen()));
    await settle(tester);

    // Type "resilient" into the word field (first TextField)
    await tester.enterText(find.byType(TextField).first, 'resilient');
    await settle(tester);

    // Should display suggested meaning pill
    expect(find.textContaining('GỢI Ý: '), findsWidgets);
    expect(find.textContaining('kiên cường'), findsWidgets);

    // Part of speech header should display suggested ADJECTIVE
    expect(find.text('GỢI Ý: ADJECTIVE'), findsOneWidget);

    // Tapping the suggestion pill fills the meaning field
    await tester.tap(find.text('[ÁP DỤNG]'));
    await settle(tester);

    // Meaning field (second TextField) should now have the text
    final meaningField = tester.widget<TextField>(find.byType(TextField).at(1));
    expect(meaningField.controller?.text, contains('kiên cường'));
  });

  testWidgets('User manual PartOfSpeech selection overrides suggestion', (tester) async {
    await tester.pumpWidget(wrap(const WordEditorScreen()));
    await settle(tester);

    // Type "resilient" -> suggests ADJECTIVE
    await tester.enterText(find.byType(TextField).first, 'resilient');
    await settle(tester);

    expect(find.text('GỢI Ý: ADJECTIVE'), findsOneWidget);

    // User explicitly taps "NOUN"
    await tester.tap(find.text('NOUN'));
    await settle(tester);

    // Save should work with PartOfSpeech.noun
    await tester.enterText(find.byType(TextField).at(1), 'nghĩa riêng');
    await settle(tester);

    await tester.tap(find.text('SAVE WORD'));
    await settle(tester);

    expect(provider.words.single.word, 'resilient');
    expect(provider.words.single.partOfSpeech, PartOfSpeech.noun);
  });
}
