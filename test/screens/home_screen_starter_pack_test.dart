import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:veea_english_app/core/theme/pixel_theme.dart';
import 'package:veea_english_app/data/local/sqlite_vocabulary_repository.dart';
import 'package:veea_english_app/providers/vocabulary_provider.dart';
import 'package:veea_english_app/screens/home_screen.dart';
import 'package:veea_english_app/services/tts_service.dart';
import 'package:veea_english_app/widgets/word_row.dart';

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

  testWidgets(
    'First-run shows welcome banner and loads 5 starter words on tap',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(wrap(const HomeScreen()));
      await tester.pumpAndSettle();

      // Verify Welcome Banner is shown for fresh install
      expect(find.text('WELCOME TO VEEA'), findsOneWidget);
      expect(find.text('LOAD 5 STARTER WORDS'), findsOneWidget);
      expect(find.byType(WordRow), findsNothing);

      // Tap LOAD 5 STARTER WORDS
      final button = find.text('LOAD 5 STARTER WORDS');
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)),
      );
      await tester.pumpAndSettle();

      // Starter pack loaded: banner is gone, 5 words appear
      expect(find.text('WELCOME TO VEEA'), findsNothing);
      expect(find.byType(WordRow), findsNWidgets(5));
      expect(find.text('resilient'), findsOneWidget);
      expect(find.text('bottleneck'), findsOneWidget);
      expect(find.text('trade-off'), findsOneWidget);
      expect(find.text('serendipity'), findsOneWidget);
      expect(find.text('pragmatic'), findsOneWidget);
      expect(vocabProvider.stats.totalWords, 5);
    },
  );
}
