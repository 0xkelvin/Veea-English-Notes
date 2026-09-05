import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:veea_english_app/core/theme/pixel_theme.dart';
import 'package:veea_english_app/data/local/sqlite_vocabulary_repository.dart';
import 'package:veea_english_app/models/word_challenge.dart';
import 'package:veea_english_app/providers/vocabulary_provider.dart';
import 'package:veea_english_app/services/friend_challenge_service.dart';
import 'package:veea_english_app/services/tts_service.dart';
import 'package:veea_english_app/widgets/word_drop_overlay.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late SqliteVocabularyRepository repo;
  late VocabularyProvider vocabProvider;
  late FriendChallengeService challengeService;
  final today = DateTime(2026, 8, 18, 10);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    repo = await SqliteVocabularyRepository.open(
      path: inMemoryDatabasePath,
      now: () => today,
    );
    vocabProvider = VocabularyProvider(repo, now: () => today);
    await vocabProvider.init();

    challengeService = FriendChallengeService(prefs: prefs, random: Random(42));
    await challengeService.init();
  });

  tearDown(() => repo.close());

  Widget wrap(Widget child) => MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: vocabProvider),
      ChangeNotifierProvider.value(value: challengeService),
      ChangeNotifierProvider(create: (_) => TtsService()),
    ],
    child: MaterialApp(
      theme: PixelTheme.light(),
      home: Scaffold(body: child),
    ),
  );

  testWidgets('WordDropOverlay displays challenge and handles correct answer', (tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    final challenge = WordChallenge(
      id: 'c1',
      senderId: 'alex',
      senderName: 'Alex',
      targetWord: 'resilient',
      targetMeaning: 'kiên cường',
      partOfSpeech: 'ADJ',
      mode: ChallengeMode.vnToEn,
      options: ['resilient', 'reluctant', 'eloquent', 'vulnerable'],
      correctAnswer: 'resilient',
      createdAt: DateTime.now(),
    );

    await tester.pumpWidget(wrap(WordDropOverlay(challenge: challenge)));
    await tester.pump();

    // Verify incoming challenge header & clue
    expect(find.text('INCOMING WORD DROP!'), findsOneWidget);
    expect(find.text('ALEX'), findsOneWidget);
    expect(find.text('kiên cường'), findsOneWidget);
    expect(find.text('ADJ'), findsOneWidget);

    // Verify all 4 options are rendered
    expect(find.text('resilient'), findsOneWidget);
    expect(find.text('reluctant'), findsOneWidget);
    expect(find.text('eloquent'), findsOneWidget);
    expect(find.text('vulnerable'), findsOneWidget);

    // Tap the correct option
    await tester.tap(find.text('resilient'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // Verify victory result view
    expect(find.text('★ CORRECT! ★'), findsOneWidget);
    expect(find.text('RESILIENT'), findsOneWidget);
    expect(find.text('CHALLENGE BACK ⚡'), findsOneWidget);
  });

  testWidgets('WordDropOverlay allows 1-tap save to notebook on wrong answer', (tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    final challenge = WordChallenge(
      id: 'c2',
      senderId: 'alex',
      senderName: 'Alex',
      targetWord: 'bottleneck',
      targetMeaning: 'điểm nghẽn',
      partOfSpeech: 'NOUN',
      mode: ChallengeMode.vnToEn,
      options: ['bottleneck', 'redundant', 'mitigate', 'scalability'],
      correctAnswer: 'bottleneck',
      createdAt: DateTime.now(),
    );

    await tester.pumpWidget(wrap(WordDropOverlay(challenge: challenge)));
    await tester.pump();

    // Tap wrong option
    await tester.tap(find.text('redundant'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // Verify wrong answer view
    expect(find.text('✖ INCORRECT!'), findsOneWidget);
    expect(find.text('+ SAVE TO MY JOURNAL'), findsOneWidget);

    // Tap save to notebook
    await tester.runAsync(() async {
      await tester.tap(find.text('+ SAVE TO MY JOURNAL'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();

    expect(find.text('SAVED TO JOURNAL!'), findsOneWidget);
    expect(vocabProvider.words.any((w) => w.word == 'bottleneck'), isTrue);
  });
}
