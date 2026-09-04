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

  testWidgets('CommuteTapeSelectorSheet displays dates and supports multi-day presets', (tester) async {
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

    // Verify Presets are present
    expect(find.text('HÔM NAY'), findsOneWidget);
    expect(find.text('3 NGÀY GẦN ĐÂY'), findsOneWidget);
    expect(find.text('TẤT CẢ TỪ'), findsOneWidget);

    // Verify Dates are rendered
    expect(find.text('NGÀY 2026-08-18'), findsOneWidget);
    expect(find.text('NGÀY 2026-08-17'), findsOneWidget);
    expect(find.text('NGÀY 2026-08-16'), findsOneWidget);

    // Tap 'TẤT CẢ TỪ' preset
    await tester.tap(find.text('TẤT CẢ TỪ'));
    await tester.pump();
    expect(find.text('ĐÃ CHỌN: 4 TỪ'), findsOneWidget);

    // Tap 'BỎ CHỌN'
    await tester.tap(find.text('BỎ CHỌN'));
    await tester.pump();
    expect(find.text('ĐÃ CHỌN: 0 TỪ'), findsOneWidget);

    // Toggle 2026-08-18 checkbox (2 words)
    await tester.tap(find.text('NGÀY 2026-08-18'));
    await tester.pump();

    // Toggle 2026-08-17 day header checkbox
    final day17Finder = find.ancestor(
      of: find.text('NGÀY 2026-08-17'),
      matching: find.byType(InkWell),
    );
    await tester.tap(day17Finder);
    await tester.pump();

    // Tap play selection
    await tester.tap(find.text('HÔM NAY'));
    await tester.pump();
    expect(find.text('ĐÃ CHỌN: 2 TỪ'), findsOneWidget);

    await tester.tap(find.text('▶ PHÁT NGAY'));
    await tester.pump();

    expect(commuteService.totalWords, 2);
    expect(commuteService.playlist.map((w) => w.word), containsAll(['resilient', 'bottleneck']));
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
}
