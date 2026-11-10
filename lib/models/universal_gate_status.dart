class ShortcutProtectedApp {
  const ShortcutProtectedApp({
    required this.id,
    required this.name,
    this.verifiedAt,
  });
  final String id;
  final String name;
  final DateTime? verifiedAt;
}

class UniversalGateStatus {
  const UniversalGateStatus({
    this.enabled = false,
    this.apps = const [],
    this.error,
  });
  final bool enabled;
  final List<ShortcutProtectedApp> apps;
  final String? error;

  factory UniversalGateStatus.fromMap(Map<dynamic, dynamic>? value) {
    final apps = <ShortcutProtectedApp>[];
    for (final item in value?['apps'] as List? ?? const []) {
      if (item is! Map || item['id'] is! String || item['name'] is! String) {
        continue;
      }
      final timestamp = item['verifiedAt'];
      apps.add(
        ShortcutProtectedApp(
          id: item['id'],
          name: item['name'],
          verifiedAt: timestamp is num && timestamp > 0
              ? DateTime.fromMillisecondsSinceEpoch((timestamp * 1000).round())
              : null,
        ),
      );
    }
    return UniversalGateStatus(
      enabled: value?['enabled'] == true,
      apps: List.unmodifiable(apps),
      error: value?['error'] as String?,
    );
  }
}
