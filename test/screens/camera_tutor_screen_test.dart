import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:veea_english_app/core/theme/pixel_theme.dart';
import 'package:veea_english_app/data/local/sqlite_vocabulary_repository.dart';
import 'package:veea_english_app/models/offline_tutor.dart';
import 'package:veea_english_app/providers/offline_tutor_controller.dart';
import 'package:veea_english_app/providers/vocabulary_provider.dart';
import 'package:veea_english_app/screens/camera_tutor_screen.dart';
import 'package:veea_english_app/screens/pixel_lens_screen.dart';
import 'package:veea_english_app/screens/word_editor_screen.dart';
import 'package:veea_english_app/services/pronunciation_service.dart';
import 'package:veea_english_app/widgets/camera_tools_sheet.dart';
import '../support/fake_offline_tutor.dart';

class _UnusedDatabase implements Database {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class TutorTestPronunciation extends PronunciationService {
  TutorTestPronunciation(super.db);
  @override
  Future<String?> lookup(String word) async => '/kʌp/';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeOfflineTutor native;
  late OfflineTutorController tutor;
  setUpAll(() async {
    const fontPath = String.fromEnvironment('VEEA_TUTOR_FONT');
    const iconPath = String.fromEnvironment('VEEA_TUTOR_ICON_FONT');
    for (final font in [
      ('SF Pro Text', fontPath),
      ('MaterialIcons', iconPath),
    ]) {
      if (font.$2.isNotEmpty) {
        await (FontLoader(font.$1)
              ..addFont(File(font.$2).readAsBytes().then(ByteData.sublistView)))
            .load();
      }
    }
  });
  setUp(() {
    native = FakeOfflineTutor();
    const scene = String.fromEnvironment('VEEA_TUTOR_SCENE');
    const reply = String.fromEnvironment('VEEA_TUTOR_REPLY');
    if (scene.isNotEmpty) native.capturePath = scene;
    if (reply.isNotEmpty) native.reply = File(reply).readAsStringSync();
    tutor = OfflineTutorController(service: native);
  });
  tearDown(() async {
    tutor.dispose();
    await native.stream.close();
  });

  Widget page({
    double scale = 1,
    bool dark = false,
    Future<void> Function(BuildContext, TutorVocabulary)? save,
  }) => MaterialApp(
    theme: dark ? PixelTheme.dark() : PixelTheme.light(),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(scale)),
      child: child!,
    ),
    home: RepaintBoundary(
      key: const Key('tutor_capture'),
      child: CameraTutorScreen(
        controller: tutor,
        previewBuilder: (_) => const ColoredBox(
          color: Color(0xff243b44),
          child: Center(
            child: Icon(
              Icons.local_cafe_outlined,
              color: Colors.white,
              size: 64,
            ),
          ),
        ),
        choosePhoto: () async => '/synthetic/chosen.jpg',
        saveWord: save,
      ),
    ),
  );

  Future<void> capture(WidgetTester tester, String name) async {
    const folder = String.fromEnvironment('VEEA_TUTOR_CAPTURE_DIR');
    if (folder.isEmpty) return;
    await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const Key('tutor_capture')),
      );
      final image = await boundary.toImage(pixelRatio: 2);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('$folder/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(data!.buffer.asUint8List());
      image.dispose();
    });
  }

  testWidgets(
    'missing model explains one-time setup and cancelled import keeps setup visible',
    (tester) async {
      native.statusValue = tutorNeedsModel;
      native.importResult = null;
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();
      expect(find.text('One-time setup'), findsOneWidget);
      expect(find.byKey(const Key('tutor_question')), findsNothing);
      await tester.scrollUntilVisible(
        find.byKey(const Key('import_tutor_model')),
        200,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('import_tutor_model')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('import_tutor_model')), findsOneWidget);
      expect(native.requests, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'capture, typed question, bilingual lesson and follow-up use native service',
    (tester) async {
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();
      expect(
        tester.widget<IconButton>(find.byKey(const Key('ask_tutor'))).onPressed,
        isNull,
      );
      await tester.tap(find.byKey(const Key('capture_tutor_photo')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('tutor_question')),
        'What is this?',
      );
      await tester.tap(find.byKey(const Key('ask_tutor')));
      await tester.pumpAndSettle();
      expect(find.text('Đây là một chiếc cốc.'), findsOneWidget);
      expect(find.text('Đây là một chiếc cốc.').hitTestable(), findsOneWidget);
      expect(find.text('cup'), findsOneWidget);
      expect(native.requests.single['imagePath'], '/synthetic/scene-1.jpg');
      await tester.enterText(
        find.byKey(const Key('tutor_question')),
        'Can I order coffee?',
      );
      await tester.tap(find.byKey(const Key('ask_tutor')));
      await tester.pumpAndSettle();
      expect(native.requests.last['imagePath'], isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('save action passes only the selected editable vocabulary card', (
    tester,
  ) async {
    TutorVocabulary? selected;
    await tester.pumpWidget(
      page(
        save: (_, word) async {
          selected = word;
        },
      ),
    );
    await tester.pumpAndSettle();
    await tutor.capture();
    await tutor.ask('What is it?');
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const ValueKey('save_tutor_word_cup')),
    );
    await tester.tap(find.byKey(const ValueKey('save_tutor_word_cup')));
    expect(selected?.word, 'cup');
    expect(selected?.meaningVi, 'cái cốc');
    expect(selected?.exampleEn, 'I would like a cup of coffee.');
  });

  testWidgets(
    'real save uses existing editor and stores the selected word locally without altering the lesson',
    (tester) async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      final repo = await tester.runAsync(
        () => SqliteVocabularyRepository.open(path: inMemoryDatabasePath),
      );
      final vocabulary = VocabularyProvider(repo!);
      await tester.runAsync(vocabulary.init);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<VocabularyProvider>.value(value: vocabulary),
            Provider<PronunciationService>(
              create: (_) => TutorTestPronunciation(repo.database),
            ),
          ],
          child: page(),
        ),
      );
      await tester.pumpAndSettle();
      await tutor.capture();
      await tutor.ask('cup?');
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('save_tutor_word_cup')),
      );
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('save_tutor_word_cup')));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(find.byType(WordEditorScreen), findsOneWidget);
      expect(find.text('cái cốc'), findsOneWidget);
      await tester.ensureVisible(find.text('Save word'));
      await tester.runAsync(() async {
        await tester.tap(find.text('Save word'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      final words = await tester.runAsync(repo.exportAll);
      expect(words, hasLength(1));
      expect(words!.single.word, 'cup');
      expect(words.single.meaning, 'cái cốc');
      expect(words.single.source, 'Camera tutor');
      expect(words.single.examples, ['I would like a cup of coffee.']);
      expect(tutor.turns, hasLength(1));
      expect(
        native.calls.where((call) => call == 'pause').length,
        greaterThanOrEqualTo(2),
      );
      expect(native.calls, isNot(contains('resume')));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      vocabulary.dispose();
      await tester.runAsync(repo.close);
    },
  );

  testWidgets(
    'one-button setup offers download and shows verification before opening camera',
    (tester) async {
      native.statusValue = tutorNeedsModel;
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const Key('download_tutor_model')),
        200,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('download_tutor_model')));
      await tester.pumpAndSettle();
      expect(native.calls, contains('download'));
      expect(native.calls, contains('resume'));
      expect(find.byKey(const Key('capture_tutor_photo')), findsOneWidget);
      expect(native.captures, 0);
    },
  );
  testWidgets(
    'retake returns to live view and waits for the next explicit capture',
    (tester) async {
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();
      await tutor.capture();
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('capture_tutor_photo')));
      await tester.tap(find.byKey(const Key('capture_tutor_photo')));
      await tester.pumpAndSettle();
      expect(tutor.hasScene, isFalse);
      expect(native.captures, 1);
      expect(find.text('Live camera · Offline'), findsOneWidget);
      await tester.tap(find.byKey(const Key('capture_tutor_photo')));
      await tester.pumpAndSettle();
      expect(tutor.hasScene, isTrue);
      expect(native.captures, 2);
    },
  );
  for (final variant in [(false, 1.0), (true, 1.0), (false, 2.0)]) {
    testWidgets(
      'camera lesson fits compact screen dark=${variant.$1} scale=${variant.$2}',
      (tester) async {
        tester.view.physicalSize = const Size(320, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(page(dark: variant.$1, scale: variant.$2));
        await tester.pumpAndSettle();
        await tutor.capture();
        await tutor.ask('What is this?');
        await tester.pumpAndSettle();
        await capture(tester, 'lesson_top_${variant.$1}_${variant.$2}');
        await tester.ensureVisible(
          find.byKey(
            ValueKey(
              'save_tutor_word_${tutor.turns.first.reply.vocabulary.first.word}',
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await capture(tester, 'lesson_${variant.$1}_${variant.$2}');
      },
    );
  }

  testWidgets(
    'unsupported runtime explains availability and does not pretend to provide AI',
    (tester) async {
      native.statusValue = const OfflineTutorStatus();
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();
      expect(
        find.textContaining('iPhone preview on this branch'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('import_tutor_model')), findsNothing);
      expect(native.requests, isEmpty);
    },
  );

  testWidgets(
    'camera chooser preserves the existing text scanner and exposes tutor separately',
    (tester) async {
      await tester.pumpWidget(
        Provider<PronunciationService>(
          create: (_) => TutorTestPronunciation(_UnusedDatabase()),
          child: MaterialApp(
            theme: PixelTheme.light(),
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showCameraTools(context),
                  child: const Text('Camera'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Camera'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('open_camera_tutor')), findsOneWidget);
      await tester.tap(find.byKey(const Key('open_camera_scan')));
      await tester.pumpAndSettle();
      expect(find.byType(PixelLensScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
