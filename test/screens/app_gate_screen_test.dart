import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:veea_english_app/core/theme/pixel_theme.dart';
import 'package:veea_english_app/data/local/sqlite_vocabulary_repository.dart';
import 'package:veea_english_app/models/gate_config.dart';
import 'package:veea_english_app/models/part_of_speech.dart';
import 'package:veea_english_app/models/vocabulary_word.dart';
import 'package:veea_english_app/providers/app_gate_provider.dart';
import 'package:veea_english_app/providers/cartridge_provider.dart';
import 'package:veea_english_app/providers/theme_provider.dart';
import 'package:veea_english_app/providers/vocabulary_provider.dart';
import 'package:veea_english_app/providers/widget_provider.dart';
import 'package:veea_english_app/screens/app_gate_screen.dart';
import 'package:veea_english_app/screens/settings_screen.dart';
import 'package:veea_english_app/services/app_gate_service.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  final today = DateTime(2026, 8, 21, 10, 0);
  late SqliteVocabularyRepository repo;
  late VocabularyProvider vocabProvider;
  late AppGateProvider gateProvider;
  late List<MethodCall> channelCalls;

  final sampleWord = VocabularyWord(
    id: 'w_preliminary',
    word: 'preliminary',
    meaning: 'sơ bộ, mở đầu (trước phần chính)',
    pronunciation: '/prɪˈlɪməˌnɛri/',
    partOfSpeech: PartOfSpeech.adjective,
    source: 'Article · Reuters',
    examples: const [
      'Wait for the preliminary results before changing the plan.',
    ],
    date: '2026-08-21',
    createdAt: today,
    updatedAt: today,
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    channelCalls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel(AppGateService.channelName),
          (call) async {
            channelCalls.add(call);
            if (call.method == 'requestPermissions') return true;
            if (call.method == 'pickAppsToGate') {
              return <String>['Instagram', 'X'];
            }
            return null;
          },
        );

    repo = await SqliteVocabularyRepository.open(
      path: inMemoryDatabasePath,
      now: () => today,
    );
    await repo.insert(sampleWord);

    vocabProvider = VocabularyProvider(repo, now: () => today);
    await vocabProvider.init();

    gateProvider = AppGateProvider(repository: repo, now: () => today);
    await gateProvider.init();
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel(AppGateService.channelName),
          null,
        );
    gateProvider.dispose();
    vocabProvider.dispose();
    await repo.close();
  });

  Widget buildTestApp(Widget child) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: vocabProvider),
        ChangeNotifierProvider.value(value: gateProvider),
      ],
      child: MaterialApp(theme: PixelTheme.light(), home: child),
    );
  }

  group('GateMaskHelper', () {
    test('builds Stage 0 and Stage 1 masks accurately', () {
      expect(
        GateMaskHelper.buildMask('preliminary', 0),
        'p _ _ _ _ _ _ _ _ _ y',
      );
      expect(
        GateMaskHelper.buildMask('preliminary', 1),
        'p r _ _ _ _ _ _ _ _ y',
      );
    });

    test('blanks case-insensitive word occurrences in example sentence', () {
      expect(
        GateMaskHelper.blankWordInSentence(
          'Wait for the Preliminary results.',
          'preliminary',
        ),
        'Wait for the ___________ results.',
      );
    });
  });

  group('AppGateProvider guardrails', () {
    test(
      'blocks enabling App Gate when fewer than 3 words are saved',
      () async {
        // Only 1 word is currently in repo
        final ok = await gateProvider.setEnabled(true, totalWords: 1);
        expect(ok, isFalse);
        expect(gateProvider.config.enabled, isFalse);
        expect(gateProvider.lastError, contains('at least 3 words'));

        // With 3 words, enabling succeeds and invokes native setGateEnabled
        final ok3 = await gateProvider.setEnabled(true, totalWords: 3);
        expect(ok3, isTrue);
        expect(gateProvider.config.enabled, isTrue);
        expect(
          channelCalls.any((c) => c.method == 'setGateEnabled'),
          isTrue,
        );
      },
    );
  });

  group('AppGateScreen 3-Stage Challenge State Machine', () {
    testWidgets(
      'Stage 0 -> Stage 1 -> Stage 2 (Teach & Retype hides on first keystroke) -> Unlock',
      (tester) async {
        tester.view.physicalSize = const Size(800, 1600);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(
          buildTestApp(const AppGateScreen(targetApp: 'Instagram')),
        );
        await tester.pumpAndSettle();

        // --- Stage 0: Initial Prompt ---
        expect(find.text('VEEA GATE'), findsOneWidget);
        expect(find.text('LOCKED · INSTAGRAM'), findsOneWidget);
        expect(
          find.text('sơ bộ, mở đầu (trước phần chính)'),
          findsOneWidget,
        );
        expect(
          find.text(
            '"Wait for the ___________ results before changing the plan."',
          ),
          findsOneWidget,
        );
        expect(find.text('p _ _ _ _ _ _ _ _ _ y'), findsOneWidget);
        expect(find.text('11 letters'), findsOneWidget);
        expect(find.textContaining('IPA:'), findsNothing);

        // Submit wrong answer #1 -> transitions to Stage 1
        final inputFinder = find.byKey(const Key('app_gate_input'));
        await tester.enterText(inputFinder, 'wrongone');
        await tester.tap(find.text('UNLOCK INSTAGRAM'));
        await tester.pumpAndSettle();

        // --- Stage 1: IPA + Audio + 2nd letter revealed ---
        expect(find.text('p r _ _ _ _ _ _ _ _ y'), findsOneWidget);
        expect(find.text('IPA: /prɪˈlɪməˌnɛri/'), findsOneWidget);
        expect(find.text('HEAR IT'), findsOneWidget);
        expect(
          find.text('Missed once · IPA + audio + 2nd letter unlocked'),
          findsOneWidget,
        );

        // Submit wrong answer #2 -> transitions to Stage 2 ("Teach & Retype")
        await tester.enterText(inputFinder, 'wrongtwo');
        await tester.tap(find.text('UNLOCK INSTAGRAM'));
        await tester.pumpAndSettle();

        // --- Stage 2: Full word shown initially ---
        expect(
          find.text('Attempt 2 failed · Memorise & type'),
          findsOneWidget,
        );
        expect(find.text('preliminary'), findsOneWidget);
        expect(
          find.text(
            'Start typing below — the answer hides on your first keystroke.',
          ),
          findsOneWidget,
        );

        // Crucial rule: typing first character hides the full word immediately!
        await tester.enterText(inputFinder, 'p');
        await tester.pump();

        expect(
          find.text('Attempt 2 failed · Memorise & type'),
          findsNothing,
        );
        expect(
          find.text(
            'Answer hidden. Finish typing 11 letters from memory, or',
          ),
          findsOneWidget,
        );
        expect(find.text('peek again'), findsOneWidget);

        // Tapping "peek again" clears input and re-shows the word
        await tester.tap(find.text('peek again'));
        await tester.pump();
        expect(
          find.text('Attempt 2 failed · Memorise & type'),
          findsOneWidget,
        );
        expect(find.text('preliminary'), findsOneWidget);

        // Now type full word and submit -> Unlocks!
        await tester.enterText(inputFinder, 'preliminary');
        await tester.pump();
        await tester.runAsync(() async {
          await tester.tap(find.text('UNLOCK INSTAGRAM'));
          await Future<void>.delayed(const Duration(milliseconds: 50));
        });
        await tester.pumpAndSettle();

        // --- Unlocked state ---
        expect(find.text('UNLOCKED · 15:00 PASS'), findsOneWidget);
        expect(find.text('3 tries · Re-queued'), findsOneWidget);
        expect(find.text('CONTINUE TO INSTAGRAM'), findsOneWidget);

        // Verify native grantPass was called and SQLite word was marked lastGateFailed = true
        expect(channelCalls.any((c) => c.method == 'grantPass'), isTrue);
        final updatedWord = await tester.runAsync(
          () => repo.findById('w_preliminary'),
        );
        expect(updatedWord?.srsStage, 0);
        expect(updatedWord?.lastGateFailed, isTrue);
      },
    );

    testWidgets(
      'SettingsScreen allows user to select and customize gated apps via Pick Apps to Gate dialog',
      (tester) async {
        tester.view.physicalSize = const Size(800, 4200);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(
          MultiProvider(
            providers: [
              ChangeNotifierProvider.value(value: vocabProvider),
              ChangeNotifierProvider.value(value: gateProvider),
              ChangeNotifierProvider(create: (_) => ThemeProvider()),
              ChangeNotifierProvider(create: (_) => WidgetProvider()),
              ChangeNotifierProvider(create: (_) => CartridgeProvider()),
            ],
            child: MaterialApp(
              theme: PixelTheme.light(),
              home: const SettingsScreen(),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('APP GATE ("WORD TOLL")'), findsOneWidget);
        expect(find.text('PICK APPS TO GATE'), findsOneWidget);

        await tester.runAsync(() async {
          await tester.tap(find.text('PICK APPS TO GATE'));
          await Future<void>.delayed(const Duration(milliseconds: 50));
        });
        await tester.pumpAndSettle();

        expect(find.text('SELECT APPS TO GATE'), findsOneWidget);

        // Filter for Facebook in the picker search field and select it
        await tester.enterText(
          find.widgetWithText(TextField, 'Filter apps (e.g. Instagram, TikTok)…'),
          'Face',
        );
        await tester.pump();
        expect(find.text('Facebook'), findsOneWidget);

        await tester.tap(find.text('Facebook'));
        await tester.pump();

        // Save selection
        await tester.runAsync(() async {
          await tester.tap(find.textContaining('SAVE ('));
          await Future<void>.delayed(const Duration(milliseconds: 50));
        });
        await tester.pumpAndSettle();

        expect(gateProvider.config.gatedApps, contains('Facebook'));
      },
    );
  });
}
