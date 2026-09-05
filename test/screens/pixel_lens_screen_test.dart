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

  testWidgets('Non-English words and symbols are grayed down and have capture disabled', (tester) async {
    await tester.pumpWidget(buildApp());
    await settle(tester);

    // Open paste dialog via semantic label
    final pasteFinder = find.byWidgetPredicate(
      (w) => w is Semantics && w.properties.label == 'Paste text snippet',
    );
    expect(pasteFinder, findsOneWidget);
    await tester.tap(pasteFinder);
    await settle(tester);

    expect(find.text('PASTE TEXT OR OCR SNIPPET'), findsOneWidget);

    // Enter mixed Vietnamese, symbol, and English text
    await tester.enterText(
      find.byType(TextField),
      'Học tiếng Anh với Flutter và #402 resilient code.',
    );
    await tester.tap(find.text('SCAN WORDS'));
    await settle(tester);

    // The English word 'Flutter' or 'resilient' should be found
    expect(find.text('Flutter'), findsOneWidget);
    expect(find.text('resilient'), findsOneWidget);

    // Vietnamese word 'tiếng' should be rendered in the token cloud
    final tiengToken = find.text('tiếng');
    expect(tiengToken, findsOneWidget);

    // Tap on the Vietnamese token 'tiếng'
    await tester.tap(tiengToken);
    await settle(tester);

    // Verify it shows NOT ENGLISH WORD badge and CAPTURE DISABLED
    expect(find.text('NOT ENGLISH WORD'), findsOneWidget);
    expect(find.text('NON-ENGLISH TOKEN • CAPTURE DISABLED'), findsOneWidget);

    // Tap on the English word 'resilient'
    await tester.tap(find.text('resilient'));
    await settle(tester);

    // Verify it shows normal capture button
    expect(find.text('NOT ENGLISH WORD'), findsNothing);
    expect(find.textContaining('CAPTURE "RESILIENT"'), findsOneWidget);
  });

  testWidgets('PixelLensScreen does not overflow on narrow screens', (tester) async {
    tester.view.physicalSize = const Size(320 * 2, 800 * 2);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(buildApp());
    await settle(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('PIXEL LENS OCR'), findsOneWidget);
  });
}
