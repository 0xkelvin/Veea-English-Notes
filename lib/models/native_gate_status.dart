class NativeGateApplication {
  const NativeGateApplication({
    required this.id,
    required this.label,
    this.unlockedUntil,
  });

  final String id;
  final String label;
  final DateTime? unlockedUntil;
}

class NativeGateStatus {
  const NativeGateStatus({
    this.supported = false,
    this.available = false,
    this.authorized = false,
    this.enabled = false,
    this.configured = false,
    this.passMinutes = 15,
    this.applications = const [],
    this.error,
  });

  final String? error;
  final bool supported;
  final bool available;
  final bool authorized;
  final bool enabled;
  final bool configured;
  final int passMinutes;
  final List<NativeGateApplication> applications;

  factory NativeGateStatus.fromMap(Map<dynamic, dynamic>? map) {
    if (map == null) return const NativeGateStatus();
    final applications = <NativeGateApplication>[];
    final rawApps = map['applications'];
    if (rawApps is List) {
      for (final raw in rawApps) {
        if (raw is! Map || raw['id'] is! String) continue;
        final seconds = raw['unlockedUntil'];
        applications.add(
          NativeGateApplication(
            id: raw['id'] as String,
            label: raw['label'] as String? ?? 'Protected app',
            unlockedUntil: seconds is num && seconds > 0
                ? DateTime.fromMillisecondsSinceEpoch((seconds * 1000).round())
                : null,
          ),
        );
      }
    }
    return NativeGateStatus(
      supported: map['supported'] == true,
      available: map['available'] == true,
      authorized: map['authorized'] == true,
      enabled: map['enabled'] == true,
      configured: map['configured'] == true || map['enabled'] == true,
      passMinutes: (map['passMinutes'] as num?)?.toInt() ?? 15,
      applications: applications,
      error: map['error'] is String && (map['error'] as String).isNotEmpty
          ? map['error'] as String
          : null,
    );
  }
}
