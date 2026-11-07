import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:veea_english_app/core/theme/pixel_theme.dart';
import 'package:veea_english_app/data/local/sqlite_vocabulary_repository.dart';
import 'package:veea_english_app/models/vocabulary_word.dart';
import 'package:veea_english_app/providers/vocabulary_provider.dart';
// import 'package:veea_english_app/screens/arcade_screen.dart';
import 'package:veea_english_app/screens/home_screen.dart';
import 'package:veea_english_app/screens/word_editor_screen.dart';
import 'package:veea_english_app/services/tts_service.dart';
import 'package:veea_english_app/widgets/pixel/pixel_icon.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

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
  });

  tearDown(() => repo.close());

  Widget wrap(Widget child) => MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: vocabProvider),
      ChangeNotifierProvider(create: (_) => TtsService()),
    ],
    child: MaterialApp(theme: PixelTheme.light(), home: child),
  );

  testWidgets('HomeScreen renders Dual-Bar layout cleanly with games hidden', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(wrap(const HomeScreen()));
    await tester.pumpAndSettle();

    // Top Bar verification (Minimal & focused, "VEEA // JOURNAL" removed)
    expect(find.text('VEEA // JOURNAL'), findsNothing);
    expect(
      find.byTooltip('Search all words'),
      findsNothing,
    ); // Using semanticLabels
    expect(find.bySemanticsLabel('Search all words'), findsOneWidget);
    expect(find.bySemanticsLabel('Scan words with camera'), findsOneWidget);
    expect(find.bySemanticsLabel('Settings'), findsOneWidget);

    // Bottom Dock verification (ARCADE is hidden)
    expect(find.text('Listen'), findsOneWidget);
    expect(find.text('ARCADE'), findsNothing);
    expect(find.text('Add word'), findsOneWidget);
    expect(find.text('Review'), findsOneWidget);

    // Tap Hero ADD button -> opens WordEditorScreen
    await tester.tap(find.text('Add word'));
    await tester.pumpAndSettle();
    expect(find.byType(WordEditorScreen), findsOneWidget);

    // Close editor
    await tester.tap(find.bySemanticsLabel('Close without saving'));
    await tester.pumpAndSettle();
  });

  for (final layout in [
    (width: 320.0, scale: 1.0, count: 5),
    (width: 606.0, scale: 1.0, count: 5),
    (width: 844.0, scale: 1.0, count: 125),
    (width: 320.0, scale: 2.0, count: 5),
  ]) {
    testWidgets(
      'Review badge stays attached to its centered icon at ${layout.width}px and ${layout.scale}x text',
      (tester) async {
        tester.view.physicalSize = Size(layout.width, 1200);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.runAsync(() async {
          for (var i = 0; i < layout.count; i++) {
            await repo.insert(
              VocabularyWord.create(
                id: 'word-$i',
                word: 'word $i',
                meaning: 'Meaning',
                date: '2026-08-18',
                now: today,
              ),
            );
          }
          await vocabProvider.init();
        });
        await tester.pumpWidget(
          wrap(
            Builder(
              builder: (context) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(layout.scale)),
                child: const HomeScreen(),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final review = find.bySemanticsLabel('Spaced repetition review');
        final icon = find.descendant(
          of: review,
          matching: find.byType(PixelIcon),
        );
        final count = find.descendant(
          of: review,
          matching: find.text(layout.count > 99 ? '99+' : '${layout.count}'),
        );
        final iconRect = tester.getRect(icon);
        final countRect = tester.getRect(count);
        expect(
          tester.getCenter(icon).dx,
          closeTo(tester.getCenter(review).dx, 0.1),
        );
        expect(
          tester.getCenter(find.text('Review')).dx,
          closeTo(iconRect.center.dx, 0.1),
        );
        expect(countRect.left, lessThanOrEqualTo(iconRect.right + 8));
        expect(countRect.center.dx, greaterThan(iconRect.center.dx));
        expect(countRect.bottom, greaterThan(iconRect.top));
        expect(tester.takeException(), isNull);
      },
    );
  }
}
