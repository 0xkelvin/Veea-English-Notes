import 'package:flutter/foundation.dart';

/// Build-time configuration.
///
/// Supplied with `--dart-define` so the same source builds against a local
/// server, staging or production without a code change:
///
/// ```
/// flutter run --dart-define=VEEA_API_BASE_URL=http://localhost:18386
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

  static const bool _legacyPasswordAccounts = bool.fromEnvironment(
    'VEEA_LEGACY_PASSWORD_ACCOUNTS',
  );
  static bool? _legacyOverride;
  static bool get legacyPasswordAccounts =>
      _legacyOverride ?? _legacyPasswordAccounts;
  @visibleForTesting
  static void overrideLegacyAccounts(bool? value) {
    assert(() {
      _legacyOverride = value;
      return true;
    }());
  }

  static const String zaloCommunityUrl = String.fromEnvironment(
    'VEEA_ZALO_COMMUNITY_URL',
  );
  static const String appVersion = String.fromEnvironment(
    'VEEA_APP_VERSION',
    defaultValue: '1.0.2',
  );

  /// Temporarily paused. Restore native widget registration/embedding too
  /// before enabling this again (see README).
  static const bool areHomeScreenWidgetsEnabled = false;

  /// Feature flag for Pixel Link friend battles / duels.
  /// Set to false via --dart-define=VEEA_ENABLE_FRIEND_DUELS=false to disable.
  static const bool isFriendDuelsEnabled = bool.fromEnvironment(
    'VEEA_ENABLE_FRIEND_DUELS',
    defaultValue: true,
  );

  /// Distinguishes the local offline challenge simulation from production real-time duels.
  static const bool isFriendDuelsLabDemo = true;

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
