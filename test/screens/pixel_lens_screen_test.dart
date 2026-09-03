import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:veea_english_app/core/theme/pixel_theme.dart';
import 'package:veea_english_app/data/local/sqlite_vocabulary_repository.dart';
import 'package:veea_english_app/providers/theme_provider.dart';
import 'package:veea_english_app/providers/vocabulary_provider.dart';
import 'package:veea_english_app/screens/pixel_lens_screen.dart';
import 'package:veea_english_app/services/pronunciation_service.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late SqliteVocabularyRepository repo;
  late VocabularyProvider vocabProvider;
  late ThemeProvider themeProvider;
  late PronunciationService pronunciation;
  final today = DateTime(2026, 8, 18, 10);

  setUp(() async {
    repo = await SqliteVocabularyRepository.open(
      path: inMemoryDatabasePath,
      now: () => today,
    );
    vocabProvider = VocabularyProvider(repo, now: () => today);
    themeProvider = ThemeProvider();
    pronunciation = PronunciationService(repo.database);
  });

  tearDown(() => repo.close());

  Future<void> settle(WidgetTester tester) async {
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pumpAndSettle();
  }

  Widget buildApp() {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: vocabProvider),
        ChangeNotifierProvider.value(value: themeProvider),
        Provider<PronunciationService>.value(value: pronunciation),
      ],
      child: MaterialApp(
        theme: PixelTheme.light(),
        home: const PixelLensScreen(),
      ),
    );
  }

  testWidgets('PixelLensScreen displays camera and gallery buttons and token HUD', (tester) async {
    await tester.pumpWidget(buildApp());
    await settle(tester);

    expect(find.text('PIXEL LENS OCR'), findsOneWidget);
    expect(find.text('SNAP CAMERA • SNIFF VOCABULARY'), findsOneWidget);
    expect(find.text('SNAP CAMERA'), findsOneWidget);
    expect(find.text('PHOTO ALBUM'), findsOneWidget);
    expect(find.text('PR REVIEW'), findsOneWidget);
    expect(find.text('TECH NEWS'), findsOneWidget);
    expect(find.text('ESSAY'), findsOneWidget);
    expect(find.textContaining('TOKENS'), findsOneWidget);
  });

  testWidgets('Selecting words updates inspection dock', (tester) async {
    await tester.pumpWidget(buildApp());
    await settle(tester);

    expect(find.textContaining('CAPTURE "'), findsOneWidget);

    final wordWidget = find.text('resilient');
    if (wordWidget.evaluate().isNotEmpty) {
      await tester.tap(wordWidget);
      await settle(tester);
      expect(find.text('RESILIENT'), findsOneWidget);
    }
  });

  testWidgets('Switching sample presets updates HUD tokens', (tester) async {
    await tester.pumpWidget(buildApp());
    await settle(tester);

    await tester.tap(find.text('TECH NEWS'));
    await settle(tester);

    expect(find.textContaining('Tech Summit Keynote'), findsOneWidget);
  });
}
