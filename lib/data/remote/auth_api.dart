import 'api_client.dart';
import 'token_store.dart';

/// Sign-up, sign-in and sign-out against the cloud service.
class AuthApi {
  const AuthApi({required ApiClient client, required TokenStore tokens})
    : _client = client,
      _tokens = tokens;

  final ApiClient _client;
  final TokenStore _tokens;

  /// Creates an account and stores the session it returns.
  Future<void> register({
    required String email,
    required String password,
  }) async {
    final data = await _client.post(
      '/auth/register',
      body: {'email': email, 'password': password},
      authenticated: false,
    );

    // Registration nests its tokens under the new user record.
    final tokens = data['tokens'];
    if (tokens is! Map<String, Object?>) {
      throw const ApiException('Malformed registration response');
    }
    await _persist(tokens, email);
  }

  Future<void> login({required String email, required String password}) async {
    final data = await _client.post(
      '/auth/login',
      body: {'email': email, 'password': password},
      authenticated: false,
    );
    await _persist(data, email);
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

  Future<void> _persist(Map<String, Object?> tokens, String email) async {
    final accessToken = tokens['access_token'] as String?;
    final refreshToken = tokens['refresh_token'] as String?;

    if (accessToken == null || refreshToken == null) {
      throw const ApiException('Malformed authentication response');
    }

    await _tokens.save(
      accessToken: accessToken,
      refreshToken: refreshToken,
      email: email,
    );
  }
}
