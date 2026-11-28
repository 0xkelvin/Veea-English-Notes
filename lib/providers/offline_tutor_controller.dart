import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/offline_tutor.dart';
import '../services/offline_tutor_service.dart';

enum TutorOperation {
  idle,
  checking,
  downloading,
  importing,
  takingPhoto,
  thinking,
}

/// One ephemeral camera lesson. Only an explicit save in the ordinary word
/// editor persists anything to the notebook; photos/audio/chat are not synced.
class OfflineTutorController extends ChangeNotifier {
  OfflineTutorController({OfflineTutorService? service})
    : _service = service ?? NativeOfflineTutorService();
  final OfflineTutorService _service;
  StreamSubscription<Map<Object?, Object?>>? _subscription;
  var status = const OfflineTutorStatus();
  TutorOperation operation = TutorOperation.checking;
  final List<TutorTurn> _turns = [];
  List<TutorTurn> get turns => List.unmodifiable(_turns);
  String? imagePath;
  String? error;
  String? pendingQuestion;
  String dictation = '';
  int speechRevision = 0;
  int submissionRevision = 0;
  bool listening = false;
  bool microphoneStarting = false;
  bool readAloud = true;
  double? downloadProgress;
  String downloadPhase = 'downloading';
  bool cancellingDownload = false;
  String speechLocale = 'vi-VN';
  bool _disposed = false;
  bool _paused = false;
  bool _sendImage = true;
  bool _acceptSpeech = false;
  int _epoch = 0;
  bool get busy => operation != TutorOperation.idle;
  bool get hasScene => imagePath != null;
  bool get canAsk =>
      status.ready &&
      hasScene &&
      !busy &&
      !microphoneStarting &&
      !_paused &&
      _turns.length < 6;
  bool _current(int epoch) => !_disposed && epoch == _epoch;

  Future<void> initialize() async {
    final epoch = ++_epoch;
    operation = TutorOperation.checking;
    _notify();
    try {
      final next = await _service.status();
      if (!_current(epoch)) return;
      status = next;
      if (status.speechLocales.isNotEmpty &&
          !status.speechLocales.contains(speechLocale)) {
        speechLocale = status.speechLocales.first;
      }
      if (status.supported) {
        _subscription ??= _service.events.listen(
          _event,
          onError: (_) {
            if (_disposed) return;
            listening = false;
            microphoneStarting = false;
            _acceptSpeech = false;
            _notify();
          },
        );
      }
    } catch (_) {
      if (_current(epoch)) {
        error = 'Could not check the tutor. Close this page and try again.';
      }
    } finally {
      if (_current(epoch)) {
        operation = TutorOperation.idle;
        _notify();
      }
    }
  }

  Future<void> importModel() async {
    if (busy ||
        _disposed ||
        !status.supported ||
        !status.runtimeAvailable ||
        !status.canRun ||
        listening ||
        microphoneStarting) {
      return;
    }
    final epoch = ++_epoch;
    operation = TutorOperation.importing;
    error = null;
    _notify();
    try {
      await _service.stopListening();
      await _service.stopSpeaking();
      if (!_current(epoch)) return;
      await _service.pause();
      if (!_current(epoch)) return;
      final next = await _service.importModel();
      if (!_current(epoch)) return;
      if (next != null) {
        status = next;
        _turns.clear();
        imagePath = null;
        _sendImage = true;
      }
    } catch (exception) {
      if (_current(epoch)) error = _message(exception);
    } finally {
      if (_current(epoch)) {
        if (status.ready && !hasScene) {
          try {
            await _service.resume();
          } catch (_) {}
        }
        if (_current(epoch)) {
          operation = TutorOperation.idle;
          _notify();
        }
      }
    }
  }

  Future<void> downloadModel() async {
    if (busy ||
        _disposed ||
        !status.supported ||
        !status.runtimeAvailable ||
        !status.canRun ||
        listening ||
        microphoneStarting) {
      return;
    }
    final epoch = ++_epoch;
    operation = TutorOperation.downloading;
    downloadProgress = null;
    downloadPhase = 'downloading';
    cancellingDownload = false;
    error = null;
    _notify();
    try {
      final next = await _service.downloadModel();
      if (!_current(epoch)) return;
      status = next;
      if (status.ready) {
        imagePath = null;
        _turns.clear();
        _sendImage = true;
        await _service.resume();
      } else {
        error =
            'The model has not finished installing. Please try the download again.';
      }
    } catch (exception) {
      if (_current(epoch)) error = _message(exception);
    } finally {
      if (_current(epoch)) {
        operation = TutorOperation.idle;
        downloadProgress = null;
        _notify();
      }
    }
  }

  Future<void> cancelDownload() async {
    if (_disposed ||
        operation != TutorOperation.downloading ||
        cancellingDownload) {
      return;
    }
    final epoch = ++_epoch;
    cancellingDownload = true;
    _notify();
    try {
      await _service.cancelModelDownload();
      if (!_current(epoch)) return;
      status = await _service.status();
      if (_current(epoch)) error = null;
    } catch (exception) {
      if (_current(epoch)) error = _message(exception);
    } finally {
      if (_current(epoch)) {
        cancellingDownload = false;
        downloadProgress = null;
        operation = TutorOperation.idle;
        _notify();
      }
    }
  }

  Future<void> removeModel() async {
    if (busy || _disposed || listening || microphoneStarting) return;
    final epoch = ++_epoch;
    operation = TutorOperation.importing;
    _notify();
    try {
      await _service.stopListening();
      await _service.stopSpeaking();
      if (!_current(epoch)) return;
      final next = await _service.removeModel();
      if (!_current(epoch)) return;
      status = next;
      imagePath = null;
      _turns.clear();
      error = null;
      _sendImage = true;
    } catch (exception) {
      if (_current(epoch)) error = _message(exception);
    } finally {
      if (_current(epoch)) {
        operation = TutorOperation.idle;
        _notify();
      }
    }
  }

  Future<void> capture() => _newScene(() => _service.capturePhoto());
  Future<void> choosePhoto(Future<String?> Function() pick) =>
      _newScene(() async {
        await _service.pause();
        final path = await pick();
        if (path == null && !hasScene && !_disposed && !_paused) {
          await _service.resume();
        }
        return path;
      });

  /// Retaking is two steps: show the live view first, then let the user choose
  /// the new frame. Never photograph blindly behind the frozen scene.
  Future<void> startNewScene() async {
    if (_disposed ||
        _paused ||
        !status.ready ||
        (busy && operation != TutorOperation.thinking)) {
      return;
    }
    final epoch = ++_epoch;
    operation = TutorOperation.takingPhoto;
    listening = false;
    microphoneStarting = false;
    _acceptSpeech = false;
    pendingQuestion = null;
    error = null;
    _notify();
    try {
      await _service.cancel();
      await _service.stopListening();
      await _service.stopSpeaking();
      if (!_current(epoch)) return;
      await _service.reset();
      if (!_current(epoch)) return;
      _turns.clear();
      imagePath = null;
      _sendImage = true;
      await _service.resume();
    } catch (exception) {
      if (_current(epoch)) error = _message(exception);
    } finally {
      if (_current(epoch)) {
        operation = TutorOperation.idle;
        _notify();
      }
    }
  }

  Future<void> _newScene(Future<String?> Function() capture) async {
    if (_disposed ||
        _paused ||
        !status.ready ||
        (busy && operation != TutorOperation.thinking)) {
      return;
    }
    final interrupted = operation == TutorOperation.thinking;
    final epoch = ++_epoch;
    operation = TutorOperation.takingPhoto;
    error = null;
    pendingQuestion = null;
    listening = false;
    microphoneStarting = false;
    _acceptSpeech = false;
    _notify();
    try {
      await _service.cancel();
      if (!_current(epoch)) return;
      await _service.stopListening();
      await _service.stopSpeaking();
      if (!_current(epoch)) return;
      if (interrupted) {
        await _service.reset();
        if (!_current(epoch)) return;
        _turns.clear();
        _sendImage = true;
      }
      final path = await capture();
      if (!_current(epoch) || path == null) return;
      await _service.reset();
      if (!_current(epoch)) return;
      imagePath = path;
      _turns.clear();
      _sendImage = true;
      // Freeze the chosen scene and release the camera while learning. Native
      // pause keeps a completed idle conversation and stops audio/capture only.
      await _service.pause();
    } catch (exception) {
      if (_current(epoch)) error = _message(exception);
    } finally {
      if (_current(epoch)) {
        operation = TutorOperation.idle;
        _notify();
      }
    }
  }

  Future<void> ask(String text) async {
    if (!canAsk) return;
    final question = text.trim();
    if (question.isEmpty) return;
    if (question.length > 1200) {
      error = 'Keep your question under 1,200 characters.';
      _notify();
      return;
    }
    final epoch = ++_epoch;
    operation = TutorOperation.thinking;
    pendingQuestion = question;
    error = null;
    listening = false;
    _acceptSpeech = false;
    submissionRevision++;
    _notify();
    try {
      await _service.stopListening();
      await _service.stopSpeaking();
      if (!_current(epoch)) return;
      final raw = await _service.ask(
        question: question,
        imagePath: _sendImage ? imagePath : null,
        requestId: epoch,
      );
      if (!_current(epoch)) return;
      final reply = TutorReply.parse(raw);
      _turns.add(TutorTurn(question: question, reply: reply));
      _sendImage = false;
      operation = TutorOperation.idle;
      pendingQuestion = null;
      _notify();
      if (readAloud) await speak(reply);
    } catch (exception) {
      if (!_current(epoch)) return;
      // Native generation failures discard the unfinished turn and retain
      // completed history. A transport/parser failure has no such guarantee.
      final keepsCompletedHistory =
          exception is PlatformException &&
          const {
            'INVALID_OUTPUT',
            'INFERENCE_TIMEOUT',
            'CONTEXT_FULL',
            'INFERENCE_FAILED',
            'MODEL_LOAD_FAILED',
            'INSUFFICIENT_MEMORY',
            'BUSY',
            'CANCELLED',
          }.contains(exception.code);
      if (!keepsCompletedHistory) {
        try {
          await _service.reset();
        } catch (_) {}
      }
      if (_current(epoch)) {
        if (!keepsCompletedHistory) {
          _sendImage = true;
          _turns.clear();
        }
        error = exception is FormatException
            ? 'The tutor could not format that reply. Try asking a shorter question.'
            : _message(exception);
      }
    } finally {
      if (_current(epoch)) {
        operation = TutorOperation.idle;
        pendingQuestion = null;
        _notify();
      }
    }
  }

  Future<void> cancel() async {
    if (_disposed || operation != TutorOperation.thinking) return;
    final epoch = ++_epoch;
    pendingQuestion = null;
    try {
      await _service.cancel();
      if (!_current(epoch)) return;
      await _service.reset();
      if (_current(epoch)) {
        _sendImage = true;
        _turns.clear();
      }
    } catch (_) {
      if (_current(epoch)) {
        error =
            'Could not stop the tutor. Close this page before trying again.';
      }
    } finally {
      if (_current(epoch)) {
        operation = TutorOperation.idle;
        _notify();
      }
    }
  }

  Future<void> toggleListening() async {
    if (listening) {
      try {
        await _service.stopListening();
      } catch (_) {}
      if (!_disposed) {
        listening = false;
        _notify();
      }
      return;
    }
    if (!canAsk || !status.speechLocales.contains(speechLocale)) return;
    final epoch = _epoch;
    microphoneStarting = true;
    _acceptSpeech = true;
    error = null;
    _notify();
    try {
      await _service.stopSpeaking();
      if (!_current(epoch) || _paused || !_acceptSpeech) return;
      await _service.startListening(speechLocale);
      if (_current(epoch)) listening = true;
    } catch (exception) {
      if (_current(epoch)) {
        _acceptSpeech = false;
        error = _message(exception);
      }
    } finally {
      if (_current(epoch)) {
        microphoneStarting = false;
        _notify();
      }
    }
  }

  Future<void> speak(TutorReply reply) async {
    if (_disposed || _paused || busy || listening || microphoneStarting) return;
    final epoch = _epoch;
    try {
      await _service.speak([
        {'text': reply.explanationVi, 'language': 'vi-VN'},
        {'text': reply.answerEn, 'language': 'en-US'},
      ]);
    } on PlatformException catch (exception) {
      if (!_current(epoch) || _paused) return;
      if (exception.code == 'VOICE_UNAVAILABLE') {
        try {
          await _service.speak([
            {'text': reply.answerEn, 'language': 'en-US'},
          ]);
          if (!_current(epoch) || _paused) return;
          error =
              'Vietnamese read-aloud is unavailable. The English reply is read aloud instead.';
          _notify();
          return;
        } catch (_) {}
      }
      if (_current(epoch)) {
        error =
            'Read-aloud is unavailable for this language. The written reply is still available.';
        _notify();
      }
    } catch (_) {
      if (_current(epoch) && !_paused) {
        error =
            'Read-aloud is unavailable. The written reply is still available.';
        _notify();
      }
    }
  }

  Future<void> pronounce(String word) async {
    if (_disposed || _paused || busy || listening || microphoneStarting) return;
    try {
      await _service.speak([
        {'text': word, 'language': 'en-US'},
      ]);
    } catch (_) {
      if (!_disposed) {
        error = 'English read-aloud is unavailable on this phone.';
        _notify();
      }
    }
  }

  void toggleReadAloud() {
    readAloud = !readAloud;
    if (!readAloud) unawaited(_service.stopSpeaking().catchError((_) {}));
    _notify();
  }

  void setSpeechLocale(String locale) {
    if (!listening &&
        !microphoneStarting &&
        status.speechLocales.contains(locale)) {
      speechLocale = locale;
      _notify();
    }
  }

  void _event(Map<Object?, Object?> event) {
    if (_disposed || _paused) return;
    switch (event['type']) {
      case 'model':
        if (!busy &&
            (event['state'] == 'imported' || event['state'] == 'removed')) {
          unawaited(_refreshInstalledModel());
        }
      case 'modelDownload':
        if (operation != TutorOperation.downloading || cancellingDownload) {
          return;
        }
        final progress = event['progress'];
        if (progress is num && progress.isFinite) {
          downloadProgress = progress.toDouble().clamp(0, 1);
        }
        final phase = event['phase'];
        if (phase == 'downloading' ||
            phase == 'verifying' ||
            phase == 'installing') {
          downloadPhase = phase as String;
        }
        _notify();
      case 'speech':
        if (!_acceptSpeech) return;
        final text = event['text'];
        if (text is! String || text.length > 1200) return;
        dictation = text;
        speechRevision++;
        if (event['isFinal'] == true) {
          _acceptSpeech = false;
          listening = false;
          microphoneStarting = false;
          _notify();
          if (text.trim().isNotEmpty) unawaited(ask(text));
        } else {
          _notify();
        }
      case 'listening':
        listening = event['active'] == true;
        _notify();
      case 'error':
        _acceptSpeech = false;
        listening = false;
        microphoneStarting = false;
        error = _message(
          PlatformException(
            code: event['code'] as String? ?? 'VOICE_UNAVAILABLE',
          ),
        );
        _notify();
    }
  }

  Future<void> _refreshInstalledModel() async {
    final epoch = _epoch;
    try {
      final next = await _service.status();
      if (!_current(epoch) || _paused || busy) return;
      status = next;
      imagePath = null;
      _turns.clear();
      _sendImage = true;
      if (status.ready) await _service.resume();
      if (_current(epoch)) _notify();
    } catch (_) {}
  }

  Future<void> pause() async {
    if (_disposed || _paused) return;
    _paused = true;
    ++_epoch;
    listening = false;
    _acceptSpeech = false;
    microphoneStarting = false;
    cancellingDownload = false;
    pendingQuestion = null;
    if (operation != TutorOperation.idle) {
      _sendImage = true;
      _turns.clear();
    }
    operation = TutorOperation.idle;
    _notify();
    try {
      await _service.pause();
    } catch (_) {}
  }

  Future<void> resume() async {
    if (_disposed || !_paused) return;
    try {
      if (hasScene) {
        await _service.pause();
      } else {
        await _service.resume();
      }
      if (_disposed) return;
      _paused = false;
      await initialize();
    } catch (_) {
      if (!_disposed) {
        error = 'Could not resume the camera. Close this page and reopen it.';
        _notify();
      }
    }
  }

  String _message(Object exception) {
    final code = exception is PlatformException ? exception.code : '';
    return switch (code) {
      'CANCELLED' => 'The request was cancelled. You can try again.',
      'MODEL_MISSING' => 'Set up the AI model before starting a lesson.',
      'MODEL_INVALID' || 'INVALID_MODEL' =>
        'This model could not be opened. Import a compatible Gemma 4 E2B .litertlm file.',
      'LOW_MEMORY' || 'DEVICE_UNSUPPORTED' || 'UNSUPPORTED_DEVICE' =>
        'This phone does not have enough memory for the camera tutor.',
      'INSUFFICIENT_MEMORY' =>
        'Not enough memory is available right now. Close the tutor and try again.',
      'NOT_ENOUGH_SPACE' || 'INSUFFICIENT_STORAGE' =>
        'Free some space on your phone, then download or import the model again.',
      'BUSY' => 'The tutor is finishing another task. Try again in a moment.',
      'CAMERA_DENIED' || 'CAMERA_PERMISSION' || 'CAMERA_PERMISSION_DENIED' =>
        'Allow camera access in iPhone Settings, or choose a photo.',
      'CAMERA_UNAVAILABLE' =>
        'The camera is not ready. Try again, or choose a photo.',
      'SPEECH_DENIED' ||
      'MICROPHONE_DENIED' ||
      'VOICE_PERMISSION' ||
      'SPEECH_PERMISSION_DENIED' ||
      'MICROPHONE_PERMISSION_DENIED' =>
        'Allow microphone and speech access in iPhone Settings, or type your question.',
      'VOICE_UNAVAILABLE' ||
      'SPEECH_UNAVAILABLE' ||
      'SPEECH_LOCALE_UNSUPPORTED' =>
        'Offline voice input is unavailable in this language. You can type your question.',
      'CONTEXT_FULL' =>
        'This lesson is full. Take a new photo to start another conversation.',
      'MODEL_LOAD_FAILED' =>
        'The model could not load on this phone. Close the tutor and try again.',
      'INFERENCE_TIMEOUT' =>
        'The tutor took too long. Try a shorter question or a new photo.',
      'INVALID_OUTPUT' =>
        'The tutor gave an incomplete reply. Try asking a shorter question.',
      'NO_SCENE' ||
      'INVALID_IMAGE' => 'Take or choose a new photo to continue.',
      'IMPORT_FAILED' =>
        'The model could not be imported. Your previous model was kept.',
      'NETWORK_REQUIRED' || 'WIFI_REQUIRED' =>
        'Connect to Wi-Fi to download the model, then try again.',
      'DOWNLOAD_FAILED' =>
        'The model download did not finish. Check Wi-Fi and try again.',
      'CHECKSUM_MISMATCH' || 'DOWNLOAD_INVALID' =>
        'The model did not pass verification. Download it again from the official source.',
      _ =>
        'The tutor could not finish on this phone. Try again or start with a new photo.',
    };
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    ++_epoch;
    unawaited(_subscription?.cancel() ?? Future<void>.value());
    unawaited(_service.close().catchError((_) {}));
    super.dispose();
  }
}
