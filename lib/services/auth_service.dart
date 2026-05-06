import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/auth_models.dart';

class AuthService {
  static const String _baseUrl = 'http://localhost:8386/api/v1';

  final http.Client _client;

  AuthService({http.Client? client}) : _client = client ?? http.Client();

  // ── Register ──────────────────────────────────────────────────────

  /// POST /api/v1/auth/register
  /// Returns [AppUser] + [AuthTokens].
  Future<({AppUser user, AuthTokens tokens})> register({
    required String email,
    required String password,
  }) async {
    final response = await _post('/auth/register', {
      'email': email,
      'password': password,
    });

    final data = response['data'] as Map<String, dynamic>;
    final tokens = AuthTokens.fromJson(data['tokens'] as Map<String, dynamic>);
    final user = AppUser(
      userId: data['user_id'] as String,
      email: data['email'] as String,
    );
    return (user: user, tokens: tokens);
  }

  // ── Login ─────────────────────────────────────────────────────────

  /// POST /api/v1/auth/login
  /// Returns [AppUser] (email only) + [AuthTokens].
  Future<({AppUser user, AuthTokens tokens})> login({
    required String email,
    required String password,
  }) async {
    final response = await _post('/auth/login', {
      'email': email,
      'password': password,
    });

    final data = response['data'] as Map<String, dynamic>;
    final tokens = AuthTokens.fromJson(data as Map<String, dynamic>);
    final user = AppUser(userId: '', email: email);
    return (user: user, tokens: tokens);
  }

  // ── Refresh ───────────────────────────────────────────────────────

  /// POST /api/v1/auth/refresh
  Future<AuthTokens> refresh({required String refreshToken}) async {
    final response = await _post('/auth/refresh', {
      'refresh_token': refreshToken,
    });
    return AuthTokens.fromJson(response['data'] as Map<String, dynamic>);
  }

  // ── Logout ────────────────────────────────────────────────────────

  /// POST /api/v1/auth/logout
  Future<void> logout({
    required String accessToken,
    required String refreshToken,
  }) async {
    final uri = Uri.parse('$_baseUrl/auth/logout');
    final res = await _client.post(
      uri,
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $accessToken',
      },
      body: json.encode({'refresh_token': refreshToken}),
    );

    if (res.statusCode != 204 && res.statusCode != 200) {
      _throwFromResponse(res);
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────

  Future<Map<String, dynamic>> _post(
      String path, Map<String, dynamic> body) async {
    final uri = Uri.parse('$_baseUrl$path');
    final res = await _client.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: json.encode(body),
    );

    final decoded = json.decode(res.body) as Map<String, dynamic>;

    if (res.statusCode >= 200 && res.statusCode < 300) {
      return decoded;
    }

    _throwFromResponse(res, decoded);
  }

  Never _throwFromResponse(http.Response res,
      [Map<String, dynamic>? decoded]) {
    final body = decoded ?? _tryDecode(res.body);
    final err = body?['error'] as Map<String, dynamic>?;
    final message = err?['message'] as String? ??
        'Request failed (${res.statusCode})';
    final code = err?['code'] as String?;
    throw AuthException(message, code: code);
  }

  Map<String, dynamic>? _tryDecode(String body) {
    try {
      return json.decode(body) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }
}
