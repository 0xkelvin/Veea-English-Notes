import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:veea_english_app/core/theme/pixel_theme.dart';
import 'package:veea_english_app/data/local/sqlite_vocabulary_repository.dart';
import 'package:veea_english_app/models/vocabulary_word.dart';
import 'package:veea_english_app/providers/app_gate_provider.dart';
import 'package:veea_english_app/providers/vocabulary_provider.dart';
import 'package:veea_english_app/screens/app_gate_screen.dart';
import 'package:veea_english_app/screens/learning_rules_screen.dart';
import 'package:veea_english_app/screens/selected_practice_words_screen.dart';
import 'package:veea_english_app/services/app_gate_service.dart';
import 'package:veea_english_app/widgets/gate_learning_settings.dart';
import 'package:veea_english_app/widgets/native_gate_settings.dart';
import 'package:veea_english_app/widgets/native_gate_return_hint.dart';
import 'package:veea_english_app/main.dart';
import 'package:veea_english_app/data/remote/api_client.dart';
import 'package:veea_english_app/data/remote/auth_api.dart';
import 'package:veea_english_app/data/remote/token_store.dart';
import 'package:veea_english_app/data/remote/vocabulary_api.dart';
import 'package:veea_english_app/providers/auth_provider.dart';
import 'package:veea_english_app/providers/theme_provider.dart';
import 'package:veea_english_app/services/pronunciation_service.dart';
import 'package:veea_english_app/services/sync_service.dart';
import 'package:veea_english_app/widgets/practice_word_picker.dart';
import 'package:veea_english_app/services/tts_service.dart';

class _RecordingTts extends TtsService {
  final spoken = <String>[];
  @override
  Future<void> speak(String word) async {
    spoken.add(word);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('flutter_tts'),
        (call) async => 1,
      );
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  const target = 'native:00000000-0000-0000-0000-000000000001';
  late DateTime now;
  late SqliteVocabularyRepository repo;
  late AppGateProvider gate;
  late VocabularyProvider vocab;
  late List<MethodCall> calls;
  late List<VocabularyWord> words;
  late _RecordingTts speech;
  var nativeMinutes = 15;
  var authorized = false;
  var configured = false;
  var enabled = false;
  var failGrant = false;
  DateTime? expiry;
  Map<String, Object?> status() => {
    'supported': true,
    'available': true,
    'authorized': authorized,
    'enabled': enabled,
    'configured': configured,
    'passMinutes': nativeMinutes,
    'applications': [
      {
        'id': target,
        'label': 'Protected app 1',
        'unlockedUntil': expiry == null
            ? 0
            : expiry!.millisecondsSinceEpoch / 1000,
      },
    ],
  };

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    now = DateTime(2026, 11, 7, 10);
    calls = [];
    speech = _RecordingTts();
    authorized = false;
    configured = false;
    enabled = false;
    failGrant = false;
    nativeMinutes = 15;
    expiry = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel(AppGateService.channelName),
          (call) async {
            calls.add(call);
            switch (call.method) {
              case 'getScreenTimeStatus':
                return status();
              case 'requestScreenTimeAuthorization':
                authorized = true;
                return status();
              case 'setScreenTimeEnabled':
                configured = enabled =
                    (call.arguments as Map)['enabled'] == true;
                return status();
              case 'setScreenTimeDuration':
                nativeMinutes = (call.arguments as Map)['passMinutes'] as int;
                return status();
              case 'grantPass':
                if (failGrant) {
                  throw PlatformException(
                    code: 'MONITOR_FAILED',
                    message: 'Please retry your unlock.',
                  );
                }
                if ((call.arguments as Map)['targetApp'] == target) {
                  expiry = now.add(const Duration(minutes: 15));
                  return status();
                }
                return null;
              case 'revokePass':
                if ((call.arguments as Map)['targetApp'] == target) {
                  expiry = null;
                }
                return null;
              default:
                return null;
            }
          },
        );
    repo = await SqliteVocabularyRepository.open(
      path: inMemoryDatabasePath,
      now: () => now,
    );
    words = [
      for (final entry in [
        ('a', 'resilient'),
        ('b', 'curious'),
        ('c', 'patient'),
      ])
        VocabularyWord.create(
          id: entry.$1,
          word: entry.$2,
          meaning: 'Meaning ${entry.$1}',
          date: '2026-11-07',
          now: now,
        ),
    ];
    for (final word in words) {
      await repo.insert(word);
    }
    gate = AppGateProvider(repository: repo, now: () => now);
    await gate.init();
    vocab = VocabularyProvider(repo, now: () => now);
    await vocab.init();
  });

  tearDown(() async {
    gate.dispose();
    speech.dispose();
    vocab.dispose();
    await repo.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel(AppGateService.channelName),
          null,
        );
  });

  Widget app(Widget child, {ThemeData? theme, TextScaler? textScaler}) =>
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: gate),
          ChangeNotifierProvider.value(value: vocab),
          ChangeNotifierProvider<TtsService>.value(value: speech),
        ],
        child: MaterialApp(
          theme: theme ?? PixelTheme.light(),
          builder: textScaler == null
              ? null
              : (context, child) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(textScaler: textScaler),
                  child: child!,
                ),
          home: child,
        ),
      );

  test(
    'interrupted round survives provider restart and excludes solved words for its app only',
    () async {
      await gate.setWordsPerUnlock(3);
      await gate.recordStepCompletion(wordId: 'a', targetApp: 'X', attempts: 0);
      gate.dispose();
      gate = AppGateProvider(repository: repo, now: () => now);
      await gate.init();
      expect(gate.progressForApp(' x '), 1);
      expect(gate.solvedWordIdsForApp('X'), {'a'});
      expect((await gate.selectGateWord(targetApp: 'X'))!.id, isNot('a'));
      expect(gate.progressForApp('YouTube'), 0);
      expect(calls.where((c) => c.method == 'grantPass'), isEmpty);
    },
  );

  test(
    'retrying an already saved step cannot award learning credit twice',
    () async {
      await repo.recordGateCompletion(
        wordId: 'a',
        targetApp: 'X',
        attempts: 0,
        completesRound: false,
      );
      await repo.recordGateCompletion(
        wordId: 'a',
        targetApp: 'x',
        attempts: 0,
        completesRound: false,
      );
      expect((await repo.findById('a'))!.srsStage, 1);
      expect((await repo.gateRoundProgress())['x'], {'a'});
      expect(await repo.recentGateLogs(), hasLength(1));
    },
  );

  test(
    'early unlock and a failed final grant preserve the completed round steps',
    () async {
      await gate.setWordsPerUnlock(2);
      await expectLater(
        gate.completeGateChallenge(wordId: 'a', targetApp: 'X', attempts: 0),
        throwsA(isA<PlatformException>()),
      );
      expect(calls.where((c) => c.method == 'grantPass'), isEmpty);
      await gate.recordStepCompletion(wordId: 'a', targetApp: 'X', attempts: 0);
      failGrant = true;
      await expectLater(
        gate.completeGateChallenge(wordId: 'b', targetApp: 'X', attempts: 0),
        throwsA(isA<PlatformException>()),
      );
      expect(gate.progressForApp('X'), 2);
      expect((await repo.gateRoundProgress())['x'], {'a'});
      expect((await repo.pendingGateAnswers())['x']!.wordId, 'b');
      expect((await repo.findById('b'))!.srsStage, 0);
      failGrant = false;
      await gate.completeGateChallenge(
        wordId: 'b',
        targetApp: 'X',
        attempts: 0,
      );
      expect(gate.progressForApp('X'), 0);
      expect(await repo.gateRoundProgress(), isEmpty);
      expect(gate.unlockedUntilFor('YouTube'), isNull);
    },
  );

  test(
    'native expiry is restored from iOS and expires at the exact boundary',
    () async {
      authorized = enabled = configured = true;
      expiry = now.add(const Duration(minutes: 4));
      await gate.refreshNativeScreenTime();
      expect(gate.unlockedUntilFor(target), expiry);
      gate.dispose();
      gate = AppGateProvider(repository: repo, now: () => now);
      await gate.init();
      expect(gate.unlockedUntilFor(target), expiry);
      now = expiry!;
      expect(gate.unlockedUntilFor(target), isNull);
    },
  );

  test(
    'the final correct answer survives restart and keeps its original hint grade on retry',
    () async {
      await gate.setWordsPerUnlock(2);
      await gate.recordStepCompletion(wordId: 'a', targetApp: 'X', attempts: 0);
      failGrant = true;
      await expectLater(
        gate.completeGateChallenge(wordId: 'b', targetApp: 'X', attempts: 2),
        throwsA(isA<PlatformException>()),
      );
      gate.dispose();
      gate = AppGateProvider(repository: repo, now: () => now);
      await gate.init();
      expect(gate.progressForApp('X'), 2);
      expect(gate.cachedGateWord('X')!.id, 'b');
      failGrant = false;
      await gate.completeGateChallenge(
        wordId: 'b',
        targetApp: 'X',
        attempts: 0,
      );
      expect((await repo.findById('b'))!.lastGateFailed, isTrue);
      expect(
        (await repo.recentGateLogs())
            .firstWhere((log) => log.wordId == 'b')
            .attempts,
        2,
      );
      expect(await repo.pendingGateAnswers(), isEmpty);
    },
  );

  test(
    'changing the rule preserves a pending answer as a completed step',
    () async {
      await gate.setWordsPerUnlock(2);
      await gate.recordStepCompletion(wordId: 'a', targetApp: 'X', attempts: 0);
      failGrant = true;
      await expectLater(
        gate.completeGateChallenge(wordId: 'b', targetApp: 'X', attempts: 1),
        throwsA(isA<PlatformException>()),
      );
      await gate.setWordsPerUnlock(3);
      expect(gate.progressForApp('X'), 2);
      expect(await repo.pendingGateAnswers(), isEmpty);
      expect((await gate.selectGateWord(targetApp: 'X'))!.id, 'c');
      failGrant = false;
      await gate.completeGateChallenge(
        wordId: 'c',
        targetApp: 'X',
        attempts: 0,
      );
      expect(
        (await repo.recentGateLogs()).where((log) => log.wordId == 'b'),
        hasLength(1),
      );
    },
  );

  test(
    'a failed progress write rolls back both learning credit and the round step',
    () async {
      await repo.database.execute(
        "CREATE TRIGGER reject_step BEFORE INSERT ON gate_round_progress BEGIN SELECT RAISE(ABORT, 'test storage failure'); END",
      );
      await expectLater(
        gate.recordStepCompletion(wordId: 'a', targetApp: 'X', attempts: 0),
        throwsA(isA<DatabaseException>()),
      );
      expect((await repo.findById('a'))!.srsStage, 0);
      expect(await repo.recentGateLogs(), isEmpty);
      expect(await repo.gateRoundProgress(), isEmpty);
      expect(gate.progressForApp('X'), 0);
    },
  );

  test(
    'a history failure after granting access reports unlocked and consumes the earned round',
    () async {
      await gate.setWordsPerUnlock(2);
      await gate.recordStepCompletion(wordId: 'a', targetApp: 'X', attempts: 0);
      await repo.database.execute(
        "CREATE TRIGGER reject_history BEFORE UPDATE OF srs_stage ON words BEGIN SELECT RAISE(ABORT, 'test storage failure'); END",
      );
      await gate.completeGateChallenge(
        wordId: 'b',
        targetApp: 'X',
        attempts: 0,
      );
      expect(gate.unlockedUntilFor('X'), now.add(const Duration(minutes: 15)));
      expect(gate.lastError, contains('Access is unlocked'));
      expect(gate.progressForApp('X'), 0);
      expect(await repo.gateRoundProgress(), isEmpty);
      expect(await repo.pendingGateAnswers(), isEmpty);
      expect((await repo.findById('b'))!.srsStage, 0);
    },
  );

  test(
    'a native grant uses its returned expiry independently of the Shortcut duration',
    () async {
      authorized = configured = enabled = true;
      await gate.refreshNativeScreenTime();
      await gate.setPassDurationMinutes(0);
      calls.clear();
      await gate.completeGateChallenge(
        wordId: 'a',
        targetApp: target,
        attempts: 0,
      );
      expect(
        gate.unlockedUntilFor(target),
        now.add(const Duration(minutes: 15)),
      );
      expect(calls.where((c) => c.method == 'getScreenTimeStatus'), isEmpty);
      expect(gate.config.passDurationMinutes, 0);
      expect(
        (calls.firstWhere((call) => call.method == 'grantPass').arguments
            as Map)['durationMinutes'],
        15,
      );
    },
  );

  test(
    'restoring permission keeps the existing selected app without opening another picker',
    () async {
      configured = true;
      await gate.refreshNativeScreenTime();
      calls.clear();
      expect(await gate.enableNativeProtection(totalWords: 3), isTrue);
      expect(
        calls.any((c) => c.method == 'chooseScreenTimeApplications'),
        isFalse,
      );
      expect(gate.nativeStatus.applications.single.id, target);
    },
  );

  test(
    'a notebook shrinking below the rule can claim already earned work without another SRS update',
    () async {
      await gate.setWordsPerUnlock(3);
      await gate.recordStepCompletion(wordId: 'a', targetApp: 'X', attempts: 0);
      await repo.softDelete('b', now);
      await repo.softDelete('c', now);
      await gate.prepareChallenge();
      expect(gate.requiredWords, 1);
      await gate.completeGateChallenge(
        wordId: 'a',
        targetApp: 'X',
        attempts: 0,
      );
      expect((await repo.findById('a'))!.srsStage, 1);
      expect(await repo.gateRoundProgress(), isEmpty);
    },
  );

  test(
    'deleted words cannot earn access and a daily goal never blocks saved-word review',
    () async {
      expect(gate.config.dailyWordGoal, isFalse);
      await repo.softDelete('a', now);
      await expectLater(
        gate.completeGateChallenge(wordId: 'a', targetApp: 'X', attempts: 0),
        throwsA(isA<PlatformException>()),
      );
      expect(calls.where((c) => c.method == 'grantPass'), isEmpty);
      now = now.add(const Duration(days: 1));
      await gate.setDailyWordGoal(true);
      await gate.completeGateChallenge(
        wordId: 'b',
        targetApp: 'X',
        attempts: 0,
      );
    },
  );

  test(
    'database upgrade from version 6 preserves words and adds durable rounds',
    () async {
      final directory = await Directory.systemTemp.createTemp('veea-upgrade-');
      final path = '${directory.path}/old.db';
      try {
        final old = await SqliteVocabularyRepository.open(
          path: path,
          now: () => now,
        );
        await old.insert(words.first);
        await old.database.execute('DROP TABLE gate_round_progress');
        await old.database.execute('DROP TABLE gate_pending_answers');
        await old.database.execute(
          'ALTER TABLE words DROP COLUMN word_search_text',
        );
        for (final table in [
          'account_workspaces',
          'app_metadata',
          'feedback_outbox',
        ]) {
          await old.database.execute('DROP TABLE $table');
        }
        await old.database.execute('PRAGMA user_version = 6');
        await old.close();
        final upgraded = await SqliteVocabularyRepository.open(
          path: path,
          now: () => now,
        );
        try {
          expect((await upgraded.exportAll()).single.id, 'a');
          await upgraded.recordGateCompletion(
            wordId: 'a',
            targetApp: 'X',
            attempts: 0,
            completesRound: false,
          );
          expect((await upgraded.gateRoundProgress())['x'], {'a'});
        } finally {
          await upgraded.close();
        }
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );

  testWidgets(
    'practice challenge grants no access, writes no history, and cannot launch or revoke an app',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      calls.clear();
      await tester.pumpWidget(
        app(
          AppGateScreen(
            targetApp: 'X',
            initialWord: words.first,
            previewMode: true,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('app_gate_input')),
        'resilient',
      );
      await tester.ensureVisible(find.text('Unlock X'));
      await tester.tap(find.text('Unlock X'));
      await tester.pumpAndSettle();
      expect(find.text('PRACTICE COMPLETE'), findsOneWidget);
      expect(find.byType(NativeGateReturnHint), findsNothing);
      expect(
        calls.where(
          (c) => ['grantPass', 'launchApp', 'revokePass'].contains(c.method),
        ),
        isEmpty,
      );
      await tester.runAsync(() async {
        expect(await repo.recentGateLogs(), isEmpty);
        expect((await repo.findById('a'))!.srsStage, 0);
      });
      await tester.tap(find.text('Practice again'));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      expect(
        calls.where(
          (c) => ['grantPass', 'launchApp', 'revokePass'].contains(c.method),
        ),
        isEmpty,
      );
      expect(find.byKey(const Key('app_gate_input')), findsOneWidget);
    },
  );

  testWidgets(
    'permission recovery explains the state and still allows protection to be turned off',
    (tester) async {
      configured = true;
      await tester.runAsync(() => gate.refreshNativeScreenTime());
      await tester.pumpWidget(
        app(
          Scaffold(
            body: SingleChildScrollView(
              child: NativeGateSettings(gate: gate, totalWords: 3),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('access was removed'), findsOneWidget);
      expect(find.text('Restore Screen Time access'), findsOneWidget);
      expect(find.text('Turn off Screen Time protection'), findsOneWidget);
    },
  );

  testWidgets(
    'a failed grant can be claimed without typing the final answer again',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      failGrant = true;
      await tester.pumpWidget(
        app(AppGateScreen(targetApp: 'X', initialWord: words.first)),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('app_gate_input')),
        'resilient',
      );
      await tester.runAsync(() async {
        await tester.tap(find.text('Unlock X'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      expect(find.text('Claim earned access'), findsOneWidget);
      expect(find.byKey(const Key('app_gate_input')), findsNothing);
      failGrant = false;
      await tester.runAsync(() async {
        await tester.tap(find.text('Claim earned access'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      expect(find.text('Unlocked · 15:00 PASS'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'returning after expiry clears the previous word answer before a new challenge',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        app(AppGateScreen(targetApp: 'X', initialWord: words.first)),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('app_gate_input')),
        'resilient',
      );
      await tester.runAsync(() async {
        await tester.tap(find.text('Unlock X'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      now = now.add(const Duration(minutes: 16));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('app_gate_input')))
            .controller!
            .text,
        isEmpty,
      );
      expect(calls.where((call) => call.method == 'grantPass'), hasLength(1));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'native return guidance appears only after a successful grant and leaving preserves access',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      authorized = enabled = configured = true;
      await tester.runAsync(() => gate.refreshNativeScreenTime());
      Object? routeResult = 'not closed';
      await tester.pumpWidget(
        app(
          Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  routeResult = await Navigator.of(context).push<Object?>(
                    MaterialPageRoute<Object?>(
                      builder: (_) => AppGateScreen(
                        targetApp: target,
                        initialWord: words.first,
                      ),
                    ),
                  );
                },
                child: const Text('Veea notebook'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Veea notebook'));
      await tester.pumpAndSettle();
      expect(find.byType(NativeGateReturnHint), findsNothing);
      failGrant = true;
      await tester.enterText(
        find.byKey(const Key('app_gate_input')),
        'resilient',
      );
      await tester.ensureVisible(find.text('Unlock Protected app 1'));
      await tester.runAsync(() async {
        await tester.tap(find.text('Unlock Protected app 1'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      expect(find.byType(NativeGateReturnHint), findsNothing);
      expect(gate.unlockedUntilFor(target), isNull);
      failGrant = false;
      await tester.ensureVisible(find.text('Claim earned access'));
      await tester.runAsync(() async {
        await tester.tap(find.text('Claim earned access'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      expect(find.text('Your app is unlocked'), findsOneWidget);
      expect(find.text('15:00 remaining'), findsOneWidget);
      expect(find.textContaining('top-left corner'), findsOneWidget);
      expect(find.textContaining('No return link?'), findsOneWidget);
      expect(calls.where((c) => c.method == 'launchApp'), isEmpty);
      final earnedExpiry = gate.unlockedUntilFor(target);
      expect(earnedExpiry, isNotNull);
      await tester.ensureVisible(find.text('Back to Veea'));
      await tester.tap(find.text('Back to Veea'));
      await tester.pumpAndSettle();
      expect(find.text('Veea notebook'), findsOneWidget);
      expect(routeResult, isNull);
      expect(gate.unlockedUntilFor(target), earnedExpiry);
      expect(calls.where((c) => c.method == 'revokePass'), isEmpty);
    },
  );

  testWidgets(
    'native return guidance stays usable with enlarged text in dark mode',
    (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      authorized = enabled = configured = true;
      expiry = now.add(const Duration(minutes: 15));
      await tester.runAsync(() => gate.refreshNativeScreenTime());
      await tester.pumpWidget(
        app(
          const AppGateScreen(targetApp: target),
          theme: PixelTheme.dark(),
          textScaler: const TextScaler.linear(2),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Learn to unlock'), findsOneWidget);
      expect(find.text('Your app is unlocked'), findsOneWidget);
      await tester.ensureVisible(find.textContaining('No return link?'));
      expect(find.text('Back to Veea'), findsNothing);
      expect(find.text('WORD REVIEWED'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'an active native pass needs no notebook and its return guidance expires',
    (tester) async {
      authorized = enabled = configured = true;
      expiry = now.add(const Duration(seconds: 2));
      await tester.runAsync(() async {
        await repo.deleteAll();
        await gate.prepareChallenge();
        await gate.refreshNativeScreenTime();
      });
      await tester.pumpWidget(app(const AppGateScreen(targetApp: target)));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      expect(find.text('Your app is unlocked'), findsOneWidget);
      expect(find.text('0:02 remaining'), findsOneWidget);
      expect(find.text('NO WORDS IN NOTEBOOK'), findsNothing);
      expect(find.text('WORD REVIEWED'), findsNothing);
      now = now.add(const Duration(seconds: 2));
      await tester.pump(const Duration(seconds: 1));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      expect(find.byType(NativeGateReturnHint), findsNothing);
      expect(find.text('NO WORDS IN NOTEBOOK'), findsOneWidget);
      expect(calls.where((c) => c.method == 'launchApp'), isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'relocking after native success removes return guidance and revokes the pass',
    (tester) async {
      authorized = enabled = configured = true;
      await tester.runAsync(() => gate.refreshNativeScreenTime());
      await tester.pumpWidget(
        app(AppGateScreen(targetApp: target, initialWord: words.first)),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('app_gate_input')),
        'resilient',
      );
      await tester.ensureVisible(find.text('Unlock Protected app 1'));
      await tester.runAsync(() async {
        await tester.tap(find.text('Unlock Protected app 1'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      expect(find.byType(NativeGateReturnHint), findsOneWidget);
      expect(find.text('WORD REVIEWED'), findsOneWidget);
      await tester.ensureVisible(find.text('Lock again · Next word'));
      await tester.runAsync(() async {
        await tester.tap(find.text('Lock again · Next word'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      expect(find.byType(NativeGateReturnHint), findsNothing);
      expect(find.byKey(const Key('app_gate_input')), findsOneWidget);
      expect(gate.unlockedUntilFor(target), isNull);
      expect(calls.where((c) => c.method == 'revokePass'), hasLength(1));
      expect(calls.where((c) => c.method == 'launchApp'), isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'a restored native pass shows its real remaining time and returns to the challenge at expiry',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      authorized = enabled = configured = true;
      expiry = now.add(const Duration(seconds: 2));
      await tester.runAsync(() => gate.refreshNativeScreenTime());
      await tester.pumpWidget(app(const AppGateScreen(targetApp: target)));
      await tester.pumpAndSettle();
      expect(find.text('Unlocked · 0:02 PASS'), findsOneWidget);
      expect(find.byType(NativeGateReturnHint), findsOneWidget);
      expect(find.text('WORD REVIEWED'), findsNothing);
      now = now.add(const Duration(seconds: 2));
      await tester.pump(const Duration(seconds: 1));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('app_gate_input')), findsOneWidget);
      expect(find.byType(NativeGateReturnHint), findsNothing);
      expect(calls.where((c) => c.method == 'revokePass'), isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'learning rules are shared and automatic pronunciation starts off',
    (tester) async {
      await tester.pumpWidget(
        app(
          Scaffold(
            body: SingleChildScrollView(
              child: GateLearningSettings(gate: gate, totalWords: 3),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        isFalse,
      );
      expect(find.text('Practice words'), findsOneWidget);
    },
  );

  testWidgets(
    'repeated gate events do not stack pages and a different app replaces the challenge target',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const tokens = TokenStore();
      final client = ApiClient(tokenStore: tokens);
      final sync = SyncService(repository: repo, api: VocabularyApi(client));
      final auth = AuthProvider(
        authApi: AuthApi(client: client, tokens: tokens),
        tokens: tokens,
        client: client,
        repository: repo,
        sync: sync,
      );
      addTearDown(auth.dispose);
      addTearDown(sync.dispose);
      await tester.pumpWidget(
        VeeaEnglishApp(
          vocabulary: vocab,
          auth: auth,
          sync: sync,
          pronunciation: PronunciationService(repo.database),
          appGateProvider: gate,
          themeProvider: ThemeProvider(),
        ),
      );
      await tester.pumpAndSettle();
      Future<void> intercept(String targetApp) async {
        await tester.runAsync(() async {
          gate.service.triggerGate(targetApp);
          await Future<void>.delayed(const Duration(milliseconds: 100));
        });
        await tester.pumpAndSettle();
      }

      await intercept(target);
      expect(find.text('Locked · Protected app 1'), findsOneWidget);
      await intercept(target);
      expect(find.byType(AppGateScreen, skipOffstage: false), findsOneWidget);
      await intercept('native:00000000-0000-0000-0000-000000000002');
      expect(find.text('Locked · Protected app'), findsOneWidget);
      expect(find.byType(AppGateScreen, skipOffstage: false), findsOneWidget);
      Navigator.of(tester.element(find.byType(AppGateScreen))).pop();
      await tester.pumpAndSettle();
      await intercept(target);
      expect(find.text('Locked · Protected app 1'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
  test(
    'custom practice pool is saved across restart and excludes unselected and future words',
    () async {
      await gate.setPracticeWords(['b', 'c']);
      await gate.setWordsPerUnlock(2);
      await repo.insert(
        VocabularyWord.create(
          id: 'd',
          word: 'newcomer',
          meaning: 'New word',
          date: '2026-11-07',
          now: now,
        ),
      );
      gate.dispose();
      gate = AppGateProvider(repository: repo, now: () => now);
      await gate.init();
      expect(gate.config.practiceWordIds!.toSet(), {'b', 'c'});
      expect(gate.practiceWordCount, 2);
      expect([
        'b',
        'c',
      ], contains((await gate.selectGateWord(targetApp: 'X'))!.id));
      await expectLater(
        gate.completeGateChallenge(wordId: 'a', targetApp: 'X', attempts: 0),
        throwsA(isA<PlatformException>()),
      );
      expect(calls.where((call) => call.method == 'grantPass'), isEmpty);
      await gate.setPracticeWords(null);
      expect(gate.practiceWordCount, 4);
    },
  );

  test(
    'any count is supported up to the pool size and deletion never expands a custom pool',
    () async {
      for (var index = 0; index < 12; index++) {
        await repo.insert(
          VocabularyWord.create(
            id: 'extra$index',
            word: 'word$index',
            meaning: 'Extra word',
            date: '2026-11-07',
            now: now,
          ),
        );
      }
      await gate.setWordsPerUnlock(11);
      expect(gate.requiredWords, 11);
      expect((await repo.getGateConfig()).wordsPerUnlock, 11);
      await gate.setWordsPerUnlock(100);
      expect(gate.requiredWords, 15);
      await gate.setPracticeWords(['a', 'b']);
      expect(gate.requiredWords, 2);
      expect(gate.poolNotice, contains('adjusted'));
      await repo.softDelete('b', now);
      await gate.prepareChallenge();
      expect(gate.requiredWords, 1);
      await repo.softDelete('a', now);
      await gate.prepareChallenge();
      expect(gate.practiceWordCount, 0);
      expect(await gate.selectGateWord(targetApp: 'X'), isNull);
      await expectLater(
        gate.setPracticeWords([]),
        throwsA(isA<PlatformException>()),
      );
    },
  );

  test(
    'changing the pool retains eligible completed work and original grades',
    () async {
      await gate.setWordsPerUnlock(2);
      await gate.recordStepCompletion(wordId: 'a', targetApp: 'X', attempts: 0);
      failGrant = true;
      await expectLater(
        gate.completeGateChallenge(wordId: 'b', targetApp: 'X', attempts: 2),
        throwsA(isA<PlatformException>()),
      );
      await gate.setPracticeWords(['b', 'c']);
      expect(gate.solvedWordIdsForApp('X'), {'b'});
      expect((await repo.findById('b'))!.lastGateFailed, isTrue);
      expect(await repo.pendingGateAnswers(), isEmpty);
      failGrant = false;
      await gate.completeGateChallenge(
        wordId: 'c',
        targetApp: 'X',
        attempts: 0,
      );
      expect((await repo.findById('c'))!.srsStage, 1);
    },
  );

  test(
    'two selected words alternate across apps and provider restarts',
    () async {
      await gate.setPracticeWords(['a', 'b']);
      final order = <String>[];
      for (var index = 0; index < 4; index++) {
        final app = index.isEven ? 'X' : 'YouTube';
        final word = (await gate.selectGateWord(targetApp: app))!;
        order.add(word.id);
        await gate.completeGateChallenge(
          wordId: word.id,
          targetApp: app,
          attempts: 0,
        );
        gate.dispose();
        gate = AppGateProvider(repository: repo, now: () => now);
        await gate.init();
      }
      expect(order.toSet(), {'a', 'b'});
      expect(order[0], order[2]);
      expect(order[1], order[3]);
      expect(order[0], isNot(order[1]));
      expect((await repo.gateWordTurns()).values.toSet(), {3, 4});
    },
  );

  test('failed grants and duplicate steps do not advance rotation', () async {
    await gate.setPracticeWords(['a', 'b']);
    failGrant = true;
    await expectLater(
      gate.completeGateChallenge(wordId: 'a', targetApp: 'X', attempts: 0),
      throwsA(isA<PlatformException>()),
    );
    expect(await repo.gateWordTurns(), isEmpty);
    failGrant = false;
    await gate.completeGateChallenge(wordId: 'a', targetApp: 'X', attempts: 0);
    expect(await repo.gateWordTurns(), {'a': 1});
    await gate.setWordsPerUnlock(2);
    await gate.recordStepCompletion(wordId: 'b', targetApp: 'X', attempts: 0);
    final turns = await repo.gateWordTurns();
    await repo.recordGateCompletion(
      wordId: 'b',
      targetApp: 'X',
      attempts: 0,
      completesRound: false,
    );
    expect(await repo.gateWordTurns(), turns);
    expect((await gate.selectGateWord(targetApp: 'X'))!.id, 'a');
  });

  test(
    'version 8 migration seeds rotation without changing words or history',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'veea-rotation-v9-',
      );
      final path = '${directory.path}/legacy.db';
      try {
        final old = await SqliteVocabularyRepository.open(
          path: path,
          now: () => now,
        );
        for (final word in words) {
          await old.insert(word);
        }
        await old.recordGateCompletion(
          wordId: 'b',
          targetApp: 'X',
          attempts: 1,
          now: now.subtract(const Duration(days: 1)),
        );
        await old.recordGateCompletion(
          wordId: 'a',
          targetApp: 'X',
          attempts: 0,
          now: now,
        );
        final beforeWords = (await old.exportAll())
            .map((w) => w.toDbMap())
            .toList();
        final beforeLogs = await old.database.query('gate_logs');
        await old.database.execute('DROP TABLE gate_word_rotation');
        await old.database.execute(
          'ALTER TABLE words DROP COLUMN word_search_text',
        );
        for (final table in [
          'account_workspaces',
          'app_metadata',
          'feedback_outbox',
        ]) {
          await old.database.execute('DROP TABLE $table');
        }
        await old.database.execute('PRAGMA user_version = 8');
        await old.close();
        final upgraded = await SqliteVocabularyRepository.open(
          path: path,
          now: () => now,
        );
        try {
          expect(await upgraded.gateWordTurns(), {'b': 1, 'a': 2});
          expect(
            (await upgraded.exportAll()).map((w) => w.toDbMap()).toList(),
            beforeWords,
          );
          expect(await upgraded.database.query('gate_logs'), beforeLogs);
        } finally {
          await upgraded.close();
        }
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );

  testWidgets(
    'learning rules previews chosen words across dates and opens their complete list',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.runAsync(() async {
        await repo.update(words[0].copyWith(date: '2026-11-05'));
        await repo.update(words[2].copyWith(date: '2026-11-06'));
        await gate.setPracticeWords(['a', 'c']);
      });
      await tester.pumpWidget(app(LearningRulesScreen(gate: gate)));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('practice_word_preview_a')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('practice_word_preview_c')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('practice_word_preview_b')),
        findsNothing,
      );
      expect(find.text('Nov 5, 2026'), findsOneWidget);
      expect(find.text('Nov 6, 2026'), findsOneWidget);
      await tester.tap(find.byKey(const Key('view_selected_practice_words')));
      await tester.pumpAndSettle();
      expect(find.byType(SelectedPracticeWordsScreen), findsOneWidget);
      expect(
        find.byKey(const ValueKey('selected_practice_word_a')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('selected_practice_word_c')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('selected_practice_word_b')),
        findsNothing,
      );
      expect(find.text('2 words in practice'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'review searches dates and meanings without changing learning state; saved changes refresh the list',
    (tester) async {
      await tester.runAsync(() async {
        await repo.update(words[0].copyWith(date: '2026-11-05'));
        await gate.setPracticeWords(['a', 'c']);
      });
      await tester.pumpWidget(app(SelectedPracticeWordsScreen(gate: gate)));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('selected_practice_word_search')),
        'Nov 5',
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('selected_practice_word_a')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('selected_practice_word_c')),
        findsNothing,
      );
      expect(find.text('1 of 2 selected words shown'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('selected_practice_word_search')),
        'Meaning c',
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('selected_practice_word_c')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('selected_practice_word_a')),
        findsNothing,
      );
      await tester.enterText(
        find.byKey(const Key('selected_practice_word_search')),
        'nonexistent',
      );
      await tester.pumpAndSettle();
      expect(
        find.text('No selected words match. Try another search.'),
        findsOneWidget,
      );
      await tester.tap(find.byTooltip('Clear search'));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        expect((await repo.getGateConfig()).practiceWordIds, ['a', 'c']);
        expect(await repo.gateWordTurns(), isEmpty);
        expect(await repo.recentGateLogs(), isEmpty);
        expect((await repo.findById('a'))!.srsStage, 0);
        await gate.setPracticeWords(['b']);
      });
      await tester.pumpAndSettle();
      expect(find.text('1 word in practice'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('selected_practice_word_b')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('selected_practice_word_a')),
        findsNothing,
      );
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('edit_selected_practice_words')));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      expect(find.byType(PracticeWordPicker), findsOneWidget);
      expect(find.text('All 3 notebook words'), findsOneWidget);
      await tester.tap(find.byKey(const Key('cancel_practice_words')));
      await tester.pumpAndSettle();
      expect(find.byType(SelectedPracticeWordsScreen), findsOneWidget);
      expect(find.text('1 word in practice'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'automatic all shows the notebook and removes deleted words from review',
    (tester) async {
      await tester.pumpWidget(app(SelectedPracticeWordsScreen(gate: gate)));
      await tester.pumpAndSettle();
      expect(find.text('3 words in practice'), findsOneWidget);
      await tester.runAsync(() async {
        await repo.softDelete('b', now);
        await gate.prepareChallenge();
      });
      await tester.pumpAndSettle();
      expect(find.text('2 words in practice'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('selected_practice_word_b')),
        findsNothing,
      );
      await tester.runAsync(() async {
        await repo.softDelete('a', now);
        await repo.softDelete('c', now);
        await gate.prepareChallenge();
      });
      await tester.pumpAndSettle();
      expect(
        find.text('Your notebook has no saved words yet.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'version 7 daily requirement migrates to a nonblocking goal with audio off',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'veea-learning-v8-',
      );
      final path = '${directory.path}/legacy.db';
      try {
        final old = await SqliteVocabularyRepository.open(
          path: path,
          now: () => now,
        );
        await old.insert(words.first);
        await old.database.execute(
          'UPDATE gate_config SET require_daily_capture = 1, words_per_unlock = 1',
        );
        for (final name in [
          'auto_pronounce',
          'daily_word_goal',
          'practice_word_ids_json',
        ]) {
          await old.database.execute(
            'ALTER TABLE gate_config DROP COLUMN $name',
          );
        }
        await old.database.execute(
          'ALTER TABLE words DROP COLUMN word_search_text',
        );
        for (final table in [
          'account_workspaces',
          'app_metadata',
          'feedback_outbox',
        ]) {
          await old.database.execute('DROP TABLE $table');
        }
        await old.database.execute('PRAGMA user_version = 7');
        await old.close();
        final upgraded = await SqliteVocabularyRepository.open(
          path: path,
          now: () => now,
        );
        try {
          final config = await upgraded.getGateConfig();
          expect(config.dailyWordGoal, isTrue);
          expect(config.autoPronounce, isFalse);
          expect(
            (await upgraded.database.query(
              'gate_config',
            )).single['require_daily_capture'],
            0,
          );
          expect((await upgraded.exportAll()).single.id, 'a');
        } finally {
          await upgraded.close();
        }
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );

  testWidgets(
    'picker searches the whole notebook and keeps checkboxes selected across searches',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: PracticeWordPicker(words: words, selectedIds: const []),
        ),
      );
      await tester.enterText(
        find.byKey(const Key('practice_word_search')),
        'curious',
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('practice_word_b')));
      await tester.tap(find.byKey(const ValueKey('practice_word_b')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('practice_word_search')),
        'patient',
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('practice_word_c')));
      await tester.tap(find.byKey(const ValueKey('practice_word_c')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('practice_word_search')), '');
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<CheckboxListTile>(
              find.byKey(const ValueKey('practice_word_b')),
            )
            .value,
        isTrue,
      );
      expect(
        tester
            .widget<CheckboxListTile>(
              find.byKey(const ValueKey('practice_word_c')),
            )
            .value,
        isTrue,
      );
      expect(
        tester
            .widget<CheckboxListTile>(
              find.byKey(const ValueKey('practice_word_a')),
            )
            .value,
        isFalse,
      );
      expect(find.textContaining('2 of 3'), findsOneWidget);
    },
  );

  testWidgets(
    'the number editor accepts 2 and rejects a count above the selected pool',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        app(
          Scaffold(
            body: SingleChildScrollView(
              child: GateLearningSettings(gate: gate, totalWords: 3),
            ),
          ),
        ),
      );
      await tester.runAsync(
        () => tester.tap(find.byKey(const Key('edit_unlock_count'))),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('unlock_count_input')), '4');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text('Enter a number from 1 to 3.'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('unlock_count_input')), '2');
      await tester.runAsync(() async {
        await tester.tap(find.text('Save'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        for (
          var attempt = 0;
          attempt < 100 && gate.requiredWords != 2;
          attempt++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      expect(gate.requiredWords, 2);
    },
  );

  testWidgets(
    'automatic speech defaults off while manual pronunciation remains available',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        app(
          AppGateScreen(
            targetApp: 'X',
            initialWord: words.first,
            previewMode: true,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Hear it'));
      await tester.pumpAndSettle();
      expect(speech.spoken, ['resilient']);
      speech.spoken.clear();
      await tester.enterText(
        find.byKey(const Key('app_gate_input')),
        'resilient',
      );
      await tester.tap(find.text('Unlock X'));
      await tester.pumpAndSettle();
      expect(speech.spoken, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('enabling automatic pronunciation reads a correct answer', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() => gate.setAutoPronounce(true));
    await tester.pumpWidget(
      app(
        AppGateScreen(
          targetApp: 'X',
          initialWord: words.first,
          previewMode: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('app_gate_input')),
      'resilient',
    );
    await tester.tap(find.text('Unlock X'));
    await tester.pumpAndSettle();
    expect(speech.spoken, ['resilient']);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  test(
    'upgrade disables old Shortcut config while preserving the notebook and pool',
    () async {
      await repo.saveGateConfig(
        gate.config.copyWith(
          enabled: true,
          passDurationMinutes: 0,
          practiceWordIds: ['a', 'c'],
        ),
      );
      calls.clear();
      gate.dispose();
      gate = AppGateProvider(repository: repo, now: () => now);
      await gate.init();
      final saved = await repo.getGateConfig();
      expect(saved.enabled, isFalse);
      expect(saved.passDurationMinutes, 15);
      expect(saved.practiceWordIds, ['a', 'c']);
      expect((await repo.exportAll()).length, 3);
      expect(calls.where((call) => call.method == 'getInstalledApps'), isEmpty);
      final retired =
          calls.singleWhere((call) => call.method == 'setGateEnabled').arguments
              as Map;
      expect(retired['enabled'], isFalse);
      expect(retired['gatedApps'], isEmpty);
    },
  );

  test(
    'incoming old Shortcut events and pending targets cannot start a launch challenge',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      Future<void> incoming(String targetApp) async {
        await messenger.handlePlatformMessage(
          AppGateService.channelName,
          const StandardMethodCodec().encodeMethodCall(
            MethodCall('onGateTriggered', {'targetApp': targetApp}),
          ),
          null,
        );
      }

      await incoming('X');
      await incoming('shortcut:name:books:request:123-456');
      expect(gate.service.consumePendingTargetApp(), isNull);
      await incoming(target);
      expect(gate.service.consumePendingTargetApp(), target);
      expect(gate.service.consumePendingTargetApp(), isNull);
    },
  );

  test(
    'duration persists through native refresh without changing an earned pass',
    () async {
      authorized = enabled = configured = true;
      expiry = now.add(const Duration(minutes: 15));
      await gate.refreshNativeScreenTime();
      expect(await gate.setNativeDuration(90), isTrue);
      expect(gate.nativeStatus.passMinutes, 90);
      expect(gate.unlockedUntilFor(target), expiry);
      gate.dispose();
      gate = AppGateProvider(repository: repo, now: () => now);
      await gate.init();
      expect(gate.nativeStatus.passMinutes, 90);
      expect(gate.unlockedUntilFor(target), expiry);
      calls.clear();
      expect(await gate.setNativeDuration(4), isFalse);
      expect(await gate.setNativeDuration(1441), isFalse);
      expect(
        calls.where((call) => call.method == 'setScreenTimeDuration'),
        isEmpty,
      );
      expect(gate.nativeStatus.passMinutes, 90);
      expect(gate.unlockedUntilFor(target), expiry);
    },
  );

  testWidgets('restored long access uses hours in its countdown', (
    tester,
  ) async {
    authorized = enabled = configured = true;
    expiry = now.add(const Duration(minutes: 90));
    await tester.runAsync(() => gate.refreshNativeScreenTime());
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(app(AppGateScreen(targetApp: target)));
    await tester.pumpAndSettle();
    expect(find.text('1:30:00 remaining'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
  testWidgets(
    'unlocking inside Veea gives Home instructions without a misleading return arrow',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      authorized = enabled = configured = true;
      expiry = now.add(const Duration(minutes: 15));
      await tester.runAsync(() => gate.refreshNativeScreenTime());
      await tester.pumpWidget(
        app(AppGateScreen(targetApp: target, openedFromVeea: true)),
      );
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Open your app from Home or the app switcher. Your access is already active.',
        ),
        findsOneWidget,
      );
      expect(
        find.text('Tap the return link in the top-left corner of your screen.'),
        findsNothing,
      );
      expect(find.byIcon(Icons.north_west), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
}
