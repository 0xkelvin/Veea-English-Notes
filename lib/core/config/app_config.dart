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

  // The first public release offers all learning and app-lock controls free.
  // Reintroducing sales requires a reviewed learning-value product decision.
  static bool? _freeLaunchOverride;
  static bool get isFreeLaunch => _freeLaunchOverride ?? true;
  @visibleForTesting
  static void overrideFreeLaunch(bool? value) {
    assert(() {
      _freeLaunchOverride = value;
      return true;
    }());
  }

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

  /// The saved notebook is not uploaded. Explicit online word lookups are
  /// separate, user-approved requests to translation providers.
  /// Account and purchase services remain independent of this setting.
  static const bool isVocabularySyncEnabled = false;

  /// The exact non-consumable ID from App Store Connect. Empty fails closed.
  static const String _appleProProductId = String.fromEnvironment(
    'VEEA_APPLE_PRO_PRODUCT_ID',
  );

  static String? _appleProductOverride;
  static String get appleProProductId =>
      _appleProductOverride ?? _appleProProductId;
  @visibleForTesting
  static void overrideAppleProduct(String? product) {
    assert(() {
      _appleProductOverride = product;
      return true;
    }());
  }

  static const String _compiledZaloCommunityUrl = String.fromEnvironment(
    'VEEA_ZALO_COMMUNITY_URL',
  );
  static String? _zaloCommunityUrlOverride;
  static String get zaloCommunityUrl =>
      _zaloCommunityUrlOverride ?? _compiledZaloCommunityUrl;
  @visibleForTesting
  static void overrideZaloCommunityUrl(String? value) {
    assert(() {
      _zaloCommunityUrlOverride = value;
      return true;
    }());
  }

  /// Optional external HTTPS privacy policy URL supplied at build time.
  /// Empty by default so builds never point to an unverified address.
  static const String _compiledPrivacyPolicyUrl = String.fromEnvironment(
    'VEEA_PRIVACY_POLICY_URL',
  );
  static String? _privacyPolicyUrlOverride;
  static Uri? get privacyPolicyUri => parseTrustedHttpsUrl(
    _privacyPolicyUrlOverride ?? _compiledPrivacyPolicyUrl,
  );
  static String? get privacyPolicyUrl => privacyPolicyUri?.toString();
  @visibleForTesting
  static void overridePrivacyPolicyUrl(String? value) {
    assert(() {
      _privacyPolicyUrlOverride = value;
      return true;
    }());
  }

  /// Optional support mailbox supplied at build time.
  /// Empty by default so builds never advertise an unverified support email.
  static const String _compiledSupportEmail = String.fromEnvironment(
    'VEEA_SUPPORT_EMAIL',
  );
  static String? _supportEmailOverride;
  static String? get supportEmail =>
      parseSupportEmail(_supportEmailOverride ?? _compiledSupportEmail);
  @visibleForTesting
  static void overrideSupportEmail(String? value) {
    assert(() {
      _supportEmailOverride = value;
      return true;
    }());
  }

  /// Explicit build flag for legacy remote feedback delivery (`/client/config`
  /// and `/feedback`). Defaults to false because the Go account backend does
  /// not expose those routes.
  static const bool _compiledFeedbackDeliveryEnabled = bool.fromEnvironment(
    'VEEA_FEEDBACK_DELIVERY_ENABLED',
  );
  static bool? _feedbackDeliveryOverride;
  static bool get isFeedbackDeliveryEnabled =>
      isCloudEnabled &&
      (_feedbackDeliveryOverride ?? _compiledFeedbackDeliveryEnabled);
  @visibleForTesting
  static void overrideFeedbackDelivery(bool? value) {
    assert(() {
      _feedbackDeliveryOverride = value;
      return true;
    }());
  }

  /// Validates an externally configured HTTPS URL.
  ///
  /// Rejects non-HTTPS schemes, embedded credentials, explicit ports, raw IPs,
  /// localhost, control/whitespace characters, and path traversal segments.
  static Uri? parseTrustedHttpsUrl(String? raw) {
    if (raw == null) return null;
    final trimmed = raw.trim();
    if (trimmed.isEmpty ||
        RegExp(r'[\s\x00-\x1F\x7F]').hasMatch(trimmed) ||
        RegExp(
          r'/(?:\.|%2e){1,2}(?:/|[?#]|$)',
          caseSensitive: false,
        ).hasMatch(trimmed) ||
        trimmed.contains('\\')) {
      return null;
    }
    final uri = Uri.tryParse(trimmed);
    if (uri == null ||
        uri.scheme != 'https' ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasPort) {
      return null;
    }
    // Reject empty userinfo form such as https://@example.test/privacy.
    final afterScheme = trimmed.substring('https://'.length);
    final authorityEnd = afterScheme.indexOf(RegExp(r'[/?#]'));
    final rawAuthority = authorityEnd == -1
        ? afterScheme
        : afterScheme.substring(0, authorityEnd);
    if (rawAuthority.contains('@')) return null;

    if (!_isValidPublicHost(uri.host)) return null;

    final lowerRawPath = uri.path.toLowerCase();
    if (uri.pathSegments.any((segment) => segment == '..' || segment == '.') ||
        lowerRawPath.contains('%2e')) {
      return null;
    }
    return uri;
  }

  /// Validates a configured support email address for safe `mailto:` handoff.
  ///
  /// Rejects whitespace, control characters, multiple recipients, and URI
  /// delimiters that could inject query parameters or mail headers.
  static String? parseSupportEmail(String? raw) {
    if (raw == null) return null;
    final trimmed = raw.trim();
    if (trimmed.isEmpty ||
        trimmed.length > 254 ||
        RegExp(r'[\s\x00-\x1F\x7F?&,:;/\\<>"()\[\]]').hasMatch(trimmed)) {
      return null;
    }
    final parts = trimmed.split('@');
    if (parts.length != 2) return null;
    final local = parts[0];
    final domain = parts[1].toLowerCase();
    if (local.isEmpty ||
        local.length > 64 ||
        local.startsWith('.') ||
        local.endsWith('.') ||
        local.contains('..') ||
        !RegExp(r'^[A-Za-z0-9._+-]+$').hasMatch(local)) {
      return null;
    }
    if (!_isValidPublicHost(domain)) return null;
    return '$local@$domain';
  }

  static bool _isValidPublicHost(String host) {
    final lower = host.toLowerCase();
    if (lower.isEmpty ||
        lower.length > 253 ||
        lower == 'localhost' ||
        !lower.contains('.') ||
        lower.startsWith('.') ||
        lower.endsWith('.') ||
        lower.contains('..')) {
      return false;
    }
    final labels = lower.split('.');
    final labelPattern = RegExp(r'^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$');
    for (final label in labels) {
      if (!labelPattern.hasMatch(label)) return false;
    }
    // Final TLD label must be purely alphabetic (rejects IPv4 literals).
    return RegExp(r'^[a-z]{2,63}$').hasMatch(labels.last);
  }

  static const String appVersion = String.fromEnvironment(
    'VEEA_APP_VERSION',
    defaultValue: '2.3.0',
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
