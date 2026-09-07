import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:veea_english_app/core/theme/pixel_theme.dart';
import 'package:veea_english_app/data/local/sqlite_vocabulary_repository.dart';
import 'package:veea_english_app/models/vocabulary_word.dart';
import 'package:veea_english_app/providers/vocabulary_provider.dart';
import 'package:veea_english_app/services/tts_service.dart';
import 'package:veea_english_app/widgets/date_bar.dart';
import 'package:veea_english_app/widgets/pixel/retro_calendar_sheet.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  TestWidgetsFlutterBinding.ensureInitialized();

  late SqliteVocabularyRepository repo;
  late VocabularyProvider vocabProvider;
  final today = DateTime(2026, 8, 18, 10);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    repo = await SqliteVocabularyRepository.open(
      path: inMemoryDatabasePath,
      now: () => today,
    );
    vocabProvider = VocabularyProvider(repo, now: () => today);
    await vocabProvider.init();

    // Day 1: 2026-08-18 (2 words)
    await vocabProvider.addWord(
      word: 'resilient',
      meaning: 'kiên cường',
    );
    await vocabProvider.addWord(
      word: 'bottleneck',
      meaning: 'điểm nghẽn',
    );

    // Day 2: 2026-08-16 (4 words)
    await repo.insert(
      VocabularyWord.create(
        id: 'custom_1',
        word: 'decouple',
        meaning: 'tách rời',
        date: '2026-08-16',
        now: today,
      ),
    );
    await repo.insert(
      VocabularyWord.create(
        id: 'custom_2',
        word: 'throughput',
        meaning: 'băng thông',
        date: '2026-08-16',
        now: today,
      ),
    );
    await repo.insert(
      VocabularyWord.create(
        id: 'custom_3',
        word: 'telemetry',
        meaning: 'dữ liệu đo xa',
        date: '2026-08-16',
        now: today,
      ),
    );
    await repo.insert(
      VocabularyWord.create(
        id: 'custom_4',
        word: 'idempotent',
        meaning: 'bảo toàn kết quả',
        date: '2026-08-16',
        now: today,
      ),
    );

    // Refresh provider
    await vocabProvider.selectDate(today);
  });

  tearDown(() => repo.close());

  Widget wrap(Widget child) => MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: vocabProvider),
          ChangeNotifierProvider(create: (_) => TtsService()),
        ],
        child: MaterialApp(theme: PixelTheme.light(), home: child),
      );

  Future<void> settle(WidgetTester tester) async {
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pumpAndSettle();
  }

  group('RetroCalendarSheet', () {
    testWidgets(
      'renders calendar sheet with grayed down empty days and word count badges',
      (tester) async {
        tester.view.physicalSize = const Size(800, 1600);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(
          wrap(
            Scaffold(
              body: Builder(
                builder: (context) => ElevatedButton(
                  onPressed: () =>
                      RetroCalendarSheet.show(context: context, provider: vocabProvider),
                  child: const Text('OPEN'),
                ),
              ),
            ),
          ),
        );
        await settle(tester);

        // Tap to open
        await tester.tap(find.text('OPEN'));
        await settle(tester);

        // Verify title and month
        expect(find.text('VOCABULARY CALENDAR'), findsOneWidget);
        expect(find.text('MONTH 8 / 2026'), findsOneWidget);
        expect(find.text('MONTH ACTIVITY: 6 WORDS · 2 DAYS LEARNED'), findsOneWidget);

        // Day 16 had 4 words: check that '4' badge is visible
        expect(find.text('4'), findsWidgets);

        // Day 18 had 2 words: check that '2' badge is visible
        expect(find.text('2'), findsWidgets);

        // Selected day details card
        expect(find.text('JUMP TO THIS DAY’S JOURNAL'), findsOneWidget);
      },
    );

    testWidgets('DateBar calendar icon opens RetroCalendarSheet', (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        wrap(
          const Scaffold(
            body: DateBar(),
          ),
        ),
      );
      await settle(tester);

      // Tap calendar icon button
      final calendarButton = find.bySemanticsLabel('Open calendar');
      expect(calendarButton, findsOneWidget);
      await tester.tap(calendarButton);
      await settle(tester);

      expect(find.text('VOCABULARY CALENDAR'), findsOneWidget);
      expect(find.text('MONTH 8 / 2026'), findsOneWidget);
    });

    testWidgets('Tapping a day in the calendar selects that day and jumps to journal', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        wrap(
          const Scaffold(
            body: DateBar(),
          ),
        ),
      );
      await settle(tester);

      // Open calendar
      await tester.tap(find.bySemanticsLabel('Open calendar'));
      await settle(tester);

      // Find day 16 (which has 4 words)
      final day16Finder = find.text('16');
      expect(day16Finder, findsWidgets);
      await tester.tap(day16Finder.first);
      await settle(tester);

      // Details card should preview day 16's 4 words
      expect(find.text('4 WORDS'), findsOneWidget);
      expect(find.text('decouple'), findsOneWidget);

      // Tap jump button
      await tester.tap(find.text('JUMP TO THIS DAY’S JOURNAL'));
      await settle(tester);

      // Calendar sheet should be closed
      expect(find.text('VOCABULARY CALENDAR'), findsNothing);

      // Provider selected date should now be 2026-08-16
      expect(vocabProvider.selectedDateKey, '2026-08-16');
    });

    testWidgets('Tapping an empty day reveals empty status and message', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        wrap(
          const Scaffold(
            body: DateBar(),
          ),
        ),
      );
      await settle(tester);

      await tester.tap(find.bySemanticsLabel('Open calendar'));
      await settle(tester);

      // Day 17 is yesterday (0 words recorded)
      final day17Finder = find.text('17');
      expect(day17Finder, findsWidgets);
      await tester.tap(day17Finder.first);
      await settle(tester);

      // Details card shows EMPTY badge and inactive notice
      expect(find.text('EMPTY'), findsWidgets);
      expect(find.text('No words were recorded on this day.'), findsOneWidget);
    });

    testWidgets('Month navigation switches month and TODAY button returns to today', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        wrap(
          const Scaffold(
            body: DateBar(),
          ),
        ),
      );
      await settle(tester);

      await tester.tap(find.bySemanticsLabel('Open calendar'));
      await settle(tester);

      expect(find.text('MONTH 8 / 2026'), findsOneWidget);

      // Tap previous month
      await tester.tap(find.bySemanticsLabel('Previous month'));
      await settle(tester);
      expect(find.text('MONTH 7 / 2026'), findsOneWidget);

      // Tap next month
      await tester.tap(find.bySemanticsLabel('Next month'));
      await settle(tester);
      expect(find.text('MONTH 8 / 2026'), findsOneWidget);

      // Select day 16, then tap TODAY
      await tester.tap(find.text('16').first);
      await settle(tester);
      expect(find.text('4 WORDS'), findsOneWidget);

      await tester.tap(find.text('TODAY'));
      await settle(tester);

      // Today is 2026-08-18 with 2 words
      expect(find.text('2 WORDS'), findsOneWidget);
    });

    testWidgets('Tapping DateBar center text label also opens RetroCalendarSheet', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        wrap(
          const Scaffold(
            body: DateBar(),
          ),
        ),
      );
      await settle(tester);

      // Tap date label in DateBar
      final dateLabel = find.text('TODAY · 18 Aug');
      expect(dateLabel, findsOneWidget);
      await tester.tap(dateLabel);
      await settle(tester);

      expect(find.text('VOCABULARY CALENDAR'), findsOneWidget);
    });
  });
}
