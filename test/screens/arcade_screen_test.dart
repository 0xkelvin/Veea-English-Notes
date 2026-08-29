import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:veea_english_app/core/theme/pixel_theme.dart';
import 'package:veea_english_app/data/local/sqlite_vocabulary_repository.dart';
import 'package:veea_english_app/models/vocabulary_word.dart';
import 'package:veea_english_app/providers/theme_provider.dart';
import 'package:veea_english_app/providers/vocabulary_provider.dart';
import 'package:veea_english_app/screens/arcade_screen.dart';
import 'package:veea_english_app/screens/games/vocab_snake_game.dart';
import 'package:veea_english_app/screens/games/word_rush_game.dart';
import 'package:veea_english_app/services/tts_service.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late SqliteVocabularyRepository repo;
  late VocabularyProvider vocabProvider;
  late ThemeProvider themeProvider;
  final today = DateTime(2026, 8, 18, 10);

  setUp(() async {
    repo = await SqliteVocabularyRepository.open(
      path: inMemoryDatabasePath,
      now: () => today,
    );

    Future<void> seed(String id, String word, String meaning) {
      return repo.insert(
        VocabularyWord.create(
          id: id,
          word: word,
          meaning: meaning,
          date: '2026-08-18',
          now: today,
        ),
      );
    }

    await seed('1', 'resilient', 'kiên cường');
    await seed('2', 'brittle', 'dễ vỡ');
    await seed('3', 'ergonomic', 'tiện dụng');
    await seed('4', 'tenacious', 'bền bỉ');

    vocabProvider = VocabularyProvider(repo, now: () => today);
    await vocabProvider.init();
    themeProvider = ThemeProvider();
  });

  tearDown(() => repo.close());

  Widget buildApp(Widget child) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: vocabProvider),
        ChangeNotifierProvider.value(value: themeProvider),
        ChangeNotifierProvider(create: (_) => TtsService()),
      ],
      child: MaterialApp(theme: PixelTheme.light(), home: child),
    );
  }

  testWidgets('ArcadeScreen displays 2 arcade game options', (tester) async {
    await tester.pumpWidget(buildApp(const ArcadeScreen()));
    await tester.pump();

    expect(find.text('ARCADE CENTER'), findsOneWidget);
    expect(find.text('WORD RUSH 60S'), findsOneWidget);
    expect(find.text('VOCAB SNAKE'), findsOneWidget);
  });

  testWidgets('WordRushGame launches and displays timer and score', (tester) async {
    await tester.pumpWidget(buildApp(const WordRushGame()));
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pump();

    expect(find.text('WORD RUSH 60S'), findsOneWidget);
    expect(find.textContaining('⏱'), findsOneWidget);
    expect(find.textContaining('SCORE:'), findsOneWidget);
  });

  testWidgets('VocabSnakeGame launches and shows D-Pad and grid', (tester) async {
    await tester.pumpWidget(buildApp(const VocabSnakeGame()));
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pump();

    expect(find.text('VOCAB SNAKE'), findsOneWidget);
    expect(find.text('STEER SNAKE TO EAT:'), findsOneWidget);
  });
}
