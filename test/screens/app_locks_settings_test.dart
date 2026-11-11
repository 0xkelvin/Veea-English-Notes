import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:veea_english_app/core/theme/pixel_theme.dart';
import 'package:veea_english_app/data/local/sqlite_vocabulary_repository.dart';
import 'package:veea_english_app/models/vocabulary_word.dart';
import 'package:veea_english_app/providers/app_gate_provider.dart';
import 'package:veea_english_app/services/app_gate_service.dart';
import 'package:veea_english_app/widgets/app_locks_settings_section.dart';
import 'package:veea_english_app/widgets/guided_protection_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  const a = 'native:00000000-0000-0000-0000-000000000001';
  const b = 'native:00000000-0000-0000-0000-000000000002';
  final now = DateTime(2026, 11, 11, 14);
  late SqliteVocabularyRepository repo;
  late AppGateProvider gate;
  late List<MethodCall> calls;
  late Set<String> apps, paused;
  var enabled = true,
      authorized = true,
      failToggle = false,
      denyPermission = false,
      available = true;
  Map<String, Object?> status() => {
    'supported': true,
    'available': available,
    'authorized': authorized,
    'enabled': enabled && authorized,
    'configured': enabled,
    'passMinutes': 5,
    'applications': [
      for (final id in apps)
        {
          'id': id,
          'label': id == a ? 'Music' : 'Freeform',
          'lockEnabled': !paused.contains(id),
          'customPassMinutes': id == a ? 15 : null,
        },
    ],
  };
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    apps = {a, b};
    paused = {};
    calls = [];
    enabled = true;
    authorized = true;
    available = true;
    failToggle = false;
    denyPermission = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel(AppGateService.channelName),
          (call) async {
            calls.add(call);
            final args = call.arguments is Map
                ? call.arguments as Map
                : const {};
            switch (call.method) {
              case 'getScreenTimeStatus':
                return status();
              case 'requestScreenTimeAuthorization':
                if (denyPermission) {
                  throw PlatformException(
                    code: 'DENIED',
                    message: 'Screen Time access was not allowed.',
                  );
                }
                authorized = true;
                return status();
              case 'setScreenTimeEnabled':
                enabled = args['enabled'] as bool;
                return status();
              case 'setScreenTimeApplicationLocked':
                if (failToggle) {
                  throw PlatformException(
                    code: 'SAVE',
                    message: 'Could not update this app.',
                  );
                }
                final id = args['targetApp'] as String;
                if (args['enabled'] == true) {
                  paused.remove(id);
                } else {
                  paused.add(id);
                }
                return status();
              default:
                return null;
            }
          },
        );
    repo = await SqliteVocabularyRepository.open(
      path: inMemoryDatabasePath,
      now: () => now,
    );
    for (final word in ['recipe', 'consent', 'resilient']) {
      await repo.insert(
        VocabularyWord.create(
          id: word,
          word: word,
          meaning: 'meaning',
          date: '2026-11-11',
          now: now,
        ),
      );
    }
    gate = AppGateProvider(repository: repo, now: () => now);
    await gate.init();
    calls.clear();
  });
  tearDown(() async {
    gate.dispose();
    await repo.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel(AppGateService.channelName),
          null,
        );
  });
  Future<void> open(
    WidgetTester tester, {
    bool dark = false,
    double scale = 1,
    int totalWords = 3,
  }) async {
    await tester.pumpWidget(
      RepaintBoundary(
        key: const Key('locks_preview'),
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: dark ? PixelTheme.dark() : PixelTheme.light(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: Scaffold(
            appBar: AppBar(title: const Text('Settings')),
            body: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Builder(
                builder: (context) => AppLocksSettingsSection(
                  gate: gate,
                  totalWords: totalWords,
                  onManage: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => Scaffold(
                        appBar: AppBar(
                          title: const Text('Manage Apps to Lock'),
                        ),
                        body: SingleChildScrollView(
                          child: GuidedProtectionSettings(
                            gate: gate,
                            totalWords: 3,
                            onAddWord: () {},
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  Finder appSwitch(String id) => find.byKey(ValueKey('settings_app_lock_$id'));
  testWidgets(
    'Settings shows master, selected app switches and management link',
    (tester) async {
      await open(tester);
      expect(find.text('App locks'), findsOneWidget);
      expect(find.text('App protection'), findsNothing);
      expect(find.text('Enable locks'), findsOneWidget);
      expect(find.text('Music'), findsOneWidget);
      expect(find.text('Freeform'), findsOneWidget);
      expect(find.byType(Switch), findsNWidgets(3));
      expect(find.text('Add, remove, and set unlock times'), findsOneWidget);
    },
  );
  testWidgets(
    'a per-app switch changes only that rule and retains time settings',
    (tester) async {
      await open(tester);
      await tap(tester, appSwitch(a));
      expect(paused, {a});
      expect(gate.nativeStatus.durationFor(a), 15);
      expect(gate.nativeStatus.enabled, isTrue);
      expect(gate.nativeStatus.applications.length, 2);
      expect(tester.widget<Switch>(appSwitch(a)).value, isFalse);
      expect(tester.widget<Switch>(appSwitch(b)).value, isTrue);
      await tap(tester, appSwitch(a));
      expect(paused, isEmpty);
      expect(
        calls.where((c) => c.method == 'removeScreenTimeApplication'),
        isEmpty,
      );
    },
  );
  testWidgets(
    'master off disables app controls and preserves choices for master on',
    (tester) async {
      paused.add(a);
      await gate.refreshNativeScreenTime();
      await open(tester);
      await tap(tester, find.byKey(const Key('settings_enable_locks')));
      expect(enabled, isFalse);
      expect(paused, {a});
      expect(apps, {a, b});
      expect(tester.widget<Switch>(appSwitch(b)).onChanged, isNull);
      expect(tester.widget<Switch>(appSwitch(a)).value, isFalse);
      expect(tester.widget<Switch>(appSwitch(b)).value, isTrue);
      await tap(tester, find.byKey(const Key('settings_enable_locks')));
      expect(enabled, isTrue);
      expect(tester.widget<Switch>(appSwitch(a)).value, isFalse);
      expect(tester.widget<Switch>(appSwitch(b)).value, isTrue);
    },
  );
  testWidgets('empty state disables the master but still opens management', (
    tester,
  ) async {
    apps.clear();
    enabled = false;
    await gate.refreshNativeScreenTime();
    await open(tester);
    expect(find.text('No apps added'), findsOneWidget);
    expect(find.text('No locks yet'), findsOneWidget);
    expect(
      tester
          .widget<SwitchListTile>(
            find.byKey(const Key('settings_enable_locks')),
          )
          .onChanged,
      isNull,
    );
    await tap(tester, find.text('Manage Apps to Lock'));
    expect(find.text('Add Apps'), findsOneWidget);
    expect(find.text('Default unlock time'), findsOneWidget);
  });
  testWidgets('management link opens the existing page with app times', (
    tester,
  ) async {
    await open(tester);
    await tap(tester, find.text('Manage Apps to Lock'));
    expect(find.text('Default unlock time'), findsOneWidget);
    expect(find.text('15 min'), findsOneWidget);
    expect(find.text('Default · 5 min'), findsOneWidget);
  });
  testWidgets('failed toggle keeps state and shows a visible error', (
    tester,
  ) async {
    failToggle = true;
    await open(tester);
    await tap(tester, appSwitch(a));
    expect(paused, isEmpty);
    expect(tester.widget<Switch>(appSwitch(a)).value, isTrue);
    expect(
      find
          .descendant(
            of: find.byType(SnackBar),
            matching: find.text('Could not update this app.'),
          )
          .hitTestable(),
      findsOneWidget,
    );
  });
  testWidgets('permission denial leaves locks off and explains the failure', (
    tester,
  ) async {
    enabled = false;
    authorized = false;
    denyPermission = true;
    await gate.refreshNativeScreenTime();
    await open(tester);
    await tap(tester, find.byKey(const Key('settings_enable_locks')));
    expect(gate.nativeStatus.enabled, isFalse);
    expect(
      find
          .descendant(
            of: find.byType(SnackBar),
            matching: find.text('Screen Time access was not allowed.'),
          )
          .hitTestable(),
      findsOneWidget,
    );
  });
  testWidgets(
    'all apps paused leaves master available to turn an app back on',
    (tester) async {
      paused.addAll(apps);
      await gate.refreshNativeScreenTime();
      await open(tester);
      expect(
        find.text('No apps enabled · Turn on an app below'),
        findsOneWidget,
      );
      expect(tester.widget<Switch>(appSwitch(a)).onChanged, isNotNull);
      await tap(tester, appSwitch(a));
      expect(paused, {b});
    },
  );
  testWidgets('compact dark screen and large text do not overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await open(tester, dark: true, scale: 2);
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('Manage Apps to Lock'));
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'missing build capability and vocabulary prerequisite keep master disabled',
    (tester) async {
      enabled = false;
      available = false;
      await gate.refreshNativeScreenTime();
      await open(tester);
      expect(
        tester
            .widget<SwitchListTile>(
              find.byKey(const Key('settings_enable_locks')),
            )
            .onChanged,
        isNull,
      );
      available = true;
      await gate.refreshNativeScreenTime();
      await open(tester, totalWords: 0);
      expect(find.text('Save 3 words to enable locks'), findsOneWidget);
      expect(
        tester
            .widget<SwitchListTile>(
              find.byKey(const Key('settings_enable_locks')),
            )
            .onChanged,
        isNull,
      );
    },
  );

  testWidgets('per-app switches have distinct accessible labels', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await open(tester);
    expect(find.bySemanticsLabel('Lock Music'), findsOneWidget);
    expect(find.bySemanticsLabel('Lock Freeform'), findsOneWidget);
    semantics.dispose();
  });
  test(
    'pausing retains completed vocabulary steps for the next challenge',
    () async {
      await gate.setWordsPerUnlock(2);
      await gate.recordStepCompletion(
        wordId: 'recipe',
        targetApp: a,
        attempts: 1,
      );
      expect(gate.solvedWordIdsForApp(a), {'recipe'});
      await gate.setNativeApplicationLocked(a, false);
      await gate.setNativeApplicationLocked(a, true);
      expect(gate.solvedWordIdsForApp(a), {'recipe'});
      expect(gate.nativeStatus.durationFor(a), 15);
    },
  );
  const renderDir = String.fromEnvironment('VEEA_APP_LOCKS_RENDER_DIR');
  if (renderDir.isNotEmpty) {
    testWidgets('render populated and empty Settings states', (tester) async {
      tester.view.physicalSize = const Size(390, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.runAsync(() async {
        for (final entry in {
          'SF Pro Text': '/System/Library/Fonts/SFNS.ttf',
          'MaterialIcons':
              '/Users/kelvinm/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
        }.entries) {
          await (FontLoader(entry.key)..addFont(
                File(
                  entry.value,
                ).readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
              ))
              .load();
        }
      });
      Future<void> capture(String name) async {
        await tester.pumpAndSettle();
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const Key('locks_preview')),
        );
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 2);
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          await Directory(renderDir).create(recursive: true);
          await File(
            '$renderDir/$name.png',
          ).writeAsBytes(data!.buffer.asUint8List());
          image.dispose();
        });
      }

      await open(tester);
      await capture('settings-app-locks-light');
      await open(tester, dark: true);
      await capture('settings-app-locks-dark');
      apps.clear();
      enabled = false;
      await gate.refreshNativeScreenTime();
      await open(tester);
      await capture('settings-app-locks-empty');
    });
  }
}
