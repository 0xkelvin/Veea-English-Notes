import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:veea_english_app/core/theme/pixel_theme.dart';
import 'package:veea_english_app/data/local/sqlite_vocabulary_repository.dart';
import 'package:veea_english_app/providers/vocabulary_provider.dart';
import 'package:veea_english_app/screens/word_editor_screen.dart';
import 'package:veea_english_app/services/pronunciation_service.dart';
import 'package:veea_english_app/services/tts_service.dart';
import 'package:veea_english_app/widgets/pixel/pixel_button.dart';

/// The editor must produce a transcription without the user typing one — none
/// of the characters in `/rɪˈzɪljənt/` exist on a phone keyboard.
void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  TestWidgetsFlutterBinding.ensureInitialized();

  final today = DateTime(2026, 8, 18, 10);

  late SqliteVocabularyRepository repo;
  late VocabularyProvider provider;
  late PronunciationService pronunciation;

  setUp(() async {
    repo = await SqliteVocabularyRepository.open(
      path: inMemoryDatabasePath,
      now: () => today,
    );
    provider = VocabularyProvider(repo, now: () => today);
    await provider.init();
    pronunciation = PronunciationService(repo.database);
    await pronunciation.importIfNeeded();
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

  /// Matches a pixel icon button by what it says it does. Semantics labels
  /// need the semantics tree switched on; the widget is directly findable.
  Finder iconButton(String label) => find.byWidgetPredicate(
    (widget) => widget is PixelIconButton && widget.semanticLabel == label,
  );

  /// Lets the real SQLite lookup, which runs off the test clock, come back.
  Future<void> settle(WidgetTester tester) async {
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('fills the transcription in as the word is typed', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(const WordEditorScreen()));
    await tester.pumpAndSettle();

    // Nothing to show before a word exists.
    expect(find.textContaining('/'), findsNothing);

    await tester.enterText(find.byType(TextField).first, 'resilient');
    await settle(tester);

    expect(find.text('/rɪˈzɪljənt/'), findsOneWidget);
    expect(find.text('PRONUNCIATION · AUTOMATIC'), findsOneWidget);
  });

  testWidgets('follows the word when it is edited', (tester) async {
    await tester.pumpWidget(wrap(const WordEditorScreen()));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, 'resilient');
    await settle(tester);
    expect(find.text('/rɪˈzɪljənt/'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, 'brittle');
    await settle(tester);

    expect(find.text('/ˈbrɪtəl/'), findsOneWidget);
    expect(find.text('/rɪˈzɪljənt/'), findsNothing);
  });

  testWidgets('says so when the dictionary does not know the word', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(const WordEditorScreen()));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, 'zzzqqqxyz');
    await settle(tester);

    // Better than a blank line, which reads as "still loading".
    expect(find.text('Not in the dictionary'), findsOneWidget);
  });

  testWidgets('saves the transcription without the user touching it', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(const WordEditorScreen()));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, 'resilient');
    await settle(tester);
    await tester.enterText(find.byType(TextField).at(1), 'kiên cường');
    await settle(tester);

    await tester.tap(find.text('SAVE WORD'));
    await settle(tester);

    expect(provider.words.single.pronunciation, 'rɪˈzɪljənt');
  });

  testWidgets('offers an override for what the dictionary gets wrong', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(const WordEditorScreen()));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, 'resilient');
    await settle(tester);

    await tester.tap(iconButton('Set the pronunciation by hand'));
    await tester.pumpAndSettle();

    // Typed with slashes, as a user copying from a dictionary would.
    await tester.enterText(find.byType(TextField).last, '/mine/');
    await tester.tap(find.text('USE THIS'));
    await settle(tester);

    expect(find.text('/mine/'), findsOneWidget);
    expect(find.text('PRONUNCIATION · YOURS'), findsOneWidget);
  });

  testWidgets('an override survives further edits to the word', (tester) async {
    await tester.pumpWidget(wrap(const WordEditorScreen()));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, 'resilient');
    await settle(tester);

    await tester.tap(iconButton('Set the pronunciation by hand'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'mine');
    await tester.tap(find.text('USE THIS'));
    await settle(tester);

    // Retyping the word must not silently undo the user's correction.
    await tester.enterText(find.byType(TextField).first, 'brittle');
    await settle(tester);

    expect(find.text('/mine/'), findsOneWidget);
    expect(find.text('/ˈbrɪtəl/'), findsNothing);
  });

  testWidgets('the override can be handed back to the dictionary', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(const WordEditorScreen()));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, 'resilient');
    await settle(tester);

    await tester.tap(iconButton('Set the pronunciation by hand'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'mine');
    await tester.tap(find.text('USE THIS'));
    await settle(tester);

    await tester.tap(iconButton('Use the automatic pronunciation'));
    await settle(tester);

    expect(find.text('/rɪˈzɪljənt/'), findsOneWidget);
    expect(find.text('PRONUNCIATION · AUTOMATIC'), findsOneWidget);
  });
}
