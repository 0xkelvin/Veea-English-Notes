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
import 'package:veea_english_app/providers/universal_shortcut_controller.dart';
import 'package:veea_english_app/screens/shortcut_setup_screen.dart';
import 'package:veea_english_app/screens/universal_shortcut_setup_screen.dart';
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
  var universalEnabled = false;
  var failTurnOff = false;
  List<Map<String, Object>> observedApps = [];
  var importSupported = true;
  var verified = false;
  var openLink = true;
  var launch = true;
  var preparedAtImport = false;

  setUp(() async {
    universalEnabled = false;
    failTurnOff = false;
    observedApps = [];
    importSupported = true;
    verified = false;
    openLink = true;
    launch = true;
    preparedAtImport = false;
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
          case 'getUniversalGateStatus':
            return {'enabled': universalEnabled, 'apps': observedApps};
          case 'setUniversalGateEnabled':
            final enabled = (call.arguments as Map)['enabled'] == true;
            if (!enabled && failTurnOff) {
              throw PlatformException(code: 'FAILED');
            }
            universalEnabled = enabled;
            return null;
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
        preparedAtImport =
            gate.config.enabled &&
            gate.config.passDurationMinutes == 0 &&
            gate.config.gatedApps.contains('X') &&
            calls.any((call) => call.method == 'beginShortcutSetupTest');
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

  UniversalShortcutController universal({Uri? link}) {
    final value = UniversalShortcutController(
      gate: gate,
      installUrl: link ?? Uri.parse(UniversalShortcutSetupScreen.installLink),
      openLink: (url) async {
        urls.add(url);
        expect(gate.config.enabled, true);
        expect(gate.config.passDurationMinutes, 0);
        expect(universalEnabled, true);
        return openLink;
      },
    );
    addTearDown(value.dispose);
    return value;
  }

  test(
    'universal progress survives a fresh opening without sharing apps',
    () async {
      await gate.setWordsPerUnlock(2);
      await gate.recordStepCompletion(
        wordId: 'consent',
        targetApp: 'shortcut:name:safari:request:100-200',
        attempts: 1,
      );
      expect(gate.progressForApp('shortcut:name:safari:request:101-201'), 1);
      expect(gate.progressForApp('shortcut:name:books:request:102-202'), 0);
      final saved = await repo.gateRoundProgress();
      expect(saved.keys, ['shortcut:name:safari']);
    },
  );

  test(
    'universal setup prepares notebook without choosing default apps',
    () async {
      final value = universal();
      await value.setup(3);
      expect(value.error, isNull);
      expect(value.openedInstaller, true);
      expect(gate.config.gatedApps, isEmpty);
      expect(urls.single.host, 'www.icloud.com');
      expect(value.status.apps, isEmpty);
      // Returning from Apple is not proof that the user enabled an automation.
      await value.refresh();
      expect(value.status.apps, isEmpty);
    },
  );

  test(
    'universal setup rejects missing link, old iOS, and insufficient words',
    () async {
      final invalid = universal(link: Uri());
      await invalid.setup(3);
      expect(invalid.error, contains('unavailable'));
      expect(universalEnabled, false);
      final value = universal();
      importSupported = false;
      await value.setup(3);
      expect(value.error, contains('iOS 27'));
      importSupported = true;
      await value.setup(0);
      expect(value.error, contains('3 words'));
      expect(urls, isEmpty);
      expect(universalEnabled, false);
    },
  );

  test(
    'universal installer failure can retry without claiming activation',
    () async {
      final value = universal();
      openLink = false;
      await value.setup(3);
      expect(value.error, contains('Could not open'));
      expect(value.openedInstaller, false);
      openLink = true;
      await value.setup(3);
      expect(value.error, isNull);
      expect(value.openedInstaller, true);
      expect(value.status.apps, isEmpty);
    },
  );

  test(
    'observed apps keep separate verification and turn off handles failure',
    () async {
      final value = universal();
      await value.setup(3);
      observedApps = [
        {
          'id': 'shortcut:name:safari',
          'name': 'Safari',
          'verifiedAt': 1794100000,
        },
        {'id': 'shortcut:name:books', 'name': 'Books', 'verifiedAt': 0},
      ];
      await value.refresh();
      expect(value.status.apps.map((app) => app.name), ['Safari', 'Books']);
      expect(value.status.apps.first.verifiedAt, isNotNull);
      expect(value.status.apps.last.verifiedAt, isNull);
      expect(gate.service.shortcutAppNames['shortcut:name:books'], 'Books');
      failTurnOff = true;
      await value.turnOff();
      expect(value.error, contains('Could not turn off'));
      expect(value.busy, false);
      expect(value.status.enabled, true);
      failTurnOff = false;
      await value.turnOff();
      expect(value.error, isNull);
      expect(value.status.enabled, false);
    },
  );

  test(
    'installer prepares chosen app before approval; cancellation never claims success',
    () async {
      expect(await controller.addShortcut(totalWords: 3), true);
      await controller.refresh();
      expect(controller.tested, false);
      expect(preparedAtImport, true);
      expect(gate.config.enabled, true);
      expect(gate.config.gatedApps, ['X']);
      expect(gate.config.passDurationMinutes, 0);
      expect(calls.any((c) => c.method == 'launchApp'), false);
      expect(
        urls.single.toString(),
        'https://www.icloud.com/shortcuts/d46f1dd0603a4c09a05fa9a12dd43d3e',
      );
    },
  );

  test('setup guards the notebook before sending users to Apple', () async {
    expect(await controller.addShortcut(totalWords: 0), false);
    expect(urls, isEmpty);
    expect(gate.config.enabled, false);
    expect(calls.where((c) => c.method == 'beginShortcutSetupTest'), isEmpty);
  });

  test(
    'failed installer can retry and unsupported iOS never opens a wrong template',
    () async {
      openLink = false;
      expect(await controller.addShortcut(totalWords: 3), false);
      expect(controller.openedInstaller, false);
      openLink = true;
      expect(await controller.addShortcut(totalWords: 3), true);
      urls.clear();
      importSupported = false;
      expect(await controller.addShortcut(totalWords: 3), false);
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
    'single handoff and returning from installer never show false success',
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
      expect(find.text('Learn before opening X'), findsOneWidget);
      await tester.ensureVisible(find.text('Set up in Apple Shortcuts'));
      await tester.runAsync(() async {
        await tester.tap(find.text('Set up in Apple Shortcuts'));
        for (var i = 0; controller.busy && i < 100; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pumpAndSettle();
      expect(find.text('Turn on Automation → Add Shortcut'), findsOneWidget);
      expect(find.text('Test successful'), findsNothing);
      expect(find.text('Enable it once'), findsNothing);
      await tester.ensureVisible(find.text('Test: open X'));
      await tester.runAsync(() async {
        await tester.tap(find.text('Test: open X'));
        for (var i = 0; controller.busy && i < 100; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pumpAndSettle();
      expect(find.textContaining('Not verified yet.'), findsOneWidget);
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
    await tester.ensureVisible(find.text('Set up in Apple Shortcuts'));
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('Test: open X'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('first-launch flow hides all Shortcut setup', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: PixelTheme.light(),
        home: Scaffold(
          body: SingleChildScrollView(
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
    expect(find.text('X'), findsNothing);
    expect(
      find.textContaining('App protection is available on iPhone'),
      findsOneWidget,
    );
    expect(find.text('Choose apps to protect'), findsNothing);
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
              enableUniversalSetup: true,
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
    expect(find.text('Choose apps to protect'), findsNothing);
    await tester.ensureVisible(find.text('Learning rules'));
    expect(find.text('Learning rules'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
