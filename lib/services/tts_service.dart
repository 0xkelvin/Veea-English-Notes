import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

/// Reads a word aloud.
///
/// Initialisation is lazy so the engine is only touched once the user actually
/// taps speak.
class TtsService extends ChangeNotifier {
  final FlutterTts _tts = FlutterTts();
  bool _initialized = false;
  bool _isSpeaking = false;
  String _currentWord = '';

  bool get isSpeaking => _isSpeaking;

  /// The word currently being read, so its row can show a live state.
  String get currentWord => _currentWord;

  /// `Platform` throws on web, so every use is guarded by [kIsWeb].
  bool get _isIOS => !kIsWeb && Platform.isIOS;

  Future<void> _ensureInitialized() async {
    if (_initialized) return;

    if (_isIOS) {
      await _tts.setSharedInstance(true);
      await _tts.setIosAudioCategory(IosTextToSpeechAudioCategory.playback, [
        IosTextToSpeechAudioCategoryOptions.allowBluetooth,
        IosTextToSpeechAudioCategoryOptions.allowBluetoothA2DP,
        IosTextToSpeechAudioCategoryOptions.mixWithOthers,
        IosTextToSpeechAudioCategoryOptions.duckOthers,
      ]);
      await _tts.awaitSpeakCompletion(true);
    }

    await _tts.setLanguage('en-US');
    // Slower than default: the point is to hear the shape of the word.
    await _tts.setSpeechRate(0.5);
    await _tts.setPitch(1.0);
    await _tts.setVolume(1.0);

    _tts.setStartHandler(() {
      _isSpeaking = true;
      notifyListeners();
    });
    _tts.setCompletionHandler(_reset);
    _tts.setCancelHandler(_reset);
    _tts.setErrorHandler((message) {
      debugPrint('TTS error: $message');
      _reset();
    });

    _initialized = true;
  }

  Future<void> speak(String text) async {
    try {
      await _ensureInitialized();
      await _tts.stop();
      _currentWord = text;
      _isSpeaking = true;
      notifyListeners();
      await _tts.speak(text);
    } catch (error, stack) {
      // A missing or busy speech engine must not take the screen down.
      debugPrint('TTS speak failed: $error\n$stack');
      _reset();
    }
  }

  Future<void> stop() async {
    await _tts.stop();
    _reset();
  }

  void _reset() {
    _isSpeaking = false;
    _currentWord = '';
    notifyListeners();
  }

  bool _isDisposed = false;

  @override
  void notifyListeners() {
    if (_isDisposed) return;
    super.notifyListeners();
  }

  @override
  void dispose() {
    _isDisposed = true;
    _tts.stop();
    super.dispose();
  }
}
