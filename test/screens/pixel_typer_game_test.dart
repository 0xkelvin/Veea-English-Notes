import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:veea_english_app/core/theme/pixel_theme.dart';
import 'package:veea_english_app/data/local/sqlite_vocabulary_repository.dart';
import 'package:veea_english_app/models/vocabulary_word.dart';
import 'package:veea_english_app/providers/theme_provider.dart';
import 'package:veea_english_app/providers/vocabulary_provider.dart';
import 'package:veea_english_app/screens/games/pixel_typer_game.dart';
import 'package:veea_english_app/services/tts_service.dart';

void main() {
  group('typerCanonical', () {
    test('lowercases and keeps letters and digits', () {
      expect(typerCanonical('Resilient'), 'resilient');
      expect(typerCanonical('P95'), 'p95');
    });

    test('strips the punctuation a phone keyboard should not have to type', () {
      expect(typerCanonical('state-of-the-art'), 'stateoftheart');
      expect(typerCanonical('ship it'), 'shipit');
      expect(typerCanonical("don't"), 'dont');
    });

    test('returns empty for a word with nothing typeable', () {
      expect(typerCanonical('—'), '');
    });
  });

  group('typerDisplaySlots', () {
    test('reveals only the typed prefix', () {
      final slots = typerDisplaySlots('brittle', 3);

      expect(slots.length, 7);
      expect(slots.every((s) => s.isTypeable), isTrue);
      expect(slots.take(3).every((s) => s.isRevealed), isTrue);
      expect(slots.skip(3).every((s) => s.isRevealed), isFalse);
    });

    test('always shows punctuation, and does not count it as typed', () {
      // Two letters typed ("st") must not leak the hyphen's neighbours.
      final slots = typerDisplaySlots('state-of-the-art', 2);

      final hyphens = slots.where((s) => s.char == '-').toList();
      expect(hyphens.length, 3);
      expect(hyphens.every((s) => s.isRevealed && !s.isTypeable), isTrue);

      final letters = slots.where((s) => s.isTypeable).toList();
      expect(letters.where((s) => s.isRevealed).length, 2);
    });

    test('reveals every letter once the whole word is typed', () {
      final slots = typerDisplaySlots('ship it', typerCanonical('ship it').length);
      expect(slots.every((s) => s.isRevealed), isTrue);
    });
  });

  group('PixelTyperGame', () {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;

    late SqliteVocabularyRepository repo;
    late VocabularyProvider vocabProvider;
    late ThemeProvider themeProvider;
    final today = DateTime(2026, 8, 18, 10);

    // Meaning -> word, so a test can read the badge on screen and know which
    // letters to press. Deliberately distinct initials: the game refuses to
    // spawn two targets that share a first letter.
    const seeded = {
      'kiên cường': 'resilient',
      'dễ vỡ': 'brittle',
      'tiện dụng': 'ergonomic',
      'bền bỉ': 'tenacious',
    };

    setUp(() async {
      repo = await SqliteVocabularyRepository.open(
        path: inMemoryDatabasePath,
        now: () => today,
      );

      var id = 0;
      for (final entry in seeded.entries) {
        await repo.insert(
          VocabularyWord.create(
            id: '${++id}',
            word: entry.value,
            meaning: entry.key,
            date: '2026-08-18',
            now: today,
          ),
        );
      }

      vocabProvider = VocabularyProvider(repo, now: () => today);
      await vocabProvider.init();
      themeProvider = ThemeProvider();
    });

    tearDown(() => repo.close());

    Widget buildApp(Widget child) {
      return MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: vocabProvider),
          ChangeNotifierProvider.value(value: themeProvider),
          ChangeNotifierProvider(create: (_) => TtsService()),
        ],
        child: MaterialApp(theme: PixelTheme.light(), home: child),
      );
    }

    Future<void> launch(WidgetTester tester) async {
      await tester.pumpWidget(buildApp(const PixelTyperGame()));
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)),
      );
      await tester.pump();
    }

    /// The word currently descending, read off its meaning badge.
    String visibleWord(WidgetTester tester) {
      for (final entry in seeded.entries) {
        if (find.text(entry.key).evaluate().isNotEmpty) return entry.value;
      }
      fail('no target badge on screen');
    }

    Future<void> pressLetter(WidgetTester tester, String letter) async {
      // By key, not by letter text: a revealed answer slot renders the same
      // glyph, and a tap on that would do nothing.
      await tester.tap(find.byKey(ValueKey('typer_key_$letter')));
      await tester.pump();
    }

    testWidgets('launches with the arena, keyboard, and full shields', (
      tester,
    ) async {
      await launch(tester);

      expect(find.text('PIXEL TYPER'), findsOneWidget);
      expect(find.text('TYPE THE ENGLISH WORD:'), findsOneWidget);
      expect(find.textContaining('SCORE:'), findsOneWidget);
      expect(find.text('WAVE 1'), findsOneWidget);
      // Full QWERTY on screen: no system keyboard to cover the descent field.
      expect(find.byKey(const ValueKey('typer_key_q')), findsOneWidget);
      expect(find.byKey(const ValueKey('typer_key_delete')), findsOneWidget);
    });

    testWidgets('typing a matching letter fills the buffer', (tester) async {
      await launch(tester);
      final word = visibleWord(tester);

      await pressLetter(tester, word[0]);

      expect(find.text('${word[0].toUpperCase()}▌'), findsOneWidget);
    });

    testWidgets('a letter that matches no target is rejected, not absorbed', (
      tester,
    ) async {
      await launch(tester);
      final word = visibleWord(tester);

      // 'z' starts none of the seeded words.
      expect(word.startsWith('z'), isFalse);
      await pressLetter(tester, 'z');

      // Buffer still shows the bare cursor.
      expect(find.text('▌'), findsOneWidget);
    });

    testWidgets('completing a word scores it and clears the buffer', (
      tester,
    ) async {
      await launch(tester);
      final word = visibleWord(tester);

      for (final letter in typerCanonical(word).split('')) {
        await pressLetter(tester, letter);
      }

      expect(find.text('▌'), findsOneWidget);
      expect(find.textContaining('SCORE: 0'), findsNothing);
      // The cleared word is called out in the arena.
      expect(find.textContaining(word.toUpperCase()), findsWidgets);

      // Let the unawaited SRS write land before the repo closes.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
    });

    testWidgets('a cleared word is rescheduled out of the due queue', (
      tester,
    ) async {
      // Every database round trip goes through runAsync: awaiting real I/O
      // directly would hang on the test's fake clock.
      Future<List<VocabularyWord>> due(WidgetTester tester) async {
        final rows = await tester.runAsync(
          () => vocabProvider.wordsDueForReview(limit: 10),
        );
        return rows!;
      }

      expect((await due(tester)).length, 4);

      await launch(tester);
      final word = visibleWord(tester);

      for (final letter in typerCanonical(word).split('')) {
        await pressLetter(tester, letter);
      }

      // The rating is written without being awaited, so give the real I/O a
      // moment and then flush the microtask it completes onto.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)),
      );
      await tester.pump();

      // Unlike every other game in the arcade, playing this one advances SM-2.
      expect((await due(tester)).map((w) => w.word), isNot(contains(word)));
    });

    testWidgets('lays out on a small phone without overflowing', (
      tester,
    ) async {
      // The on-screen keyboard costs a fixed slice of the screen; on the
      // shortest phone still supported, the arena has to absorb the rest.
      tester.view.physicalSize = const Size(320 * 3, 568 * 3);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      await launch(tester);

      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('typer_key_m')), findsOneWidget);
    });

    testWidgets('the hint key reveals the next letter', (tester) async {
      await launch(tester);
      final word = visibleWord(tester);

      await tester.tap(find.byKey(const ValueKey('typer_key_hint')));
      await tester.pump();

      expect(find.text('${word[0].toUpperCase()}▌'), findsOneWidget);
    });
  });
}
