import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:veea_english_app/core/theme/pixel_theme.dart';
import 'package:veea_english_app/models/part_of_speech.dart';
import 'package:veea_english_app/models/vocabulary_word.dart';
import 'package:veea_english_app/services/tts_service.dart';
import 'package:veea_english_app/widgets/highlighted_text.dart';
import 'package:veea_english_app/widgets/word_row.dart';

void main() {
  final testWord = VocabularyWord(
    id: 'word-1',
    word: 'resilient',
    meaning: 'Có khả năng phục hồi nhanh chóng',
    date: '2026-09-10',
    createdAt: DateTime(2026, 9, 10),
    updatedAt: DateTime(2026, 9, 10),
    partOfSpeech: PartOfSpeech.adjective,
    pronunciation: 'rɪˈzɪliənt',
    source: 'Safari',
    examples: const ['She remained resilient during tough times.'],
    tags: const ['mindset', 'ielts'],
  );

  Widget wrap(Widget child) => ChangeNotifierProvider(
        create: (_) => TtsService(),
        child: MaterialApp(
          theme: PixelTheme.light(),
          home: Scaffold(body: child),
        ),
      );

  testWidgets('WordRow displays card with word, meaning, POS badge, and highlighted example', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        WordRow(
          word: testWord,
          onTap: () {},
        ),
      ),
    );

    // Verify word and meaning
    expect(find.text('resilient'), findsOneWidget);
    expect(find.text('Có khả năng phục hồi nhanh chóng'), findsOneWidget);

    // Verify Part of Speech micro-badge
    expect(find.text('ADJ'), findsOneWidget);

    // Verify HighlightedText exists for the example sentence
    expect(find.byType(HighlightedText), findsOneWidget);

    // Verify tags and source
    expect(find.text('#mindset'), findsOneWidget);
    expect(find.text('#ielts'), findsOneWidget);
    expect(find.text('FROM SAFARI'), findsOneWidget);
  });
}
