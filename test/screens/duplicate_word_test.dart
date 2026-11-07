import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:veea_english_app/core/theme/pixel_theme.dart';
import 'package:veea_english_app/data/local/sqlite_vocabulary_repository.dart';
import 'package:veea_english_app/models/vocabulary_word.dart';
import 'package:veea_english_app/providers/vocabulary_provider.dart';
import 'package:veea_english_app/screens/word_editor_screen.dart';
import 'package:veea_english_app/services/pronunciation_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  late SqliteVocabularyRepository repo;
  late VocabularyProvider provider;
  final now = DateTime(2026, 11, 7);
  setUp(() async {
    repo = await SqliteVocabularyRepository.open(path: inMemoryDatabasePath);
    await repo.insert(
      VocabularyWord.create(
        id: 'old',
        word: 'bank',
        meaning: 'ngân hàng',
        date: '2026-10-01',
        now: now,
      ),
    );
    provider = VocabularyProvider(repo, now: () => now);
    await provider.init();
  });
  tearDown(() async {
    provider.dispose();
    await repo.close();
  });
  Widget wrap(Widget child, {double scale = 1}) => MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: provider),
      Provider(create: (_) => PronunciationService(repo.database)),
    ],
    child: MaterialApp(
      theme: PixelTheme.light(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: child,
    ),
  );
  Future<void> settle(WidgetTester tester) async {
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pumpAndSettle();
  }

  Future<void> save(WidgetTester tester) async {
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Save word'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.text('Save word'));
      await Future<void>.delayed(const Duration(milliseconds: 150));
    });
    await settle(tester);
  }

  testWidgets(
    'photo draft warns across dates and identical meaning cannot create a second entry',
    (tester) async {
      await tester.pumpWidget(
        wrap(
          const WordEditorScreen.draft(
            draft: WordDraft(
              word: ' BANK ',
              meaning: 'ngân hàng',
              source: 'Camera Scan',
            ),
          ),
        ),
      );
      await settle(tester);
      expect(find.byKey(const Key('word_duplicate_notice')), findsOneWidget);
      await save(tester);
      expect(find.byKey(const Key('duplicate_word_sheet')), findsOneWidget);
      expect(find.text('Saved Oct 1, 2026'), findsOneWidget);
      expect(find.byKey(const Key('duplicate_save_another')), findsNothing);
      await tester.tap(find.byKey(const Key('duplicate_keep_editing')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField).first).controller!.text,
        ' BANK ',
      );
      expect(await tester.runAsync(() => repo.exportAll()), hasLength(1));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'different meaning is saved only after the user explicitly chooses it',
    (tester) async {
      await tester.pumpWidget(
        wrap(
          const WordEditorScreen.draft(
            draft: WordDraft(word: 'bank', meaning: 'bờ sông'),
          ),
        ),
      );
      await settle(tester);
      await save(tester);
      expect(find.byKey(const Key('duplicate_save_another')), findsOneWidget);
      expect(await tester.runAsync(() => repo.exportAll()), hasLength(1));
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('duplicate_save_another')));
        await Future<void>.delayed(const Duration(milliseconds: 150));
      });
      await settle(tester);
      final saved = await tester.runAsync(() => repo.exportAll());
      expect(saved, hasLength(2));
      expect(
        saved!.map((w) => w.meaning),
        containsAll(['ngân hàng', 'bờ sông']),
      );
      expect(
        (await tester.runAsync(() => repo.findById('old')))!.date,
        '2026-10-01',
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'opening the existing entry retains the unsaved draft for back navigation',
    (tester) async {
      await tester.pumpWidget(
        wrap(
          const WordEditorScreen.draft(
            draft: WordDraft(word: 'bank', meaning: 'my draft meaning'),
          ),
        ),
      );
      await settle(tester);
      await save(tester);
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('duplicate_open_old')));
        await Future<void>.delayed(const Duration(milliseconds: 150));
      });
      await settle(tester);
      expect(find.text('Save changes'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField).at(1)).controller!.text,
        'ngân hàng',
      );
      await tester.binding.handlePopRoute();
      await settle(tester);
      expect(
        tester.widget<TextField>(find.byType(TextField).at(1)).controller!.text,
        'my draft meaning',
      );
      expect(await tester.runAsync(() => repo.exportAll()), hasLength(1));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'typing warns early and stale results clear when spelling changes',
    (tester) async {
      await tester.pumpWidget(wrap(const WordEditorScreen()));
      await settle(tester);
      await tester.enterText(find.byType(TextField).first, ' BANK ');
      await tester.pump(const Duration(milliseconds: 300));
      await settle(tester);
      expect(find.byKey(const Key('word_duplicate_notice')), findsOneWidget);
      await tester.enterText(find.byType(TextField).first, 'banking');
      await tester.pump(const Duration(milliseconds: 300));
      await settle(tester);
      expect(find.byKey(const Key('word_duplicate_notice')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets('duplicate sheet remains usable with large text', (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      wrap(
        const WordEditorScreen.draft(
          draft: WordDraft(word: 'bank', meaning: 'ngân hàng'),
        ),
        scale: 2,
      ),
    );
    await settle(tester);
    await save(tester);
    expect(
      find.byKey(const Key('duplicate_keep_editing')).hitTestable(),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const Key('duplicate_keep_editing')));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
