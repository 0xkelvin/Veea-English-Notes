import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:veea_english_app/core/theme/pixel_theme.dart';
import 'package:veea_english_app/data/local/sqlite_vocabulary_repository.dart';
import 'package:veea_english_app/data/remote/api_client.dart';
import 'package:veea_english_app/data/remote/auth_api.dart';
import 'package:veea_english_app/data/remote/token_store.dart';
import 'package:veea_english_app/data/remote/vocabulary_api.dart';
import 'package:veea_english_app/models/part_of_speech.dart';
import 'package:veea_english_app/models/vocabulary_word.dart';
import 'package:veea_english_app/providers/auth_provider.dart';
import 'package:veea_english_app/providers/vocabulary_provider.dart';
import 'package:veea_english_app/screens/search_screen.dart';
import 'package:veea_english_app/screens/home_screen.dart';
import 'package:veea_english_app/screens/word_editor_screen.dart';
import 'package:veea_english_app/services/sync_service.dart';
import 'package:veea_english_app/services/tts_service.dart';
import 'package:veea_english_app/widgets/pixel/pixel_field.dart';

/// Renders whole screens to PNG so the pixel styling — and in particular the
/// Vietnamese diacritics in the bundled font — can be reviewed and regressions
/// caught. Regenerate with `flutter test --update-goldens`.
void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  // Without this the test renderer substitutes its placeholder font and every
  // glyph paints as a filled box — which would hide the whole point of these
  // goldens, namely that Vietnamese diacritics render in the pixel face.
  setUpAll(() async {
    await ui.loadFontFromList(
      File('assets/fonts/Handjet.ttf').readAsBytesSync(),
      fontFamily: PixelTheme.fontFamily,
    );
  });

  final today = DateTime(2026, 8, 18, 10);

  late SqliteVocabularyRepository repo;
  late VocabularyProvider provider;

  setUp(() async {
    repo = await SqliteVocabularyRepository.open(
      path: inMemoryDatabasePath,
      now: () => today,
    );

    Future<void> seed({
      required String id,
      required String word,
      required String meaning,
      String? pronunciation,
      PartOfSpeech? pos,
      String? source,
      List<String> examples = const [],
      List<String> tags = const [],
      String date = '2026-08-18',
      int hour = 9,
    }) {
      return repo.insert(
        VocabularyWord.create(
          id: id,
          word: word,
          meaning: meaning,
          date: date,
          now: DateTime(2026, 8, 18, hour),
          pronunciation: pronunciation,
          partOfSpeech: pos,
          source: source,
          examples: examples,
          tags: tags,
        ),
      );
    }

    await seed(
      id: '1',
      word: 'resilient',
      meaning: 'kiên cường, dẻo dai',
      pronunciation: '/rɪˈzɪliənt/',
      pos: PartOfSpeech.adjective,
      source: 'a PR review',
      examples: ['We need a resilient distributed system.'],
      tags: ['work', 'tech'],
      hour: 9,
    );
    await seed(
      id: '2',
      word: 'throttle',
      meaning: 'điều tiết, hãm lại',
      pos: PartOfSpeech.verb,
      source: 'standup',
      hour: 8,
    );
    await seed(
      id: '3',
      word: 'ergonomic',
      meaning: 'tiện dụng, dễ dùng',
      pronunciation: '/ˌɜːɡəˈnɒmɪk/',
      pos: PartOfSpeech.adjective,
      examples: ['an ergonomic API surface'],
      hour: 7,
    );
    // Yesterday, so the streak counter shows more than one.
    await seed(
      id: '4',
      word: 'brittle',
      meaning: 'giòn, dễ vỡ',
      date: '2026-08-17',
    );

    provider = VocabularyProvider(repo, now: () => today);
    await provider.init();
  });

  tearDown(() => repo.close());

  Widget wrap(Widget child, Brightness brightness) {
    // Nothing in these tests triggers a network call; the transport exists
    // only so the screens have the providers they read from.
    final apiClient = ApiClient(tokenStore: const TokenStore());

    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: provider),
        ChangeNotifierProvider(create: (_) => TtsService()),
        ChangeNotifierProvider(
          create: (_) => SyncService(
            repository: repo,
            api: VocabularyApi(apiClient),
            now: () => today,
          ),
        ),
        ChangeNotifierProvider(
          create: (_) => AuthProvider(
            authApi: AuthApi(client: apiClient, tokens: const TokenStore()),
            tokens: const TokenStore(),
            client: apiClient,
          ),
        ),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: brightness == Brightness.light
            ? PixelTheme.light()
            : PixelTheme.dark(),
        scrollBehavior: const PixelScrollBehavior(),
        home: child,
      ),
    );
  }

  Future<void> sizeToPhone(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1179, 2556);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
  }

  testWidgets('home screen, light', (tester) async {
    await sizeToPhone(tester);
    await tester.pumpWidget(wrap(const HomeScreen(), Brightness.light));
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(HomeScreen),
      matchesGoldenFile('home_light.png'),
    );
  });

  testWidgets('home screen, dark', (tester) async {
    await sizeToPhone(tester);
    await tester.pumpWidget(wrap(const HomeScreen(), Brightness.dark));
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(HomeScreen),
      matchesGoldenFile('home_dark.png'),
    );
  });

  testWidgets('word editor, light', (tester) async {
    await sizeToPhone(tester);
    await tester.pumpWidget(
      wrap(WordEditorScreen(existing: provider.words.first), Brightness.light),
    );
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(WordEditorScreen),
      matchesGoldenFile('editor_light.png'),
    );
  });

  testWidgets('word editor, dark', (tester) async {
    await sizeToPhone(tester);
    await tester.pumpWidget(
      wrap(WordEditorScreen(existing: provider.words.first), Brightness.dark),
    );
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(WordEditorScreen),
      matchesGoldenFile('editor_dark.png'),
    );
  });

  testWidgets('search results show which day each word came from', (
    tester,
  ) async {
    await sizeToPhone(tester);
    await tester.pumpWidget(wrap(const SearchScreen(), Brightness.light));
    await tester.pumpAndSettle();

    // Typed without diacritics, as it would be on a plain keyboard.
    await tester.enterText(find.byType(TextField), 'kien cuong');

    // Advance past the input debounce on the test clock...
    await tester.pump(const Duration(milliseconds: 300));
    // ...then give the real SQLite query, which runs off the test clock,
    // actual time to come back.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pumpAndSettle();

    expect(find.text('resilient'), findsOneWidget);

    await expectLater(
      find.byType(SearchScreen),
      matchesGoldenFile('search_light.png'),
    );
  });
}
