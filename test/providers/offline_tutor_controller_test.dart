import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:veea_english_app/models/offline_tutor.dart';
import 'package:veea_english_app/providers/offline_tutor_controller.dart';
import '../support/fake_offline_tutor.dart';

void main() {
  late FakeOfflineTutor native;
  late OfflineTutorController tutor;
  setUp(() {
    native = FakeOfflineTutor();
    tutor = OfflineTutorController(service: native);
  });
  tearDown(() async {
    tutor.dispose();
    await native.stream.close();
  });
  Future<void> scene() async {
    await tutor.initialize();
    await tutor.capture();
  }

  test(
    'missing model has no capture, question or speech side effects; import enables it',
    () async {
      native.statusValue = tutorNeedsModel;
      await tutor.initialize();
      await tutor.capture();
      await tutor.ask('What is this?');
      await tutor.toggleListening();
      expect(native.calls, ['status']);
      await tutor.importModel();
      expect(tutor.status.ready, isTrue);
      await tutor.capture();
      expect(tutor.hasScene, isTrue);
    },
  );
  test(
    'unsupported platforms never invoke import, capture or inference',
    () async {
      native.statusValue = const OfflineTutorStatus();
      await tutor.initialize();
      await tutor.importModel();
      await tutor.capture();
      await tutor.ask('hello');
      expect(native.calls, ['status']);
    },
  );
  test('cancelling import leaves a ready model and lesson intact', () async {
    await scene();
    await tutor.ask('What is this?');
    native.importResult = null;
    await tutor.importModel();
    expect(tutor.status.ready, isTrue);
    expect(tutor.turns, hasLength(1));
    expect(tutor.imagePath, '/synthetic/scene-1.jpg');
  });
  test(
    'first question includes captured scene; follow-ups use the same native conversation',
    () async {
      await scene();
      await tutor.ask('What is this?');
      await tutor.ask('How do I order one?');
      expect(native.requests[0]['imagePath'], '/synthetic/scene-1.jpg');
      expect(native.requests[1]['imagePath'], isNull);
      expect(tutor.turns, hasLength(2));
      expect(tutor.turns.first.reply.vocabulary.single.word, 'cup');
      expect(native.spoken.first.map((s) => s['language']), ['vi-VN', 'en-US']);
      expect(
        native.calls.indexOf('stopListening'),
        lessThan(native.calls.indexOf('ask')),
      );
    },
  );
  test(
    'questions without a photo, empty questions and oversized input never reach the model',
    () async {
      await tutor.initialize();
      await tutor.ask('hello');
      expect(native.requests, isEmpty);
      await tutor.capture();
      await tutor.ask(' ');
      await tutor.ask('x' * 1201);
      expect(native.requests, isEmpty);
      expect(tutor.error, contains('1,200'));
    },
  );
  test(
    'a new scene resets follow-up context and starts with that image',
    () async {
      await scene();
      await tutor.ask('cup?');
      await tutor.capture();
      expect(tutor.turns, isEmpty);
      await tutor.ask('What is this now?');
      expect(native.requests.last['imagePath'], '/synthetic/scene-2.jpg');
    },
  );
  test(
    'cancel and a late model completion cannot publish or speak stale words',
    () async {
      await scene();
      final pending = Completer<String>();
      native.pending = pending.future;
      final request = tutor.ask('old?');
      await Future<void>.delayed(Duration.zero);
      expect(tutor.operation, TutorOperation.thinking);
      await tutor.cancel();
      pending.complete(cupLesson);
      await request;
      expect(tutor.turns, isEmpty);
      expect(native.spoken, isEmpty);
      expect(tutor.canAsk, isTrue);
      native.pending = null;
      await tutor.ask('retry');
      expect(native.requests.last['imagePath'], '/synthetic/scene-1.jpg');
    },
  );
  test('new scene wins over a pending reply from the previous photo', () async {
    await scene();
    final pending = Completer<String>();
    native.pending = pending.future;
    final old = tutor.ask('old');
    await Future<void>.delayed(Duration.zero);
    await tutor.capture();
    pending.complete(cupLesson);
    await old;
    expect(tutor.imagePath, '/synthetic/scene-2.jpg');
    expect(tutor.turns, isEmpty);
    expect(native.spoken, isEmpty);
  });
  test(
    'cancelling the photo chooser after interrupting generation does not reuse a partial conversation',
    () async {
      await scene();
      await tutor.ask('first');
      final pending = Completer<String>();
      native.pending = pending.future;
      final old = tutor.ask('old');
      await Future<void>.delayed(Duration.zero);
      await tutor.choosePhoto(() async => null);
      pending.complete(cupLesson);
      await old;
      native.pending = null;
      await tutor.ask('retry');
      expect(native.requests.last['imagePath'], '/synthetic/scene-1.jpg');
    },
  );
  test(
    'malformed output is never shown or spoken; retry resends the scene',
    () async {
      await scene();
      native.reply = 'secret reasoning <think>unformatted</think>';
      await tutor.ask('question');
      expect(tutor.turns, isEmpty);
      expect(native.spoken, isEmpty);
      expect(tutor.error, isNot(contains('secret reasoning')));
      native.reply = cupLesson;
      await tutor.ask('again');
      expect(native.requests.last['imagePath'], '/synthetic/scene-1.jpg');
    },
  );
  for (final code in ['INVALID_OUTPUT', 'INFERENCE_TIMEOUT']) {
    test(
      '$code keeps completed lessons and retries within the same scene',
      () async {
        await scene();
        await tutor.ask('first');
        final resets = native.calls.where((call) => call == 'reset').length;
        native.askError = PlatformException(code: code);
        await tutor.ask('failed follow-up');
        expect(tutor.turns, hasLength(1));
        expect(
          native.calls.where((call) => call == 'reset'),
          hasLength(resets),
        );
        native.askError = null;
        await tutor.ask('retry');
        expect(tutor.turns, hasLength(2));
        expect(native.requests.last['imagePath'], isNull);
      },
    );
  }
  test(
    'six completed turns bound local context and another photo starts a fresh lesson',
    () async {
      await scene();
      for (var n = 0; n < 7; n++) {
        await tutor.ask('question $n');
      }
      expect(native.requests, hasLength(6));
      expect(tutor.canAsk, isFalse);
      await tutor.capture();
      expect(tutor.canAsk, isTrue);
      expect(tutor.turns, isEmpty);
    },
  );
  test(
    'offline voice final is sent once even after stop/listening-false event',
    () async {
      await scene();
      await tutor.toggleListening();
      native.stream.add({
        'type': 'speech',
        'text': 'Đây là gì?',
        'isFinal': false,
      });
      expect(tutor.dictation, 'Đây là gì?');
      await tutor.toggleListening();
      native.stream.add({'type': 'listening', 'active': false});
      native.stream.add({
        'type': 'speech',
        'text': 'Đây là gì?',
        'isFinal': true,
      });
      native.stream.add({
        'type': 'speech',
        'text': 'Đây là gì?',
        'isFinal': true,
      });
      await Future<void>.delayed(Duration.zero);
      expect(native.requests, hasLength(1));
      expect(tutor.turns, hasLength(1));
    },
  );
  test(
    'leaving while speech output stops cannot start a late microphone',
    () async {
      await scene();
      final stopped = Completer<void>();
      native.pendingStopSpeaking = stopped.future;
      final starting = tutor.toggleListening();
      await Future<void>.delayed(Duration.zero);
      await tutor.pause();
      stopped.complete();
      await starting;
      expect(native.calls.where((call) => call.startsWith('listen:')), isEmpty);
      expect(tutor.microphoneStarting, isFalse);
      expect(tutor.listening, isFalse);
    },
  );
  test('denied offline microphone keeps typed learning available', () async {
    await scene();
    native.speechError = PlatformException(code: 'SPEECH_DENIED');
    await tutor.toggleListening();
    expect(tutor.listening, isFalse);
    expect(tutor.canAsk, isTrue);
    await tutor.ask('typed question');
    expect(tutor.turns, hasLength(1));
  });
  test(
    'muting and unavailable local TTS never discard the written lesson',
    () async {
      await scene();
      tutor.toggleReadAloud();
      await tutor.ask('first');
      expect(native.spoken, isEmpty);
      tutor.toggleReadAloud();
      native.ttsError = PlatformException(code: 'VOICE_UNAVAILABLE');
      await tutor.ask('next');
      expect(tutor.turns, hasLength(2));
      expect(tutor.error, contains('written reply'));
    },
  );
  test(
    'idle editor/background pause stops devices but preserves follow-up context',
    () async {
      await scene();
      await tutor.ask('cup');
      await tutor.pause();
      expect(tutor.canAsk, isFalse);
      expect(tutor.turns, hasLength(1));
      await tutor.resume();
      await tutor.ask('give an example');
      expect(native.requests.last['imagePath'], isNull);
      expect(tutor.turns, hasLength(2));
    },
  );
  test(
    'background during generation rejects late completion and resumes with the scene',
    () async {
      await scene();
      final pending = Completer<String>();
      native.pending = pending.future;
      final old = tutor.ask('old');
      await Future<void>.delayed(Duration.zero);
      await tutor.pause();
      pending.complete(cupLesson);
      await old;
      expect(tutor.turns, isEmpty);
      expect(native.spoken, isEmpty);
      native.pending = null;
      await tutor.resume();
      await tutor.ask('again');
      expect(native.requests.last['imagePath'], isNotNull);
    },
  );
  test(
    'dispose ignores late inference and speech events and releases the native tutor',
    () async {
      await scene();
      final pending = Completer<String>();
      native.pending = pending.future;
      final old = tutor.ask('old');
      await Future<void>.delayed(Duration.zero);
      tutor.dispose();
      native.stream.add({'type': 'speech', 'text': 'late', 'isFinal': true});
      pending.complete(cupLesson);
      await old;
      expect(native.spoken, isEmpty);
      expect(native.calls, contains('close'));
      expect(native.requests, hasLength(1));
    },
  );

  test(
    'download progress does not enable tutor before verified installed status',
    () async {
      native.statusValue = tutorNeedsModel;
      final result = Completer<OfflineTutorStatus>();
      native.pendingDownload = result.future;
      await tutor.initialize();
      final installing = tutor.downloadModel();
      native.stream.add({
        'type': 'modelDownload',
        'progress': 0.4,
        'phase': 'downloading',
      });
      expect(tutor.downloadProgress, 0.4);
      expect(tutor.status.ready, isFalse);
      native.stream.add({
        'type': 'modelDownload',
        'progress': 1.0,
        'phase': 'verifying',
      });
      expect(tutor.downloadPhase, 'verifying');
      expect(tutor.status.ready, isFalse);
      result.complete(tutorReady);
      await installing;
      expect(tutor.status.ready, isTrue);
      expect(tutor.busy, isFalse);
    },
  );
  test(
    'cancelled download cannot publish a late ready result and can retry',
    () async {
      native.statusValue = tutorNeedsModel;
      final result = Completer<OfflineTutorStatus>();
      native.pendingDownload = result.future;
      await tutor.initialize();
      final installing = tutor.downloadModel();
      await tutor.cancelDownload();
      result.complete(tutorReady);
      await installing;
      expect(tutor.status.ready, isFalse);
      expect(tutor.busy, isFalse);
      native.pendingDownload = null;
      await tutor.downloadModel();
      expect(tutor.status.ready, isTrue);
    },
  );
  test(
    'download failure retains old model and invalid progress is bounded',
    () async {
      await tutor.initialize();
      final result = Completer<OfflineTutorStatus>();
      native.pendingDownload = result.future;
      final installing = tutor.downloadModel();
      native.stream.add({
        'type': 'modelDownload',
        'progress': 4.0,
        'phase': 'downloading',
      });
      expect(tutor.downloadProgress, 1.0);
      native.stream.add({
        'type': 'modelDownload',
        'progress': double.nan,
        'phase': 'bad phase',
      });
      expect(tutor.downloadProgress, 1.0);
      expect(tutor.downloadPhase, 'downloading');
      result.completeError(PlatformException(code: 'DOWNLOAD_FAILED'));
      await installing;
      expect(tutor.status.ready, isTrue);
      expect(tutor.error, contains('Wi-Fi'));
    },
  );
  test(
    'new-photo action exposes live preview before another frame is taken',
    () async {
      await scene();
      await tutor.ask('What is this?');
      final count = native.captures;
      await tutor.startNewScene();
      expect(tutor.imagePath, isNull);
      expect(tutor.canAsk, isFalse);
      expect(tutor.turns, isEmpty);
      expect(native.captures, count);
      expect(native.calls.last, 'resume');
      await tutor.capture();
      expect(tutor.canAsk, isTrue);
      expect(native.calls.last, 'pause');
    },
  );
  group('untrusted structured lesson output', () {
    test('accepts JSON fences, trims and deduplicates word cards', () {
      final original = jsonDecode(cupLesson) as Map<String, dynamic>;
      original['vocabulary'] = [
        ...(original['vocabulary'] as List),
        {'word': ' CUP ', 'meaningVi': 'cốc', 'exampleEn': ''},
        {'word': 44},
      ];
      final reply = TutorReply.parse('```json\n${jsonEncode(original)}\n```');
      expect(reply.vocabulary, hasLength(1));
      expect(reply.vocabulary.single.word, 'cup');
    });
    for (final (index, input) in [
      '[]',
      '{}',
      '{"answerEn":42}',
      '{"explanationVi":"x","answerEn":"y","vocabulary":false}',
      'x' * 65537,
    ].indexed) {
      test('rejects invalid shape or excessive response $index', () {
        expect(() => TutorReply.parse(input), throwsFormatException);
      });
    }
  });
}
