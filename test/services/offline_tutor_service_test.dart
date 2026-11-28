import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:veea_english_app/services/offline_tutor_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel(NativeOfflineTutorService.channelName);
  const eventChannel = MethodChannel(
    NativeOfflineTutorService.eventChannelName,
  );
  final calls = <MethodCall>[];
  final streamCalls = <String>[];
  final ready = <String, Object?>{
    'supported': true,
    'runtimeAvailable': true,
    'canRun': true,
    'modelReady': true,
    'modelBytes': 2588147712,
    'deviceMemoryBytes': 8000000000,
    'speechLocales': ['vi-VN', 'en-US'],
  };
  setUp(() {
    calls.clear();
    streamCalls.clear();
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return switch (call.method) {
        'getStatus' || 'downloadModel' || 'removeModel' => ready,
        'importModel' => null,
        'capturePhoto' => '/app/tmp/offline_tutor/frame.jpg',
        'ask' => '{"explanationVi":"x","answerEn":"y","vocabulary":[]}',
        _ => null,
      };
    });
    messenger.setMockMethodCallHandler(eventChannel, (call) async {
      streamCalls.add(call.method);
      return null;
    });
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(eventChannel, null);
  });

  test(
    'model setup and generation use only the native channel contract',
    () async {
      final service = NativeOfflineTutorService();
      expect((await service.status()).ready, isTrue);
      expect(await service.importModel(), isNull);
      expect((await service.downloadModel()).ready, isTrue);
      await service.cancelModelDownload();
      expect(await service.capturePhoto(), '/app/tmp/offline_tutor/frame.jpg');
      await service.ask(
        question: 'what is this?',
        imagePath: '/app/tmp/offline_tutor/frame.jpg',
        requestId: 7,
      );
      expect(calls.last.method, 'ask');
      expect(calls.last.arguments, {
        'question': 'what is this?',
        'imagePath': '/app/tmp/offline_tutor/frame.jpg',
        'requestId': 7,
      });
      await service.startListening('vi-VN');
      await service.stopListening();
      await service.speak([
        {'text': 'cốc', 'language': 'vi-VN'},
      ]);
      await service.stopSpeaking();
      await service.cancel();
      await service.reset();
      await service.pause();
      await service.resume();
      await service.removeModel();
      await service.close();
      expect(
        calls.map((c) => c.method),
        containsAllInOrder([
          'downloadModel',
          'cancelModelDownload',
          'capturePhoto',
          'ask',
          'startListening',
          'stopListening',
          'speak',
          'stopSpeaking',
          'cancel',
          'reset',
          'pause',
          'resume',
          'removeModel',
          'dispose',
        ]),
      );
    },
  );
  test(
    'unregistered platform is unavailable rather than a simulated lesson',
    () async {
      messenger.setMockMethodCallHandler(channel, null);
      expect((await NativeOfflineTutorService().status()).supported, isFalse);
    },
  );
  test(
    'overlapping screen listeners share one event subscription and cannot erase each other',
    () async {
      final first = <Map<Object?, Object?>>[],
          second = <Map<Object?, Object?>>[];
      final a = NativeOfflineTutorService().events.listen(first.add);
      final b = NativeOfflineTutorService().events.listen(second.add);
      await Future<void>.delayed(Duration.zero);
      await messenger.handlePlatformMessage(
        NativeOfflineTutorService.eventChannelName,
        const StandardMethodCodec().encodeSuccessEnvelope({
          'type': 'speech',
          'text': 'first',
          'isFinal': false,
        }),
        (_) {},
      );
      await Future<void>.delayed(Duration.zero);
      expect(first.single['text'], 'first');
      expect(second.single['text'], 'first');
      await a.cancel();
      await messenger.handlePlatformMessage(
        NativeOfflineTutorService.eventChannelName,
        const StandardMethodCodec().encodeSuccessEnvelope({
          'type': 'speech',
          'text': 'second',
          'isFinal': true,
        }),
        (_) {},
      );
      await Future<void>.delayed(Duration.zero);
      expect(second.last['text'], 'second');
      expect(first, hasLength(1));
      await b.cancel();
      expect(streamCalls, ['listen', 'cancel']);
    },
  );
}
