import 'package:flutter/material.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:veea_english_app/core/theme/pixel_theme.dart';
import 'package:veea_english_app/data/local/sqlite_vocabulary_repository.dart';
import 'package:veea_english_app/models/part_of_speech.dart';
import 'package:veea_english_app/providers/vocabulary_provider.dart';
import 'package:veea_english_app/screens/word_editor_screen.dart';
import 'package:veea_english_app/services/pronunciation_service.dart';
import 'package:veea_english_app/services/tts_service.dart';
import 'package:veea_english_app/services/word_suggestion_service.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late SqliteVocabularyRepository repo;
  late VocabularyProvider provider;
  late PronunciationService pronunciation;
  final today = DateTime(2026, 8, 18, 10);

  setUp(() async {
    WordSuggestionService.clearCache();
    repo = await SqliteVocabularyRepository.open(
      path: inMemoryDatabasePath,
      now: () => today,
    );
    provider = VocabularyProvider(repo, now: () => today);
    await provider.init();
    pronunciation = PronunciationService(repo.database);
  });

  tearDown(() => repo.close());

  Widget wrap(Widget child) => MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: provider),
      ChangeNotifierProvider(create: (_) => TtsService()),
      Provider<PronunciationService>.value(value: pronunciation),
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

  Future<void> openDetails(WidgetTester tester) async {
    // Dragging the form dismisses the keyboard and brings optional details
    // above the pinned Save area, as it does on a small phone.
    await tester.drag(find.byType(ListView).first, const Offset(0, -250));
    await tester.pumpAndSettle();
    await tester.tap(find.text('More details').hitTestable());
    await tester.pumpAndSettle();
  }

  Future<TextField> meaningField(WidgetTester tester) async {
    tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position
        .jumpTo(0);
    await tester.pumpAndSettle();
    final field = find.descendant(
      of: find.byKey(const Key('word_editor_meaning')),
      matching: find.byType(TextField),
    );
    await tester.scrollUntilVisible(
      field,
      100,
      scrollable: find.byType(Scrollable).first,
    );
    return tester.widget<TextField>(field);
  }

  testWidgets(
    'online lookup sends only the chosen word after explicit approval',
    (tester) async {
      final requests = <Uri>[];
      final client = MockClient((request) async {
        requests.add(request.url);
        return http.Response.bytes(
          utf8.encode(
            jsonEncode([
              [
                ["như mê cung", "labyrinthine", null, null, 1],
              ],
            ]),
          ),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });
      addTearDown(client.close);
      await tester.pumpWidget(wrap(WordEditorScreen(suggestionClient: client)));
      await settle(tester);
      await tester.enterText(find.byType(TextField).first, 'labyrinthine');
      await settle(tester);
      expect(requests, isEmpty);
      await tester.ensureVisible(
        find.byKey(const Key('online_meaning_lookup')),
      );
      await tester.tap(find.byKey(const Key('online_meaning_lookup')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Google Translate'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(requests, isEmpty);
      await tester.tap(find.byKey(const Key('online_meaning_lookup')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('approve_online_lookup')));
      await settle(tester);
      expect(requests, hasLength(1));
      expect(requests.single.queryParameters['q'], 'labyrinthine');
      expect(find.textContaining('như mê cung'), findsWidgets);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('typing another word clears the previous meaning suggestion', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(const WordEditorScreen()));
    await settle(tester);
    await tester.enterText(find.byType(TextField).first, 'solution');
    await settle(tester);
    expect(find.byKey(const Key('suggested_meaning_text')), findsOneWidget);
    await tester.enterText(
      find.byType(TextField).first,
      'unknownwordwithoutmeaning',
    );
    await settle(tester);
    expect(find.byKey(const Key('suggested_meaning_text')), findsNothing);
    expect(find.byKey(const Key('online_meaning_lookup')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'Typing "solution" suggests "giải pháp" and NOUN without showing "kiên cường"',
    (tester) async {
      await tester.pumpWidget(wrap(const WordEditorScreen()));
      await settle(tester);

      // Initial empty state has "kiên cường" as subtle default hint
      expect(find.text('kiên cường'), findsOneWidget);

      // Type "solution" into the word field
      await tester.enterText(find.byType(TextField).first, 'solution');
      await settle(tester);

      // "kiên cường" must NOT be displayed anymore
      expect(find.text('kiên cường'), findsNothing);

      // Should display suggested meaning with "giải pháp"
      expect(find.textContaining('giải pháp'), findsWidgets);

      // Part of speech header should display suggested NOUN
      await openDetails(tester);
      expect(find.text('GỢI Ý: NOUN'), findsOneWidget);

      // Tapping the suggestion pill fills the meaning field
      await tester.ensureVisible(
        find.byKey(const Key('use_meaning_suggestion')),
      );
      await tester.tap(find.byKey(const Key('use_meaning_suggestion')));
      await settle(tester);

      final meaning = await meaningField(tester);
      expect(meaning.controller?.text, contains('giải pháp'));
    },
  );

  testWidgets(
    'Typing English word suggests Vietnamese meaning and PartOfSpeech',
    (tester) async {
      await tester.pumpWidget(wrap(const WordEditorScreen()));
      await settle(tester);

      // Type "resilient" into the word field (first TextField)
      await tester.enterText(find.byType(TextField).first, 'resilient');
      await settle(tester);

      // Should display suggested meaning pill
      expect(find.byKey(const Key('use_meaning_suggestion')), findsWidgets);
      expect(find.textContaining('Kiên cường'), findsWidgets);

      // Part of speech header should display suggested ADJECTIVE
      await openDetails(tester);
      expect(find.text('GỢI Ý: ADJECTIVE'), findsOneWidget);

      // Tapping the suggestion pill fills the meaning field
      await tester.ensureVisible(
        find.byKey(const Key('use_meaning_suggestion')),
      );
      await tester.tap(find.byKey(const Key('use_meaning_suggestion')));
      await settle(tester);

      // Meaning field (second TextField) should now have the text
      final meaning = await meaningField(tester);
      expect(meaning.controller?.text.toLowerCase(), contains('kiên cường'));
    },
  );

  testWidgets('User manual PartOfSpeech selection overrides suggestion', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(const WordEditorScreen()));
    await settle(tester);

    // Type "resilient" -> suggests ADJECTIVE
    await tester.enterText(find.byType(TextField).first, 'resilient');
    await settle(tester);

    // Fill the required fields before scrolling into optional details.
    await tester.enterText(find.byType(TextField).at(1), 'nghĩa riêng');
    await settle(tester);

    await openDetails(tester);
    expect(find.text('GỢI Ý: ADJECTIVE'), findsOneWidget);

    // User explicitly taps "NOUN"
    await tester.ensureVisible(find.text('NOUN'));
    await tester.tap(find.text('NOUN'));
    await settle(tester);

    // Save should work with PartOfSpeech.noun
    await tester.tap(find.text('Save word'));
    await settle(tester);

    expect(provider.words.single.word, 'resilient');
    expect(provider.words.single.partOfSpeech, PartOfSpeech.noun);
  });

  testWidgets(
    'Typing "option" suggests Vietnamese meaning "lựa chọn" and NOUN',
    (tester) async {
      await tester.pumpWidget(wrap(const WordEditorScreen()));
      await settle(tester);

      await tester.enterText(find.byType(TextField).first, 'option');
      await settle(tester);

      expect(find.textContaining('lựa chọn'), findsWidgets);
      await openDetails(tester);
      expect(find.text('GỢI Ý: NOUN'), findsOneWidget);

      await tester.ensureVisible(
        find.byKey(const Key('use_meaning_suggestion')),
      );
      await tester.tap(find.byKey(const Key('use_meaning_suggestion')));
      await settle(tester);

      final meaning = await meaningField(tester);
      expect(meaning.controller?.text, contains('lựa chọn'));
    },
  );
}
