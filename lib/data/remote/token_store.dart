import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// A session is one atomic keychain entry, so tokens and notebook ownership
/// cannot be left belonging to different accounts after an interrupted write.
class TokenStore {
  const TokenStore([this._storage = const FlutterSecureStorage()]);
  static const _sessionKey = 'auth.session.v2';
  static const _lastAccountKey = 'auth.last_account_identifier';
  final FlutterSecureStorage _storage;

  Future<Map<String, dynamic>?> _session() async {
    final raw = await _storage.read(key: _sessionKey);
    return raw == null ? null : jsonDecode(raw) as Map<String, dynamic>;
  }

  Future<String?> _read(String field, String legacy) async =>
      (await _session())?[field] as String? ?? await _storage.read(key: legacy);
  Future<String?> readAccessToken() =>
      _read('access_token', 'auth.access_token');
  Future<String?> readRefreshToken() =>
      _read('refresh_token', 'auth.refresh_token');
  Future<String?> readIdentifier() => _read('identifier', 'auth.identifier');
  Future<String?> readAccountId() async =>
      (await _session())?['account_id'] as String?;
  Future<String?> readAuthMethod() async =>
      (await _session())?['auth_method'] as String?;
  Future<String?> readLastAccount() => _storage.read(key: _lastAccountKey);
  Future<void> saveLastAccount(String account) =>
      _storage.write(key: _lastAccountKey, value: account);
  Future<void> clearLastAccount() => _storage.delete(key: _lastAccountKey);
  Future<bool> get hasSession async => await readRefreshToken() != null;

  Future<void> save({
    required String accessToken,
    required String refreshToken,
    String? identifier,
    String? accountId,
    String? authMethod,
  }) async {
    final previous = await _session() ?? <String, dynamic>{};
    await _storage.write(
      key: _sessionKey,
      value: jsonEncode({
        ...previous,
        'access_token': accessToken,
        'refresh_token': refreshToken,
        'identifier': ?identifier,
        'account_id': ?accountId,
        'auth_method': ?authMethod,
      }),
    );
  }

  Future<void> saveAccessToken(String accessToken) async {
    final refresh = await readRefreshToken();
    if (refresh == null) return;
    await save(
      accessToken: accessToken,
      refreshToken: refresh,
      identifier: await readIdentifier(),
    );
  }

  Future<void> saveIdentifier(String identifier) async {
    final access = await readAccessToken();
    final refresh = await readRefreshToken();
    if (access == null || refresh == null) return;
    await save(
      accessToken: access,
      refreshToken: refresh,
      identifier: identifier,
    );
  }

  Future<void> clear() async {
    await _storage.delete(key: _sessionKey);
    for (final key in [
      'auth.access_token',
      'auth.refresh_token',
      'auth.identifier',
    ]) {
      await _storage.delete(key: key);
    }
  }
}
