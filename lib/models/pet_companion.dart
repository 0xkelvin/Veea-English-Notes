enum PetMood {
  ecstatic,
  happy,
  studying,
  hungry,
  sleepy,
}

enum PetStage {
  egg(1, 'EGG SPROUT', 'Lv. 1-2'),
  hatchling(2, 'BIT HATCHLING', 'Lv. 3-5'),
  cyberPup(3, 'CYBER PUP', 'Lv. 6-9'),
  mechaDragon(4, 'MECHA DRAGON', 'Lv. 10+');

  const PetStage(this.stageNumber, this.displayName, this.levelRange);

  final int stageNumber;
  final String displayName;
  final String levelRange;
}

/// 8-Bit Virtual Pet Companion Model ("Veea-chi").
class PetCompanion {
  const PetCompanion({
    this.name = 'VEEA-CHI',
    this.xp = 20,
    this.wordsFedToday = 0,
    this.lastFedDateKey = '',
  });

  final String name;
  final int xp;
  final int wordsFedToday;
  final String lastFedDateKey;

  /// Calculates level: every 50 XP = 1 Level.
  int get level => (xp ~/ 50) + 1;

  /// XP progress inside current level (0..49).
  int get currentLevelXp => xp % 50;

  /// Evolution stage based on level.
  PetStage get stage {
    if (level <= 2) return PetStage.egg;
    if (level <= 5) return PetStage.hatchling;
    if (level <= 9) return PetStage.cyberPup;
    return PetStage.mechaDragon;
  }

  /// Derives mood from feeding count and streak.
  PetMood calculateMood({required int streakDays, required int dueCount}) {
    if (wordsFedToday >= 5) return PetMood.ecstatic;
    if (wordsFedToday >= 1) return PetMood.happy;
    if (dueCount > 0) return PetMood.hungry;
    if (streakDays > 0) return PetMood.happy;
    return PetMood.sleepy;
  }

  PetCompanion copyWith({
    String? name,
    int? xp,
    int? wordsFedToday,
    String? lastFedDateKey,
  }) {
    return PetCompanion(
      name: name ?? this.name,
      xp: xp ?? this.xp,
      wordsFedToday: wordsFedToday ?? this.wordsFedToday,
      lastFedDateKey: lastFedDateKey ?? this.lastFedDateKey,
    );
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'xp': xp,
        'wordsFedToday': wordsFedToday,
        'lastFedDateKey': lastFedDateKey,
      };

  factory PetCompanion.fromJson(Map<String, dynamic> json) {
    return PetCompanion(
      name: json['name'] as String? ?? 'VEEA-CHI',
      xp: (json['xp'] as num?)?.toInt() ?? 20,
      wordsFedToday: (json['wordsFedToday'] as num?)?.toInt() ?? 0,
      lastFedDateKey: json['lastFedDateKey'] as String? ?? '',
    );
  }
}
