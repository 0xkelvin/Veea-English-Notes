import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:veea_english_app/core/theme/pixel_theme.dart';
import 'package:veea_english_app/data/local/sqlite_vocabulary_repository.dart';
import 'package:veea_english_app/providers/vocabulary_provider.dart';
// import 'package:veea_english_app/screens/arcade_screen.dart';
import 'package:veea_english_app/screens/home_screen.dart';
import 'package:veea_english_app/screens/word_editor_screen.dart';
import 'package:veea_english_app/services/tts_service.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late SqliteVocabularyRepository repo;
  late VocabularyProvider vocabProvider;
  final today = DateTime(2026, 8, 18, 10);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    repo = await SqliteVocabularyRepository.open(
      path: inMemoryDatabasePath,
      now: () => today,
    );
    vocabProvider = VocabularyProvider(repo, now: () => today);
    await vocabProvider.init();
  });

  tearDown(() => repo.close());

  Widget wrap(Widget child) => MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: vocabProvider),
      ChangeNotifierProvider(create: (_) => TtsService()),
    ],
    child: MaterialApp(theme: PixelTheme.light(), home: child),
  );

  testWidgets('HomeScreen renders Dual-Bar layout cleanly with games hidden', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(wrap(const HomeScreen()));
    await tester.pumpAndSettle();

    // Top Bar verification (Minimal & focused, "VEEA // JOURNAL" removed)
    expect(find.text('VEEA // JOURNAL'), findsNothing);
    expect(
      find.byTooltip('Search all words'),
      findsNothing,
    ); // Using semanticLabels
    expect(find.bySemanticsLabel('Search all words'), findsOneWidget);
    expect(find.bySemanticsLabel('Pixel Lens OCR Scanner'), findsOneWidget);
    expect(find.bySemanticsLabel('Settings'), findsOneWidget);

    // Bottom Dock verification (ARCADE is hidden)
    expect(find.text('AUDIO'), findsOneWidget);
    expect(find.text('ARCADE'), findsNothing);
    expect(find.text('ADD'), findsOneWidget);
    expect(find.text('REVIEW'), findsOneWidget);

    // Tap Hero ADD button -> opens WordEditorScreen
    await tester.tap(find.text('ADD'));
    await tester.pumpAndSettle();
    expect(find.byType(WordEditorScreen), findsOneWidget);

    // Close editor
    await tester.tap(find.bySemanticsLabel('Close without saving'));
    await tester.pumpAndSettle();
  });
}
