import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:veea_english_app/core/theme/pixel_theme.dart';
import 'package:veea_english_app/data/feedback_repository.dart';
import 'package:veea_english_app/providers/feedback_provider.dart';
import 'package:veea_english_app/screens/phone_account_screen.dart';
import 'package:veea_english_app/screens/feedback_screen.dart';
import 'package:veea_english_app/data/local/sqlite_vocabulary_repository.dart';
import 'package:veea_english_app/data/remote/api_client.dart';
import 'package:veea_english_app/data/remote/auth_api.dart';
import 'package:veea_english_app/data/remote/token_store.dart';
import 'package:veea_english_app/data/remote/vocabulary_api.dart';
import 'package:veea_english_app/models/part_of_speech.dart';
import 'package:veea_english_app/models/srs_review.dart';
import 'package:veea_english_app/models/vocabulary_word.dart';
import 'package:veea_english_app/providers/app_gate_provider.dart';
import 'package:veea_english_app/providers/auth_provider.dart';
import 'package:veea_english_app/providers/cartridge_provider.dart';
import 'package:veea_english_app/providers/theme_provider.dart';
import 'package:veea_english_app/providers/vocabulary_provider.dart';
import 'package:veea_english_app/providers/widget_provider.dart';
import 'package:veea_english_app/screens/app_gate_screen.dart';
import 'package:veea_english_app/screens/audio_commute_screen.dart';
import 'package:veea_english_app/screens/pixel_lens_screen.dart';
import 'package:veea_english_app/screens/home_screen.dart';
import 'package:veea_english_app/screens/learning_rules_screen.dart';
import 'package:veea_english_app/screens/review_screen.dart';
import 'package:veea_english_app/screens/search_screen.dart';
import 'package:veea_english_app/screens/selected_practice_words_screen.dart';
import 'package:veea_english_app/screens/settings_screen.dart';
import 'package:veea_english_app/screens/word_editor_screen.dart';
import 'package:veea_english_app/services/app_gate_service.dart';
import 'package:veea_english_app/services/pronunciation_service.dart';
import 'package:veea_english_app/services/sync_service.dart';
import 'package:veea_english_app/services/tts_service.dart';
import 'package:veea_english_app/widgets/practice_word_picker.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  const captureDir = String.fromEnvironment('VEEA_UX_CAPTURE_DIR');
  const fontPath = String.fromEnvironment('VEEA_UX_FONT');
  const iconFontPath = String.fromEnvironment('VEEA_UX_ICON_FONT');
  final now = DateTime(2026, 11, 7, 10);
  late SqliteVocabularyRepository repo;
  late VocabularyProvider vocabulary;
  late AppGateProvider gate;
  late List<VocabularyWord> words;
  late TtsService tts;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUpAll(() async {
    messenger.setMockMethodCallHandler(
      const MethodChannel('flutter_tts'),
      (_) async => 1,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel(AppGateService.channelName),
      (_) async => null,
    );
    for (final entry in [
      ('SF Pro Text', fontPath),
      ('MaterialIcons', iconFontPath),
    ]) {
      if (entry.$2.isNotEmpty) {
        final font = FontLoader(entry.$1)
          ..addFont(
            File(entry.$2).readAsBytes().then((b) => ByteData.sublistView(b)),
          );
        await font.load();
      }
    }
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    repo = await SqliteVocabularyRepository.open(
      path: inMemoryDatabasePath,
      now: () => now,
    );
    words = [
      VocabularyWord.create(
        id: 'a',
        word: 'resilient',
        meaning: 'Kiên cường, có khả năng phục hồi sau khó khăn',
        pronunciation: '/rɪˈzɪliənt/',
        date: '2026-11-07',
        now: now,
        partOfSpeech: PartOfSpeech.adjective,
        examples: ['She stayed resilient through a difficult year.'],
      ),
      VocabularyWord.create(
        id: 'b',
        word: 'curious',
        meaning: 'Tò mò, muốn tìm hiểu điều mới',
        date: '2026-11-05',
        now: now.subtract(const Duration(days: 2)),
        partOfSpeech: PartOfSpeech.adjective,
      ),
      VocabularyWord.create(
        id: 'c',
        word: 'counterintuitive',
        meaning: 'Trái với trực giác hoặc điều thường được mong đợi',
        date: '2026-11-07',
        now: now.subtract(const Duration(hours: 1)),
      ),
    ];
    for (final word in words) {
      await repo.insert(word);
    }
    vocabulary = VocabularyProvider(repo, now: () => now);
    await vocabulary.init();
    gate = AppGateProvider(repository: repo, now: () => now);
    await gate.init();
    await gate.setPracticeWords(['a', 'b']);
    tts = TtsService();
  });

  tearDown(() async {
    vocabulary.dispose();
    gate.dispose();
    tts.dispose();
    await repo.close();
  });

  Widget wrap(Widget child, {double scale = 1, bool dark = false}) {
    const tokens = TokenStore();
    final client = ApiClient(tokenStore: tokens);
    final sync = SyncService(repository: repo, api: VocabularyApi(client));
    return RepaintBoundary(
      key: const Key('ux_capture'),
      child: MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: vocabulary),
          ChangeNotifierProvider(
            create: (_) =>
                FeedbackProvider(FeedbackRepository(repo.database, client)),
          ),
          ChangeNotifierProvider.value(value: gate),
          ChangeNotifierProvider.value(value: tts),
          ChangeNotifierProvider(create: (_) => ThemeProvider()),
          ChangeNotifierProvider(create: (_) => WidgetProvider()),
          ChangeNotifierProvider(create: (_) => CartridgeProvider()),
          ChangeNotifierProvider(create: (_) => sync),
          ChangeNotifierProvider(
            create: (_) => AuthProvider(
              authApi: AuthApi(client: client, tokens: tokens),
              tokens: tokens,
              client: client,
              repository: repo,
              sync: sync,
            ),
          ),
          Provider<PronunciationService>(
            create: (_) => PronunciationService(repo.database),
          ),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: dark ? PixelTheme.dark() : PixelTheme.light(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: child,
        ),
      ),
    );
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 120)),
    );
    await tester.pumpAndSettle();
  }

  void viewport(WidgetTester tester, Size size, {double keyboard = 0}) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
    addTearDown(tester.view.reset);
  }

  Future<void> capture(WidgetTester tester, String name) async {
    if (captureDir.isEmpty) return;
    await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const Key('ux_capture')),
      );
      final image = await boundary.toImage(pixelRatio: 2);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('$captureDir/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(data!.buffer.asUint8List());
      image.dispose();
    });
  }

  final screens = <String, Widget Function()>{
    'listen': () => const AudioCommuteScreen(),
    'scan': () => const PixelLensScreen(),
    'notebook': () => const HomeScreen(),
    'settings': () => const SettingsScreen(),
    'account': () => const AccountScreen(),
    'feedback': () => const FeedbackScreen(),
    'protection': () => const AppProtectionScreen(),
    'learning_rules': () => LearningRulesScreen(gate: gate),
    'practice_picker': () =>
        PracticeWordPicker(words: words, selectedIds: const ['a', 'b']),
    'review_picker': () => PracticeWordPicker(
      words: words,
      selectedIds: const ['a', 'b', 'c'],
      title: 'Review words',
      confirmLabel: 'Start review',
      allowFutureWords: false,
      confirmAtBottom: true,
    ),
    'selected_words': () => SelectedPracticeWordsScreen(gate: gate),
    'add_word': () => const WordEditorScreen(),
    'edit_word': () => WordEditorScreen(existing: words.first),
    'search': () => const SearchScreen(),
    'review': () => const ReviewScreen(practiceAll: true),
    'unlock': () => AppGateScreen(
      targetApp: 'X',
      initialWord: words.first,
      previewMode: true,
    ),
  };
  final variants = [
    (name: 'phone', size: const Size(390, 844), scale: 1.0, dark: false),
    (name: 'large_text', size: const Size(320, 568), scale: 2.0, dark: false),
    (name: 'landscape', size: const Size(740, 360), scale: 1.0, dark: false),
    (name: 'dark', size: const Size(390, 844), scale: 1.0, dark: true),
  ];
  for (final screen in screens.entries) {
    for (final variant in variants) {
      testWidgets(
        '${screen.key} fits ${variant.name}',
        (tester) async {
          viewport(tester, variant.size);
          await tester.pumpWidget(
            wrap(screen.value(), scale: variant.scale, dark: variant.dark),
          );
          await settle(tester);
          expect(tester.takeException(), isNull);
          if (variant.name == 'phone' || variant.name == 'dark') {
            await capture(tester, '${screen.key}_${variant.name}');
          }
          if (screen.key == 'search') {
            await tester.tap(find.byKey(const Key('search_include_notes')));
            await settle(tester);
            expect(tester.takeException(), isNull);
          }
          await tester.pumpWidget(const SizedBox.shrink());
        },
        variant: const TargetPlatformVariant({TargetPlatform.iOS}),
      );
    }
  }

  for (final layout in [
    (name: 'phone', size: const Size(390, 844), scale: 1.0, keyboard: 0.0),
    (name: 'large_text', size: const Size(320, 568), scale: 2.0, keyboard: 0.0),
    (name: 'keyboard', size: const Size(390, 844), scale: 1.3, keyboard: 330.0),
  ]) {
    testWidgets(
      'Long suggested meaning has a separate action on ${layout.name}',
      (tester) async {
        viewport(tester, layout.size, keyboard: layout.keyboard);
        await tester.pumpWidget(
          wrap(const WordEditorScreen(), scale: layout.scale),
        );
        await settle(tester);
        await tester.enterText(
          find.descendant(
            of: find.byKey(const Key('word_editor_word')),
            matching: find.byType(TextField),
          ),
          words.first.word,
        );
        await settle(tester);
        final suggested = find.byKey(const Key('suggested_meaning_text'));
        final use = find.byKey(const Key('use_meaning_suggestion'));
        await tester.scrollUntilVisible(
          use,
          150,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        expect(tester.widget<Text>(suggested).maxLines, isNull);
        expect(tester.widget<Text>(suggested).data, words.first.meaning);
        expect(
          tester.getRect(use).top,
          greaterThan(tester.getRect(suggested).bottom),
        );
        expect(find.text('Use this meaning'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await capture(tester, 'meaning_suggestion_${layout.name}');
        await tester.tap(use);
        await settle(tester);
        final meaning = find.descendant(
          of: find.byKey(const Key('word_editor_meaning')),
          matching: find.byType(TextField),
        );
        // Inline duplicate information changes the form height. Find the
        // field from the top instead of assuming it stayed above the button.
        tester
            .state<ScrollableState>(find.byType(Scrollable).first)
            .position
            .jumpTo(0);
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          meaning,
          150,
          scrollable: find.byType(Scrollable).first,
        );
        expect(
          tester.widget<TextField>(meaning).controller!.text,
          words.first.meaning,
        );
        expect(find.byKey(const Key('suggested_meaning_text')), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: const TargetPlatformVariant({TargetPlatform.iOS}),
    );
  }

  for (final entry in {
    'add_word': () => const WordEditorScreen(),
    'search': () => const SearchScreen(),
    'practice_picker': () =>
        PracticeWordPicker(words: words, selectedIds: const ['a', 'b']),
    'review_picker': () => PracticeWordPicker(
      words: words,
      selectedIds: const ['a', 'b', 'c'],
      title: 'Review words',
      confirmLabel: 'Start review',
      allowFutureWords: false,
      confirmAtBottom: true,
    ),
    'unlock': () => AppGateScreen(
      targetApp: 'X',
      initialWord: words.first,
      previewMode: true,
    ),
  }.entries) {
    testWidgets(
      '${entry.key} remains usable with keyboard and larger text',
      (tester) async {
        viewport(tester, const Size(390, 844), keyboard: 330);
        await tester.pumpWidget(wrap(entry.value(), scale: 1.3));
        await settle(tester);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: const TargetPlatformVariant({TargetPlatform.iOS}),
    );
  }

  for (final entry in {
    'notebook': () => const HomeScreen(),
    'review': () => const ReviewScreen(),
    'selected_words': () => SelectedPracticeWordsScreen(gate: gate),
  }.entries) {
    testWidgets(
      '${entry.key} empty state supports enlarged text',
      (tester) async {
        viewport(tester, const Size(320, 568));
        await tester.runAsync(() async {
          for (final word in words) {
            await repo.softDelete(word.id, now);
          }
          await vocabulary.init();
          await gate.prepareChallenge();
        });
        await tester.pumpWidget(wrap(entry.value(), scale: 2));
        await settle(tester);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: const TargetPlatformVariant({TargetPlatform.iOS}),
    );
  }

  Future<void> openReviewPicker(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('choose_review_words')));
    await settle(tester);
    expect(find.text('Review words'), findsOneWidget);
    expect(
      find.byKey(const Key('include_future_practice_words')),
      findsNothing,
    );
  }

  Future<void> selectReviewDate(WidgetTester tester, String day) async {
    await tester.tap(find.byKey(const Key('practice_calendar')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(day));
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'Review picks across dates, preserves cancelled sessions and starts fresh stats',
    (tester) async {
      viewport(tester, const Size(390, 844));
      final configBefore = await tester.runAsync(
        () async => (await repo.getGateConfig()).toDbMap(),
      );
      await tester.pumpWidget(wrap(const ReviewScreen(practiceAll: true)));
      await settle(tester);
      await tester.tap(find.text('Show meaning'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Good'));
      await settle(tester);
      expect(find.text('Word 2 of 3'), findsOneWidget);
      await tester.tap(find.text('Show meaning'));
      await tester.pumpAndSettle();
      await openReviewPicker(tester);
      await tester.tap(find.byKey(const ValueKey('practice_word_a')));
      await tester.tap(find.byKey(const Key('cancel_practice_words')));
      await settle(tester);
      expect(find.text('Word 2 of 3'), findsOneWidget);
      expect(find.text('Good'), findsOneWidget);
      await openReviewPicker(tester);
      expect(
        tester
            .widget<CheckboxListTile>(
              find.byKey(const ValueKey('practice_word_a')),
            )
            .value,
        isTrue,
      );
      await tester.tap(find.byKey(const Key('practice_selection_options')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Clear entire selection (3)'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('save_practice_words')))
            .onPressed,
        isNull,
      );
      await selectReviewDate(tester, '5');
      await tester.tap(find.byKey(const Key('select_visible_practice_words')));
      await tester.pumpAndSettle();
      await selectReviewDate(tester, '7');
      await tester.tap(find.byKey(const ValueKey('practice_word_c')));
      await tester.pumpAndSettle();
      expect(find.text('2 of 3 words selected'), findsOneWidget);
      await capture(tester, 'review_selection_phone');
      await tester.tap(find.byKey(const Key('save_practice_words')));
      await settle(tester);
      expect(find.text('Word 1 of 2'), findsOneWidget);
      expect(find.text('2 days'), findsOneWidget);
      await capture(tester, 'review_selected_session_phone');
      for (var i = 0; i < 2; i++) {
        await tester.tap(find.text('Show meaning'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Good'));
        await settle(tester);
      }
      expect(find.text('Review complete'), findsOneWidget);
      expect(find.text('2 / 2'), findsOneWidget);
      await tester.runAsync(() async {
        expect((await repo.getGateConfig()).toDbMap(), configBefore);
        expect(await repo.recentGateLogs(), isEmpty);
        final reviews = await repo.database.query('srs_reviews');
        expect(reviews.map((row) => row['word_id']).toSet(), {'a', 'b', 'c'});
        expect(reviews.every((row) => row['repetitions'] == 1), isTrue);
      });
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: const TargetPlatformVariant({TargetPlatform.iOS}),
  );

  testWidgets(
    'Review all includes every saved word beyond the default cap and future due dates',
    (tester) async {
      viewport(tester, const Size(390, 844));
      await tester.runAsync(() async {
        for (var i = 0; i < 55; i++) {
          await repo.insert(
            VocabularyWord.create(
              id: 'extra-$i',
              word: 'extra $i',
              meaning: 'Meaning',
              date: '2026-11-07',
              now: now,
            ),
          );
        }
        await repo.recordSrsReview(
          wordId: 'b',
          rating: SrsRating.easy,
          now: now,
        );
        await vocabulary.init();
      });
      await tester.pumpWidget(wrap(const ReviewScreen()));
      await settle(tester);
      expect(find.text('Word 1 of 20'), findsOneWidget);
      await openReviewPicker(tester);
      await tester.tap(find.byKey(const Key('select_visible_practice_words')));
      await tester.pumpAndSettle();
      expect(find.text('58 of 58 words selected'), findsOneWidget);
      expect(
        find.byKey(const Key('include_future_practice_words')),
        findsNothing,
      );
      await tester.tap(find.byKey(const Key('save_practice_words')));
      await settle(tester);
      expect(find.text('Word 1 of 58'), findsOneWidget);
      expect(find.text('All words'), findsOneWidget);
      await openReviewPicker(tester);
      await tester.enterText(
        find.byKey(const Key('practice_word_search')),
        'curious',
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<CheckboxListTile>(
              find.byKey(const ValueKey('practice_word_b')),
            )
            .value,
        isTrue,
      );
      await tester.tap(find.byKey(const Key('cancel_practice_words')));
      await settle(tester);
      expect(find.text('Word 1 of 58'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: const TargetPlatformVariant({TargetPlatform.iOS}),
  );

  testWidgets(
    'Review selection load failure keeps the current session and can be retried',
    (tester) async {
      viewport(tester, const Size(390, 844));
      await tester.pumpWidget(wrap(const ReviewScreen(practiceAll: true)));
      await settle(tester);
      await tester.runAsync(
        () => repo.database.execute(
          'ALTER TABLE words RENAME TO unavailable_words',
        ),
      );
      await tester.tap(find.byKey(const Key('choose_review_words')));
      await settle(tester);
      expect(
        find.text('Could not load your words. Please try choosing again.'),
        findsOneWidget,
      );
      expect(find.text('Word 1 of 3'), findsOneWidget);
      await tester.runAsync(
        () => repo.database.execute(
          'ALTER TABLE unavailable_words RENAME TO words',
        ),
      );
      await openReviewPicker(tester);
      await tester.tap(find.byKey(const Key('cancel_practice_words')));
      await settle(tester);
      expect(find.text('Word 1 of 3'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: const TargetPlatformVariant({TargetPlatform.iOS}),
  );

  testWidgets(
    'reviewing recent words includes other dates and a failed save keeps the current card',
    (tester) async {
      viewport(tester, const Size(390, 844));
      await tester.runAsync(() async {
        await repo.database.execute(
          "CREATE TRIGGER reject_review BEFORE INSERT ON srs_reviews BEGIN SELECT RAISE(FAIL, 'test save failed'); END",
        );
      });
      await tester.pumpWidget(wrap(const ReviewScreen(practiceAll: true)));
      await settle(tester);
      expect(find.text('Word 1 of 3'), findsOneWidget);
      await tester.tap(find.text('Show meaning'));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.text('Good'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      expect(find.text('Word 1 of 3'), findsOneWidget);
      expect(
        find.text(
          'Your review was not saved. Please try rating this word again.',
        ),
        findsOneWidget,
      );
      await tester.runAsync(() async {
        expect(await repo.database.query('srs_reviews'), isEmpty);
        await repo.database.execute('DROP TRIGGER reject_review');
      });
      await tester.runAsync(() async {
        await tester.tap(find.text('Good'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      expect(find.text('Word 2 of 3'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final layout in [
    (name: 'phone', size: const Size(390, 844), scale: 1.0, dark: false),
    (name: 'large_text', size: const Size(320, 568), scale: 2.0, dark: false),
    (name: 'landscape', size: const Size(740, 360), scale: 1.0, dark: false),
    (name: 'dark', size: const Size(390, 844), scale: 1.0, dark: true),
  ]) {
    testWidgets(
      'Listening settings stay hidden until opened and preserve changes on ${layout.name}',
      (tester) async {
        viewport(tester, layout.size);
        await tester.pumpWidget(
          wrap(
            const AudioCommuteScreen(),
            scale: layout.scale,
            dark: layout.dark,
          ),
        );
        await settle(tester);
        expect(find.text('TAP PLAY TO BEGIN'), findsNothing);
        expect(find.byType(ChoiceChip), findsNothing);
        expect(find.byKey(const Key('listen_pause_menu')), findsNothing);
        expect(
          find.byKey(const Key('listen_settings_button')).hitTestable(),
          findsOneWidget,
        );
        await capture(tester, 'listen_clean_${layout.name}');
        await tester.tap(find.byKey(const Key('listen_settings_button')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('listen_settings_sheet')), findsOneWidget);
        final sheetScroll = find.descendant(
          of: find.byKey(const Key('listen_settings_scroll')),
          matching: find.byType(Scrollable),
        );
        for (final option in [
          ('listen_pause_menu', '3 sec'),
          ('listen_repeats_menu', '2 times'),
          ('listen_content_menu', 'Word and example'),
        ]) {
          final row = find.byKey(Key(option.$1));
          await tester.scrollUntilVisible(
            row.hitTestable(),
            180,
            scrollable: sheetScroll,
          );
          await tester.pumpAndSettle();
          await tester.tap(row);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          final item = find.byWidgetPredicate(
            (widget) =>
                widget is CheckedPopupMenuItem &&
                widget.child is Text &&
                (widget.child as Text).data == option.$2,
          );
          await tester.tap(item);
          await tester.pumpAndSettle();
          expect(
            find.descendant(of: row, matching: find.text(option.$2)),
            findsOneWidget,
          );
        }
        expect(find.byTooltip('Play'), findsOneWidget);
        await capture(tester, 'listen_settings_${layout.name}');
        await tester.tap(find.text('Done'));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('listen_settings_sheet')), findsNothing);
        expect(find.byKey(const Key('listen_pause_menu')), findsNothing);
        expect(find.byTooltip('Play'), findsOneWidget);
        await tester.tap(find.byKey(const Key('listen_settings_button')));
        await tester.pumpAndSettle();
        for (final value in ['3 sec', '2 times', 'Word and example']) {
          expect(find.text(value), findsOneWidget);
        }
        final pause = find.byKey(const Key('listen_pause_menu'));
        await tester.scrollUntilVisible(
          pause.hitTestable(),
          -180,
          scrollable: sheetScroll,
        );
        await tester.pumpAndSettle();
        await tester.tap(pause);
        await tester.pumpAndSettle();
        final selected = tester.widget<CheckedPopupMenuItem<int>>(
          find.byWidgetPredicate(
            (widget) =>
                widget is CheckedPopupMenuItem<int> && widget.value == 3,
          ),
        );
        expect(selected.checked, isTrue);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(
          find.descendant(of: pause, matching: find.text('3 sec')),
          findsOneWidget,
        );
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('listen_settings_sheet')), findsNothing);
        expect(find.byTooltip('Play'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: const TargetPlatformVariant({TargetPlatform.iOS}),
    );
  }

  testWidgets(
    'opening and dismissing listening settings keeps playback running',
    (tester) async {
      viewport(tester, const Size(390, 844));
      await tester.pumpWidget(wrap(const AudioCommuteScreen()));
      await settle(tester);
      await tester.tap(find.byTooltip('Play'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(find.byTooltip('Pause'), findsOneWidget);
      await tester.tap(find.byKey(const Key('listen_settings_button')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(find.byKey(const Key('listen_settings_sheet')), findsOneWidget);
      expect(find.byTooltip('Pause'), findsOneWidget);
      await tester.tap(find.text('Done'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(find.byKey(const Key('listen_settings_sheet')), findsNothing);
      expect(find.byTooltip('Pause'), findsOneWidget);
      await tester.tap(find.byTooltip('Pause'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: const TargetPlatformVariant({TargetPlatform.iOS}),
  );

  testWidgets(
    'Search defaults to English words and notes are an explicit option',
    (tester) async {
      viewport(tester, const Size(390, 844));
      await tester.runAsync(() async {
        for (final word in words) {
          await repo.softDelete(word.id, now);
        }
        for (final entry in {
          'consent': 'bằng lòng',
          'confront': 'đối đầu',
          'recipe': 'công thức, cách nấu ăn',
          'resilient': 'có khả năng phục hồi',
        }.entries) {
          await repo.insert(
            VocabularyWord.create(
              id: 'search-${entry.key}',
              word: entry.key,
              meaning: entry.value,
              date: '2026-11-07',
              now: now,
            ),
          );
        }
        await vocabulary.init();
      });
      await tester.pumpWidget(wrap(const SearchScreen()));
      await settle(tester);
      final scope = find.byKey(const Key('search_include_notes'));
      expect(tester.widget<FilterChip>(scope).selected, isFalse);
      await tester.enterText(find.byType(TextField), 'co');
      await tester.pump(const Duration(milliseconds: 200));
      await settle(tester);
      expect(find.text('2 words found'), findsOneWidget);
      expect(find.text('consent'), findsOneWidget);
      expect(find.text('confront'), findsOneWidget);
      expect(find.text('recipe'), findsNothing);
      await capture(tester, 'search_words_phone');
      await tester.tap(scope);
      await tester.pump(const Duration(milliseconds: 200));
      await settle(tester);
      expect(find.text('4 words found'), findsOneWidget);
      expect(tester.widget<FilterChip>(scope).selected, isTrue);
      await capture(tester, 'search_notes_phone');
      await tester.scrollUntilVisible(
        find.text('recipe'),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('recipe'), findsOneWidget);
      await tester.tap(scope);
      await tester.pump(const Duration(milliseconds: 200));
      await settle(tester);
      expect(find.text('2 words found'), findsOneWidget);
      expect(find.text('recipe'), findsNothing);
      await tester.enterText(find.byType(TextField), 'cong thuc');
      await tester.pump(const Duration(milliseconds: 200));
      await settle(tester);
      await tester.tap(find.text('Search meanings & notes'));
      await tester.pump(const Duration(milliseconds: 200));
      await settle(tester);
      expect(find.text('recipe'), findsOneWidget);
      await tester.tap(find.byTooltip('Clear search'));
      await tester.pumpAndSettle();
      expect(find.text('Find a saved word'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: const TargetPlatformVariant({TargetPlatform.iOS}),
  );

  testWidgets(
    'search failure offers retry, and clearing restores the search prompt',
    (tester) async {
      viewport(tester, const Size(390, 844));
      await tester.runAsync(
        () => repo.database.execute(
          'ALTER TABLE words RENAME TO words_temporarily_unavailable',
        ),
      );
      await tester.pumpWidget(wrap(const SearchScreen()));
      await settle(tester);
      await tester.enterText(find.byType(TextField), 'resilient');
      await tester.pump(const Duration(milliseconds: 200));
      await settle(tester);
      expect(
        find.text('Could not search your words. Please try again.'),
        findsOneWidget,
      );
      await tester.runAsync(
        () => repo.database.execute(
          'ALTER TABLE words_temporarily_unavailable RENAME TO words',
        ),
      );
      await tester.runAsync(() async {
        await tester.tap(find.text('Try again'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      expect(find.text('resilient'), findsWidgets);
      await tester.tap(find.byTooltip('Clear search'));
      await tester.pumpAndSettle();
      expect(find.text('Find a saved word'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
