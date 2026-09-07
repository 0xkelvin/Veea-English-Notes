import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:veea_english_app/core/theme/pixel_theme.dart';
import 'package:veea_english_app/data/local/sqlite_vocabulary_repository.dart';
import 'package:veea_english_app/providers/vocabulary_provider.dart';
import 'package:veea_english_app/screens/home_screen.dart';
import 'package:veea_english_app/services/tts_service.dart';
import 'package:veea_english_app/services/word_suggestion_service.dart';
import 'package:veea_english_app/widgets/pixel/clipboard_detector_toast.dart';
import 'package:veea_english_app/widgets/word_row.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  TestWidgetsFlutterBinding.ensureInitialized();

  late SqliteVocabularyRepository repo;
  late VocabularyProvider vocabProvider;
  final today = DateTime(2026, 8, 18, 10);

  setUp(() async {
    WordSuggestionService.allowOnlineTranslation = false;
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

  Future<void> settle(WidgetTester tester) async {
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'HomeScreen detects English word on clipboard and displays retro toast',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(
        wrap(
          HomeScreen(
            clipboardReader: () async => ' "resilient" ',
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Verify toast is displayed
      final toastFinder = find.byType(ClipboardDetectorToast);
      expect(toastFinder, findsOneWidget);
      expect(
        find.descendant(
          of: toastFinder,
          matching: find.textContaining('resilient'),
        ),
        findsOneWidget,
      );
      expect(find.text('ADD TO TODAY'), findsOneWidget);

      // Tap ADD TO TODAY
      await tester.tap(find.text('ADD TO TODAY'));
      await settle(tester);

      // Toast is dismissed
      expect(find.byType(ClipboardDetectorToast), findsNothing);

      // Word has been added to today's notebook
      expect(find.byType(WordRow), findsOneWidget);
      expect(find.text('resilient'), findsOneWidget);
      expect(vocabProvider.words.length, 1);
    },
  );

  testWidgets('HomeScreen dismisses clipboard toast when close button is tapped', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      wrap(
        HomeScreen(
          clipboardReader: () async => 'bottleneck',
        ),
      ),
    );
    await tester.pumpAndSettle();

    final toastFinder = find.byType(ClipboardDetectorToast);
    expect(toastFinder, findsOneWidget);
    expect(
      find.descendant(
        of: toastFinder,
        matching: find.textContaining('bottleneck'),
      ),
      findsOneWidget,
    );

    // Tap dismiss
    await tester.tap(find.bySemanticsLabel('Dismiss clipboard word'));
    await tester.pumpAndSettle();

    // Toast is gone and no words were added
    expect(find.byType(ClipboardDetectorToast), findsNothing);
    expect(vocabProvider.words, isEmpty);
  });

  testWidgets('HomeScreen ignores invalid or non-vocabulary clipboard text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      wrap(
        HomeScreen(
          clipboardReader: () async => 'https://flutter.dev/docs/testing',
        ),
      ),
    );
    await tester.pumpAndSettle();

    // No toast displayed for URL
    expect(find.byType(ClipboardDetectorToast), findsNothing);
  });

  testWidgets(
    'HomeScreen detects new clipboard word when app resumes from background',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      String? currentClipboard;

      await tester.pumpWidget(
        wrap(
          HomeScreen(
            clipboardReader: () async => currentClipboard,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ClipboardDetectorToast), findsNothing);

      // Simulate copying a word in Safari and returning to Veea
      currentClipboard = 'trade-off';
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();

      // Toast now appears
      final resumedToastFinder = find.byType(ClipboardDetectorToast);
      expect(resumedToastFinder, findsOneWidget);
      expect(
        find.descendant(
          of: resumedToastFinder,
          matching: find.textContaining('trade-off'),
        ),
        findsOneWidget,
      );
    },
  );
}
