import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Holds the signed-in session.
///
/// Tokens live in the platform keychain/keystore rather than
/// SharedPreferences: a refresh token is a long-lived credential, and
/// SharedPreferences is world-readable on a rooted or jailbroken device.
class TokenStore {
  const TokenStore([this._storage = const FlutterSecureStorage()]);

  static const _accessKey = 'auth.access_token';
  static const _refreshKey = 'auth.refresh_token';

  /// The email address or phone number the account signs in with, kept only
  /// so the account screen can show who is signed in while offline.
  static const _identifierKey = 'auth.identifier';

  final FlutterSecureStorage _storage;

  Future<String?> readAccessToken() => _storage.read(key: _accessKey);

  Future<String?> readRefreshToken() => _storage.read(key: _refreshKey);

  Future<String?> readIdentifier() => _storage.read(key: _identifierKey);

  Future<bool> get hasSession async => await readRefreshToken() != null;

  Future<void> save({
    required String accessToken,
    required String refreshToken,
    String? identifier,
  }) async {
    await _storage.write(key: _accessKey, value: accessToken);
    await _storage.write(key: _refreshKey, value: refreshToken);
    if (identifier != null) {
      await _storage.write(key: _identifierKey, value: identifier);
    }
  }

  /// Replaces only the access token, after a silent refresh.
  Future<void> saveAccessToken(String accessToken) =>
      _storage.write(key: _accessKey, value: accessToken);

  Future<void> saveIdentifier(String identifier) =>
      _storage.write(key: _identifierKey, value: identifier);

  Future<void> clear() async {
    await _storage.delete(key: _accessKey);
    await _storage.delete(key: _refreshKey);
    await _storage.delete(key: _identifierKey);
  }
}
