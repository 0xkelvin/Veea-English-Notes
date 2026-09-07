import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:veea_english_app/core/theme/pixel_theme.dart';
import 'package:veea_english_app/models/part_of_speech.dart';
import 'package:veea_english_app/widgets/pixel/context_wizard_sheet.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget buildTestableSheet({
    required String word,
    String? meaning,
    PartOfSpeech? partOfSpeech,
    required ValueChanged<String> onSelectSentence,
    required ValueChanged<String> onAddTag,
  }) {
    return MaterialApp(
      theme: PixelTheme.light(),
      home: Scaffold(
        body: ContextWizardSheet(
          word: word,
          meaning: meaning,
          partOfSpeech: partOfSpeech,
          onSelectSentence: onSelectSentence,
          onAddTag: onAddTag,
        ),
      ),
    );
  }

  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  group('ContextWizardSheet Widget', () {
    testWidgets('renders word banner, POS tag, and sections', (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        buildTestableSheet(
          word: 'database',
          meaning: 'cơ sở dữ liệu',
          partOfSpeech: PartOfSpeech.noun,
          onSelectSentence: (_) {},
          onAddTag: (_) {},
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('AI CONTEXT WIZARD'), findsOneWidget);
      expect(find.text('WORD: DATABASE'), findsOneWidget);
      expect(find.text('NOUN'), findsOneWidget);
      expect(find.text('(cơ sở dữ liệu)'), findsOneWidget);
      expect(find.text('RE-ROLL'), findsOneWidget);
      expect(find.text('2. POWER COLLOCATIONS & COMMON PAIRS'), findsOneWidget);
      expect(find.text('3. SYNONYM & NUANCE BREAKDOWN'), findsOneWidget);
    });

    testWidgets('re-roll button shuffles sentence structures', (tester) async {
      await tester.pumpWidget(
        buildTestableSheet(
          word: 'database',
          partOfSpeech: PartOfSpeech.noun,
          onSelectSentence: (_) {},
          onAddTag: (_) {},
        ),
      );
      await tester.pumpAndSettle();

      // Find the first sentence text
      final firstTextFinder = find.byWidgetPredicate(
        (widget) => widget is Text && widget.data != null && widget.data!.startsWith('“'),
      );
      expect(firstTextFinder, findsWidgets);
      final initialSentence = (tester.firstWidget(firstTextFinder) as Text).data;

      // Tap RE-ROLL
      await tester.tap(find.text('RE-ROLL'));
      await tester.pumpAndSettle();

      // Sentence should have shifted
      final newSentence = (tester.firstWidget(firstTextFinder) as Text).data;
      expect(newSentence, isNot(equals(initialSentence)));
    });

    testWidgets('tapping sentence triggers onSelectSentence callback', (tester) async {
      String? selected;
      await tester.pumpWidget(
        buildTestableSheet(
          word: 'resilient',
          onSelectSentence: (s) => selected = s,
          onAddTag: (_) {},
        ),
      );
      await tester.pumpAndSettle();

      final firstSentenceBox = find.text('TAP TO INSERT ↵').first;
      await tester.tap(firstSentenceBox);
      await tester.pumpAndSettle();

      expect(selected, isNotNull);
      expect(selected!.contains('resilient'), isTrue);
    });

    testWidgets('tapping collocation chip triggers onAddTag callback', (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      String? addedTag;
      await tester.pumpWidget(
        buildTestableSheet(
          word: 'resilient',
          onSelectSentence: (_) {},
          onAddTag: (tag) => addedTag = tag,
        ),
      );
      await tester.pumpAndSettle();

      final tagChip = find.text('+ resilient infrastructure');
      expect(tagChip, findsOneWidget);
      await tester.tap(tagChip);
      await tester.pumpAndSettle();

      expect(addedTag, 'resilient infrastructure');
    });
  });
}
