import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:veea_english_app/core/config/app_config.dart';
import 'package:veea_english_app/core/theme/pixel_theme.dart';
import 'package:veea_english_app/data/local/sqlite_vocabulary_repository.dart';
import 'package:veea_english_app/data/pro_repository.dart';
import 'package:veea_english_app/models/vocabulary_word.dart';
import 'package:veea_english_app/providers/app_gate_provider.dart';
import 'package:veea_english_app/providers/auth_provider.dart';
import 'package:veea_english_app/providers/pro_provider.dart';
import 'package:veea_english_app/screens/pro_screen.dart';
import 'package:veea_english_app/services/app_gate_service.dart';
import 'package:veea_english_app/widgets/native_gate_settings.dart';
import '../providers/pro_provider_test.dart' show TestAuth, TestPro;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  const appA = 'native:00000000-0000-0000-0000-000000000001';
  const appB = 'native:00000000-0000-0000-0000-000000000002';
  final now = DateTime(2026, 11, 26, 12);

  late SqliteVocabularyRepository repo;
  late AppGateProvider gate;
  late TestAuth auth;
  late TestPro proRepo;
  late ProProvider pro;
  late List<MethodCall> calls;
  late Set<String> apps;
  late Set<String> paused;
  late Map<String, int> overrides;
  var defaultMinutes = 15;
  var enabled = true;
  var authorized = true;
  var pickerRequiresPro = false;

  Map<String, Object?> status() => {
    'supported': true,
    'available': true,
    'authorized': authorized,
    'enabled': enabled && apps.any((id) => !paused.contains(id)),
    'configured': enabled,
    'passMinutes': defaultMinutes,
    'applications': [
      for (final id in apps)
        {
          'id': id,
          'label': id == appA ? 'Safari' : 'Books',
          'lockEnabled': !paused.contains(id),
          'customPassMinutes': overrides[id],
        },
    ],
  };

  setUp(() async {
    AppConfig.overrideFreeLaunch(null);
    AppConfig.overrideBaseUrl('http://localhost');
    AppConfig.overrideAppleProduct('app.test.pro');
    SharedPreferences.setMockInitialValues({});
    apps = {appA};
    paused = {};
    overrides = {};
    calls = [];
    defaultMinutes = 15;
    enabled = true;
    authorized = true;
    pickerRequiresPro = false;

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
                if (pickerRequiresPro) {
                  throw PlatformException(
                    code: 'PRO_REQUIRED',
                    message: 'Upgrade to Pro to lock more than one app.',
                  );
                }
                return true;
              case 'setScreenTimeDuration':
                defaultMinutes = args['passMinutes'] as int;
                return status();
              case 'setScreenTimeApplicationDuration':
                final id = args['targetApp'] as String;
                if (args['passMinutes'] == null) {
                  overrides.remove(id);
                } else {
                  overrides[id] = args['passMinutes'] as int;
                }
                return status();
              case 'setScreenTimeEnabled':
                enabled = args['enabled'] as bool;
                if (!enabled) {
                  paused.addAll(apps);
                } else {
                  paused.clear();
                }
                return status();
              case 'removeScreenTimeApplication':
                final id = args['targetApp'] as String;
                apps.remove(id);
                paused.remove(id);
                overrides.remove(id);
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
    for (final word in ['recipe', 'consent', 'resilient']) {
      await repo.insert(
        VocabularyWord.create(
          id: word,
          word: word,
          meaning: 'meaning',
          date: '2026-11-26',
          now: now,
        ),
      );
    }
    gate = AppGateProvider(repository: repo, now: () => now);
    await gate.init();
    auth = TestAuth();
    proRepo = TestPro();
    pro = ProProvider(auth: auth, repository: proRepo);
    calls.clear();
  });

  tearDown(() async {
    AppConfig.overrideFreeLaunch(null);
    AppConfig.overrideBaseUrl(null);
    AppConfig.overrideAppleProduct(null);
    gate.dispose();
    pro.dispose();
    auth.dispose();
    await repo.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel(AppGateService.channelName),
          null,
        );
  });

  Widget buildHarness({
    bool includePro = true,
    bool dark = false,
    double scale = 1,
    EdgeInsets viewInsets = EdgeInsets.zero,
  }) {
    final app = MaterialApp(
      theme: dark ? PixelTheme.dark() : PixelTheme.light(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(scale),
          viewInsets: viewInsets,
        ),
        child: child!,
      ),
      home: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: NativeGateSettings(gate: gate, totalWords: 3),
        ),
      ),
    );
    if (!includePro) return app;
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthProvider>.value(value: auth),
        ChangeNotifierProvider<ProProvider>.value(value: pro),
      ],
      child: app,
    );
  }

  Future<void> tapAndWait(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await Scrollable.ensureVisible(tester.element(finder), alignment: 0.5);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pump();
    for (var i = 0; i < 100 && gate.nativeBusy; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    expect(gate.nativeBusy, isFalse);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'Free user sees single-app summary with Change App and can set default and per-app custom times without Pro upsell',
    (tester) async {
      expect(AppConfig.isFreeLaunch, isFalse);
      expect(pro.hasPro, isFalse);
      await tester.pumpWidget(buildHarness());
      await tester.pumpAndSettle();

      expect(find.text('Free · One app lock'), findsOneWidget);
      expect(
        find.textContaining('Lock 1 app with 1 word per unlock'),
        findsOneWidget,
      );
      expect(find.text('Change App'), findsOneWidget);

      // Both default and per-app custom durations are free with zero Pro upsell.
      for (final key in ['default_unlock_time', 'unlock_time_$appA']) {
        await tester.ensureVisible(find.byKey(ValueKey(key)));
        await tester.tap(find.byKey(ValueKey(key)));
        await tester.pumpAndSettle();
        expect(find.byType(ProScreen), findsNothing);
        expect(find.text('Custom time · Pro'), findsNothing);
        await tester.tap(find.text('Custom time'));
        await tester.pumpAndSettle();
        expect(find.text('Access duration'), findsOneWidget);
        expect(
          find.byKey(const Key('save_protection_duration')),
          findsOneWidget,
        );
        await tapAndWait(tester, find.text('Cancel'));
      }

      // Plan summary Get Pro button opens ProScreen.
      await tapAndWait(tester, find.byKey(const Key('plan_summary_upgrade')));
      expect(find.byType(ProScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Free user with legacy multi-app selection sees paused explanation and can remove or turn off locks without paywall trap',
    (tester) async {
      apps = {appA, appB};
      paused = {appB};
      await gate.refreshNativeScreenTime();

      await tester.pumpWidget(buildHarness());
      await tester.pumpAndSettle();

      expect(find.text('Your apps · 2'), findsOneWidget);
      expect(
        find.textContaining('Extra apps from earlier builds are paused'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Locking paused · Free locks 1 app at a time.'),
        findsOneWidget,
      );

      // Removing paused extra app succeeds freely without opening ProScreen.
      final removeBooks = find.descendant(
        of: find.byKey(const ValueKey('locked_app_$appB')),
        matching: find.widgetWithText(TextButton, 'Remove'),
      );
      await tester.ensureVisible(removeBooks);
      await tester.tap(removeBooks);
      await tester.pumpAndSettle();
      await tapAndWait(tester, find.text('Remove app'));
      expect(apps, {appA});
      expect(find.byType(ProScreen), findsNothing);

      // Disabling remaining lock turns off freely without opening ProScreen.
      await tapAndWait(
        tester,
        find.widgetWithText(SwitchListTile, 'Lock selected apps'),
      );
      expect(enabled, isFalse);
      expect(find.byType(ProScreen), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Free partial state can turn all locks off without buying or deleting selections',
    (tester) async {
      apps = {appA, appB};
      paused = {appB};
      await gate.refreshNativeScreenTime();
      await tester.pumpWidget(buildHarness());
      await tester.pumpAndSettle();
      await tapAndWait(tester, find.byKey(const Key('turn_off_all_locks')));
      expect(enabled, isFalse);
      expect(paused, {appA, appB});
      expect(apps, {appA, appB});
      expect(find.byType(ProScreen), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'native PRO_REQUIRED from multi-app picker opens ProScreen when ProProvider present and falls back to SnackBar when absent',
    (tester) async {
      pickerRequiresPro = true;

      // With ProProvider present -> navigates to ProScreen.
      await tester.pumpWidget(buildHarness(includePro: true));
      await tester.pumpAndSettle();
      await tapAndWait(tester, find.byKey(const Key('add_locked_apps')));
      expect(find.byType(ProScreen), findsOneWidget);
      expect(tester.takeException(), isNull);

      // Without ProProvider -> does not crash, shows clear SnackBar error.
      await tester.pumpWidget(buildHarness(includePro: false));
      await tester.pumpAndSettle();
      await tapAndWait(tester, find.byKey(const Key('add_locked_apps')));
      expect(find.byType(ProScreen), findsNothing);
      expect(
        find.descendant(
          of: find.byType(SnackBar),
          matching: find.text('Upgrade to Pro to lock more than one app.'),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Pro user sees Pro plan summary with Add Apps and no Get Pro button',
    (tester) async {
      proRepo.state = const ProStoreState(
        hasPro: true,
        hasLifetime: true,
        localApple: true,
        price: '99.000 ₫',
      );
      auth.select('user-1');
      await tester.pumpWidget(buildHarness());
      await tester.pumpAndSettle();

      expect(find.text('Pro · Multiple app locks'), findsOneWidget);
      expect(find.byKey(const Key('plan_summary_upgrade')), findsNothing);
      expect(find.text('Add Apps'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'small 320px dark screen with 200% text scale and keyboard insets does not overflow',
    (tester) async {
      apps = {appA, appB};
      paused = {appB};
      await gate.refreshNativeScreenTime();

      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        buildHarness(
          dark: true,
          scale: 2,
          viewInsets: const EdgeInsets.only(bottom: 200),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.widgetWithText(SwitchListTile, 'Lock selected apps'),
      );
      expect(tester.takeException(), isNull);
    },
  );
}
