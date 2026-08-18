import 'api_client.dart';
import 'token_store.dart';

/// The signed-in account as the server sees it.
class AccountProfile {
  const AccountProfile({this.email, this.phone});

  /// Null on an account identified only by a phone number.
  final String? email;

  /// Null on an account identified only by an email address.
  final String? phone;

  /// Whichever identifier to show when only one can be shown.
  String get primary => email ?? phone ?? '';

  factory AccountProfile.fromJson(Map<String, Object?> json) {
    return AccountProfile(
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
