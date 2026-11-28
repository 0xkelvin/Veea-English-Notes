import 'package:flutter/services.dart';

import '../models/offline_tutor.dart';

/// The complete transport is a local platform channel. Inference never falls
/// back to HTTP, an account API, or a cloud speech provider.
abstract class OfflineTutorService {
  Stream<Map<Object?, Object?>> get events;
  Future<OfflineTutorStatus> status();
  Future<OfflineTutorStatus?> importModel();
  Future<OfflineTutorStatus> downloadModel();
  Future<void> cancelModelDownload();
  Future<OfflineTutorStatus> removeModel();
  Future<String> capturePhoto();
  Future<String> ask({
    required String question,
    String? imagePath,
    required int requestId,
  });
  Future<void> cancel();
  Future<void> reset();
  Future<void> startListening(String locale);
  Future<void> stopListening();
  Future<void> speak(List<Map<String, String>> segments);
  Future<void> stopSpeaking();
  Future<void> pause();
  Future<void> resume();
  Future<void> close();
}

class NativeOfflineTutorService implements OfflineTutorService {
  static const channelName = 'veea/offline_tutor';
  static const eventChannelName = 'veea/offline_tutor/events';
  static const previewType = 'veea/camera_tutor_preview';
  static const _channel = MethodChannel(channelName);
  static const _events = EventChannel(eventChannelName);
  static final _eventStream = _events
      .receiveBroadcastStream()
      .where((event) => event is Map)
      .map((event) => Map<Object?, Object?>.from(event as Map));

  @override
  Stream<Map<Object?, Object?>> get events => _eventStream;

  @override
  Future<OfflineTutorStatus> status() async {
    try {
      final map = await _channel.invokeMapMethod<Object?, Object?>('getStatus');
      return OfflineTutorStatus.fromMap(map ?? const {});
    } on MissingPluginException {
      return const OfflineTutorStatus();
    }
  }

  @override
  Future<OfflineTutorStatus?> importModel() async {
    final map = await _channel.invokeMapMethod<Object?, Object?>('importModel');
    return map == null ? null : OfflineTutorStatus.fromMap(map);
  }

  @override
  Future<OfflineTutorStatus> downloadModel() async =>
      OfflineTutorStatus.fromMap(
        await _channel.invokeMapMethod<Object?, Object?>('downloadModel') ??
            const {},
      );

  @override
  Future<void> cancelModelDownload() =>
      _channel.invokeMethod<void>('cancelModelDownload');

  @override
  Future<OfflineTutorStatus> removeModel() async => OfflineTutorStatus.fromMap(
    await _channel.invokeMapMethod<Object?, Object?>('removeModel') ?? const {},
  );

  @override
  Future<String> capturePhoto() async {
    final path = await _channel.invokeMethod<String>('capturePhoto');
    if (path == null || path.isEmpty) {
      throw PlatformException(code: 'CAMERA_UNAVAILABLE');
    }
    return path;
  }

  @override
  Future<String> ask({
    required String question,
    String? imagePath,
    required int requestId,
  }) async =>
      await _channel.invokeMethod<String>('ask', {
        'question': question,
        'imagePath': imagePath,
        'requestId': requestId,
      }) ??
      '';

  @override
  Future<void> cancel() => _channel.invokeMethod<void>('cancel');
  @override
  Future<void> reset() => _channel.invokeMethod<void>('reset');
  @override
  Future<void> startListening(String locale) =>
      _channel.invokeMethod<void>('startListening', {'locale': locale});
  @override
  Future<void> stopListening() => _channel.invokeMethod<void>('stopListening');
  @override
  Future<void> speak(List<Map<String, String>> segments) =>
      _channel.invokeMethod<void>('speak', {'segments': segments});
  @override
  Future<void> stopSpeaking() => _channel.invokeMethod<void>('stopSpeaking');
  @override
  Future<void> pause() => _channel.invokeMethod<void>('pause');
  @override
  Future<void> resume() => _channel.invokeMethod<void>('resume');
  @override
  Future<void> close() => _channel.invokeMethod<void>('dispose');
}
