import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:veea_english_app/core/theme/pixel_theme.dart';
import 'package:veea_english_app/data/local/sqlite_vocabulary_repository.dart';
import 'package:veea_english_app/models/native_gate_status.dart';
import 'package:veea_english_app/models/vocabulary_word.dart';
import 'package:veea_english_app/providers/app_gate_provider.dart';
import 'package:veea_english_app/services/app_gate_service.dart';
import 'package:veea_english_app/widgets/guided_protection_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  const a = 'native:00000000-0000-0000-0000-000000000001';
  const b = 'native:00000000-0000-0000-0000-000000000002';
  var now = DateTime(2026, 11, 11, 12);
  DateTime? appExpiry;
  late SqliteVocabularyRepository repo;
  late AppGateProvider gate;
  late List<MethodCall> calls;
  late Set<String> apps;
  late Map<String, int> overrides;
  var defaultMinutes = 5;
  var authorized = true;
  var enabled = true;
  var failSave = false;
  Map<String, Object?> status() => {
    'supported': true,
    'available': true,
    'authorized': authorized,
    'enabled': enabled,
    'configured': enabled,
    'passMinutes': defaultMinutes,
    'applications': [
      for (final id in apps)
        {
          'id': id,
          'label': id == a ? 'Safari' : 'Books',
          'customPassMinutes': overrides[id],
          'unlockedUntil': id == a
              ? (appExpiry?.millisecondsSinceEpoch ?? 0) / 1000
              : 0,
        },
    ],
  };
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    apps = {a, b};
    overrides = {a: 15};
    calls = [];
    defaultMinutes = 5;
    authorized = true;
    enabled = true;
    failSave = false;
    appExpiry = null;
    now = DateTime(2026, 11, 11, 12);
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
                authorized = true;
                return status();
              case 'chooseScreenTimeApplications':
                return false; // User cancels the picker.
              case 'setScreenTimeApplicationDuration':
                if (failSave) {
                  throw PlatformException(
                    code: 'STORAGE',
                    message: 'Could not save this app’s time.',
                  );
                }
                final id = args['targetApp'] as String;
                if (args['passMinutes'] == null) {
                  overrides.remove(id);
                } else {
                  overrides[id] = args['passMinutes'] as int;
                }
                return status();
              case 'setScreenTimeDuration':
                defaultMinutes = args['passMinutes'] as int;
                return status();
              case 'setScreenTimeEnabled':
                enabled = args['enabled'] as bool;
                return status();
              case 'removeScreenTimeApplication':
                apps.remove(args['targetApp']);
                overrides.remove(args['targetApp']);
                if (apps.isEmpty) enabled = false;
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
    for (final word in ['consent', 'recipe', 'resilient']) {
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
  }) async {
    await tester.pumpWidget(
      RepaintBoundary(
        key: const Key('manage_apps_capture'),
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
            appBar: AppBar(title: const Text('Manage Apps to Lock')),
            body: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: GuidedProtectionSettings(
                gate: gate,
                totalWords: 3,
                onAddWord: () {},
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
    await tester.runAsync(() async {
      await tester.tap(finder);
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (gate.nativeBusy && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(gate.nativeBusy, isFalse);
    });
    await tester.pumpAndSettle();
  }

  test('status resolves a custom duration and falls back to the default', () {
    final parsed = NativeGateStatus.fromMap(status());
    expect(parsed.durationFor(a), 15);
    expect(parsed.durationFor(b), 5);
    expect(
      NativeGateStatus.fromMap({
        'passMinutes': 30,
        'applications': [
          {'id': b},
        ],
      }).durationFor(b),
      30,
    );
  });
  testWidgets('lists selected apps and makes custom versus default clear', (
    tester,
  ) async {
    await open(tester);
    expect(find.text('Safari'), findsOneWidget);
    expect(find.text('Books'), findsOneWidget);
    expect(find.text('Your apps · 2'), findsOneWidget);
    expect(find.text('Default · 5 min'), findsOneWidget);
    expect(find.text('15 min'), findsOneWidget);
    expect(find.textContaining('Every Open'), findsNothing);
  });
  testWidgets(
    'a custom duration changes only that app and can revert to default',
    (tester) async {
      await open(tester);
      await tap(tester, find.byKey(const ValueKey('unlock_time_$b')));
      await tap(tester, find.text('30 minutes'));
      expect(gate.nativeStatus.durationFor(a), 15);
      expect(gate.nativeStatus.durationFor(b), 30);
      await tap(tester, find.byKey(const ValueKey('unlock_time_$b')));
      await tap(tester, find.text('Use default'));
      expect(gate.nativeStatus.durationFor(b), 5);
      expect(
        calls
            .lastWhere((c) => c.method == 'setScreenTimeApplicationDuration')
            .arguments,
        {'targetApp': b, 'passMinutes': null},
      );
    },
  );
  testWidgets(
    'changing default leaves overrides intact; cancelling does not save',
    (tester) async {
      await open(tester);
      await tap(tester, find.byKey(const Key('default_unlock_time')));
      await tap(tester, find.text('15 minutes'));
      expect(gate.nativeStatus.durationFor(b), 15);
      expect(overrides[a], 15);
      final saves = calls
          .where((c) => c.method == 'setScreenTimeDuration')
          .length;
      await tap(tester, find.byKey(const Key('default_unlock_time')));
      await tap(tester, find.text('Cancel'));
      expect(
        calls.where((c) => c.method == 'setScreenTimeDuration').length,
        saves,
      );
    },
  );
  testWidgets(
    'custom time opens the wheel and cancellation keeps the app rule',
    (tester) async {
      await open(tester);
      await tap(tester, find.byKey(const ValueKey('unlock_time_$a')));
      await tap(tester, find.text('Custom time'));
      expect(find.text('Hours'), findsOneWidget);
      expect(find.text('Minutes'), findsOneWidget);
      await tap(tester, find.text('Cancel'));
      expect(overrides[a], 15);
      expect(
        calls.where((c) => c.method == 'setScreenTimeApplicationDuration'),
        isEmpty,
      );
    },
  );
  testWidgets('removal needs confirmation and leaves the other app selected', (
    tester,
  ) async {
    await open(tester);
    await tap(tester, find.widgetWithText(TextButton, 'Remove').first);
    await tap(tester, find.text('Cancel'));
    expect(apps, {a, b});
    await tap(tester, find.widgetWithText(TextButton, 'Remove').first);
    await tap(tester, find.text('Remove app'));
    expect(apps, {b});
    expect(overrides.containsKey(a), isFalse);
    expect(find.text('Your apps · 1'), findsOneWidget);
  });
  test(
    'removing the final app turns locking off; invalid override never reaches iOS',
    () async {
      expect(await gate.setNativeApplicationDuration(a, 0), isFalse);
      expect(
        calls.where((c) => c.method == 'setScreenTimeApplicationDuration'),
        isEmpty,
      );
      await gate.removeNativeApplication(a);
      await gate.removeNativeApplication(b);
      expect(gate.nativeStatus.applications, isEmpty);
      expect(gate.nativeStatus.enabled, isFalse);
    },
  );
  testWidgets('save failure keeps the old duration and displays the error', (
    tester,
  ) async {
    failSave = true;
    await open(tester);
    await tap(tester, find.byKey(const ValueKey('unlock_time_$a')));
    await tap(tester, find.text('30 minutes'));
    expect(gate.nativeStatus.durationFor(a), 15);
    expect(
      find
          .descendant(
            of: find.byType(SnackBar),
            matching: find.text('Could not save this app’s time.'),
          )
          .hitTestable(),
      findsOneWidget,
    );
  });
  testWidgets(
    'picker cancellation keeps selected apps; authorization comes first',
    (tester) async {
      authorized = false;
      await gate.refreshNativeScreenTime();
      await open(tester);
      calls.clear();
      await tap(tester, find.text('Add Apps'));
      expect(calls.map((c) => c.method), [
        'requestScreenTimeAuthorization',
        'chooseScreenTimeApplications',
        'getScreenTimeStatus',
      ]);
      expect(gate.nativeStatus.applications.length, 2);
    },
  );
  testWidgets('compact dark screen with large text remains usable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await open(tester, dark: true, scale: 2);
    expect(tester.takeException(), isNull);
    await tap(tester, find.byKey(const ValueKey('unlock_time_$b')));
    await tap(tester, find.text('Use default'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('time sheets identify the app and announce the selected choice', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await open(tester);
    await tap(tester, find.byKey(const ValueKey('unlock_time_$b')));
    expect(
      find.descendant(
        of: find.byType(BottomSheet),
        matching: find.text('Books'),
      ),
      findsOneWidget,
    );
    expect(
      tester
          .getSemantics(find.widgetWithText(ListTile, 'Use default'))
          .flagsCollection
          .isSelected,
      ui.Tristate.isTrue,
    );
    await tap(tester, find.text('Custom time'));
    expect(
      find.descendant(
        of: find.byType(BottomSheet),
        matching: find.text('Books'),
      ),
      findsOneWidget,
    );
    await tap(tester, find.text('Cancel'));
    semantics.dispose();
  });
  test(
    'failed history cleanup cannot undo or misreport native removal',
    () async {
      await repo.database.execute(
        "CREATE TRIGGER reject_round_cleanup BEFORE DELETE ON gate_round_progress BEGIN SELECT RAISE(ABORT, 'test cleanup failure'); END",
      );
      // Force a row so SQLite executes the trigger on deletion.
      await gate.setWordsPerUnlock(2);
      await gate.recordStepCompletion(
        wordId: 'recipe',
        targetApp: a,
        attempts: 1,
      );
      expect(await gate.removeNativeApplication(a), isTrue);
      expect(gate.nativeStatus.applications.map((app) => app.id), [b]);
      expect(gate.nativeError, isNull);
      expect(gate.solvedWordIdsForApp(a), isEmpty);
    },
  );
  testWidgets('an expired pass label refreshes while management stays open', (
    tester,
  ) async {
    appExpiry = now.add(const Duration(seconds: 1));
    await gate.refreshNativeScreenTime();
    await open(tester);
    expect(find.textContaining('Unlocked until'), findsOneWidget);
    now = now.add(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(find.textContaining('Unlocked until'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
  const renderDir = String.fromEnvironment('VEEA_MANAGE_APPS_RENDER_DIR');
  if (renderDir.isNotEmpty) {
    testWidgets('render management and time sheet for visual review', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 1050);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.runAsync(() async {
        final font = FontLoader('SF Pro Text')
          ..addFont(
            File(
              '/System/Library/Fonts/SFNS.ttf',
            ).readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
          );
        await font.load();
        final icons = FontLoader('MaterialIcons')
          ..addFont(
            File(
              '/Users/kelvinm/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
            ).readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
          );
        await icons.load();
      });
      Future<void> capture(String name) async {
        await tester.pumpAndSettle();
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const Key('manage_apps_capture')),
        );
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 2);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await Directory(renderDir).create(recursive: true);
          await File(
            '$renderDir/$name.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }

      await open(tester);
      await capture('manage-apps-light');
      await tap(tester, find.byKey(const ValueKey('unlock_time_$b')));
      await capture('app-unlock-time-light');
      await tap(tester, find.text('Cancel'));
      await open(tester, dark: true);
      await capture('manage-apps-dark');
      expect(tester.takeException(), isNull);
    });
  }
}
