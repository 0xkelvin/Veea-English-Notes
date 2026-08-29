import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:veea_english_app/core/config/app_config.dart';
import 'package:veea_english_app/core/theme/pixel_theme.dart';
import 'package:veea_english_app/data/local/sqlite_vocabulary_repository.dart';
import 'package:veea_english_app/data/remote/api_client.dart';
import 'package:veea_english_app/data/remote/auth_api.dart';
import 'package:veea_english_app/data/remote/token_store.dart';
import 'package:veea_english_app/data/remote/vocabulary_api.dart';
import 'package:veea_english_app/models/part_of_speech.dart';
import 'package:veea_english_app/models/vocabulary_word.dart';
import 'package:veea_english_app/providers/auth_provider.dart';
import 'package:veea_english_app/providers/cartridge_provider.dart';
import 'package:veea_english_app/providers/pet_provider.dart';
import 'package:veea_english_app/providers/theme_provider.dart';
import 'package:veea_english_app/providers/vocabulary_provider.dart';
import 'package:veea_english_app/providers/widget_provider.dart';
import 'package:veea_english_app/screens/search_screen.dart';
import 'package:veea_english_app/screens/account_screen.dart';
import 'package:veea_english_app/screens/home_screen.dart';
import 'package:veea_english_app/screens/word_editor_screen.dart';
import 'package:veea_english_app/services/pronunciation_service.dart';
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
  late PronunciationService pronunciation;

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

    // The editor looks pronunciation up as the word is typed; importing here
    // means the goldens show what the user actually sees.
    pronunciation = PronunciationService(repo.database);
    await pronunciation.importIfNeeded();
  });

  tearDown(() => repo.close());

  Widget wrap(Widget child, Brightness brightness) {
    // Nothing in these tests triggers a network call; the transport exists
    // only so the screens have the providers they read from.
    final apiClient = ApiClient(tokenStore: const TokenStore());
    final syncService = SyncService(
      repository: repo,
      api: VocabularyApi(apiClient),
      now: () => today,
    );

    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: provider),
        ChangeNotifierProvider(create: (_) => TtsService()),
        ChangeNotifierProvider(create: (_) => ThemeProvider()),
        ChangeNotifierProvider(create: (_) => WidgetProvider()),
        ChangeNotifierProvider(create: (_) => PetProvider()),
        ChangeNotifierProvider(create: (_) => CartridgeProvider()),
        Provider<PronunciationService>.value(value: pronunciation),
        ChangeNotifierProvider(create: (_) => syncService),
        ChangeNotifierProvider(
          create: (_) => AuthProvider(
            authApi: AuthApi(client: apiClient, tokens: const TokenStore()),
            tokens: const TokenStore(),
            client: apiClient,
            repository: repo,
            sync: syncService,
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

  /// Pumps, then gives the pronunciation lookup — a real SQLite query, which
  /// runs off the test clock — actual time to come back.
  Future<void> settleWithLookup(WidgetTester tester) async {
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pumpAndSettle();
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
    await settleWithLookup(tester);

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
    await settleWithLookup(tester);

    await expectLater(
      find.byType(WordEditorScreen),
      matchesGoldenFile('editor_dark.png'),
    );
  });

  group('account screen', () {
    // The account UI only appears when a server is configured; the default
    // build is local-only.
    setUp(() => AppConfig.overrideBaseUrl('https://example.test'));
    tearDown(() => AppConfig.overrideBaseUrl(null));

    testWidgets('signed out, offering sign in', (tester) async {
      await sizeToPhone(tester);
      await tester.pumpWidget(wrap(const AccountScreen(), Brightness.light));
      await tester.pumpAndSettle();

      expect(find.text('SIGN IN TO SYNC'), findsOneWidget);
      await expectLater(
        find.byType(AccountScreen),
        matchesGoldenFile('account_signed_out.png'),
      );
    });

    testWidgets('the field labels itself as the input is read', (tester) async {
      await sizeToPhone(tester);
      await tester.pumpWidget(wrap(const AccountScreen(), Brightness.light));
      await tester.pumpAndSettle();

      // Starts ambiguous...
      expect(find.text('EMAIL OR PHONE'), findsOneWidget);

      await tester.enterText(
        find.byType(TextField).first,
        'kelvin@example.com',
      );
      await tester.pumpAndSettle();
      expect(find.text('EMAIL'), findsOneWidget);

      await tester.enterText(find.byType(TextField).first, '+84901234567');
      await tester.pumpAndSettle();
      expect(find.text('PHONE'), findsOneWidget);
    });

    testWidgets('a national number is refused with a clear reason', (
      tester,
    ) async {
      await sizeToPhone(tester);
      await tester.pumpWidget(wrap(const AccountScreen(), Brightness.light));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, '0901234567');
      await tester.pumpAndSettle();

      // The message names the actual problem rather than "invalid email".
      expect(
        find.textContaining('COUNTRY CODE', findRichText: true),
        findsOneWidget,
      );
    });
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
