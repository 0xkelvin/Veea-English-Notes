import 'package:flutter/foundation.dart';

import '../data/remote/api_client.dart';
import '../data/remote/auth_api.dart';
import '../data/remote/token_store.dart';

enum AuthState {
  /// Session not yet read from storage.
  unknown,
  signedOut,
  signedIn,
}

/// Owns the signed-in session.
///
/// Being signed out is a normal, fully functional state: the app is local
/// first and an account only adds sync across devices.
class AuthProvider extends ChangeNotifier {
  AuthProvider({
    required AuthApi authApi,
    required TokenStore tokens,
    required ApiClient client,
  }) : _authApi = authApi,
       _tokens = tokens {
    // The transport signals when a refresh token is finally rejected.
    client.onSessionExpired = _handleSessionExpired;
  }

  final AuthApi _authApi;
  final TokenStore _tokens;

  AuthState _state = AuthState.unknown;
  String? _email;
  String? _lastError;
  bool _busy = false;

  AuthState get state => _state;
  bool get isSignedIn => _state == AuthState.signedIn;
  bool get isBusy => _busy;
  String? get email => _email;
  String? get lastError => _lastError;

  /// Restores any session left on the device.
  Future<void> restore() async {
    _email = await _tokens.readEmail();
    _state = await _tokens.hasSession
        ? AuthState.signedIn
        : AuthState.signedOut;
    notifyListeners();
  }

  Future<bool> signIn({required String email, required String password}) {
    return _run(() => _authApi.login(email: email, password: password), email);
  }

  Future<bool> register({required String email, required String password}) {
    return _run(
      () => _authApi.register(email: email, password: password),
      email,
    );
  }

  Future<void> signOut() async {
    await _authApi.logout();
    _email = null;
    _state = AuthState.signedOut;
    notifyListeners();
  }

  void consumeError() {
    if (_lastError == null) return;
    _lastError = null;
    notifyListeners();
  }

  Future<bool> _run(Future<void> Function() action, String email) async {
    if (_busy) return false;
    _busy = true;
    _lastError = null;
    notifyListeners();

    try {
      await action();
      _email = email;
      _state = AuthState.signedIn;
      return true;
    } on ApiException catch (error) {
      _lastError = error is OfflineException
          ? 'Could not reach the server'
          : error.message;
      return false;
    } catch (error, stack) {
      debugPrint('Authentication failed: $error\n$stack');
      _lastError = 'Something went wrong';
      return false;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// The refresh token was rejected: the session is over and cannot be
  /// recovered without the user signing in again.
  void _handleSessionExpired() {
    if (_state != AuthState.signedIn) return;
    _state = AuthState.signedOut;
    _lastError = 'Your session expired — sign in again to keep syncing';
    notifyListeners();
  }
}
