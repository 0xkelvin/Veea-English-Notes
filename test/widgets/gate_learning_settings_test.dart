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
import 'package:veea_english_app/widgets/gate_learning_settings.dart';
import 'package:veea_english_app/widgets/practice_word_picker.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  const captureDir = String.fromEnvironment('VEEA_UX_CAPTURE_DIR');
  const fontPath = String.fromEnvironment('VEEA_UX_FONT');
  const iconPath = String.fromEnvironment('VEEA_UX_ICON_FONT');
  setUpAll(() async {
    for (final entry in [
      ('SF Pro Text', fontPath),
      ('MaterialIcons', iconPath),
    ]) {
      if (entry.$2.isNotEmpty) {
        await (FontLoader(
              entry.$1,
            )..addFont(File(entry.$2).readAsBytes().then(ByteData.sublistView)))
            .load();
      }
    }
  });
  Future<void> capture(WidgetTester tester, String name) async {
    if (captureDir.isEmpty) return;
    await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const Key('rules_capture')),
      );
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('$captureDir/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  final now = DateTime(2026, 11, 26, 12);
  late SqliteVocabularyRepository repo;
  late AppGateProvider gate;

  setUp(() async {
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
          meaning: const {
            'recipe': 'công thức nấu ăn',
            'consent': 'sự đồng ý',
            'resilient': 'kiên cường',
            'fluent': 'trôi chảy',
            'habit': 'thói quen',
          }[word]!,
          date: '2026-11-26',
          now: now,
        ),
      );
    }
    gate = AppGateProvider(repository: repo, now: () => now);
    await gate.init();
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

  Widget buildHarness({
    bool dark = false,
    double scale = 1,
    EdgeInsets viewInsets = EdgeInsets.zero,
  }) {
    final app = MaterialApp(
      debugShowCheckedModeBanner: false,
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
    return RepaintBoundary(key: const Key('rules_capture'), child: app);
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

  testWidgets('legacy count remains visible and pronunciation stays free', (
    tester,
  ) async {
    expect(gate.config.practiceWordIds, isNull);
    expect(gate.notebookWords.length, 5);
    await tester.pumpWidget(buildHarness());
    await tester.pumpAndSettle();
    expect(find.text('Review 1 word to unlock'), findsOneWidget);
    expect(
      find.textContaining('Your existing practice rule still applies'),
      findsOneWidget,
    );
    final pronunciation = find.widgetWithText(
      SwitchListTile,
      'Auto-play pronunciation',
    );
    await tester.ensureVisible(pronunciation);
    await tester.runAsync(() => tester.tap(pronunciation));
    await drainSql(tester);
    expect(gate.config.autoPronounce, isTrue);
    expect(gate.config.practiceWordIds, isNull);
  });

  testWidgets(
    'Free selection directly becomes the entire challenge and cancellation preserves it',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.runAsync(() => gate.setPracticeWords(['recipe', 'consent']));
      await tester.pumpWidget(buildHarness());
      await tester.pumpAndSettle();
      expect(find.text('Review 2 words to unlock'), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('edit_unlock_words')));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('practice_word_search')),
        'resilient',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('practice_word_resilient')));
      await tester.pumpAndSettle();
      expect(find.text('Use 3 words per unlock'), findsOneWidget);
      expect(
        find.byKey(const Key('include_future_practice_words')),
        findsNothing,
      );
      expect(find.byKey(const Key('edit_unlock_count')), findsNothing);
      await tester.enterText(find.byKey(const Key('practice_word_search')), '');
      await tester.pumpAndSettle();
      await capture(tester, 'picker_multiple');
      await tester.tap(find.byKey(const Key('cancel_practice_words')));
      await tester.pumpAndSettle();
      expect(gate.requiredWords, 2);
      await drainSql(tester);
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('edit_unlock_words')));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('practice_word_search')),
        'resilient',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('practice_word_resilient')));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('save_practice_words')));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await drainSql(tester);
      expect(gate.practiceWords.map((word) => word.id).toSet(), {
        'recipe',
        'consent',
        'resilient',
      });
      expect(gate.requiredWords, 3);
      expect(find.text('Review 3 words to unlock'), findsOneWidget);
      expect(find.text('WORDS PER UNLOCK'), findsNothing);
    },
  );

  for (final variant in [
    (false, 1.0, 390.0),
    (false, 2.0, 320.0),
    (true, 1.0, 390.0),
  ]) {
    testWidgets(
      'learning selection layout dark=${variant.$1} scale=${variant.$2}',
      (tester) async {
        tester.view.physicalSize = Size(variant.$3, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.runAsync(
          () => gate.setPracticeWords([
            'recipe',
            'consent',
            'resilient',
            'fluent',
          ]),
        );
        await tester.pumpWidget(
          buildHarness(dark: variant.$1, scale: variant.$2),
        );
        await tester.pumpAndSettle();
        expect(find.text('Review 4 words to unlock'), findsOneWidget);
        await capture(
          tester,
          'learning_${variant.$1
              ? 'dark'
              : variant.$2 > 1
              ? 'large_text'
              : 'multiple'}',
        );
        await tester.ensureVisible(find.text('Practice challenge'));
        expect(tester.takeException(), isNull);
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byKey(const Key('edit_unlock_words')));
        await tester.runAsync(() async {
          await tester.tap(find.byKey(const Key('edit_unlock_words')));
          await Future<void>.delayed(const Duration(milliseconds: 50));
        });
        await tester.pumpAndSettle();
        expect(find.byType(PracticeWordPicker), findsOneWidget);
        expect(
          find.byKey(const Key('save_practice_words')).hitTestable(),
          findsOneWidget,
        );
        await capture(
          tester,
          'picker_${variant.$1
              ? 'dark'
              : variant.$2 > 1
              ? 'large_text'
              : 'full'}',
        );
        expect(tester.takeException(), isNull);
        Navigator.of(tester.element(find.byType(PracticeWordPicker))).pop();
        await tester.pumpAndSettle();
        await drainSql(tester);
      },
    );
  }
}
