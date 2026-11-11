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
import 'package:veea_english_app/widgets/native_gate_settings.dart';

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

  group('App Gate keyboard activation', () {
    testWidgets(
      'waits for resume, restores input, and retries a hidden keyboard',
      (tester) async {
        tester.view.physicalSize = const Size(800, 1600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final binding = tester.binding;
        binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        await tester.pumpWidget(
          buildTestApp(AppGateScreen(targetApp: 'X', initialWord: sampleWord)),
        );
        await tester.pumpAndSettle();
        expect(tester.testTextInput.isVisible, isFalse);

        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await tester.pumpAndSettle();
        final input = find.byKey(const Key('app_gate_input'));
        expect(tester.widget<TextField>(input).focusNode!.hasFocus, isTrue);
        expect(tester.testTextInput.isVisible, isTrue);
        await tester.enterText(input, 'pre');

        binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        await tester.pumpAndSettle();
        expect(tester.widget<TextField>(input).focusNode!.hasFocus, isFalse);
        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await tester.pumpAndSettle();
        expect(tester.widget<TextField>(input).controller!.text, 'pre');
        expect(tester.testTextInput.isVisible, isTrue);

        tester.testTextInput.hide();
        await tester.tap(input);
        await tester.pumpAndSettle();
        expect(tester.testTextInput.isVisible, isTrue);
        tester.testTextInput.hide();
        await tester.tap(input);
        await tester.pumpAndSettle();
        expect(tester.testTextInput.isVisible, isTrue);
      },
    );

    testWidgets(
      'a daily notebook goal does not block the challenge or keyboard',
      (tester) async {
        tester.view.physicalSize = const Size(800, 1600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.runAsync(() async {
          await gateProvider.setDailyWordGoal(true);
          await repo.update(sampleWord.copyWith(date: '2026-08-20'));
          await vocabProvider.init();
        });
        await tester.pumpWidget(
          buildTestApp(AppGateScreen(targetApp: 'X', initialWord: sampleWord)),
        );
        await tester.pumpAndSettle();
        expect(vocabProvider.todayWordCount, 0);
        expect(find.byKey(const Key('app_gate_input')), findsOneWidget);
        expect(tester.testTextInput.isVisible, isTrue);
      },
    );
  });

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

  group('AppGateProvider earned passes', () {
    test(
      'Every Open passes zero to native and does not invent a timed pass',
      () async {
        await gateProvider.setPassDurationMinutes(0);
        await gateProvider.completeGateChallenge(
          wordId: sampleWord.id,
          targetApp: 'X',
          attempts: 0,
        );
        expect(gateProvider.unlockedUntilFor('X'), isNull);
        final grant = channelCalls.lastWhere(
          (call) => call.method == 'grantPass',
        );
        expect((grant.arguments as Map)['durationMinutes'], 0);
      },
    );

    test('timed pass is tracked for the earned app only', () async {
      await gateProvider.setPassDurationMinutes(5);
      await gateProvider.completeGateChallenge(
        wordId: sampleWord.id,
        targetApp: 'X',
        attempts: 0,
      );
      expect(
        gateProvider.unlockedUntilFor('x'),
        today.add(const Duration(minutes: 5)),
      );
      expect(gateProvider.unlockedUntilFor('YouTube'), isNull);
    });
  });

  group('Native Screen Time setup and unlock failures', () {
    const nativeTarget = 'native:00000000-0000-0000-0000-000000000001';

    void useNativeHost({
      bool deny = false,
      bool cancel = false,
      bool failGrant = false,
    }) {
      var authorized = false;
      var selected = false;
      var enabled = false;
      Map<String, dynamic> status() => {
        'supported': true,
        'available': true,
        'authorized': authorized,
        'enabled': enabled,
        'passMinutes': 15,
        'applications': selected
            ? [
                {'id': nativeTarget, 'label': 'Protected app 1'},
              ]
            : [],
      };
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel(AppGateService.channelName),
            (call) async {
              channelCalls.add(call);
              switch (call.method) {
                case 'requestScreenTimeAuthorization':
                  if (deny) {
                    throw PlatformException(
                      code: 'DENIED',
                      message: 'Screen Time access was not allowed.',
                    );
                  }
                  authorized = true;
                  return status();
                case 'chooseScreenTimeApplications':
                  selected = !cancel;
                  return !cancel;
                case 'getScreenTimeStatus':
                  return status();
                case 'setScreenTimeEnabled':
                  enabled = (call.arguments as Map)['enabled'] == true;
                  return status();
                case 'grantPass':
                  if (failGrant) {
                    throw PlatformException(
                      code: 'MONITOR_FAILED',
                      message: 'Could not schedule this unlock.',
                    );
                  }
                  return null;
                default:
                  return null;
              }
            },
          );
    }

    testWidgets('unavailable build clearly retains Shortcut setup', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildTestApp(
          Scaffold(
            body: SingleChildScrollView(
              child: NativeGateSettings(gate: gateProvider, totalWords: 3),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('not available in this build'),
        findsOneWidget,
      );
      expect(find.text('Set up Screen Time'), findsNothing);
    });

    testWidgets(
      'native settings show protection and only supported timed passes',
      (tester) async {
        useNativeHost();
        await tester.runAsync(
          () => gateProvider.enableNativeProtection(totalWords: 3),
        );
        await tester.pumpWidget(
          buildTestApp(
            Scaffold(
              body: SingleChildScrollView(
                child: NativeGateSettings(gate: gateProvider, totalWords: 3),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Your apps · 1'), findsOneWidget);
        expect(find.text('15 min'), findsOneWidget);
        expect(find.text('Default unlock time'), findsOneWidget);
        expect(find.byType(ChoiceChip), findsNothing);
        expect(find.textContaining(nativeTarget), findsNothing);
        expect(find.text('Lock selected apps'), findsOneWidget);
      },
    );

    test(
      'authorization then picker then enable, without changing Shortcut duration',
      () async {
        useNativeHost();
        await gateProvider.setPassDurationMinutes(0);
        channelCalls.clear();
        expect(
          await gateProvider.enableNativeProtection(totalWords: 3),
          isTrue,
        );
        expect(gateProvider.nativeStatus.enabled, isTrue);
        expect(gateProvider.nativeStatus.applications.single.id, nativeTarget);
        expect(gateProvider.config.passDurationMinutes, 0);
        expect(channelCalls.map((c) => c.method), [
          'requestScreenTimeAuthorization',
          'chooseScreenTimeApplications',
          'getScreenTimeStatus',
          'setScreenTimeEnabled',
        ]);
        final enable = channelCalls.last.arguments as Map;
        expect(enable['passMinutes'], 15);
        expect(gateProvider.displayNameForApp(nativeTarget), 'Protected app 1');
        expect(await gateProvider.disableNativeProtection(), isTrue);
        expect(gateProvider.nativeStatus.enabled, isFalse);
      },
    );

    test(
      'permission denial never enables protection or fabricates success',
      () async {
        useNativeHost(deny: true);
        channelCalls.clear();
        expect(
          await gateProvider.enableNativeProtection(totalWords: 3),
          isFalse,
        );
        expect(gateProvider.nativeStatus.enabled, isFalse);
        expect(gateProvider.nativeError, contains('not allowed'));
        expect(channelCalls.map((c) => c.method), [
          'requestScreenTimeAuthorization',
        ]);
      },
    );

    test('cancelled selection never enables protection', () async {
      useNativeHost(cancel: true);
      channelCalls.clear();
      expect(await gateProvider.enableNativeProtection(totalWords: 3), isFalse);
      expect(
        channelCalls.any((c) => c.method == 'setScreenTimeEnabled'),
        isFalse,
      );
    });

    test('insufficient vocabulary does not request permission', () async {
      useNativeHost();
      channelCalls.clear();
      expect(await gateProvider.enableNativeProtection(totalWords: 1), isFalse);
      expect(channelCalls, isEmpty);
    });

    test(
      'failed native scheduling does not record a completed unlock',
      () async {
        useNativeHost(failGrant: true);
        await expectLater(
          gateProvider.completeGateChallenge(
            wordId: sampleWord.id,
            targetApp: nativeTarget,
            attempts: 0,
          ),
          throwsA(isA<PlatformException>()),
        );
        expect(await repo.recentGateLogs(), isEmpty);
        expect(gateProvider.unlockedUntilFor(nativeTarget), isNull);
      },
    );
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
        expect(channelCalls.any((c) => c.method == 'setGateEnabled'), isTrue);
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
        expect(find.text('Learn to unlock'), findsOneWidget);
        expect(find.text('Locked · Instagram'), findsOneWidget);
        expect(find.text('sơ bộ, mở đầu (trước phần chính)'), findsOneWidget);
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
        await tester.tap(find.text('Unlock Instagram'));
        await tester.pumpAndSettle();

        // --- Stage 1: IPA + Audio + 2nd letter revealed ---
        expect(find.text('p r _ _ _ _ _ _ _ _ y'), findsOneWidget);
        expect(find.text('IPA: /prɪˈlɪməˌnɛri/'), findsOneWidget);
        expect(find.text('Hear it'), findsOneWidget);
        expect(
          find.text('Missed once · IPA + audio + 2nd letter unlocked'),
          findsOneWidget,
        );

        // Submit wrong answer #2 -> transitions to Stage 2 ("Teach & Retype")
        await tester.enterText(inputFinder, 'wrongtwo');
        await tester.tap(find.text('Unlock Instagram'));
        await tester.pumpAndSettle();

        // --- Stage 2: Full word shown initially ---
        expect(find.text('Attempt 2 failed · Memorise & type'), findsOneWidget);
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

        expect(find.text('Attempt 2 failed · Memorise & type'), findsNothing);
        expect(
          find.text('Answer hidden. Finish typing 11 letters from memory, or'),
          findsOneWidget,
        );
        expect(find.text('peek again'), findsOneWidget);

        // Tapping "peek again" clears input and re-shows the word
        await tester.tap(find.text('peek again'));
        await tester.pump();
        expect(find.text('Attempt 2 failed · Memorise & type'), findsOneWidget);
        expect(find.text('preliminary'), findsOneWidget);

        // Now type full word and submit -> Unlocks!
        await tester.enterText(inputFinder, 'preliminary');
        await tester.pump();
        await tester.runAsync(() async {
          await tester.tap(find.text('Unlock Instagram'));
          await Future<void>.delayed(const Duration(milliseconds: 50));
        });
        await tester.pumpAndSettle();

        // --- Unlocked state ---
        expect(find.text('Unlocked · 15:00 PASS'), findsOneWidget);
        expect(find.text('3 tries · Re-queued'), findsOneWidget);
        expect(find.text('Continue to Instagram'), findsOneWidget);

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
      'first-launch Settings exposes native protection without Shortcut setup',
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

        await tester.tap(find.byKey(const Key('settings_app_protection')));
        await tester.pumpAndSettle();
        expect(
          find.textContaining('App protection is available on iPhone'),
          findsOneWidget,
        );
        expect(find.text('Shortcut protection'), findsNothing);
        expect(find.text('Pick Apps to Gate'), findsNothing);
        expect(find.text('Every time I open an app'), findsNothing);
        expect(find.text('Learning rules'), findsOneWidget);
        expect(
          channelCalls.where((call) => call.method == 'getInstalledApps'),
          isEmpty,
        );
      },
    );

    testWidgets(
      'LockFeed-style multi-word challenge (wordsPerUnlock=2) & phone app scan + auto-launch',
      (tester) async {
        tester.view.physicalSize = const Size(800, 1600);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final secondWord = VocabularyWord(
          id: 'w_resilient',
          word: 'resilient',
          meaning: 'kiên cường',
          pronunciation: '/rɪˈzɪliənt/',
          partOfSpeech: PartOfSpeech.adjective,
          date: '2026-08-21',
          createdAt: today,
          updatedAt: today,
        );
        await tester.runAsync(() async {
          await repo.insert(secondWord);
          await vocabProvider.init();
          await gateProvider.setWordsPerUnlock(2);
        });

        await tester.pumpWidget(
          buildTestApp(const AppGateScreen(targetApp: 'Facebook')),
        );
        await tester.pumpAndSettle();

        // Step 1 of 2 shown
        expect(find.text('WORD 1/2'), findsOneWidget);
        expect(find.text('Locked · Facebook'), findsOneWidget);

        // Solve word 1
        final inputFinder = find.byKey(const Key('app_gate_input'));
        final firstWordText =
            find.text('sơ bộ, mở đầu (trước phần chính)').evaluate().isNotEmpty
            ? 'preliminary'
            : 'resilient';
        final secondWordText = firstWordText == 'preliminary'
            ? 'resilient'
            : 'preliminary';

        await tester.enterText(inputFinder, firstWordText);
        await tester.runAsync(() async {
          await tester.tap(find.text('Unlock Facebook'));
          await Future<void>.delayed(const Duration(milliseconds: 50));
        });
        await tester.pumpAndSettle();

        // Advances to Word 2/2 without granting final pass yet
        expect(find.text('WORD 2/2'), findsOneWidget);
        expect(channelCalls.any((c) => c.method == 'grantPass'), isFalse);

        // Solve word 2 -> grants pass and calls native launchApp('Facebook')
        await tester.enterText(inputFinder, secondWordText);
        await tester.runAsync(() async {
          await tester.tap(find.text('Unlock Facebook'));
          await Future<void>.delayed(const Duration(milliseconds: 50));
        });
        await tester.pumpAndSettle();

        expect(channelCalls.any((c) => c.method == 'grantPass'), isTrue);
        expect(
          channelCalls.any(
            (c) =>
                c.method == 'launchApp' &&
                (c.arguments as Map)['targetApp'] == 'Facebook',
          ),
          isTrue,
        );
      },
    );
  });
}
