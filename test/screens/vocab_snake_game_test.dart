import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:veea_english_app/core/theme/pixel_palette.dart';
import 'package:veea_english_app/core/theme/pixel_theme.dart';
import 'package:veea_english_app/data/local/sqlite_vocabulary_repository.dart';
import 'package:veea_english_app/providers/vocabulary_provider.dart';
import 'package:veea_english_app/screens/games/vocab_snake_game.dart';
import 'package:veea_english_app/services/tts_service.dart';
import 'package:veea_english_app/widgets/pixel/pixel_icon.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late SqliteVocabularyRepository repo;
  late VocabularyProvider provider;
  final today = DateTime(2026, 8, 18, 10);

  setUp(() async {
    repo = await SqliteVocabularyRepository.open(
      path: inMemoryDatabasePath,
      now: () => today,
    );
    provider = VocabularyProvider(repo, now: () => today);
    await provider.init();
    await provider.addWord(word: 'resilient', meaning: 'kiên cường', source: 'test', tags: []);
    await provider.addWord(word: 'tenacious', meaning: 'bền bỉ', source: 'test', tags: []);
    await provider.addWord(word: 'eloquent', meaning: 'lưu loát', source: 'test', tags: []);
  });

  tearDown(() => repo.close());

  Widget wrap(Widget child) => MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: provider),
      ChangeNotifierProvider(create: (_) => TtsService()),
    ],
    child: MaterialApp(
      theme: PixelTheme.light(),
      home: Scaffold(body: child),
    ),
  );

  testWidgets('VocabSnakeGame D-pad displays all four arrow glyphs properly', (tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(wrap(const VocabSnakeGame()));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();

    // Verify all 4 directional arrow icons are rendered on the D-Pad
    final arrowIcons = tester.widgetList<PixelIcon>(find.byType(PixelIcon));
    final glyphs = arrowIcons.map((i) => i.glyph).toSet();

    expect(glyphs, contains(PixelGlyph.arrowUp));
    expect(glyphs, contains(PixelGlyph.arrowDown));
    expect(glyphs, contains(PixelGlyph.arrowLeft));
    expect(glyphs, contains(PixelGlyph.arrowRight));

    // Tap Down button
    final downIconFinder = find.byWidgetPredicate(
      (widget) => widget is PixelIcon && widget.glyph == PixelGlyph.arrowDown,
    );
    expect(downIconFinder, findsOneWidget);

    await tester.tap(downIconFinder);
    await tester.pump();
  });

  testWidgets('VocabSnakeGame renders all English words on board with identical ink color', (tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(wrap(const VocabSnakeGame()));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();

    // Check all English word label texts on the pellets
    const lightPalette = PixelPalette.light;
    final pelletWords = ['RESILIENT', 'TENACIOUS', 'ELOQUENT'];
    var checkedCount = 0;

    for (final pw in pelletWords) {
      final matches = find.text(pw);
      if (matches.evaluate().isNotEmpty) {
        final text = tester.widget<Text>(matches.first);
        expect(text.style?.color, equals(lightPalette.ink));
        expect(text.style?.color, isNot(equals(lightPalette.accent)));
        checkedCount++;
      }
    }

    expect(checkedCount, greaterThan(0));
  });

  testWidgets('Initial snake has 3 segments', (tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(wrap(const VocabSnakeGame()));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();

    final containers = tester.widgetList<Container>(find.byType(Container));
    final snakeSegments = containers.where((c) {
      final decoration = c.decoration;
      if (decoration is BoxDecoration) {
        return decoration.border?.top.width == 0.5;
      }
      return false;
    }).toList();

    expect(snakeSegments.length, equals(3));
  });
}
