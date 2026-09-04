import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:veea_english_app/core/theme/pixel_theme.dart';
import 'package:veea_english_app/data/local/sqlite_vocabulary_repository.dart';
import 'package:veea_english_app/providers/vocabulary_provider.dart';
import 'package:veea_english_app/screens/pixel_link_screen.dart';
import 'package:veea_english_app/services/friend_challenge_service.dart';
import 'package:veea_english_app/services/tts_service.dart';

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

  testWidgets('PixelLinkScreen displays friend code and linked friends list', (tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(wrap(const PixelLinkScreen()));
    await tester.pump();

    // Verify Title and Friend Code
    expect(find.text('PIXEL LINK // BẮN TỪ BẠN BÈ'), findsOneWidget);
    expect(find.text('MÃ GAME LINK CỦA BẠN'), findsOneWidget);
    expect(find.text('COPY MÃ'), findsOneWidget);

    // Verify Friends List
    expect(find.textContaining('BẠN BÈ ĐÃ KẾT NỐI'), findsOneWidget);
    expect(find.text('Alex (Senior FE)'), findsOneWidget);
    expect(find.text('Quốc (DevOps)'), findsOneWidget);

    // Verify simulator button
    expect(find.text('TEST ⚡'), findsOneWidget);
  });
}
