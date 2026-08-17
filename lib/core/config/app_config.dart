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

  /// Base URL of the cloud service, without a trailing slash.
  ///
  /// Empty by default: with no server configured the app stays fully local,
  /// which is the state it shipped in and remains a valid way to use it.
  static const String apiBaseUrl = String.fromEnvironment('VEEA_API_BASE_URL');

  /// Whether a cloud server has been configured for this build.
  static bool get isCloudEnabled => apiBaseUrl.isNotEmpty;

  /// Root of the versioned API.
  static String get apiRoot => '$apiBaseUrl/api/v1';

  /// How long a network call may take before it is abandoned.
  static const Duration requestTimeout = Duration(seconds: 20);
}
