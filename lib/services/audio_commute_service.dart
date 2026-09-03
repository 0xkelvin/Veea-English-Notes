import 'dart:async';
import 'package:flutter/foundation.dart';

import '../models/vocabulary_word.dart';
import 'tts_service.dart';

enum AudioCommuteState {
  idle,
  playing,
  paused,
  stopped,
}

enum CommutePlaybackMode {
  wordOnly,
  wordAndExample,
  @Deprecated('Use wordOnly. Vietnamese audio is excluded.')
  wordThenMeaning,
  @Deprecated('Use wordAndExample. Vietnamese audio is excluded.')
  wordMeaningExample,
}

/// Hands-Free Background Commute Audio Player Service.
///
/// Cycles through vocabulary words in a rhythmic recall loop:
/// 1. Speaks English Word
/// 2. (Optional) Speaks English Example Sentence
/// 3. Smoothly transitions to the next word.
///
/// Note: Only English words/examples are read aloud, avoiding Vietnamese TTS pronunciation issues.
class AudioCommuteService extends ChangeNotifier {
  AudioCommuteService({required TtsService ttsService}) : _tts = ttsService;

  final TtsService _tts;

  AudioCommuteState _state = AudioCommuteState.idle;
  CommutePlaybackMode _mode = CommutePlaybackMode.wordOnly;

  List<VocabularyWord> _playlist = [];
  List<int> _order = [];
  int _currentIndex = 0;
  int _currentRepeat = 0;
  int _repeatCountPerWord = 1;
  int _recallPauseSeconds = 2;
  bool _isShuffle = false;
  bool _isLoop = true;
  String _currentPhaseText = '';

  Timer? _stepTimer;
  bool _isDisposed = false;

  AudioCommuteState get state => _state;
  bool get isPlaying => _state == AudioCommuteState.playing;
  bool get isPaused => _state == AudioCommuteState.paused;
  CommutePlaybackMode get mode => _mode;
  int get currentIndex => _currentIndex;
  int get totalWords => _playlist.length;
  int get recallPauseSeconds => _recallPauseSeconds;
  int get repeatCountPerWord => _repeatCountPerWord;
  bool get isShuffle => _isShuffle;
  bool get isLoop => _isLoop;
  String get currentPhaseText => _currentPhaseText;

  VocabularyWord? get currentWord {
    if (_playlist.isEmpty || _order.isEmpty) return null;
    final safeIndex = _order[_currentIndex % _order.length];
    if (safeIndex < 0 || safeIndex >= _playlist.length) return null;
    return _playlist[safeIndex];
  }

  void startPlayback(List<VocabularyWord> words, {int startIndex = 0}) {
    if (words.isEmpty) return;
    _playlist = List.of(words);
    _generateOrder();
    _currentIndex = startIndex.clamp(0, _order.length - 1);
    _currentRepeat = 0;
    _state = AudioCommuteState.playing;
    _notify();
    _runCurrentWordCycle();
  }

  void resume() {
    if (_state == AudioCommuteState.paused && _playlist.isNotEmpty) {
      _state = AudioCommuteState.playing;
      _notify();
      _runCurrentWordCycle();
    }
  }

  void pause() {
    _stepTimer?.cancel();
    _stepTimer = null;
    _tts.stop();
    _state = AudioCommuteState.paused;
    _currentPhaseText = 'PAUSED';
    _notify();
  }

  void stop() {
    _stepTimer?.cancel();
    _stepTimer = null;
    _tts.stop();
    _state = AudioCommuteState.stopped;
    _currentPhaseText = '';
    _notify();
  }

  void next() {
    _stepTimer?.cancel();
    _stepTimer = null;
    _tts.stop();
    if (_playlist.isEmpty) return;

    if (_currentIndex + 1 < _order.length) {
      _currentIndex++;
    } else if (_isLoop) {
      _currentIndex = 0;
    } else {
      stop();
      return;
    }
    _currentRepeat = 0;
    if (_state == AudioCommuteState.playing) {
      _runCurrentWordCycle();
    } else {
      _notify();
    }
  }

  void previous() {
    _stepTimer?.cancel();
    _stepTimer = null;
    _tts.stop();
    if (_playlist.isEmpty) return;

    if (_currentIndex > 0) {
      _currentIndex--;
    } else if (_isLoop) {
      _currentIndex = _order.length - 1;
    }
    _currentRepeat = 0;
    if (_state == AudioCommuteState.playing) {
      _runCurrentWordCycle();
    } else {
      _notify();
    }
  }

  void toggleShuffle() {
    _isShuffle = !_isShuffle;
    _generateOrder();
    _notify();
  }

  void toggleLoop() {
    _isLoop = !_isLoop;
    _notify();
  }

  void setRecallPauseSeconds(int seconds) {
    _recallPauseSeconds = seconds.clamp(1, 10);
    _notify();
  }

  void setRepeatCount(int count) {
    _repeatCountPerWord = count.clamp(1, 5);
    _notify();
  }

  void setPlaybackMode(CommutePlaybackMode mode) {
    _mode = mode;
    _notify();
  }

  void _generateOrder() {
    _order = List.generate(_playlist.length, (i) => i);
    if (_isShuffle) {
      _order.shuffle();
    }
  }

  Future<void> _runCurrentWordCycle() async {
    if (_state != AudioCommuteState.playing || _isDisposed) return;
    final word = currentWord;
    if (word == null) {
      stop();
      return;
    }

    try {
      // Step 1: Speak English Word ONLY (never speak Vietnamese meaning)
      _currentPhaseText = 'PLAYING: ${word.word.toUpperCase()}';
      _notify();
      await _tts.speak(word.word);

      if (_state != AudioCommuteState.playing || _isDisposed) return;

      // Step 2: Optional English Example Sentence
      final wantsExample = _mode == CommutePlaybackMode.wordAndExample ||
          _mode == CommutePlaybackMode.wordMeaningExample;
      if (wantsExample && word.examples.isNotEmpty) {
        _currentPhaseText = 'PAUSE (${_recallPauseSeconds}s)…';
        _notify();
        await Future.delayed(Duration(seconds: _recallPauseSeconds));

        if (_state != AudioCommuteState.playing || _isDisposed) return;

        _currentPhaseText = 'EXAMPLE: "${word.examples.first}"';
        _notify();
        await _tts.speak(word.examples.first);
      }

      if (_state != AudioCommuteState.playing || _isDisposed) return;

      // Step 3: Check Repeat Count or Advance
      _currentRepeat++;
      if (_currentRepeat < _repeatCountPerWord) {
        _currentPhaseText = 'REPEAT (${_currentRepeat + 1}/$_repeatCountPerWord)';
        _notify();
        await Future.delayed(Duration(seconds: _recallPauseSeconds));
        _runCurrentWordCycle();
      } else {
        _currentRepeat = 0;
        _currentPhaseText = 'NEXT WORD…';
        _notify();
        await Future.delayed(Duration(seconds: _recallPauseSeconds));
        next();
      }
    } catch (e) {
      debugPrint('Audio commute playback error: $e');
    }
  }

  void _notify() {
    if (!_isDisposed) notifyListeners();
  }

  @override
  void dispose() {
    _isDisposed = true;
    _stepTimer?.cancel();
    _stepTimer = null;
    super.dispose();
  }
}
