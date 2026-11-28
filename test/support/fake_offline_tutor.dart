import 'dart:async';

import 'package:veea_english_app/models/offline_tutor.dart';
import 'package:veea_english_app/services/offline_tutor_service.dart';

const tutorReady = OfflineTutorStatus(
  supported: true,
  runtimeAvailable: true,
  canRun: true,
  modelReady: true,
  modelBytes: 2588147712,
  deviceMemoryBytes: 8000000000,
  speechLocales: ['vi-VN', 'en-US'],
);
const tutorNeedsModel = OfflineTutorStatus(
  supported: true,
  runtimeAvailable: true,
  canRun: true,
  speechLocales: ['vi-VN', 'en-US'],
);
const cupLesson =
    '''{"explanationVi":"Đây là một chiếc cốc.","answerEn":"This is a cup. You can say: a cup of coffee.","vocabulary":[{"word":"cup","meaningVi":"cái cốc","exampleEn":"I would like a cup of coffee.","pronunciation":"/kʌp/"}]}''';

class FakeOfflineTutor extends OfflineTutorService {
  final stream = StreamController<Map<Object?, Object?>>.broadcast(sync: true);
  OfflineTutorStatus statusValue = tutorReady;
  OfflineTutorStatus? importResult = tutorReady;
  String reply = cupLesson;
  Future<String>? pending;
  Future<OfflineTutorStatus>? pendingDownload;
  Future<void>? pendingStopSpeaking;
  Object? askError;
  Object? speechError;
  Object? ttsError;
  final calls = <String>[];
  final requests = <Map<String, Object?>>[];
  final spoken = <List<Map<String, String>>>[];
  int captures = 0;
  String? capturePath;
  @override
  Stream<Map<Object?, Object?>> get events => stream.stream;
  @override
  Future<OfflineTutorStatus> status() async {
    calls.add('status');
    return statusValue;
  }

  @override
  Future<OfflineTutorStatus?> importModel() async {
    calls.add('import');
    if (importResult != null) statusValue = importResult!;
    return importResult;
  }

  @override
  Future<OfflineTutorStatus> downloadModel() async {
    calls.add('download');
    if (pendingDownload != null) return pendingDownload!;
    statusValue = tutorReady;
    return statusValue;
  }

  @override
  Future<void> cancelModelDownload() async {
    calls.add('cancelDownload');
  }

  @override
  Future<OfflineTutorStatus> removeModel() async {
    calls.add('remove');
    statusValue = tutorNeedsModel;
    return statusValue;
  }

  @override
  Future<String> capturePhoto() async {
    calls.add('capture');
    captures++;
    return capturePath ?? '/synthetic/scene-$captures.jpg';
  }

  @override
  Future<String> ask({
    required String question,
    String? imagePath,
    required int requestId,
  }) async {
    calls.add('ask');
    requests.add({
      'question': question,
      'imagePath': imagePath,
      'requestId': requestId,
    });
    if (askError case final e?) throw e;
    return pending ?? reply;
  }

  @override
  Future<void> cancel() async {
    calls.add('cancel');
  }

  @override
  Future<void> reset() async {
    calls.add('reset');
  }

  @override
  Future<void> startListening(String locale) async {
    calls.add('listen:$locale');
    if (speechError case final e?) throw e;
  }

  @override
  Future<void> stopListening() async {
    calls.add('stopListening');
  }

  @override
  Future<void> speak(List<Map<String, String>> segments) async {
    calls.add('speak');
    if (ttsError case final e?) throw e;
    spoken.add(segments);
  }

  @override
  Future<void> stopSpeaking() async {
    calls.add('stopSpeaking');
    await pendingStopSpeaking;
  }

  @override
  Future<void> pause() async {
    calls.add('pause');
  }

  @override
  Future<void> resume() async {
    calls.add('resume');
  }

  @override
  Future<void> close() async {
    calls.add('close');
  }
}
