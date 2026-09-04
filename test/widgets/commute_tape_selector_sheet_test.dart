import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:veea_english_app/core/theme/pixel_theme.dart';
import 'package:veea_english_app/models/vocabulary_word.dart';
import 'package:veea_english_app/services/audio_commute_service.dart';
import 'package:veea_english_app/services/commute_playlist_service.dart';
import 'package:veea_english_app/services/tts_service.dart';
import 'package:veea_english_app/widgets/commute_tape_selector_sheet.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AudioCommuteService commuteService;
  late CommutePlaylistService playlistService;

  final words = [
    VocabularyWord(
      id: 'w1',
      word: 'resilient',
      meaning: 'kiên cường',
      date: '2026-08-18',
      createdAt: DateTime(2026, 8, 18, 10),
      updatedAt: DateTime(2026, 8, 18, 10),
    ),
    VocabularyWord(
      id: 'w2',
      word: 'bottleneck',
      meaning: 'điểm nghẽn',
      date: '2026-08-18',
      createdAt: DateTime(2026, 8, 18, 11),
      updatedAt: DateTime(2026, 8, 18, 11),
    ),
    VocabularyWord(
      id: 'w3',
      word: 'paradigm',
      meaning: 'mô hình',
      date: '2026-08-17',
      createdAt: DateTime(2026, 8, 17, 9),
      updatedAt: DateTime(2026, 8, 17, 9),
    ),
    VocabularyWord(
      id: 'w4',
      word: 'synchronous',
      meaning: 'đồng bộ',
      date: '2026-08-16',
      createdAt: DateTime(2026, 8, 16, 9),
      updatedAt: DateTime(2026, 8, 16, 9),
    ),
  ];

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    playlistService = CommutePlaylistService(prefs: prefs);
    await playlistService.init();

    commuteService = AudioCommuteService(ttsService: TtsService());
  });

  Widget wrap(Widget child) => MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: playlistService),
      ChangeNotifierProvider.value(value: commuteService),
    ],
    child: MaterialApp(
      theme: PixelTheme.light(),
      home: Scaffold(body: child),
    ),
  );

  testWidgets('CommuteTapeSelectorSheet displays calendar and supports multi-day selection', (tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      wrap(
        CommuteTapeSelectorSheet(
          allWords: words,
          commuteService: commuteService,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Verify Title and Tabs
    expect(find.text('COMMUTE TAPE SELECTOR ⏏️'), findsOneWidget);
    expect(find.text('📅 THEO NGÀY (MULTI-DAY)'), findsOneWidget);
    expect(find.text('📼 DANH SÁCH TỰ TẠO'), findsOneWidget);

    // Verify Calendar header & actions
    expect(find.text('THÁNG 8 / 2026'), findsOneWidget);
    expect(find.text('HÔM NAY'), findsOneWidget);
    expect(find.text('TẤT CẢ TỪ'), findsOneWidget);
    expect(find.text('BỎ CHỌN'), findsOneWidget);

    // Verify Weekday row
    expect(find.text('T2'), findsOneWidget);
    expect(find.text('T7'), findsOneWidget);
    expect(find.text('CN'), findsOneWidget);

    // Verify Dates are rendered in list
    expect(find.text('NGÀY 2026-08-18'), findsOneWidget);
    expect(find.text('NGÀY 2026-08-17'), findsOneWidget);
    expect(find.text('NGÀY 2026-08-16'), findsOneWidget);

    // Tap 'TẤT CẢ TỪ' preset
    await tester.tap(find.text('TẤT CẢ TỪ'));
    await tester.pump();
    expect(find.text('ĐÃ CHỌN: 4 TỪ'), findsWidgets);

    // Tap 'BỎ CHỌN'
    await tester.tap(find.text('BỎ CHỌN'));
    await tester.pump();
    expect(find.text('ĐÃ CHỌN: 0 TỪ'), findsWidgets);

    // Toggle day 18 on calendar (cell with text '18')
    final day18Finder = find.widgetWithText(InkWell, '18');
    expect(day18Finder, findsOneWidget);
    await tester.tap(day18Finder);
    await tester.pump();
    expect(find.text('ĐÃ CHỌN: 2 TỪ'), findsWidgets);

    // Toggle day 17 on calendar (cell with text '17') - multi-day selection
    final day17Finder = find.widgetWithText(InkWell, '17');
    expect(day17Finder, findsOneWidget);
    await tester.tap(day17Finder);
    await tester.pump();
    expect(find.text('ĐÃ CHỌN: 3 TỪ'), findsWidgets);

    // Tap play selection
    await tester.tap(find.text('▶ PHÁT NGAY'));
    await tester.pump();

    expect(commuteService.totalWords, 3);
    expect(commuteService.playlist.map((w) => w.word), containsAll(['resilient', 'bottleneck', 'paradigm']));
  });

  testWidgets('CommuteTapeSelectorSheet grays down days without words on calendar', (tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      wrap(
        CommuteTapeSelectorSheet(
          allWords: words,
          commuteService: commuteService,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Day 15 has 0 words -> should NOT be an InkWell (disabled/grayed down)
    expect(find.widgetWithText(InkWell, '15'), findsNothing);
    // But text '15' is present inside the calendar grid
    expect(find.text('15'), findsOneWidget);

    // Days 16, 17, 18 have words -> they are interactive InkWells
    expect(find.widgetWithText(InkWell, '16'), findsOneWidget);
    expect(find.widgetWithText(InkWell, '17'), findsOneWidget);
    expect(find.widgetWithText(InkWell, '18'), findsOneWidget);
  });

  testWidgets('CommuteTapeSelectorSheet supports custom playlist tab', (tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    // Pre-seed a playlist
    await playlistService.createPlaylist('Tech Interview', ['w1', 'w3']);

    await tester.pumpWidget(
      wrap(
        CommuteTapeSelectorSheet(
          allWords: words,
          commuteService: commuteService,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Switch to custom playlist tab
    await tester.tap(find.text('📼 DANH SÁCH TỰ TẠO'));
    await tester.pumpAndSettle();

    // Verify seeded playlist is shown
    expect(find.text('TECH INTERVIEW'), findsOneWidget);
    expect(find.text('2 TỪ • TẠO NGÀY ${DateTime.now().toString().split(' ').first}'), findsOneWidget);

    // Tap play custom playlist
    await tester.tap(find.text('▶ PHÁT BĂNG NÀY (2 TỪ)'));
    await tester.pump();

    expect(commuteService.totalWords, 2);
    expect(commuteService.playlistTitle, 'TECH INTERVIEW');
    expect(commuteService.playlist.map((w) => w.word), containsAll(['resilient', 'paradigm']));
  });

  testWidgets('Tapping TẠO + opens _PlaylistEditorSheet without ListTile/Material assertions', (tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      wrap(
        CommuteTapeSelectorSheet(
          allWords: words,
          commuteService: commuteService,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Switch to custom playlist tab
    await tester.tap(find.text('📼 DANH SÁCH TỰ TẠO'));
    await tester.pumpAndSettle();

    // Tap 'TẠO +' button
    await tester.tap(find.text('TẠO +'));
    await tester.pumpAndSettle();

    // Verify Playlist Editor Sheet opened
    expect(find.text('TẠO PLAYLIST MỚI'), findsOneWidget);
    expect(find.text('Tên danh sách'), findsOneWidget);

    // Verify CheckboxListTiles rendered for words without assertions
    expect(find.text('resilient'), findsOneWidget);
    expect(find.text('bottleneck'), findsOneWidget);

    // Toggle word selection
    await tester.tap(find.text('resilient'));
    await tester.pump();

    // Enter title
    await tester.enterText(find.byType(TextField).first, 'My Custom Tape');
    await tester.pump();

    // Save playlist
    await tester.tap(find.text('LƯU DANH SÁCH 💾'));
    await tester.pumpAndSettle();

    // Verify playlist was saved and displayed
    expect(find.text('MY CUSTOM TAPE'), findsOneWidget);
  });
}
