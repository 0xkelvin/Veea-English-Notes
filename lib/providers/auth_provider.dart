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
  String? _accountId;
  bool _phoneAccount = false;
  String? get accountId => _accountId;
  bool get isPhoneAccount =>
      _phoneAccount || _profile?.authMethod == 'phone_otp';
  AuthApi get api => _authApi;

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
    await _sync.suspend();
    _identifier = await _tokens.readIdentifier();
    _accountId = await _tokens.readAccountId();
    _phoneAccount = await _tokens.readAuthMethod() == 'phone_otp';
    _state = await _tokens.hasSession
        ? AuthState.signedIn
        : AuthState.signedOut;
    if (isSignedIn) {
      final owner = _accountId ?? _identifier?.trim().toLowerCase();
      if (owner != null) {
        _accountId = owner;
        await _repository.activateNotebook(owner);
        _sync.resumeForAccount(owner);
      }
    }
    notifyListeners();
  }

  Future<bool> signIn({required String identifier, required String password}) {
    return _authenticate(
      () =>
          _authApi.passwordSession(identifier: identifier, password: password),
    );
  }

  Future<bool> register({
    required String identifier,
    required String password,
  }) {
    return _authenticate(
      () => _authApi.passwordSession(
        identifier: identifier,
        password: password,
        register: true,
      ),
    );
  }

  Future<bool> verifyPhone(OtpChallenge challenge, String code) =>
      _authenticate(() => _authApi.verifyOtp(challenge, code));

  Future<bool> _authenticate(Future<AuthSession> Function() request) async {
    if (_busy) return false;
    _busy = true;
    _lastError = null;
    notifyListeners();
    final previousOwner = _accountId;
    final previousIdentifier = _identifier;
    final previousState = _state;
    String? switchedFrom;
    var switched = false;
    try {
      await _sync.suspend();
      final session = await request();
      switchedFrom = await _repository.activateNotebook(session.accountId);
      switched = true;
      await _tokens.saveLastAccount(session.accountId);
      await _authApi.commitSession(session);
      _accountId = session.accountId;
      _identifier = session.identifier;
      _profile = null;
      _phoneAccount = session.method == 'phone_otp';
      _state = AuthState.signedIn;
      _sync.resumeForAccount(session.accountId);
      return true;
    } catch (error) {
      if (switched) {
        try {
          await _repository.activateNotebook(switchedFrom);
        } catch (_) {
          // Leave sync suspended if ownership rollback fails: never upload a
          // notebook under the previous account’s credentials.
          _clearSession();
          _lastError =
              'Could not reopen your notebook. Please restart Veea; your saved notebooks remain on this device.';
          return false;
        }
      }
      _state = previousState;
      _identifier = previousIdentifier;
      _accountId = previousOwner;
      final previousScope =
          previousOwner ?? previousIdentifier?.trim().toLowerCase();
      if (_state == AuthState.signedIn && previousScope != null) {
        _sync.resumeForAccount(previousScope);
      }
      _lastError = error is ApiException
          ? (error.statusCode == 401
                ? 'That email, phone or password is not right'
                : error.message)
          : 'Could not open your account. Your notebooks are kept on this device.';
      return false;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> signOut() async {
    await _sync.suspend();
    await _authApi.logout();
    _clearSession();
    notifyListeners();
  }

  Future<bool> deletePhoneAccount(OtpChallenge challenge, String code) => _run(
    () async {
      await _sync.suspend();
      await _authApi.deleteWithOtp(challenge, code);
    },
    onSuccess: () async {
      await _repository.deleteAll();
      await _sync.resetCursor();
      await _tokens.clearLastAccount();
      _clearSession();
    },
    signOutOnSuccess: true,
  );

  /// Fetches both identifiers. Failure is not surfaced — the account screen
  /// still works from the locally cached identifier.
  Future<void> loadProfile() async {
    if (!isSignedIn || !AppConfig.isCloudEnabled) return;
    try {
      final owner = _accountId;
      final profile = await _authApi.profile();
      if (!isSignedIn || owner != _accountId) return;
      _profile = profile;
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
        await _tokens.clearLastAccount();
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
      await _sync.suspend();
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
      if (isSignedIn && (_accountId ?? _identifier) != null) {
        _sync.resumeForAccount(_accountId ?? _identifier!);
      }
      _busy = false;
      notifyListeners();
    }
  }

  void _clearSession() {
    _accountId = null;
    _phoneAccount = false;
    _identifier = null;
    _profile = null;
    _state = AuthState.signedOut;
  }

  /// The refresh token was rejected: the session is over and cannot be
  /// recovered without the user signing in again.
  void _handleSessionExpired() {
    if (_state != AuthState.signedIn) return;
    unawaited(_sync.suspend());
    _clearSession();
    _lastError = 'Your session expired — sign in again to keep syncing';
    notifyListeners();
  }
}
