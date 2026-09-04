import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:veea_english_app/models/part_of_speech.dart';
import 'package:veea_english_app/models/vocabulary_word.dart';
import 'package:veea_english_app/models/word_challenge.dart';
import 'package:veea_english_app/services/friend_challenge_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences prefs;
  late FriendChallengeService service;

  final sampleWord = VocabularyWord(
    id: 'w1',
    word: 'resilient',
    meaning: 'kiên cường',
    partOfSpeech: PartOfSpeech.adjective,
    date: '2026-08-18',
    createdAt: DateTime(2026, 8, 18),
    updatedAt: DateTime(2026, 8, 18),
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    service = FriendChallengeService(prefs: prefs, random: Random(42));
    await service.init();
  });

  test('FriendChallengeService initializes profile with friend code and default friends', () {
    expect(service.profile.friendCode.startsWith('VEEA-'), isTrue);
    expect(service.friends, isNotEmpty);
  });

  test('addFriend creates a new connection with friend code', () async {
    final friend = await service.addFriend('VEEA-TEST', name: 'Bob');
    expect(friend.friendCode, 'VEEA-TEST');
    expect(friend.name, 'Bob');
    expect(service.friends.any((f) => f.friendCode == 'VEEA-TEST'), isTrue);
  });

  test('createChallenge creates VN to EN challenge with 4 shuffled options', () {
    final friend = service.friends.first;
    final challenge = service.createChallenge(
      friend: friend,
      word: sampleWord,
      mode: ChallengeMode.vnToEn,
    );

    expect(challenge.mode, ChallengeMode.vnToEn);
    expect(challenge.correctAnswer, 'resilient');
    expect(challenge.options.length, 4);
    expect(challenge.options, contains('resilient'));
  });

  test('createChallenge creates EN to VN challenge with 4 shuffled options', () {
    final friend = service.friends.first;
    final challenge = service.createChallenge(
      friend: friend,
      word: sampleWord,
      mode: ChallengeMode.enToVn,
    );

    expect(challenge.mode, ChallengeMode.enToVn);
    expect(challenge.correctAnswer, 'kiên cường');
    expect(challenge.options.length, 4);
    expect(challenge.options, contains('kiên cường'));
  });

  test('submitResponse scores correctly and updates duel stats', () async {
    final friend = service.friends.first;
    final initialScore = friend.duelScoreMe;
    final challenge = service.createChallenge(
      friend: friend,
      word: sampleWord,
      mode: ChallengeMode.vnToEn,
    );

    final result = await service.submitResponse(
      challenge: challenge,
      selectedAnswer: 'resilient',
      timeTakenSeconds: 3.2,
    );

    expect(result.isCorrect, isTrue);
    expect(result.xpEarned, 150); // 100 base + 50 speed bonus
    expect(service.friends.first.duelScoreMe, initialScore + 1);
  });

  test('simulateIncomingDrop fires challenge on stream', () async {
    WordChallenge? received;
    final sub = service.incomingChallenges.listen((c) => received = c);

    service.simulateIncomingDrop(word: sampleWord, mode: ChallengeMode.vnToEn);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(received, isNotNull);
    expect(received!.targetWord, 'resilient');
    await sub.cancel();
  });
}
