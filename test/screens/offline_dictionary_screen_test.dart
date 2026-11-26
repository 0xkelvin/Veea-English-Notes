import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:veea_english_app/core/theme/pixel_theme.dart';
import 'package:veea_english_app/data/local/app_database.dart';
import 'package:veea_english_app/data/word_suggestion_store.dart';
import 'package:veea_english_app/screens/offline_dictionary_screen.dart';
import 'package:veea_english_app/services/word_suggestion_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  setUpAll(() async {
    // Read real licence assets outside widget-test fake timers.
    await rootBundle.loadString(SqliteWordSuggestionStore.noticePath);
    await rootBundle.loadString(SqliteWordSuggestionStore.licencePath);
  });
  late Database db;
  late Directory dir;
  late SqliteWordSuggestionStore store;
  setUp(() async {
    db = await AppDatabase.open(path: inMemoryDatabasePath);
    dir = await Directory.systemTemp.createTemp('veea-dictionary-screen-');
    store = SqliteWordSuggestionStore(
      db,
      dictionaryDirectory: () async => dir.path,
    );
    WordSuggestionService.configureLocalStore(store);
    await store.saveOnline(
      const WordSuggestion(word: 'stored', meaning: 'nghĩa được lưu'),
      provider: 'MyMemory',
    );
  });
  tearDown(() async {
    WordSuggestionService.configureLocalStore(null);
    await store.close();
    await db.close();
    await dir.delete(recursive: true);
  });

  Widget app({bool dark = false, double scale = 1}) => MaterialApp(
    theme: dark ? PixelTheme.dark() : PixelTheme.light(),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(scale)),
      child: child!,
    ),
    home: const OfflineDictionaryScreen(),
  );
  Future<void> settle(WidgetTester tester) async {
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'offline credits and saved count are available; cancel and clear work',
    (tester) async {
      await tester.pumpWidget(app());
      await settle(tester);
      expect(find.textContaining('110,986 entries'), findsOneWidget);
      expect(find.text('1 saved lookup'), findsOneWidget);
      expect(
        find.textContaining('Vietnamese Wiktionary contributors'),
        findsOneWidget,
      );
      await tester.ensureVisible(find.byKey(const Key('clear_saved_lookups')));
      await tester.tap(find.byKey(const Key('clear_saved_lookups')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(await tester.runAsync(store.savedCount), 1);
      await tester.tap(find.byKey(const Key('clear_saved_lookups')));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('confirm_clear_saved_lookups')));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      await settle(tester);
      expect(find.text('0 saved lookups'), findsOneWidget);
      expect(
        tester
            .widget<TextButton>(find.byKey(const Key('clear_saved_lookups')))
            .onPressed,
        isNull,
      );
      expect(await tester.runAsync(store.savedCount), 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final variant in [
    (width: 320.0, scale: 2.0, dark: false),
    (width: 390.0, scale: 1.0, dark: true),
  ]) {
    testWidgets(
      'licence remains reachable at ${variant.width}/${variant.scale}/${variant.dark}',
      (tester) async {
        tester.view.physicalSize = Size(variant.width, 568);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(app(scale: variant.scale, dark: variant.dark));
        await settle(tester);
        await tester.scrollUntilVisible(
          find.byKey(const Key('dictionary_full_licence')),
          300,
          scrollable: find.byType(Scrollable).first,
        );
        await Scrollable.ensureVisible(
          tester.element(find.byKey(const Key('dictionary_full_licence'))),
          alignment: 0.5,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('dictionary_full_licence')));
        await settle(tester);
        await settle(tester);
        expect(find.text('CC BY-SA 4.0'), findsOneWidget);
        expect(find.textContaining('Section 1'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
