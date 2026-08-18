import 'package:flutter/foundation.dart';

/// Build-time configuration.
///
/// Supplied with `--dart-define` so the same source builds against a local
/// server, staging or production without a code change:
///
/// ```
/// flutter run --dart-define=VEEA_API_BASE_URL=http://localhost:8080
/// ```
class AppConfig {
  AppConfig._();

  /// Compiled-in default.
  ///
  /// Empty by default: with no server configured the app stays fully local,
  /// which is the state it shipped in and remains a valid way to use it.
  static const String _compiledBaseUrl = String.fromEnvironment(
    'VEEA_API_BASE_URL',
  );

  static String? _override;

  /// Base URL of the cloud service, without a trailing slash.
  static String get apiBaseUrl => _override ?? _compiledBaseUrl;

  /// Whether a cloud server has been configured for this build.
  static bool get isCloudEnabled => apiBaseUrl.isNotEmpty;

  /// Root of the versioned API.
  static String get apiRoot => '$apiBaseUrl/api/v1';

  /// How long a network call may take before it is abandoned.
  static const Duration requestTimeout = Duration(seconds: 20);

  /// Points this run at a different server.
  ///
  /// Used by tests to exercise the signed-in UI, and available in debug builds
  /// to switch servers without recompiling. Refused in release so a shipped
  /// build cannot be redirected at runtime.
  @visibleForTesting
  static void overrideBaseUrl(String? value) {
    assert(() {
      _override = value;
      return true;
    }());
  }
}
