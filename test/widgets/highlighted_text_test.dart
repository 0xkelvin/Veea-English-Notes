import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:veea_english_app/widgets/highlighted_text.dart';

void main() {
  group('HighlightedText Widget Tests', () {
    testWidgets('renders plain text when target word is empty or not found', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: HighlightedText(
              text: 'This is a sample sentence without match.',
              targetWord: '',
            ),
          ),
        ),
      );

      expect(
        find.text('This is a sample sentence without match.'),
        findsOneWidget,
      );
    });

    testWidgets('highlights exact target word in sentence', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: HighlightedText(
              text: 'She is very resilient under pressure.',
              targetWord: 'resilient',
              highlightStyle: TextStyle(
                fontWeight: FontWeight.bold,
                color: Colors.green,
              ),
            ),
          ),
        ),
      );

      final richTextFinder = find.byType(RichText);
      expect(richTextFinder, findsOneWidget);

      final richText = tester.widget<RichText>(richTextFinder);
      var rootSpan = richText.text as TextSpan;
      if (rootSpan.children?.length == 1 && rootSpan.children!.first is TextSpan) {
        final inner = rootSpan.children!.first as TextSpan;
        if (inner.children != null && inner.children!.length > 1) {
          rootSpan = inner;
        }
      }

      expect(rootSpan.children, isNotNull);
      expect(rootSpan.children!.length, equals(3));

      // Prefix
      expect((rootSpan.children![0] as TextSpan).text, equals('She is very '));
      // Highlighted match
      final matchSpan = rootSpan.children![1] as TextSpan;
      expect(matchSpan.text, equals('resilient'));
      expect(matchSpan.style?.fontWeight, equals(FontWeight.bold));
      expect(matchSpan.style?.color, equals(Colors.green));
      // Suffix
      expect(
        (rootSpan.children![2] as TextSpan).text,
        equals(' under pressure.'),
      );
    });

    testWidgets('highlights inflected forms (e.g. plurals, -ly, -ed)', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: HighlightedText(
              text: 'They acted resiliently and overcame obstacles.',
              targetWord: 'resilient',
            ),
          ),
        ),
      );

      final richText = tester.widget<RichText>(find.byType(RichText));
      var rootSpan = richText.text as TextSpan;
      if (rootSpan.children?.length == 1 && rootSpan.children!.first is TextSpan) {
        final inner = rootSpan.children!.first as TextSpan;
        if (inner.children != null && inner.children!.length > 1) {
          rootSpan = inner;
        }
      }

      final matchSpan = rootSpan.children![1] as TextSpan;
      expect(matchSpan.text, equals('resiliently'));
    });
  });
}
