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
      pronunciation: '/rɪˈzɪliənt/',
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

  tearDown(() {
    commuteService.stop();
    commuteService.dispose();
  });

  Widget wrap(Widget child, {double textScale = 1.0, bool dark = false}) =>
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: playlistService),
          ChangeNotifierProvider.value(value: commuteService),
        ],
        child: MaterialApp(
          theme: dark ? PixelTheme.dark() : PixelTheme.light(),
          builder: (context, inner) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: inner!,
          ),
          home: Scaffold(body: child),
        ),
      );

  Future<void> openViaModal(
    WidgetTester tester, {
    List<VocabularyWord>? wordList,
    Size size = const Size(390, 844),
    double textScale = 1.0,
    bool dark = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      wrap(
        Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => CommuteTapeSelectorSheet.show(
                context,
                allWords: wordList ?? words,
                commuteService: commuteService,
              ),
              child: const Text('Open chooser'),
            ),
          ),
        ),
        textScale: textScale,
        dark: dark,
      ),
    );
    await tester.tap(find.text('Open chooser'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'shows word list first with hidden calendar, single footer count, and selection controls',
    (tester) async {
      await openViaModal(tester);

      // Clean sentence-case header & section labels; no legacy retro copy
      expect(find.text('Choose words'), findsOneWidget);
      expect(find.text('Words'), findsOneWidget);
      expect(find.text('Saved lists'), findsOneWidget);
      expect(find.text('COMMUTE TAPE SELECTOR ⏏️'), findsNothing);
      expect(find.text('📅 BY DATE (MULTI-DAY)'), findsNothing);
      expect(find.text('📼 CUSTOM PLAYLISTS'), findsNothing);

      // Calendar stays collapsed until requested; word list is immediately visible
      expect(find.byKey(const Key('listen_calendar_card')), findsNothing);
      expect(find.text('resilient'), findsOneWidget);
      expect(find.text('bottleneck'), findsOneWidget);

      // Single authoritative selection count in sticky footer (default = newest date)
      expect(find.byKey(const Key('listen_selected_count')), findsOneWidget);
      expect(find.text('2 words selected'), findsOneWidget);

      // Select all
      await tester.tap(find.byKey(const Key('listen_select_all')));
      await tester.pump();
      expect(find.text('4 words selected'), findsOneWidget);

      // Clear disables Play selection
      await tester.tap(find.byKey(const Key('listen_clear_selection')));
      await tester.pump();
      expect(find.text('0 words selected'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const Key('listen_play_selection')),
            )
            .onPressed,
        isNull,
      );

      // Individual word checkbox & date group header checkbox
      await tester.tap(find.byKey(const ValueKey('listen_word_w1')));
      await tester.pump();
      expect(find.text('1 word selected'), findsOneWidget);

      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('listen_date_2026-08-17')),
        80,
        scrollable: find
            .descendant(
              of: find.byKey(const Key('listen_words_scroll')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.tap(find.byKey(const ValueKey('listen_date_2026-08-17')));
      await tester.pump();
      expect(find.text('2 words selected'), findsOneWidget);

      // Confirm starts playback with the exact selected records
      await tester.tap(find.byKey(const Key('listen_play_selection')));
      await tester.pump();

      expect(commuteService.isPlaying, isTrue);
      expect(commuteService.totalWords, 2);
      expect(
        commuteService.playlist.map((w) => w.id),
        unorderedEquals(['w1', 'w3']),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('preserves active playback selection when reopened', (
    tester,
  ) async {
    commuteService.startPlayback([words[2], words[3]], autoplay: false);

    await openViaModal(tester);

    expect(find.text('2 words selected'), findsOneWidget);
    await tester.tap(find.byKey(const Key('listen_play_selection')));
    await tester.pump();

    expect(commuteService.totalWords, 2);
    expect(
      commuteService.playlist.map((w) => w.id),
      unorderedEquals(['w3', 'w4']),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'collapsible calendar supports multi-day selection and disables days without words',
    (tester) async {
      await openViaModal(tester, size: const Size(800, 1200));

      // Expand calendar deliberately
      await tester.tap(find.byKey(const Key('listen_calendar_toggle')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('listen_calendar_card')), findsOneWidget);
      expect(find.text('August 2026'), findsOneWidget);
      expect(find.text('Today'), findsOneWidget);

      // Day 15 has no words -> rendered as text but not interactive InkWell
      expect(find.text('15'), findsOneWidget);
      expect(find.widgetWithText(InkWell, '15'), findsNothing);

      // Days 16, 17, 18 have words -> interactive InkWells
      expect(find.widgetWithText(InkWell, '16'), findsOneWidget);
      expect(find.widgetWithText(InkWell, '17'), findsOneWidget);
      expect(find.widgetWithText(InkWell, '18'), findsOneWidget);

      // Clear then multi-select day 18 and day 17
      await tester.tap(find.byKey(const Key('listen_clear_selection')));
      await tester.pump();
      expect(find.text('0 words selected'), findsOneWidget);

      await tester.tap(find.widgetWithText(InkWell, '18'));
      await tester.pump();
      expect(find.text('2 words selected'), findsOneWidget);

      await tester.tap(find.widgetWithText(InkWell, '17'));
      await tester.pump();
      expect(find.text('3 words selected'), findsOneWidget);

      await tester.tap(find.byKey(const Key('listen_play_selection')));
      await tester.pump();

      expect(commuteService.totalWords, 3);
      expect(
        commuteService.playlist.map((w) => w.word),
        containsAll(['resilient', 'bottleneck', 'paradigm']),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Saved lists tab supports editing, playing, deleting, and saving from Words',
    (tester) async {
      await playlistService.createPlaylist('Tech Interview', ['w1', 'w3']);
      await openViaModal(tester, size: const Size(800, 1200));

      // Switch to Saved lists
      await tester.tap(find.byKey(const Key('listen_tab_saved_lists')));
      await tester.pumpAndSettle();

      expect(find.text('Tech Interview'), findsOneWidget);
      expect(find.text('Play (2)'), findsOneWidget);

      // Edit existing list
      await tester.tap(find.byTooltip('Edit list'));
      await tester.pumpAndSettle();
      expect(find.text('Edit list'), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('listen_list_name_field')),
        'System Design',
      );
      await tester.pump();
      await tester.tap(find.text('bottleneck'));
      await tester.pump();
      await tester.tap(find.byKey(const Key('listen_list_save_button')));
      await tester.pumpAndSettle();

      expect(find.text('System Design'), findsOneWidget);
      expect(find.text('Play (3)'), findsOneWidget);

      // Play saved list
      await tester.tap(find.text('Play (3)'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      expect(commuteService.isPlaying, isTrue);
      expect(commuteService.totalWords, 3);
      expect(commuteService.playlistTitle, 'System Design');
      expect(
        commuteService.playlist.map((w) => w.id),
        unorderedEquals(['w1', 'w2', 'w3']),
      );
      commuteService.stop();

      // Reopen and delete saved list
      await tester.tap(find.text('Open chooser'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('listen_tab_saved_lists')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Delete list'));
      await tester.pumpAndSettle();

      expect(find.text('System Design'), findsNothing);
      expect(find.text('No saved lists yet'), findsOneWidget);

      // Save current selection from Words tab as a new list
      await tester.tap(find.byKey(const Key('listen_tab_words')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('listen_save_as_list')));
      await tester.pumpAndSettle();

      expect(find.text('Save as list'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('listen_save_list_name_field')),
        'Daily Mix',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(find.text('Daily Mix'), findsOneWidget);
      expect(playlistService.playlists, hasLength(1));
      expect(playlistService.playlists.first.name, 'Daily Mix');
      expect(
        playlistService.playlists.first.wordIds,
        unorderedEquals(['w1', 'w2', 'w3']),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'creating a saved list keeps Save footer reachable with keyboard on 320px screen',
    (tester) async {
      await openViaModal(tester, size: const Size(320, 568));

      await tester.tap(find.byKey(const Key('listen_tab_saved_lists')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('listen_new_list_button')));
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: find.byKey(const Key('listen_list_editor_sheet')),
          matching: find.text('New list'),
        ),
        findsOneWidget,
      );

      // Simulate on-screen keyboard while naming the list
      tester.view.viewInsets = const FakeViewPadding(bottom: 260);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('listen_list_name_field')),
        'Commute Mix',
      );
      await tester.pump();

      final editorScrollable = find
          .descendant(
            of: find.byKey(const Key('listen_list_editor_scroll')),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(
        find.text('resilient').hitTestable(),
        80,
        scrollable: editorScrollable,
      );
      await tester.tap(find.text('resilient'));
      await tester.pump();

      // Sticky Save button stays visible and tappable above the keyboard
      final saveButton = find.byKey(const Key('listen_list_save_button'));
      expect(saveButton.hitTestable(), findsOneWidget);
      expect(tester.widget<FilledButton>(saveButton).onPressed, isNotNull);

      await tester.tap(saveButton);
      await tester.pumpAndSettle();

      expect(find.text('Commute Mix'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final layout in [
    (
      name: '320px at 200% text scale',
      size: const Size(320, 568),
      scale: 2.0,
      dark: false,
    ),
    (name: 'landscape', size: const Size(740, 360), scale: 1.0, dark: false),
    (name: 'dark mode', size: const Size(390, 844), scale: 1.0, dark: true),
  ]) {
    testWidgets('renders without overflow on ${layout.name}', (tester) async {
      await playlistService.createPlaylist('Commute Favorites', ['w1', 'w2']);

      await openViaModal(
        tester,
        size: layout.size,
        textScale: layout.scale,
        dark: layout.dark,
      );

      expect(find.text('Choose words'), findsOneWidget);
      expect(
        find.byKey(const Key('listen_play_selection')).hitTestable(),
        findsOneWidget,
      );

      // Expand calendar on this layout and verify clean rendering
      final calendarToggle = find.byKey(const Key('listen_calendar_toggle'));
      await tester.scrollUntilVisible(
        calendarToggle.hitTestable(),
        80,
        scrollable: find
            .descendant(
              of: find.byKey(const Key('listen_words_scroll')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.tap(calendarToggle);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('listen_calendar_card')), findsOneWidget);

      // Switch to Saved lists on this layout
      await tester.tap(find.byKey(const Key('listen_tab_saved_lists')));
      await tester.pumpAndSettle();
      expect(find.text('Commute Favorites'), findsOneWidget);

      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'uses lazy list rendering for large notebooks and preserves search selection',
    (tester) async {
      final largeNotebook = [
        for (var i = 0; i < 500; i++)
          VocabularyWord(
            id: 'w$i',
            word: 'word $i',
            meaning: 'meaning $i',
            date: '2026-08-18',
            createdAt: DateTime(2026, 8, 18),
            updatedAt: DateTime(2026, 8, 18),
          ),
      ];

      await openViaModal(tester, wordList: largeNotebook);

      expect(find.byType(Checkbox).evaluate().length, lessThan(40));

      await tester.tap(find.byKey(const Key('listen_clear_selection')));
      await tester.pump();
      expect(find.text('0 words selected'), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('listen_word_search')),
        'word 499',
      );
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: find.byKey(const ValueKey('listen_word_w499')),
          matching: find.text('word 499'),
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('listen_word_w499')));
      await tester.pump();
      expect(find.text('1 word selected'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
