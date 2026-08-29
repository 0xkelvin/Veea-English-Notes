import 'package:flutter_test/flutter_test.dart';
import 'package:veea_english_app/models/vocabulary_word.dart';
import 'package:veea_english_app/services/audio_commute_service.dart';
import 'package:veea_english_app/services/tts_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late TtsService tts;
  late AudioCommuteService service;

  final sampleWords = [
    VocabularyWord.create(
      id: '1',
      word: 'resilient',
      meaning: 'kiên cường',
      date: '2026-08-29',
      examples: ['a resilient system'],
      now: DateTime(2026, 8, 29),
    ),
    VocabularyWord.create(
      id: '2',
      word: 'tenacious',
      meaning: 'bền bỉ',
      date: '2026-08-29',
      examples: ['a tenacious worker'],
      now: DateTime(2026, 8, 29),
    ),
  ];

  setUp(() {
    tts = TtsService();
    service = AudioCommuteService(ttsService: tts);
  });

  tearDown(() {
    service.stop();
    service.dispose();
  });

  group('AudioCommuteService', () {
    test('initializes in idle state', () {
      expect(service.state, AudioCommuteState.idle);
      expect(service.isPlaying, isFalse);
      expect(service.totalWords, 0);
      expect(service.currentWord, isNull);
    });

    test('startPlayback sets playlist and starts playing', () {
      service.startPlayback(sampleWords);
      expect(service.state, AudioCommuteState.playing);
      expect(service.isPlaying, isTrue);
      expect(service.totalWords, 2);
      expect(service.currentWord?.word, 'resilient');
    });

    test('pause and resume toggle playback state', () {
      service.startPlayback(sampleWords);
      service.pause();
      expect(service.state, AudioCommuteState.paused);
      expect(service.isPaused, isTrue);

      service.resume();
      expect(service.state, AudioCommuteState.playing);
      expect(service.isPlaying, isTrue);
    });

    test('next and previous navigate words', () {
      service.startPlayback(sampleWords);
      expect(service.currentIndex, 0);

      service.next();
      expect(service.currentIndex, 1);
      expect(service.currentWord?.word, 'tenacious');

      service.previous();
      expect(service.currentIndex, 0);
      expect(service.currentWord?.word, 'resilient');
    });

    test('toggling shuffle and loop changes flags', () {
      service.startPlayback(sampleWords);
      expect(service.isLoop, isTrue);
      expect(service.isShuffle, isFalse);

      service.toggleShuffle();
      expect(service.isShuffle, isTrue);

      service.toggleLoop();
      expect(service.isLoop, isFalse);
    });

    test('updating recall pause and repeat count clamps values', () {
      service.setRecallPauseSeconds(4);
      expect(service.recallPauseSeconds, 4);

      service.setRepeatCount(2);
      expect(service.repeatCountPerWord, 2);
    });
  });
}
