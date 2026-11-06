import 'dart:convert';

/// Configuration for the App Gate ("Word Toll") feature.
///
/// Persisted in SQLite's singleton `gate_config` row (`id = 1`).
class GateConfig {
  const GateConfig({
    this.enabled = false,
    this.passDurationMinutes = 15,
    this.requireDailyCapture = false,
    this.gatedApps = const [],
  });

  /// Minimum number of non-deleted words required before App Gate can be
  /// enabled in Settings.
  static const int minRequiredWords = 3;

  /// Supported unlock pass durations in minutes (`0` means every open).
  static const List<int> supportedDurations = [5, 15, 30, 0];

  /// Default popular distracting apps shown as quick-toggle presets.
  static const List<String> defaultPresetApps = [
    'Instagram',
    'X',
    'YouTube',
    'TikTok',
    'Reddit',
    'Threads',
  ];

  /// Extended catalog of popular social, video, messaging, and entertainment
  /// apps shown in the App Picker checklist alongside device-installed apps.
  static const List<String> selectableAppsCatalog = [
    'Instagram',
    'X',
    'YouTube',
    'TikTok',
    'Reddit',
    'Threads',
    'Facebook',
    'Messenger',
    'WhatsApp',
    'Telegram',
    'Discord',
    'Snapchat',
    'Netflix',
    'Twitch',
    'Spotify',
    'Pinterest',
    'LinkedIn',
  ];

  final bool enabled;

  /// Pass window in minutes (`5`, `15`, `30`, or `0` for every open).
  final int passDurationMinutes;

  /// When true, requires at least 1 word captured today before unlocking.
  final bool requireDailyCapture;

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
    bool? requireDailyCapture,
    List<String>? gatedApps,
  }) {
    return GateConfig(
      enabled: enabled ?? this.enabled,
      passDurationMinutes: passDurationMinutes ?? this.passDurationMinutes,
      requireDailyCapture: requireDailyCapture ?? this.requireDailyCapture,
      gatedApps: gatedApps ?? this.gatedApps,
    );
  }

  Map<String, Object?> toDbMap() => {
    'id': 1,
    'enabled': enabled ? 1 : 0,
    'pass_duration_minutes': passDurationMinutes,
    'require_daily_capture': requireDailyCapture ? 1 : 0,
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
    return GateConfig(
      enabled: (map['enabled'] as int? ?? 0) == 1,
      passDurationMinutes: (map['pass_duration_minutes'] as int?) ?? 15,
      requireDailyCapture: (map['require_daily_capture'] as int? ?? 0) == 1,
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
