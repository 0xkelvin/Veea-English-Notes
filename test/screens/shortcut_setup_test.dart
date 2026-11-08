import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:veea_english_app/core/theme/pixel_theme.dart';
import 'package:veea_english_app/data/local/sqlite_vocabulary_repository.dart';
import 'package:veea_english_app/models/shortcut_setup.dart';
import 'package:veea_english_app/models/vocabulary_word.dart';
import 'package:veea_english_app/providers/app_gate_provider.dart';
import 'package:veea_english_app/providers/shortcut_setup_controller.dart';
import 'package:veea_english_app/screens/shortcut_setup_screen.dart';
import 'package:veea_english_app/services/app_gate_service.dart';
import 'package:veea_english_app/widgets/guided_protection_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late SqliteVocabularyRepository repo;
  late AppGateProvider gate;
  late ShortcutSetupController controller;
  late List<MethodCall> calls;
  late List<Uri> urls;
  var importSupported = true;
  var verified = false;
  var openLink = true;
  var launch = true;

  setUp(() async {
    importSupported = true;
    verified = false;
    openLink = true;
    launch = true;
    calls = [];
    urls = [];
    messenger.setMockMethodCallHandler(
      const MethodChannel(AppGateService.channelName),
      (call) async {
        calls.add(call);
        switch (call.method) {
          case 'beginShortcutSetupTest':
            verified = false;
            return null;
          case 'getShortcutSetupStatus':
            return {
              'supportsImport': importSupported,
              'tested': verified ? {'x': 1794100000} : <String, double>{},
            };
          case 'requestPermissions':
            return true;
          case 'getInstalledApps':
            return ['X', 'YouTube'];
          case 'launchApp':
            return launch;
          default:
            return null;
        }
      },
    );
    repo = await SqliteVocabularyRepository.open(path: inMemoryDatabasePath);
    for (final word in ['consent', 'resilient', 'recipe']) {
      await repo.insert(
        VocabularyWord.create(
          id: word,
          word: word,
          meaning: 'meaning',
          date: '2026-11-08',
          now: DateTime(2026, 11, 8),
        ),
      );
    }
    gate = AppGateProvider(repository: repo);
    await gate.init();
    controller = ShortcutSetupController(
      gate: gate,
      template: ShortcutTemplate.available.first,
      openLink: (url) async {
        urls.add(url);
        return openLink;
      },
    );
  });

  tearDown(() async {
    controller.dispose();
    gate.dispose();
    await repo.close();
    messenger.setMockMethodCallHandler(
      const MethodChannel(AppGateService.channelName),
      null,
    );
  });

  test(
    'installer and return to app do not claim activation or change protection',
    () async {
      expect(await controller.addShortcut(), true);
      await controller.refresh();
      expect(controller.tested, false);
      expect(gate.config.enabled, false);
      expect(gate.config.gatedApps, isEmpty);
      expect(
        urls.single.toString(),
        'https://www.icloud.com/shortcuts/f498121930cd4a5ebd6f7f516fc10aed',
      );
    },
  );

  test(
    'failed installer can retry and unsupported iOS never opens a wrong template',
    () async {
      openLink = false;
      expect(await controller.addShortcut(), false);
      expect(controller.openedInstaller, false);
      openLink = true;
      expect(await controller.addShortcut(), true);
      urls.clear();
      importSupported = false;
      expect(await controller.addShortcut(), false);
      expect(urls, isEmpty);
      expect(ShortcutTemplate.forApp('another app'), isNull);
    },
  );

  test(
    'test preserves other apps and learning choices; waits for native proof',
    () async {
      await gate.setGatedApps(['YouTube']);
      await gate.setWordsPerUnlock(2);
      await gate.setAutoPronounce(true);
      await gate.recordStepCompletion(
        wordId: 'consent',
        targetApp: 'X',
        attempts: 1,
      );
      expect(gate.progressForApp('X'), 1);
      expect(await controller.test(totalWords: 3), true);
      expect(gate.config.gatedApps, ['YouTube', 'X']);
      expect(gate.config.passDurationMinutes, 0);
      expect(gate.config.wordsPerUnlock, 2);
      expect(gate.config.autoPronounce, true);
      expect(gate.progressForApp('X'), 1);
      expect(controller.tested, false);
      expect(controller.testing, true);
      final testCalls = calls
          .where(
            (c) => [
              'revokePass',
              'beginShortcutSetupTest',
              'launchApp',
            ].contains(c.method),
          )
          .toList();
      expect(testCalls.map((c) => c.method), [
        'revokePass',
        'beginShortcutSetupTest',
        'launchApp',
      ]);
      expect(
        testCalls.every((c) => (c.arguments as Map)['targetApp'] == 'X'),
        true,
      );
      await controller.refresh();
      expect(controller.tested, false);
      verified = true;
      await controller.refresh();
      expect(controller.tested, true);
      expect(controller.testing, false);
    },
  );

  test(
    'missing app fails honestly and empty notebook cannot enable protection',
    () async {
      launch = false;
      expect(await controller.test(totalWords: 3), false);
      expect(controller.tested, false);
      expect(controller.testing, false);
      expect(controller.error, contains('Make sure it is installed'));
      calls.clear();
      expect(await controller.test(totalWords: 0), false);
      expect(calls.where((c) => c.method == 'launchApp'), isEmpty);
    },
  );

  test(
    'disabled or timed settings cannot reuse an earlier successful test',
    () async {
      verified = true;
      await controller.refresh();
      expect(controller.tested, false);
      await gate.setGatedApps(['X']);
      await gate.setEnabled(true, totalWords: 3);
      await gate.completeGateChallenge(
        wordId: 'consent',
        targetApp: 'X',
        attempts: 0,
      );
      expect(gate.unlockedUntilFor('X'), isNotNull);
      await controller.test(totalWords: 3);
      expect(gate.unlockedUntilFor('X'), isNull);
      verified = true;
      await controller.refresh();
      expect(controller.tested, true);
      await gate.setPassDurationMinutes(15);
      await controller.refresh();
      expect(controller.tested, false);
    },
  );

  test('reviewing setup ignores old proof and allows a fresh test', () async {
    await controller.test(totalWords: 3);
    verified = true;
    await controller.refresh();
    expect(controller.tested, true);
    controller.reviewSetup();
    await controller.refresh();
    expect(controller.tested, false);
    await controller.test(totalWords: 3);
    expect(verified, false);
    await controller.refresh();
    expect(controller.tested, false);
    verified = true;
    await controller.refresh();
    expect(controller.tested, true);
  });

  testWidgets(
    'three steps and returning from installer never show false success',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: PixelTheme.light(),
          home: ShortcutSetupScreen(
            gate: gate,
            template: ShortcutTemplate.available.first,
            totalWords: 3,
            controller: controller,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Step 1 of 3'), findsOneWidget);
      await tester.tap(find.text('Add shortcut'));
      await tester.pumpAndSettle();
      expect(find.text('Step 2 of 3'), findsOneWidget);
      expect(find.text('Test successful'), findsNothing);
      await tester.ensureVisible(find.text('I’ve enabled it — test now'));
      await tester.tap(find.text('I’ve enabled it — test now'));
      await tester.pumpAndSettle();
      expect(find.text('Step 3 of 3'), findsOneWidget);
      await tester.ensureVisible(find.text('Test: open X'));
      await tester.runAsync(() async {
        await tester.tap(find.text('Test: open X'));
        for (var i = 0; controller.busy && i < 100; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pumpAndSettle();
      expect(find.text('Waiting for the shortcut check…'), findsOneWidget);
      expect(find.text('Test successful'), findsNothing);
      verified = true;
      await controller.refresh();
      await tester.pumpAndSettle();
      expect(find.text('Test successful'), findsOneWidget);
    },
  );

  testWidgets('setup supports compact, enlarged text and dark mode', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: PixelTheme.dark(),
        builder: (_, child) => MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: child!,
        ),
        home: ShortcutSetupScreen(
          gate: gate,
          template: ShortcutTemplate.available.first,
          totalWords: 3,
          controller: controller,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('I already have the shortcut'));
    await tester.tap(find.text('I already have the shortcut'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('I’ve enabled it — test now'));
    await tester.tap(find.text('I’ve enabled it — test now'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('app selection remains usable with enlarged text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: PixelTheme.light(),
        builder: (_, child) => MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: child!,
        ),
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: GuidedProtectionSettings(
              gate: gate,
              totalWords: 3,
              onAddWord: () {},
              legacySettings: const SizedBox(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('X'));
    await tester.tap(find.text('X'));
    await tester.pumpAndSettle();
    expect(find.text('Step 1 of 3'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
