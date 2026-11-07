import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:veea_english_app/models/vocabulary_word.dart';
import 'package:veea_english_app/core/theme/pixel_theme.dart';
import 'package:veea_english_app/widgets/practice_word_picker.dart';

void main() {
  List<VocabularyWord> fixture() => [
    for (final entry in [
      ('a', '2026-11-05'),
      ('b', '2026-11-07'),
      ('c', '2026-11-07'),
      ('d', '2026-11-09'),
    ])
      VocabularyWord.create(
        id: entry.$1,
        word: 'word ${entry.$1}',
        meaning: 'Meaning ${entry.$1}',
        date: entry.$2,
        now: DateTime(2026, 11, 9),
      ),
  ];

  Future<void> open(
    WidgetTester tester, {
    List<String>? ids = const [],
    List<VocabularyWord>? words,
    ValueChanged<PracticePoolSelection?>? onResult,
    Size size = const Size(390, 844),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: PixelTheme.light(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                final result = await Navigator.of(context)
                    .push<PracticePoolSelection>(
                      MaterialPageRoute(
                        builder: (_) => PracticeWordPicker(
                          words: words ?? fixture(),
                          selectedIds: ids,
                        ),
                      ),
                    );
                onResult?.call(result);
              },
              child: const Text('Open picker'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open picker'));
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  Future<void> day(WidgetTester tester, String number) async {
    await tap(tester, find.byKey(const Key('practice_calendar')));
    expect(find.byType(DatePickerDialog), findsOneWidget);
    await tester.tap(find.text(number));
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
  }

  Future<void> menu(WidgetTester tester, String label) async {
    await tap(tester, find.byKey(const Key('practice_selection_options')));
    await tap(tester, find.text(label));
  }

  testWidgets(
    'one checklist has no mode switches and preserves selections across date filtering',
    (tester) async {
      await open(tester);
      expect(find.byType(SegmentedButton<bool>), findsNothing);
      expect(find.text('Any date'), findsOneWidget);
      await day(tester, '9');
      expect(find.text('All 1 word on Nov 9'), findsOneWidget);
      await tap(tester, find.byKey(const Key('select_visible_practice_words')));
      await tap(tester, find.byTooltip('Previous saved day'));
      expect(find.text('All 2 words on Nov 7'), findsOneWidget);
      await tap(tester, find.byKey(const Key('select_visible_practice_words')));
      expect(find.text('3 of 4 words selected'), findsOneWidget);
      expect(
        find.text('2 selected here · 1 selected elsewhere'),
        findsOneWidget,
      );
      await day(tester, '5');
      expect(
        tester
            .widget<CheckboxListTile>(
              find.byKey(const ValueKey('practice_word_a')),
            )
            .value,
        isFalse,
      );
      await tap(tester, find.byTooltip('Next saved day'));
      expect(
        tester
            .widget<CheckboxListTile>(
              find.byKey(const ValueKey('practice_word_b')),
            )
            .value,
        isTrue,
      );
      expect(
        tester
            .widget<CheckboxListTile>(
              find.byKey(const ValueKey('practice_word_c')),
            )
            .value,
        isTrue,
      );
      await tap(tester, find.byTooltip('Show any date'));
      expect(find.text('Any date'), findsOneWidget);
      expect(find.text('3 of 4 words selected'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'filtered select all and deselect affect only this view; global actions are in a menu',
    (tester) async {
      PracticePoolSelection? saved;
      await open(tester, ids: ['a'], onResult: (value) => saved = value);
      await day(tester, '7');
      expect(find.text('Select entire notebook (4)'), findsNothing);
      await tap(tester, find.byKey(const Key('select_visible_practice_words')));
      expect(find.text('3 of 4 words selected'), findsOneWidget);
      await tap(tester, find.byKey(const Key('select_visible_practice_words')));
      expect(find.text('1 of 4 words selected'), findsOneWidget);
      expect(
        find.text('0 selected here · 1 selected elsewhere'),
        findsOneWidget,
      );
      await menu(tester, 'Select entire notebook (4)');
      expect(find.text('4 of 4 words selected'), findsOneWidget);
      expect(
        find.text('2 selected here · 2 selected elsewhere'),
        findsOneWidget,
      );
      await menu(tester, 'Clear entire selection (4)');
      expect(find.text('0 of 4 words selected'), findsOneWidget);
      expect(
        tester
            .widget<TextButton>(find.byKey(const Key('save_practice_words')))
            .onPressed,
        isNull,
      );
      await tap(tester, find.byKey(const Key('select_visible_practice_words')));
      await tap(tester, find.byKey(const Key('save_practice_words')));
      expect(saved!.wordIds, unorderedEquals(['b', 'c']));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'search selection preserves hidden choices and saving includes them',
    (tester) async {
      PracticePoolSelection? saved;
      await open(tester, ids: ['a'], onResult: (value) => saved = value);
      await tester.enterText(
        find.byKey(const Key('practice_word_search')),
        'word b',
      );
      await tester.pumpAndSettle();
      await tap(tester, find.byKey(const Key('select_visible_practice_words')));
      expect(
        find.text('1 selected here · 1 selected elsewhere'),
        findsOneWidget,
      );
      await tap(tester, find.byKey(const Key('save_practice_words')));
      expect(saved!.wordIds, unorderedEquals(['a', 'b']));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'automatic all survives opening, filtering, temporarily unchecking and saving',
    (tester) async {
      PracticePoolSelection? saved;
      await open(tester, ids: null, onResult: (value) => saved = value);
      expect(
        tester
            .widget<SwitchListTile>(
              find.byKey(const Key('include_future_practice_words')),
            )
            .value,
        isTrue,
      );
      await day(tester, '9');
      await tap(tester, find.byKey(const ValueKey('practice_word_d')));
      expect(
        find.byKey(const Key('include_future_practice_words')),
        findsNothing,
      );
      await tap(tester, find.byKey(const ValueKey('practice_word_d')));
      expect(
        tester
            .widget<SwitchListTile>(
              find.byKey(const Key('include_future_practice_words')),
            )
            .value,
        isTrue,
      );
      await tap(tester, find.byKey(const Key('save_practice_words')));
      expect(saved, isNotNull);
      expect(saved!.wordIds, isNull);
    },
  );

  testWidgets(
    'all-word custom snapshot stays explicit unless future words are enabled',
    (tester) async {
      PracticePoolSelection? saved;
      await open(
        tester,
        ids: ['a', 'b', 'c', 'd'],
        onResult: (value) => saved = value,
      );
      expect(
        tester
            .widget<SwitchListTile>(
              find.byKey(const Key('include_future_practice_words')),
            )
            .value,
        isFalse,
      );
      await tap(tester, find.byKey(const Key('save_practice_words')));
      expect(saved!.wordIds, unorderedEquals(['a', 'b', 'c', 'd']));
      await tester.tap(find.text('Open picker'));
      await tester.pumpAndSettle();
      await tap(tester, find.byKey(const Key('include_future_practice_words')));
      await tap(tester, find.byKey(const Key('save_practice_words')));
      expect(saved!.wordIds, isNull);
    },
  );

  testWidgets(
    'Cancel discards draft selection without changing the original choices',
    (tester) async {
      final original = ['a'];
      var returned = false;
      PracticePoolSelection? result;
      await open(
        tester,
        ids: original,
        onResult: (value) {
          returned = true;
          result = value;
        },
      );
      await tap(tester, find.byKey(const Key('select_visible_practice_words')));
      await tap(tester, find.byKey(const Key('cancel_practice_words')));
      expect(returned, isTrue);
      expect(result, isNull);
      expect(original, ['a']);
    },
  );

  testWidgets(
    'large notebook rows are lazy and search, calendar and select all stay visible after scrolling',
    (tester) async {
      final words = [
        for (var i = 0; i < 2000; i++)
          VocabularyWord.create(
            id: '$i',
            word: 'word $i',
            meaning: 'Meaning',
            date: '2026-11-07',
            now: DateTime(2026, 11, 7),
          ),
      ];
      await open(tester, words: words);
      expect(find.byType(CheckboxListTile).evaluate().length, lessThan(40));
      await tester.drag(
        find.byKey(const Key('practice_word_list')),
        const Offset(0, -1000),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('practice_word_search')).hitTestable(),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('practice_calendar')).hitTestable(),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('select_visible_practice_words')).hitTestable(),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const Key('practice_word_search')),
        'word 1999',
      );
      await tester.pumpAndSettle();
      await tap(tester, find.byKey(const ValueKey('practice_word_1999')));
      expect(find.text('1 of 2000 words selected'), findsOneWidget);
      await menu(tester, 'Select entire notebook (2000)');
      expect(find.text('2000 of 2000 words selected'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'empty results retain hidden selections and small phone fits with keyboard',
    (tester) async {
      await open(tester, ids: null, size: const Size(320, 568));
      tester.view.viewInsets = const FakeViewPadding(bottom: 260);
      addTearDown(tester.view.resetViewInsets);
      await tester.enterText(
        find.byKey(const Key('practice_word_search')),
        'nonexistent',
      );
      await tester.pumpAndSettle();
      expect(
        find.text('0 selected here · 4 selected elsewhere'),
        findsOneWidget,
      );
      expect(find.text('4 of 4 words selected'), findsOneWidget);
      expect(
        tester
            .widget<TextButton>(find.byKey(const Key('save_practice_words')))
            .onPressed,
        isNotNull,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
