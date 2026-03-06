import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

class TtsService extends ChangeNotifier {
  final FlutterTts _tts = FlutterTts();
  bool _initialized = false;
  bool _isSpeaking = false;
  String _currentWord = '';

  bool get isSpeaking => _isSpeaking;
  String get currentWord => _currentWord;

  Future<void> _ensureInitialized() async {
    if (_initialized) return;

    if (!kIsWeb && Platform.isIOS) {
      await _tts.setSharedInstance(true);
      await _tts.setIosAudioCategory(
        IosTextToSpeechAudioCategory.playback,
        [
          IosTextToSpeechAudioCategoryOptions.allowBluetooth,
          IosTextToSpeechAudioCategoryOptions.allowBluetoothA2DP,
        ],
      );
    }

    await _tts.setLanguage('en-US');
    await _tts.setSpeechRate(Platform.isIOS ? 0.5 : 0.5);
    await _tts.setPitch(1.0);
    await _tts.setVolume(1.0);

    _tts.setStartHandler(() {
      _isSpeaking = true;
      notifyListeners();
    });

    _tts.setCompletionHandler(() {
      _isSpeaking = false;
      _currentWord = '';
      notifyListeners();
    });

    _tts.setCancelHandler(() {
      _isSpeaking = false;
      _currentWord = '';
      notifyListeners();
    });

    _tts.setErrorHandler((msg) {
      _isSpeaking = false;
      _currentWord = '';
      debugPrint('TTS Error: $msg');
      notifyListeners();
    });

    _initialized = true;
  }

  Future<void> speak(String text) async {
    await _ensureInitialized();
    await _tts.stop();
    _currentWord = text;
    _isSpeaking = true;
    notifyListeners();
    final result = await _tts.speak(text);
    debugPrint('TTS speak("$text") result: $result');
  }

  Future<void> stop() async {
    await _tts.stop();
    _isSpeaking = false;
    _currentWord = '';
    notifyListeners();
  }

  @override
  void dispose() {
    _tts.stop();
    super.dispose();
  }
}
