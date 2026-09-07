import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:veea_english_app/core/theme/pixel_theme.dart';
import 'package:veea_english_app/data/local/sqlite_vocabulary_repository.dart';
import 'package:veea_english_app/providers/vocabulary_provider.dart';
import 'package:veea_english_app/screens/review_screen.dart';
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

    // Add a word due for review so that _queue is populated and top bar shows progress bar
    await vocabProvider.addWord(
      word: 'resilient',
      meaning: 'kiên cường',
    );
  });

  tearDown(() => repo.close());

  Widget wrap(Widget child) => MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: vocabProvider),
          ChangeNotifierProvider(create: (_) => TtsService()),
        ],
        child: MaterialApp(theme: PixelTheme.light(), home: child),
      );

  testWidgets(
    'ReviewScreen top bar renders cleanly on 370px screen without RenderFlex overflow',
    (tester) async {
      tester.view.physicalSize = const Size(370, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(wrap(const ReviewScreen(practiceAll: true)));
      await tester.pumpAndSettle();

      expect(find.text('SPACED REVIEW'), findsOneWidget);
      expect(find.bySemanticsLabel('Exit review'), findsOneWidget);
      expect(find.bySemanticsLabel('Hands-Free Audio Review'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'ReviewScreen top bar renders cleanly on very narrow 320px screen without RenderFlex overflow',
    (tester) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(wrap(const ReviewScreen(practiceAll: true)));
      await tester.pumpAndSettle();

      expect(find.text('SPACED REVIEW'), findsOneWidget);
      expect(find.bySemanticsLabel('Exit review'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
