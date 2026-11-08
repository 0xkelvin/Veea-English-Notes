/// Prepared templates use the same app identifier as the distributed iOS app.
/// Never offer another app's template for an unsupported choice.
class ShortcutTemplate {
  const ShortcutTemplate({required this.app, required this.linkId});

  final String app;
  final String linkId;
  String get name => 'Veea Gate $app';
  Uri get installUrl => Uri.https('www.icloud.com', '/shortcuts/$linkId');
  // Importing with Keep Both can rename the new copy (e.g. "Veea Gate X 2").
  // A name-based deep link would reopen the old copy and risk duplicate triggers.
  Uri get editorUrl => Uri.parse('shortcuts://');

  static const available = [
    ShortcutTemplate(app: 'X', linkId: 'f498121930cd4a5ebd6f7f516fc10aed'),
  ];

  static ShortcutTemplate? forApp(String app) {
    for (final template in available) {
      if (template.app.toLowerCase() == app.trim().toLowerCase()) {
        return template;
      }
    }
    return null;
  }
}

class ShortcutSetupStatus {
  const ShortcutSetupStatus({
    this.tested = const {},
    this.supportsImport = false,
  });

  final Map<String, DateTime> tested;
  final bool supportsImport;

  factory ShortcutSetupStatus.fromMap(Map<dynamic, dynamic>? map) {
    final tested = <String, DateTime>{};
    if (map?['tested'] case final Map values) {
      for (final entry in values.entries) {
        if (entry.key is String && entry.value is num && entry.value > 0) {
          tested[entry.key.toString().toLowerCase()] =
              DateTime.fromMillisecondsSinceEpoch((entry.value * 1000).round());
        }
      }
    }
    return ShortcutSetupStatus(
      tested: Map.unmodifiable(tested),
      supportsImport: map?['supportsImport'] == true,
    );
  }

  bool wasTested(String app) => tested.containsKey(app.trim().toLowerCase());
}
