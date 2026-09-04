import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/friend_connection.dart';
import '../models/part_of_speech.dart';
import '../models/vocabulary_word.dart';
import '../models/word_challenge.dart';

class FriendChallengeService extends ChangeNotifier {
  FriendChallengeService({
    SharedPreferences? prefs,
    Random? random,
  })  : _prefs = prefs,
        _random = random ?? Random();

  SharedPreferences? _prefs;
  final Random _random;

  static const _profileKey = 'veea_friend_profile';
  static const _friendsKey = 'veea_friends_list';
  static const _historyKey = 'veea_challenges_history';

  FriendProfile _profile = const FriendProfile(
    id: 'user_local',
    friendCode: 'VEEA-8888',
    displayName: 'Retro Learner',
  );
  List<FriendConnection> _friends = [];
  List<WordChallenge> _challengeHistory = [];

  final _incomingChallengeController = StreamController<WordChallenge>.broadcast();
  final _resultController = StreamController<WordChallengeResult>.broadcast();

  Stream<WordChallenge> get incomingChallenges => _incomingChallengeController.stream;
  Stream<WordChallengeResult> get challengeResults => _resultController.stream;

  FriendProfile get profile => _profile;
  List<FriendConnection> get friends => List.unmodifiable(_friends);
  List<WordChallenge> get challengeHistory => List.unmodifiable(_challengeHistory);

  Future<void> init() async {
    _prefs ??= await SharedPreferences.getInstance();

    // Load or create profile
    final rawProfile = _prefs!.getString(_profileKey);
    if (rawProfile != null) {
      try {
        _profile = FriendProfile.fromJson(jsonDecode(rawProfile) as Map<String, dynamic>);
      } catch (_) {
        _profile = _generateNewProfile();
      }
    } else {
      _profile = _generateNewProfile();
      await _prefs!.setString(_profileKey, jsonEncode(_profile.toJson()));
    }

    // Load friends
    final rawFriends = _prefs!.getString(_friendsKey);
    if (rawFriends != null) {
      try {
        final list = jsonDecode(rawFriends) as List;
        _friends = list
            .map((item) => FriendConnection.fromJson(item as Map<String, dynamic>))
            .toList();
      } catch (_) {
        _friends = [];
      }
    } else {
      // Preload 2 fun retro demo friends if empty
      _friends = [
        FriendConnection(
          id: 'friend_alex',
          friendCode: 'VEEA-77K2',
          name: 'Alex (Senior FE)',
          connectedAt: DateTime.now().subtract(const Duration(days: 2)),
          duelScoreMe: 3,
          duelScoreThem: 2,
        ),
        FriendConnection(
          id: 'friend_quoc',
          friendCode: 'VEEA-49X0',
          name: 'Quốc (DevOps)',
          connectedAt: DateTime.now().subtract(const Duration(days: 5)),
          duelScoreMe: 5,
          duelScoreThem: 4,
        ),
      ];
      await _saveFriends();
    }

    // Load history
    final rawHistory = _prefs!.getString(_historyKey);
    if (rawHistory != null) {
      try {
        final list = jsonDecode(rawHistory) as List;
        _challengeHistory = list
            .map((item) => WordChallenge.fromJson(item as Map<String, dynamic>))
            .toList();
      } catch (_) {
        _challengeHistory = [];
      }
    }

    notifyListeners();
  }

  FriendProfile _generateNewProfile() {
    const chars = '23456789ABCDEFGHJKLMNPQRSTUVWXYZ';
    final code = List.generate(4, (_) => chars[_random.nextInt(chars.length)]).join();
    return FriendProfile(
      id: 'usr_${DateTime.now().millisecondsSinceEpoch}',
      friendCode: 'VEEA-$code',
      displayName: 'Pixel Runner',
      xp: 250,
      duelsWon: 8,
      duelsPlayed: 14,
    );
  }

  Future<void> updateDisplayName(String newName) async {
    _profile = _profile.copyWith(displayName: newName);
    await _prefs?.setString(_profileKey, jsonEncode(_profile.toJson()));
    notifyListeners();
  }

  Future<FriendConnection> addFriend(String code, {String? name}) async {
    final cleanCode = code.trim().toUpperCase();
    final existingIndex = _friends.indexWhere((f) => f.friendCode == cleanCode);
    if (existingIndex != -1) {
      return _friends[existingIndex];
    }

    final newFriend = FriendConnection(
      id: 'friend_${DateTime.now().millisecondsSinceEpoch}',
      friendCode: cleanCode,
      name: (name != null && name.trim().isNotEmpty)
          ? name.trim()
          : 'Player ${cleanCode.replaceAll('VEEA-', '')}',
      connectedAt: DateTime.now(),
    );

    _friends.insert(0, newFriend);
    await _saveFriends();
    notifyListeners();
    return newFriend;
  }

  Future<void> removeFriend(String friendId) async {
    _friends.removeWhere((f) => f.id == friendId);
    await _saveFriends();
    notifyListeners();
  }

  Future<void> _saveFriends() async {
    final raw = jsonEncode(_friends.map((f) => f.toJson()).toList());
    await _prefs?.setString(_friendsKey, raw);
  }

  Future<void> _saveHistory() async {
    final raw = jsonEncode(_challengeHistory.map((c) => c.toJson()).toList());
    await _prefs?.setString(_historyKey, raw);
  }

  /// Creates and dispatches an outgoing challenge to a friend.
  WordChallenge createChallenge({
    required FriendConnection friend,
    required VocabularyWord word,
    required ChallengeMode mode,
    List<VocabularyWord> otherWordsPool = const [],
  }) {
    final distractors = _generateDistractors(
      target: word,
      mode: mode,
      pool: otherWordsPool,
    );

    final correctAnswer = mode == ChallengeMode.vnToEn ? word.word : word.meaning;
    final allOptions = List<String>.from(distractors)..add(correctAnswer);
    allOptions.shuffle(_random);

    final challenge = WordChallenge(
      id: 'chal_${DateTime.now().millisecondsSinceEpoch}',
      senderId: _profile.id,
      senderName: _profile.displayName,
      receiverId: friend.id,
      receiverName: friend.name,
      targetWord: word.word,
      targetMeaning: word.meaning,
      partOfSpeech: word.partOfSpeech?.name.toUpperCase() ?? '',
      mode: mode,
      options: allOptions,
      correctAnswer: correctAnswer,
      createdAt: DateTime.now(),
      status: ChallengeStatus.pending,
    );

    _challengeHistory.insert(0, challenge);
    _saveHistory();
    notifyListeners();
    return challenge;
  }

  /// Triggers a live simulated incoming challenge overlay on this device.
  void simulateIncomingDrop({
    String? senderName,
    VocabularyWord? word,
    ChallengeMode? mode,
    List<VocabularyWord> pool = const [],
  }) {
    final testWord = word ??
        VocabularyWord(
          id: 'demo_1',
          word: 'resilient',
          meaning: 'kiên cường, có khả năng phục hồi nhanh',
          partOfSpeech: PartOfSpeech.adjective,
          date: '2026-08-18',
          createdAt: DateTime(2026, 8, 18),
          updatedAt: DateTime(2026, 8, 18),
        );

    final chosenMode = mode ??
        (_random.nextBool() ? ChallengeMode.vnToEn : ChallengeMode.enToVn);

    final distractors = _generateDistractors(
      target: testWord,
      mode: chosenMode,
      pool: pool,
    );

    final correctAnswer =
        chosenMode == ChallengeMode.vnToEn ? testWord.word : testWord.meaning;
    final allOptions = List<String>.from(distractors)..add(correctAnswer);
    allOptions.shuffle(_random);

    final incoming = WordChallenge(
      id: 'drop_${DateTime.now().millisecondsSinceEpoch}',
      senderId: 'sim_friend',
      senderName: senderName ?? (_friends.isNotEmpty ? _friends.first.name : 'Alex (Senior FE)'),
      targetWord: testWord.word,
      targetMeaning: testWord.meaning,
      partOfSpeech: testWord.partOfSpeech?.name.toUpperCase() ?? '',
      mode: chosenMode,
      options: allOptions,
      correctAnswer: correctAnswer,
      createdAt: DateTime.now(),
      status: ChallengeStatus.pending,
    );

    _incomingChallengeController.add(incoming);
  }

  List<String> _generateDistractors({
    required VocabularyWord target,
    required ChallengeMode mode,
    List<VocabularyWord> pool = const [],
  }) {
    final distractorSet = <String>{};

    if (mode == ChallengeMode.vnToEn) {
      // Collect other English words
      for (final w in pool) {
        if (w.word.toLowerCase() != target.word.toLowerCase()) {
          distractorSet.add(w.word);
          if (distractorSet.length >= 3) break;
        }
      }
      // Fallback tech distractors
      const fallbacks = [
        'tenacious',
        'mitigate',
        'bottleneck',
        'redundant',
        'scalability',
        'deprecated',
        'concurrency',
        'benchmark',
      ];
      for (final f in fallbacks) {
        if (f.toLowerCase() != target.word.toLowerCase()) {
          distractorSet.add(f);
          if (distractorSet.length >= 3) break;
        }
      }
    } else {
      // Collect Vietnamese meanings
      for (final w in pool) {
        if (w.meaning != target.meaning) {
          distractorSet.add(w.meaning);
          if (distractorSet.length >= 3) break;
        }
      }
      const fallbacks = [
        'lưu loát, hùng biện',
        'bền bỉ, ngoan cường',
        'giảm nhẹ, làm dịu bớt',
        'điểm nghẽn, tắc nghẽn',
        'dư thừa, không cần thiết',
        'khả năng mở rộng hệ thống',
        'được khuyên không nên dùng nữa',
      ];
      for (final f in fallbacks) {
        if (f != target.meaning) {
          distractorSet.add(f);
          if (distractorSet.length >= 3) break;
        }
      }
    }

    return distractorSet.take(3).toList();
  }

  /// Submits the user's answer to an active challenge.
  Future<WordChallengeResult> submitResponse({
    required WordChallenge challenge,
    required String selectedAnswer,
    required double timeTakenSeconds,
  }) async {
    final isCorrect = selectedAnswer.trim().toLowerCase() ==
        challenge.correctAnswer.trim().toLowerCase();

    final speedBonus = (isCorrect && timeTakenSeconds < 5.0) ? 50 : 0;
    final xpEarned = isCorrect ? 100 + speedBonus : 10;

    // Update profile stats
    _profile = _profile.copyWith(
      xp: _profile.xp + xpEarned,
      duelsPlayed: _profile.duelsPlayed + 1,
      duelsWon: isCorrect ? _profile.duelsWon + 1 : _profile.duelsWon,
    );
    await _prefs?.setString(_profileKey, jsonEncode(_profile.toJson()));

    // Update head-to-head friend record if applicable
    final friendIndex = _friends.indexWhere(
      (f) =>
          f.id == challenge.senderId ||
          f.name == challenge.senderName ||
          f.id == challenge.receiverId,
    );
    if (friendIndex != -1) {
      final f = _friends[friendIndex];
      _friends[friendIndex] = f.copyWith(
        duelScoreMe: isCorrect ? f.duelScoreMe + 1 : f.duelScoreMe,
        duelScoreThem: !isCorrect ? f.duelScoreThem + 1 : f.duelScoreThem,
      );
      await _saveFriends();
    }

    final updatedChallenge = challenge.copyWith(
      status: ChallengeStatus.completed,
      isWon: isCorrect,
      timeTakenSeconds: timeTakenSeconds,
      userAnswer: selectedAnswer,
    );

    _challengeHistory.insert(0, updatedChallenge);
    await _saveHistory();

    final result = WordChallengeResult(
      challenge: updatedChallenge,
      isCorrect: isCorrect,
      selectedAnswer: selectedAnswer,
      timeTakenSeconds: timeTakenSeconds,
      xpEarned: xpEarned,
    );

    _resultController.add(result);
    notifyListeners();
    return result;
  }

  @override
  void dispose() {
    _incomingChallengeController.close();
    _resultController.close();
    super.dispose();
  }
}
