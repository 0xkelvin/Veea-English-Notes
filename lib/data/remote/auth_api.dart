import 'dart:convert';
import 'api_client.dart';
import 'token_store.dart';

/// The signed-in account as the server sees it.
class AccountProfile {
  const AccountProfile({this.id, this.email, this.phone, this.authMethod});
  final String? id;
  final String? authMethod;

  /// Null on an account identified only by a phone number.
  final String? email;

  /// Null on an account identified only by an email address.
  final String? phone;

  /// Whichever identifier to show when only one can be shown.
  String get primary => email ?? phone ?? '';

  factory AccountProfile.fromJson(Map<String, Object?> json) {
    return AccountProfile(
      id: json['id'] as String?,
      authMethod: json['auth_method'] as String?,
      email: json['email'] as String?,
      phone: json['phone'] as String?,
    );
  }
}

/// Account lifecycle: sign up, sign in, sign out, and everything the user can
/// do to their own account afterwards.
class AuthApi {
  const AuthApi({required ApiClient client, required TokenStore tokens})
    : _client = client,
      _tokens = tokens;

  final ApiClient _client;
  final TokenStore _tokens;

  Future<Map<String, Object?>> clientConfig() =>
      _client.get('/client/config', authenticated: false);

  Future<OtpChallenge> requestOtp(
    String phone, {
    bool forDeletion = false,
  }) async {
    final data = await _client.post(
      forDeletion ? '/users/me/delete-otp' : '/auth/otp/request',
      body: forDeletion ? null : {'phone': phone},
      authenticated: forDeletion,
    );
    return OtpChallenge.fromJson(data);
  }

  Future<AuthSession> verifyOtp(OtpChallenge challenge, String code) async {
    final data = await _client.post(
      '/auth/otp/verify',
      body: {'challenge_id': challenge.id, 'code': code},
      authenticated: false,
    );
    return AuthSession.fromJson(
      data,
      fallbackIdentifier: challenge.phone ?? '',
      method: 'phone_otp',
    );
  }

  Future<void> deleteWithOtp(OtpChallenge challenge, String code) async {
    await _client.delete(
      '/users/me/delete-otp',
      body: {'challenge_id': challenge.id, 'code': code},
    );
    await _tokens.clear();
  }

  Future<AuthSession> passwordSession({
    required String identifier,
    required String password,
    bool register = false,
  }) async {
    final data = await _client.post(
      register ? '/auth/register' : '/auth/login',
      body: {'identifier': identifier, 'password': password},
      authenticated: false,
    );
    return AuthSession.fromJson(data, fallbackIdentifier: identifier);
  }

  Future<void> commitSession(AuthSession session) => _tokens.save(
    accessToken: session.accessToken,
    refreshToken: session.refreshToken,
    identifier: session.identifier,
    accountId: session.accountId,
    authMethod: session.method,
  );

  /// Creates an account and stores the session it returns.
  ///
  /// [identifier] is an email address or a phone number; the server decides
  /// which from its shape.
  Future<void> register({
    required String identifier,
    required String password,
  }) async {
    final data = await _client.post(
      '/auth/register',
      body: {'identifier': identifier, 'password': password},
      authenticated: false,
    );

    // Registration nests its tokens under the new user record.
    final tokens = data['tokens'];
    if (tokens is! Map<String, Object?>) {
      throw const ApiException('Malformed registration response');
    }
    await _persist(tokens, data['identifier'] as String? ?? identifier);
  }

  Future<void> login({
    required String identifier,
    required String password,
  }) async {
    final data = await _client.post(
      '/auth/login',
      body: {'identifier': identifier, 'password': password},
      authenticated: false,
    );
    await _persist(data, identifier);
  }

  /// Revokes the refresh token server-side and clears the local session.
  ///
  /// The local session is cleared even if the network call fails — the user
  /// asked to sign out, and leaving credentials on the device would be worse
  /// than an orphaned server-side token that expires on its own.
  Future<void> logout() async {
    final refreshToken = await _tokens.readRefreshToken();
    try {
      if (refreshToken != null) {
        await _client.post(
          '/auth/logout',
          body: {'refresh_token': refreshToken},
        );
      }
    } on ApiException {
      // Ignored deliberately; see above.
    } finally {
      await _tokens.clear();
    }
  }

  Future<AccountProfile> profile() async {
    return AccountProfile.fromJson(await _client.get('/users/me'));
  }

  /// Permanently deletes the account and everything on it.
  ///
  /// The session is cleared only after the server confirms, so a failed
  /// deletion leaves the user signed in and able to try again.
  Future<void> deleteAccount({required String password}) async {
    await _client.delete('/users/me', body: {'password': password});
    await _tokens.clear();
  }

  /// Changes the password.
  ///
  /// The server revokes every session, including this one, so the caller must
  /// sign in again afterwards. The local session is cleared here to match.
  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    await _client.put(
      '/users/me/password',
      body: {'current_password': currentPassword, 'new_password': newPassword},
    );
    await _tokens.clear();
  }

  /// Sets the email address or phone number on the account.
  ///
  /// Only the matching kind is replaced, so adding a phone to an email account
  /// keeps both.
  Future<AccountProfile> changeIdentifier({
    required String identifier,
    required String password,
  }) async {
    final data = await _client.put(
      '/users/me/identifier',
      body: {'identifier': identifier, 'password': password},
    );
    final profile = AccountProfile.fromJson(data);
    await _tokens.saveIdentifier(profile.primary);
    return profile;
  }

  /// Downloads every word on the account.
  Future<Map<String, Object?>> exportWords() => _client.get('/users/me/export');

  Future<void> _persist(Map<String, Object?> tokens, String identifier) async {
    final accessToken = tokens['access_token'] as String?;
    final refreshToken = tokens['refresh_token'] as String?;

    if (accessToken == null || refreshToken == null) {
      throw const ApiException('Malformed authentication response');
    }

    await _tokens.save(
      accessToken: accessToken,
      refreshToken: refreshToken,
      identifier: identifier,
    );
  }
}

class OtpChallenge {
  const OtpChallenge({
    required this.id,
    required this.expiresIn,
    required this.retryAfter,
    this.phone,
  });
  final String id;
  final int expiresIn;
  final int retryAfter;
  final String? phone;
  OtpChallenge withPhone(String phone) => OtpChallenge(
    id: id,
    expiresIn: expiresIn,
    retryAfter: retryAfter,
    phone: phone,
  );
  factory OtpChallenge.fromJson(Map<String, Object?> data) {
    final id = data['challenge_id'] as String?;
    if (id == null || id.isEmpty) {
      throw const ApiException('Could not request a verification code');
    }
    return OtpChallenge(
      id: id,
      expiresIn: (data['expires_in'] as num?)?.toInt() ?? 600,
      retryAfter: (data['retry_after'] as num?)?.toInt() ?? 60,
    );
  }
}

class AuthSession {
  const AuthSession({
    required this.accessToken,
    required this.refreshToken,
    required this.identifier,
    required this.accountId,
    this.method = 'password',
  });
  final String accessToken, refreshToken, identifier, accountId, method;
  factory AuthSession.fromJson(
    Map<String, Object?> data, {
    required String fallbackIdentifier,
    String method = 'password',
  }) {
    final tokens = (data['tokens'] as Map<String, Object?>?) ?? data;
    final access = tokens['access_token'] as String?;
    final refresh = tokens['refresh_token'] as String?;
    if (access == null ||
        access.isEmpty ||
        refresh == null ||
        refresh.isEmpty) {
      throw const ApiException('Malformed authentication response');
    }
    String? subject = data['user_id'] as String?;
    if (subject == null) {
      try {
        subject =
            (jsonDecode(
                      utf8.decode(
                        base64Url.decode(
                          base64Url.normalize(access.split('.')[1]),
                        ),
                      ),
                    )
                    as Map)['sub']
                as String?;
      } catch (_) {
        /* Legacy test servers return opaque tokens. */
      }
    }
    final identifier = data['identifier'] as String? ?? fallbackIdentifier;
    return AuthSession(
      accessToken: access,
      refreshToken: refresh,
      identifier: identifier,
      accountId: subject ?? identifier.trim().toLowerCase(),
      method: method,
    );
  }
}
