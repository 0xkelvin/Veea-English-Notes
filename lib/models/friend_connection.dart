/// Represents the current user's profile in the Game Link / Pixel Link network.
class FriendProfile {
  const FriendProfile({
    required this.id,
    required this.friendCode,
    required this.displayName,
    this.duelsWon = 0,
    this.duelsPlayed = 0,
    this.xp = 0,
  });

  final String id;
  final String friendCode;
  final String displayName;
  final int duelsWon;
  final int duelsPlayed;
  final int xp;

  FriendProfile copyWith({
    String? id,
    String? friendCode,
    String? displayName,
    int? duelsWon,
    int? duelsPlayed,
    int? xp,
  }) {
    return FriendProfile(
      id: id ?? this.id,
      friendCode: friendCode ?? this.friendCode,
      displayName: displayName ?? this.displayName,
      duelsWon: duelsWon ?? this.duelsWon,
      duelsPlayed: duelsPlayed ?? this.duelsPlayed,
      xp: xp ?? this.xp,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'friendCode': friendCode,
    'displayName': displayName,
    'duelsWon': duelsWon,
    'duelsPlayed': duelsPlayed,
    'xp': xp,
  };

  factory FriendProfile.fromJson(Map<String, dynamic> json) => FriendProfile(
    id: json['id'] as String? ?? 'user_local',
    friendCode: json['friendCode'] as String? ?? 'VEEA-0000',
    displayName: json['displayName'] as String? ?? 'Retro Learner',
    duelsWon: json['duelsWon'] as int? ?? 0,
    duelsPlayed: json['duelsPlayed'] as int? ?? 0,
    xp: json['xp'] as int? ?? 0,
  );
}

/// A connected friend on the Pixel Link network.
class FriendConnection {
  const FriendConnection({
    required this.id,
    required this.friendCode,
    required this.name,
    required this.connectedAt,
    this.duelScoreMe = 0,
    this.duelScoreThem = 0,
    this.isOnline = true,
  });

  final String id;
  final String friendCode;
  final String name;
  final DateTime connectedAt;
  final int duelScoreMe;
  final int duelScoreThem;
  final bool isOnline;

  FriendConnection copyWith({
    String? id,
    String? friendCode,
    String? name,
    DateTime? connectedAt,
    int? duelScoreMe,
    int? duelScoreThem,
    bool? isOnline,
  }) {
    return FriendConnection(
      id: id ?? this.id,
      friendCode: friendCode ?? this.friendCode,
      name: name ?? this.name,
      connectedAt: connectedAt ?? this.connectedAt,
      duelScoreMe: duelScoreMe ?? this.duelScoreMe,
      duelScoreThem: duelScoreThem ?? this.duelScoreThem,
      isOnline: isOnline ?? this.isOnline,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'friendCode': friendCode,
    'name': name,
    'connectedAt': connectedAt.toIso8601String(),
    'duelScoreMe': duelScoreMe,
    'duelScoreThem': duelScoreThem,
    'isOnline': isOnline,
  };

  factory FriendConnection.fromJson(Map<String, dynamic> json) => FriendConnection(
    id: json['id'] as String,
    friendCode: json['friendCode'] as String,
    name: json['name'] as String,
    connectedAt: DateTime.tryParse(json['connectedAt'] as String? ?? '') ?? DateTime.now(),
    duelScoreMe: json['duelScoreMe'] as int? ?? 0,
    duelScoreThem: json['duelScoreThem'] as int? ?? 0,
    isOnline: json['isOnline'] as bool? ?? true,
  );
}
