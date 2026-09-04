enum ChallengeMode {
  vnToEn, // Vietnamese meaning given, choose/type the English word
  enToVn, // English word given, choose/type the Vietnamese meaning
}

enum ChallengeStatus {
  pending,
  completed,
  expired,
}

class WordChallenge {
  const WordChallenge({
    required this.id,
    required this.senderId,
    required this.senderName,
    this.receiverId,
    this.receiverName,
    required this.targetWord,
    required this.targetMeaning,
    this.partOfSpeech = '',
    required this.mode,
    required this.options,
    required this.correctAnswer,
    required this.createdAt,
    this.status = ChallengeStatus.pending,
    this.isWon,
    this.timeTakenSeconds,
    this.userAnswer,
  });

  final String id;
  final String senderId;
  final String senderName;
  final String? receiverId;
  final String? receiverName;
  final String targetWord;
  final String targetMeaning;
  final String partOfSpeech;
  final ChallengeMode mode;
  final List<String> options;
  final String correctAnswer;
  final DateTime createdAt;
  final ChallengeStatus status;
  final bool? isWon;
  final double? timeTakenSeconds;
  final String? userAnswer;

  /// Clue displayed in the main challenge header
  String get clue => mode == ChallengeMode.vnToEn ? targetMeaning : targetWord;

  /// Question prompt displayed to the user
  String get promptTitle => mode == ChallengeMode.vnToEn
      ? 'CHỌN TỪ TIẾNG ANH ĐÚNG:'
      : 'CHỌN NGHĨA TIẾNG VIỆT ĐÚNG:';

  WordChallenge copyWith({
    String? id,
    String? senderId,
    String? senderName,
    String? targetWord,
    String? targetMeaning,
    String? partOfSpeech,
    ChallengeMode? mode,
    List<String>? options,
    String? correctAnswer,
    DateTime? createdAt,
    ChallengeStatus? status,
    bool? isWon,
    double? timeTakenSeconds,
    String? userAnswer,
  }) {
    return WordChallenge(
      id: id ?? this.id,
      senderId: senderId ?? this.senderId,
      senderName: senderName ?? this.senderName,
      targetWord: targetWord ?? this.targetWord,
      targetMeaning: targetMeaning ?? this.targetMeaning,
      partOfSpeech: partOfSpeech ?? this.partOfSpeech,
      mode: mode ?? this.mode,
      options: options ?? this.options,
      correctAnswer: correctAnswer ?? this.correctAnswer,
      createdAt: createdAt ?? this.createdAt,
      status: status ?? this.status,
      isWon: isWon ?? this.isWon,
      timeTakenSeconds: timeTakenSeconds ?? this.timeTakenSeconds,
      userAnswer: userAnswer ?? this.userAnswer,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'senderId': senderId,
    'senderName': senderName,
    'targetWord': targetWord,
    'targetMeaning': targetMeaning,
    'partOfSpeech': partOfSpeech,
    'mode': mode.name,
    'options': options,
    'correctAnswer': correctAnswer,
    'createdAt': createdAt.toIso8601String(),
    'status': status.name,
    'isWon': isWon,
    'timeTakenSeconds': timeTakenSeconds,
    'userAnswer': userAnswer,
  };

  factory WordChallenge.fromJson(Map<String, dynamic> json) => WordChallenge(
    id: json['id'] as String,
    senderId: json['senderId'] as String,
    senderName: json['senderName'] as String,
    targetWord: json['targetWord'] as String,
    targetMeaning: json['targetMeaning'] as String,
    partOfSpeech: json['partOfSpeech'] as String? ?? '',
    mode: ChallengeMode.values.firstWhere(
      (m) => m.name == json['mode'],
      orElse: () => ChallengeMode.vnToEn,
    ),
    options: List<String>.from(json['options'] as List? ?? const []),
    correctAnswer: json['correctAnswer'] as String,
    createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ?? DateTime.now(),
    status: ChallengeStatus.values.firstWhere(
      (s) => s.name == json['status'],
      orElse: () => ChallengeStatus.pending,
    ),
    isWon: json['isWon'] as bool?,
    timeTakenSeconds: (json['timeTakenSeconds'] as num?)?.toDouble(),
    userAnswer: json['userAnswer'] as String?,
  );
}

class WordChallengeResult {
  const WordChallengeResult({
    required this.challenge,
    required this.isCorrect,
    required this.selectedAnswer,
    required this.timeTakenSeconds,
    required this.xpEarned,
  });

  final WordChallenge challenge;
  final bool isCorrect;
  final String selectedAnswer;
  final double timeTakenSeconds;
  final int xpEarned;
}
