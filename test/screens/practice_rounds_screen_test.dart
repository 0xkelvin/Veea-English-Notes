import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:veea_english_app/core/theme/pixel_theme.dart';
import 'package:veea_english_app/data/pro_repository.dart';
import 'package:veea_english_app/models/vocabulary_word.dart';
import 'package:veea_english_app/providers/pro_provider.dart';
import 'package:veea_english_app/providers/vocabulary_provider.dart';
import 'package:veea_english_app/screens/home_screen.dart';
import 'package:veea_english_app/screens/practice_rounds_screen.dart';
import 'package:veea_english_app/screens/review_screen.dart';
import 'package:veea_english_app/services/tts_service.dart';

import '../providers/pro_provider_test.dart'
    show TestAuth, TestNotebook, TestPro;

class RoundVocabulary extends VocabularyProvider {
  RoundVocabulary(this.available) : super(TestNotebook());
  final List<VocabularyWord> available;
  @override
  Future<List<VocabularyWord>> allWords({int? limit}) async =>
      limit == null ? available : available.take(limit).toList();
}

class RoundSpeech extends TtsService {
  @override
  Future<void> speak(String text) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const tts = MethodChannel('flutter_tts');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  setUp(() => messenger.setMockMethodCallHandler(tts, (_) async => null));
  tearDown(() => messenger.setMockMethodCallHandler(tts, null));
  final now = DateTime(2026, 11, 27);
  VocabularyWord word(int id, {String meaning = 'meaning'}) =>
      VocabularyWord.create(
        id: '$id',
        word: 'word$id',
        meaning: meaning,
        date: '2026-11-27',
        now: now,
      );

  Future<void> openRounds(
    WidgetTester tester,
    List<VocabularyWord> words, {
    bool pro = false,
    bool fromHome = false,
    bool includePurchases = true,
  }) async {
    final vocabulary = RoundVocabulary(words);
    final speech = RoundSpeech();
    final auth = TestAuth();
    final store = TestPro();
    final purchases = ProProvider(auth: auth, repository: store);
    if (pro) {
      store.state = const ProStoreState(
        localApple: true,
        hasPro: true,
        hasLifetime: true,
      );
      await purchases.refresh();
    }
    addTearDown(vocabulary.dispose);
    addTearDown(speech.dispose);
    addTearDown(auth.dispose);
    addTearDown(purchases.dispose);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<VocabularyProvider>.value(value: vocabulary),
          ChangeNotifierProvider<TtsService>.value(value: speech),
          if (includePurchases)
            ChangeNotifierProvider<ProProvider>.value(value: purchases),
        ],
        child: MaterialApp(
          theme: PixelTheme.light(),
          home: fromHome ? const HomeScreen() : const PracticeRoundsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    if (fromHome) {
      await tester.tap(find.byKey(const Key('home_practice_rounds')));
      await tester.pumpAndSettle();
    }
  }

  testWidgets(
    'guest Free can choose a multiword round from Home without a gate provider',
    (tester) async {
      await openRounds(
        tester,
        [word(1), word(2)],
        fromHome: true,
        includePurchases: false,
      );
      expect(find.byType(PracticeRoundsScreen), findsOneWidget);
      expect(find.byKey(const Key('practice_round_count')), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('practice_round_count')),
        '2',
      );
      await tester.tap(find.byKey(const Key('start_practice_round')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<ReviewScreen>(find.byType(ReviewScreen)).roundWords,
        hasLength(2),
      );
      expect(find.byKey(const Key('choose_review_words')), findsNothing);
    },
  );

  testWidgets('Free learning rounds validate eligible words without Pro', (
    tester,
  ) async {
    await openRounds(tester, [word(1), word(2), word(3, meaning: '')]);
    final count = find.byKey(const Key('practice_round_count'));
    await tester.enterText(count, '3');
    await tester.tap(find.byKey(const Key('start_practice_round')));
    await tester.pumpAndSettle();
    expect(find.text('Choose between 1 and 2 words.'), findsOneWidget);
    expect(find.byType(ReviewScreen), findsNothing);
    await tester.enterText(count, '2');
    await tester.tap(find.byKey(const Key('start_practice_round')));
    await tester.pumpAndSettle();
    final selection = tester
        .widget<ReviewScreen>(find.byType(ReviewScreen))
        .roundWords!;
    expect(selection.map((w) => w.id), unorderedEquals(['1', '2']));
  });

  testWidgets('handles empty vocabulary and a single eligible word', (
    tester,
  ) async {
    await openRounds(tester, []);
    expect(
      find.text('Save a word with a meaning to start a round.'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('start_practice_round')), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await openRounds(tester, [word(1), word(2, meaning: ' ')], pro: true);
    expect(find.byKey(const Key('practice_round_count')), findsNothing);
    expect(
      find.text('Save more words with meanings for a longer round.'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('start_practice_round')));
    await tester.pumpAndSettle();
    expect(
      tester.widget<ReviewScreen>(find.byType(ReviewScreen)).roundWords,
      hasLength(1),
    );
  });
}
