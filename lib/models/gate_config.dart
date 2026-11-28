import 'dart:convert';

/// A correctly answered final word waiting for the OS to grant access.
class GatePendingAnswer {
  const GatePendingAnswer({required this.wordId, required this.attempts});
  final String wordId;
  final int attempts;
}

/// Configuration for the App Gate ("Earn Screen Time" / "Word Toll") feature.
///
/// Persisted in SQLite's singleton `gate_config` row (`id = 1`).
class GateConfig {
  const GateConfig({
    this.enabled = false,
    this.passDurationMinutes = 15,
    this.wordsPerUnlock = 1,
    this.autoPronounce = false,
    this.dailyWordGoal = false,
    this.practiceWordIds,
    this.gatedApps = const [],
  });

  /// Minimum number of non-deleted words required before App Gate can be
  /// enabled in Settings.
  static const int minRequiredWords = 3;

  /// Supported unlock pass durations in minutes (`0` means every open).
  static const List<int> supportedDurations = [5, 15, 30, 0];

  /// Default popular distracting apps shown as quick-toggle presets.
  static const List<String> defaultPresetApps = [
    'Facebook',
    'Instagram',
    'TikTok',
    'YouTube',
    'X',
    'Threads',
    'Reddit',
  ];

  /// Extended catalog of popular social, video, messaging, and entertainment
  /// apps shown in the App Picker checklist alongside device-installed apps.
  static const List<String> selectableAppsCatalog = [
    'Facebook',
    'Instagram',
    'TikTok',
    'YouTube',
    'X',
    'Threads',
    'Reddit',
    'Messenger',
    'WhatsApp',
    'Telegram',
    'Zalo',
    'Discord',
    'Snapchat',
    'Netflix',
    'Twitch',
    'Spotify',
    'Pinterest',
    'LinkedIn',
    'Shopee',
    'Lazada',
    'Grab',
    'Chrome',
    'Gmail',
    'ChatGPT',
    'CapCut',
  ];

  final bool enabled;

  /// Pass window in minutes (`5`, `15`, `30`, or `0` for every open).
  final int passDurationMinutes;

  /// Any positive count, capped at the current practice pool size by the provider.
  final int wordsPerUnlock;

  final bool autoPronounce;

  /// An optional notebook goal; never a condition for unlocking apps.
  final bool dailyWordGoal;

  /// Null uses the whole notebook. An empty custom pool requires new selection.
  final List<String>? practiceWordIds;

  /// Selected app names, bundle IDs, or package identifiers to gate.
  final List<String> gatedApps;

  /// Formatted badge text for the status bar when unlocked.
  String get passBadgeLabel {
    if (passDurationMinutes <= 0) return 'EVERY OPEN PASS';
    return '$passDurationMinutes:00 PASS';
  }

  /// Human-readable description of the active pass window.
  String get passActiveLabel {
    if (passDurationMinutes <= 0) return 'Pass active · Single open';
    return 'Pass active · $passDurationMinutes minutes';
  }

  GateConfig copyWith({
    bool? enabled,
    int? passDurationMinutes,
    int? wordsPerUnlock,
    bool? autoPronounce,
    bool? dailyWordGoal,
    List<String>? practiceWordIds,
    bool useAllWords = false,
    List<String>? gatedApps,
  }) {
    return GateConfig(
      enabled: enabled ?? this.enabled,
      passDurationMinutes: passDurationMinutes ?? this.passDurationMinutes,
      wordsPerUnlock: wordsPerUnlock ?? this.wordsPerUnlock,
      autoPronounce: autoPronounce ?? this.autoPronounce,
      dailyWordGoal: dailyWordGoal ?? this.dailyWordGoal,
      practiceWordIds: useAllWords
          ? null
          : practiceWordIds ?? this.practiceWordIds,
      gatedApps: gatedApps ?? this.gatedApps,
    );
  }

  Map<String, Object?> toDbMap() => {
    'id': 1,
    'enabled': enabled ? 1 : 0,
    'pass_duration_minutes': passDurationMinutes,
    'words_per_unlock': wordsPerUnlock,
    'require_daily_capture': 0,
    'auto_pronounce': autoPronounce ? 1 : 0,
    'daily_word_goal': dailyWordGoal ? 1 : 0,
    'practice_word_ids_json': practiceWordIds == null
        ? null
        : jsonEncode(practiceWordIds),
    'gated_apps_json': jsonEncode(gatedApps),
  };

  factory GateConfig.fromDbMap(Map<String, Object?> map) {
    final rawApps = map['gated_apps_json'] as String?;
    List<String> apps = const [];
    if (rawApps != null && rawApps.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawApps);
        if (decoded is List) {
          apps = decoded.map((e) => e.toString()).toList(growable: false);
        }
      } catch (_) {}
    }
    List<String>? practiceWordIds;
    if (map['practice_word_ids_json'] case final String rawPool) {
      try {
        final decoded = jsonDecode(rawPool);
        practiceWordIds = decoded is List
            ? decoded.whereType<String>().toSet().toList()
            : [];
      } catch (_) {
        practiceWordIds = [];
      }
    }
    return GateConfig(
      enabled: (map['enabled'] as int? ?? 0) == 1,
      passDurationMinutes: (map['pass_duration_minutes'] as int?) ?? 15,
      wordsPerUnlock: ((map['words_per_unlock'] as int?) ?? 1).clamp(
        1,
        2147483647,
      ),
      autoPronounce: map['auto_pronounce'] == 1,
      dailyWordGoal: map['daily_word_goal'] == 1,
      practiceWordIds: practiceWordIds,
      gatedApps: apps,
    );
  }
}

/// A single completed App Gate challenge log entry.
class GateLog {
  const GateLog({
    required this.id,
    required this.wordId,
    required this.targetApp,
    required this.attempts,
    required this.passedAt,
  });

  final String id;
  final String wordId;
  final String targetApp;

  /// Number of wrong attempts before solving (`0` = 1st try, `1` = 2nd try, etc.)
  final int attempts;

  /// Epoch milliseconds when the gate was passed.
  final int passedAt;

  Map<String, Object?> toDbMap() => {
    'id': id,
    'word_id': wordId,
    'target_app': targetApp,
    'attempts': attempts,
    'passed_at': passedAt,
  };

  factory GateLog.fromDbMap(Map<String, Object?> map) {
    return GateLog(
      id: map['id']! as String,
      wordId: map['word_id']! as String,
      targetApp: map['target_app']! as String,
      attempts: (map['attempts'] as int?) ?? 0,
      passedAt: (map['passed_at'] as int?) ?? 0,
    );
  }
}

/// Pure formatting helpers for the 3-stage App Gate challenge UI.
class GateMaskHelper {
  GateMaskHelper._();

  /// Builds the progressive letter mask for [word].
  ///
  /// - Stage 0 (`revealExtra == 0`): shows first and last letter, e.g.
  ///   `p _ _ _ _ _ _ _ _ _ y`
  /// - Stage 1 (`revealExtra == 1`): reveals the 2nd letter as well, e.g.
  ///   `p r _ _ _ _ _ _ _ _ y`
  static String buildMask(String word, int revealExtra) {
    if (word.isEmpty) return '';
    final chars = word.split('');
    final buffer = <String>[];
    for (var idx = 0; idx < chars.length; idx++) {
      final ch = chars[idx];
      if (ch == ' ') {
        buffer.add('  ');
      } else if (idx == 0 || idx == chars.length - 1 || idx <= revealExtra) {
        buffer.add(ch);
      } else {
        buffer.add('_');
      }
    }
    return buffer.join(' ');
  }

  /// Replaces case-insensitive occurrences of [word] in [sentence] with
  /// underscores matching [word]'s length.
  static String blankWordInSentence(String sentence, String word) {
    final trimmed = word.trim();
    if (trimmed.isEmpty || sentence.isEmpty) return sentence;
    final replacement = '_' * trimmed.length;
    final pattern = RegExp(RegExp.escape(trimmed), caseSensitive: false);
    return sentence.replaceAll(pattern, replacement);
  }
}
