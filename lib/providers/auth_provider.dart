import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/config/app_config.dart';
import '../data/remote/api_client.dart';
import '../data/remote/auth_api.dart';
import '../data/remote/token_store.dart';
import '../data/vocabulary_repository.dart';
import '../services/sync_service.dart';

enum AuthState {
  /// Session not yet read from storage.
  unknown,
  signedOut,
  signedIn,
}

/// Owns the signed-in session and everything the user can do to their own
/// account.
///
/// Being signed out is a normal, fully functional state: the app is local
/// first and an account only adds sync across devices.
class AuthProvider extends ChangeNotifier {
  AuthProvider({
    required AuthApi authApi,
    required TokenStore tokens,
    required ApiClient client,
    required VocabularyRepository repository,
    required SyncService sync,
  }) : _authApi = authApi,
       _tokens = tokens,
       _repository = repository,
       _sync = sync {
    // The transport signals when a refresh token is finally rejected.
    client.onSessionExpired = _handleSessionExpired;
  }

  final AuthApi _authApi;
  final TokenStore _tokens;
  final VocabularyRepository _repository;
  final SyncService _sync;

  AuthState _state = AuthState.unknown;
  String? _identifier;
  AccountProfile? _profile;
  String? _lastError;
  String? _lastMessage;
  bool _busy = false;
  bool _isDisposed = false;

  @override
  void dispose() {
    _isDisposed = true;
    super.dispose();
  }

  @override
  void notifyListeners() {
    if (_isDisposed) return;
    super.notifyListeners();
  }

  AuthState get state => _state;
  bool get isSignedIn => _state == AuthState.signedIn;
  bool get isBusy => _busy;

  /// The identifier the account signs in with, available offline.
  String? get identifier => _identifier;

  /// Both identifiers, once the profile has been fetched.
  AccountProfile? get profile => _profile;

  String? get lastError => _lastError;

  /// A one-off confirmation for the UI to show, e.g. after a password change.
  String? get lastMessage => _lastMessage;

  /// Restores any session left on the device.
  Future<void> restore() async {
    _identifier = await _tokens.readIdentifier();
    _state = await _tokens.hasSession
        ? AuthState.signedIn
        : AuthState.signedOut;
    notifyListeners();
  }

  Future<bool> signIn({required String identifier, required String password}) {
    return _run(
      () => _authApi.login(identifier: identifier, password: password),
      onSuccess: () => _identifier = identifier,
      // There is no session yet, so a 401 here means the credentials were
      // wrong — not that anything expired.
      unauthorizedMessage: 'That email, phone or password is not right',
    );
  }

  Future<bool> register({
    required String identifier,
    required String password,
  }) {
    return _run(
      () => _authApi.register(identifier: identifier, password: password),
      onSuccess: () => _identifier = identifier,
      unauthorizedMessage: 'That email, phone or password is not right',
    );
  }

  Future<void> signOut() async {
    await _authApi.logout();
    _clearSession();
    notifyListeners();
  }

  /// Fetches both identifiers. Failure is not surfaced — the account screen
  /// still works from the locally cached identifier.
  Future<void> loadProfile() async {
    if (!isSignedIn || !AppConfig.isCloudEnabled) return;
    try {
      _profile = await _authApi.profile();
      _identifier = _profile!.primary;
      notifyListeners();
    } on ApiException catch (error) {
      debugPrint('Could not load profile: ${error.message}');
    }
  }

  /// Permanently deletes the account, then wipes this device.
  ///
  /// The local database is cleared only after the server confirms: wiping
  /// first would destroy the user's words on a failed request, and those
  /// words are the entire point of the app.
  Future<bool> deleteAccount({required String password}) {
    return _run(
      () => _authApi.deleteAccount(password: password),
      onSuccess: () async {
        await _repository.deleteAll();
        await _sync.resetCursor();
        _clearSession();
      },
      signOutOnSuccess: true,
    );
  }

  /// Changes the password. The server revokes every session, so this signs the
  /// user out and they sign back in with the new one.
  Future<bool> changePassword({
    required String currentPassword,
    required String newPassword,
  }) {
    return _run(
      () => _authApi.changePassword(
        currentPassword: currentPassword,
        newPassword: newPassword,
      ),
      onSuccess: () {
        _clearSession();
        _lastMessage = 'Password changed — sign in again';
      },
      signOutOnSuccess: true,
    );
  }

  /// Sets the email address or phone number on the account.
  Future<bool> changeIdentifier({
    required String identifier,
    required String password,
  }) {
    return _run(
      () async {
        _profile = await _authApi.changeIdentifier(
          identifier: identifier,
          password: password,
        );
      },
      onSuccess: () {
        _identifier = _profile?.primary ?? identifier;
        _lastMessage = 'Account updated';
      },
    );
  }

  /// Everything on the account as a JSON document, for the user to keep.
  Future<Map<String, Object?>?> exportWords() async {
    try {
      return await _authApi.exportWords();
    } on ApiException catch (error) {
      _lastError = error is OfflineException
          ? 'Could not reach the server'
          : error.message;
      notifyListeners();
      return null;
    }
  }

  void consumeError() {
    if (_lastError == null) return;
    _lastError = null;
    notifyListeners();
  }

  void consumeMessage() {
    if (_lastMessage == null) return;
    _lastMessage = null;
    notifyListeners();
  }

  Future<bool> _run(
    Future<void> Function() action, {
    FutureOr<void> Function()? onSuccess,
    bool signOutOnSuccess = false,
    String unauthorizedMessage = 'Your session expired — sign in again',
  }) async {
    if (_busy) return false;
    _busy = true;
    _lastError = null;
    notifyListeners();

    try {
      await action();
      await onSuccess?.call();
      _state = signOutOnSuccess ? AuthState.signedOut : AuthState.signedIn;
      return true;
    } on ApiException catch (error) {
      _lastError = switch (error) {
        OfflineException() => 'Could not reach the server',
        // The server answers a bad password confirmation with 403
        // INVALID_PASSWORD rather than 401, precisely so the transport does
        // not mistake it for an expired session and sign the user out.
        _ when error.code == 'INVALID_PASSWORD' => 'That password is not right',
        _ when error.statusCode == 401 => unauthorizedMessage,
        _ => error.message,
      };
      return false;
    } catch (error, stack) {
      debugPrint('Account operation failed: $error\n$stack');
      _lastError = 'Something went wrong';
      return false;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  void _clearSession() {
    _identifier = null;
    _profile = null;
    _state = AuthState.signedOut;
  }

  /// The refresh token was rejected: the session is over and cannot be
  /// recovered without the user signing in again.
  void _handleSessionExpired() {
    if (_state != AuthState.signedIn) return;
    _clearSession();
    _lastError = 'Your session expired — sign in again to keep syncing';
    notifyListeners();
  }
}
