import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:veea_english_app/core/config/app_config.dart';
import 'package:veea_english_app/core/theme/pixel_theme.dart';
import 'package:veea_english_app/data/local/sqlite_vocabulary_repository.dart';
import 'package:veea_english_app/models/vocabulary_word.dart';
import 'package:veea_english_app/providers/app_gate_provider.dart';
import 'package:veea_english_app/providers/auth_provider.dart';
import 'package:veea_english_app/providers/pro_provider.dart';
import 'package:veea_english_app/screens/pro_screen.dart';
import 'package:veea_english_app/services/app_gate_service.dart';
import 'package:veea_english_app/widgets/gate_learning_settings.dart';
import 'package:veea_english_app/widgets/practice_word_picker.dart';
import '../providers/pro_provider_test.dart' show TestAuth, TestPro;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  final now = DateTime(2026, 11, 26, 12);
  late SqliteVocabularyRepository repo;
  late AppGateProvider gate;
  late TestAuth auth;
  late TestPro proRepo;
  late ProProvider pro;

  setUp(() async {
    AppConfig.overrideFreeLaunch(null);
    AppConfig.overrideBaseUrl('http://localhost');
    AppConfig.overrideAppleProduct('app.test.pro');
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel(AppGateService.channelName),
          (_) async => null,
        );
    repo = await SqliteVocabularyRepository.open(
      path: inMemoryDatabasePath,
      now: () => now,
    );
    for (final word in ['recipe', 'consent', 'resilient', 'fluent', 'habit']) {
      await repo.insert(
        VocabularyWord.create(
          id: word,
          word: word,
          meaning: 'meaning of $word',
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
          child: GateLearningSettings(
            gate: gate,
            totalWords: gate.notebookWords.length,
          ),
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

  Future<void> drainSql(WidgetTester tester) async {
    // SQLite replies cross the test isolate boundary. Pump fake-time
    // continuations between real I/O turns, including dialog completion.
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 15)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  testWidgets(
    'Free user sees 1 word per unlock, can edit unlimited practice pool & pronunciation, and plus/edit/upgrade surface Pro',
    (tester) async {
      expect(AppConfig.isFreeLaunch, isFalse);
      expect(gate.canUseMultipleWords, isFalse);
      expect(gate.maximumWordsPerUnlock, 1);
      expect(gate.requiredWords, 1);

      await tester.pumpWidget(buildHarness());
      await tester.pumpAndSettle();

      // Unlimited free practice pool is visible and editable without paywall.
      expect(
        find.text('All 5 words · new words included automatically.'),
        findsOneWidget,
      );
      expect(find.text('1'), findsOneWidget);
      expect(find.text('More words per unlock with Pro'), findsOneWidget);
      expect(find.byKey(const Key('upgrade_words_per_unlock')), findsOneWidget);

      // Opening practice pool editor stays free.
      await tester.ensureVisible(find.text('Edit practice words'));
      await tester.runAsync(() async {
        await tester.tap(find.text('Edit practice words'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      expect(find.byType(PracticeWordPicker), findsOneWidget);
      Navigator.of(tester.element(find.byType(PracticeWordPicker))).pop();
      await tester.pumpAndSettle();
      await drainSql(tester);

      // Auto-play pronunciation remains free.
      final pronounceTile = find.widgetWithText(
        SwitchListTile,
        'Auto-play pronunciation',
      );
      await tester.ensureVisible(pronounceTile);
      await tester.runAsync(() async {
        await tester.tap(pronounceTile);
        for (var i = 0; i < 100 && !gate.config.autoPronounce; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pumpAndSettle();
      await drainSql(tester);
      expect(gate.config.autoPronounce, isTrue);

      // Tapping + with pool >= 2 surfaces ProScreen (does not silently do nothing).
      final plusButton = find.byTooltip('Increase words per unlock');
      await tester.ensureVisible(plusButton);
      await tester.tap(plusButton);
      await tester.pumpAndSettle();
      expect(find.byType(ProScreen), findsOneWidget);
      Navigator.of(tester.element(find.byType(ProScreen))).pop();
      await tester.pumpAndSettle();

      // Tapping the count number with pool >= 2 also surfaces ProScreen.
      final editCount = find.byKey(const Key('edit_unlock_count'));
      await tester.ensureVisible(editCount);
      await tester.tap(editCount);
      await tester.pumpAndSettle();
      expect(find.byType(ProScreen), findsOneWidget);
      Navigator.of(tester.element(find.byType(ProScreen))).pop();
      await tester.pumpAndSettle();

      // Tapping the inline upgrade button navigates to ProScreen.
      final upgradeBtn = find.byKey(const Key('upgrade_words_per_unlock'));
      await tester.ensureVisible(upgradeBtn);
      await tester.tap(upgradeBtn);
      await tester.pumpAndSettle();
      expect(find.byType(ProScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Pro user can increment, decrement, and edit multiple words bounded by practice pool',
    (tester) async {
      gate.setProAccess(true);
      expect(gate.canUseMultipleWords, isTrue);
      expect(gate.maximumWordsPerUnlock, 5);

      await tester.pumpWidget(buildHarness());
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('upgrade_words_per_unlock')), findsNothing);

      // Increment via + button.
      final plusButton = find.byTooltip('Increase words per unlock');
      await tester.ensureVisible(plusButton);
      await tester.runAsync(() async {
        await tester.tap(plusButton);
        for (var i = 0; i < 100 && gate.requiredWords != 2; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pumpAndSettle();
      expect(gate.requiredWords, 2);

      // Edit via dialog: rejects above pool size (6 > 5), accepts 4.
      await tester.tap(find.byKey(const Key('edit_unlock_count')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('unlock_count_input')), '6');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text('Enter a number from 1 to 5.'), findsOneWidget);

      await tester.enterText(find.byKey(const Key('unlock_count_input')), '4');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        for (var i = 0; i < 100 && gate.requiredWords != 4; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pumpAndSettle();
      await drainSql(tester);
      expect(gate.requiredWords, 4);

      // Decrement via - button.
      final minusButton = find.byTooltip('Decrease words per unlock');
      await tester.ensureVisible(minusButton);
      await tester.runAsync(() async {
        await tester.tap(minusButton);
        for (var i = 0; i < 100 && gate.requiredWords != 3; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pumpAndSettle();
      expect(gate.requiredWords, 3);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'missing ProProvider in older widget harness keeps free settings working and shows fallback on upsell',
    (tester) async {
      await tester.pumpWidget(buildHarness(includePro: false));
      await tester.pumpAndSettle();

      // Ordinary free settings render and work without crashing.
      expect(find.text('Practice words'), findsOneWidget);
      expect(find.text('1'), findsOneWidget);
      final upgradeButton = tester.widget<TextButton>(
        find.byKey(const Key('upgrade_words_per_unlock')),
      );
      expect(upgradeButton.onPressed, isNull);
      expect(find.text('Pro upgrades unavailable'), findsOneWidget);

      final pronounceTile = find.widgetWithText(
        SwitchListTile,
        'Auto-play pronunciation',
      );
      await tester.ensureVisible(pronounceTile);
      await tester.runAsync(() async {
        await tester.tap(pronounceTile);
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      expect(gate.config.autoPronounce, isTrue);

      // Invoking + without ProProvider shows a clear fallback SnackBar instead of crashing.
      final plusButton = find.byTooltip('Increase words per unlock');
      await tester.ensureVisible(plusButton);
      await tester.tap(plusButton);
      await tester.pumpAndSettle();
      expect(find.byType(ProScreen), findsNothing);
      expect(
        find.descendant(
          of: find.byType(SnackBar),
          matching: find.textContaining('Upgrades are unavailable right now.'),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'small 320px dark screen with 200% text scale and keyboard open in count dialog does not overflow',
    (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      // First verify Free upgrade layout at 320px, 200% text, dark mode.
      await tester.pumpWidget(buildHarness(dark: true, scale: 2));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const Key('upgrade_words_per_unlock')),
      );
      expect(tester.takeException(), isNull);

      // Next verify Pro numeric dialog with simulated keyboard insets (240px).
      gate.setProAccess(true);
      await tester.pumpWidget(
        buildHarness(
          dark: true,
          scale: 2,
          viewInsets: const EdgeInsets.only(bottom: 240),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('edit_unlock_count')));
      await tester.tap(find.byKey(const Key('edit_unlock_count')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('unlock_count_input')), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
