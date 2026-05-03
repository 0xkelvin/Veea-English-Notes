import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../models/auth_models.dart';
import '../services/auth_service.dart';

enum AuthStatus { loading, authenticated, unauthenticated }

class AuthProvider extends ChangeNotifier {
  final AuthService _authService;
  final FlutterSecureStorage _storage;

  static const _keyAccessToken = 'access_token';
  static const _keyRefreshToken = 'refresh_token';
  static const _keyEmail = 'user_email';
  static const _keyUserId = 'user_id';

  AuthStatus _status = AuthStatus.loading;
  AppUser? _user;
  String? _accessToken;
  String? _refreshToken;
  String? _error;

  AuthProvider({AuthService? authService, FlutterSecureStorage? storage})
      : _authService = authService ?? AuthService(),
        _storage = storage ??
            const FlutterSecureStorage(
              mOptions: MacOsOptions(
                useDataProtectionKeyChain: false,
              ),
            );

  AuthStatus get status => _status;
  AppUser? get user => _user;
  String? get accessToken => _accessToken;
  String? get error => _error;
  bool get isAuthenticated => _status == AuthStatus.authenticated;

  // ── Initialise: restore session ──────────────────────────────────

  Future<void> init() async {
    try {
      final accessToken = await _storage.read(key: _keyAccessToken);
      final refreshToken = await _storage.read(key: _keyRefreshToken);
      final email = await _storage.read(key: _keyEmail);
      final userId = await _storage.read(key: _keyUserId);

      if (accessToken != null && refreshToken != null && email != null) {
        // Try to refresh to validate + get fresh tokens
        try {
          final tokens =
              await _authService.refresh(refreshToken: refreshToken);
          await _persistTokens(tokens, email: email, userId: userId ?? '');
          _setAuthenticated(AppUser(userId: userId ?? '', email: email));
        } catch (_) {
          // Refresh failed — clear session
          await _clearStorage();
          _setUnauthenticated();
        }
      } else {
        _setUnauthenticated();
      }
    } catch (_) {
      _setUnauthenticated();
    }
  }

  // ── Register ─────────────────────────────────────────────────────

  Future<void> register({
    required String email,
    required String password,
  }) async {
    _error = null;
    notifyListeners();

    try {
      final result =
          await _authService.register(email: email, password: password);
      await _persistTokens(result.tokens,
          email: result.user.email, userId: result.user.userId);
      _setAuthenticated(result.user);
    } on AuthException catch (e) {
      _error = e.message;
      notifyListeners();
      rethrow;
    }
  }

  // ── Login ─────────────────────────────────────────────────────────

  Future<void> login({
    required String email,
    required String password,
  }) async {
    _error = null;
    notifyListeners();

    try {
      final result =
          await _authService.login(email: email, password: password);
      await _persistTokens(result.tokens,
          email: email, userId: result.user.userId);
      _setAuthenticated(AppUser(userId: result.user.userId, email: email));
    } on AuthException catch (e) {
      _error = e.message;
      notifyListeners();
      rethrow;
    }
  }

  // ── Logout ────────────────────────────────────────────────────────

  Future<void> logout() async {
    try {
      if (_accessToken != null && _refreshToken != null) {
        await _authService.logout(
          accessToken: _accessToken!,
          refreshToken: _refreshToken!,
        );
      }
    } catch (_) {
      // Best-effort logout — clear locally regardless
    }
    await _clearStorage();
    _setUnauthenticated();
  }

  // ── Helpers ───────────────────────────────────────────────────────

  Future<void> _persistTokens(AuthTokens tokens,
      {required String email, required String userId}) async {
    _accessToken = tokens.accessToken;
    _refreshToken = tokens.refreshToken;
    await Future.wait([
      _storage.write(key: _keyAccessToken, value: tokens.accessToken),
      _storage.write(key: _keyRefreshToken, value: tokens.refreshToken),
      _storage.write(key: _keyEmail, value: email),
      _storage.write(key: _keyUserId, value: userId),
    ]);
  }

  Future<void> _clearStorage() async {
    _accessToken = null;
    _refreshToken = null;
    await Future.wait([
      _storage.delete(key: _keyAccessToken),
      _storage.delete(key: _keyRefreshToken),
      _storage.delete(key: _keyEmail),
      _storage.delete(key: _keyUserId),
    ]);
  }

  void _setAuthenticated(AppUser user) {
    _user = user;
    _status = AuthStatus.authenticated;
    notifyListeners();
  }

  void _setUnauthenticated() {
    _user = null;
    _status = AuthStatus.unauthenticated;
    notifyListeners();
  }
}
