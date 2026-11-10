import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/config/app_config.dart';
import '../data/remote/api_client.dart';
import '../data/remote/auth_api.dart';
import '../data/remote/token_store.dart';
import '../data/vocabulary_repository.dart';
import '../services/sync_service.dart';

/// Result of checking a deletion whose response was not received.
enum DeletionOutcome {
  /// Nothing was pending.
  none,

  /// The server holds a receipt for this exact deletion; local data was wiped.
  deleted,

  /// No receipt after the code/grace window; nothing was wiped.
  notDeleted,

  /// The request may still be processing or the receipt is unreachable.
  unknown,
}

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
    DateTime Function()? now,
  }) : _authApi = authApi,
       _tokens = tokens,
       _repository = repository,
       _sync = sync,
       _now = now ?? DateTime.now {
    // The transport signals when a refresh token is finally rejected.
    client.onSessionExpired = _handleSessionExpired;
  }

  final AuthApi _authApi;
  final TokenStore _tokens;
  final VocabularyRepository _repository;
  final SyncService _sync;
  final DateTime Function() _now;

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

  /// HTTP status of the last failed sign-in or phone change (-1 for a
  /// replacement session that named another account), so a flow can choose
  /// the right recovery step.
  int? get lastFailureStatus => _lastFailureStatus;
  int? _lastFailureStatus;

  /// A one-off confirmation for the UI to show, e.g. after a password change.
  String? get lastMessage => _lastMessage;

  /// Restores any session left on the device.
  Future<void> restore() async {
    await _sync.suspend();
    _identifier = await _tokens.readIdentifier();
    _accountId = await _tokens.readAccountId();
    _phoneAccount = await _tokens.readAuthMethod() == 'phone_otp';
    _pendingDeletion = await _tokens.readPendingDeletion();
    final oldPending = _pendingDeletion;
    if (oldPending != null && oldPending.confirmUntil == null) {
      _pendingDeletion = PendingDeletion(
        accountId: oldPending.accountId,
        challengeId: oldPending.challengeId,
        confirmUntil: _now().add(const Duration(minutes: 11)),
      );
      await _tokens.savePendingDeletion(_pendingDeletion!);
    }
    _state = await _tokens.hasSession
        ? AuthState.signedIn
        : AuthState.signedOut;
    if (isSignedIn) {
      final owner = _accountId ?? _identifier?.trim().toLowerCase();
      if (owner != null) {
        _accountId = owner;
        await _repository.activateNotebook(owner);
        if (_pendingDeletion == null) _sync.resumeForAccount(owner);
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
      _authenticate(() => _authApi.verifyOtp(challenge, code), phone: true);

  Future<bool> _authenticate(
    Future<AuthSession> Function() request, {
    bool phone = false,
  }) async {
    if (_busy) return false;
    _busy = true;
    _lastError = null;
    _lastFailureStatus = null;
    notifyListeners();
    final previousOwner = _accountId;
    final previousIdentifier = _identifier;
    final previousState = _state;
    String? switchedFrom;
    var switched = false;
    try {
      await _sync.suspend();
      // An unresolved deletion pins this device to the deleted account's
      // notebook; switching first would strand that notebook in an archive.
      if (_pendingDeletion != null &&
          await _resolvePendingDeletion() == DeletionOutcome.unknown) {
        _lastError =
            'Veea is still confirming your account deletion. Connect to the internet and try again. Your notebook stays on this device.';
        return false;
      }
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
      if (_state == AuthState.signedIn &&
          previousScope != null &&
          !hasPendingDeletion) {
        _sync.resumeForAccount(previousScope);
      }
      _lastFailureStatus = error is ApiException ? error.statusCode : null;
      _lastError = error is! ApiException
          ? 'Could not open your account. Your notebooks are kept on this device.'
          : phone
          ? _phoneSignInError(error)
          : (error.statusCode == 401
                ? 'That email, phone or password is not right'
                : error.message);
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

  String _phoneSignInError(ApiException error) => switch (error) {
    OfflineException() =>
      'Could not connect. Your words are still saved on this device.',
    _ when error.statusCode == 429 =>
      'Too many attempts. Please wait a minute, then request a new code.',
    _ when error.statusCode == 401 || error.statusCode == 403 =>
      'This account cannot sign in right now. Please contact Veea support.',
    _ => error.message,
  };

  // ── Verified phone-number change ────────────────────────────────────────

  /// Finishes a phone change with the code sent to the new number.
  ///
  /// The server returns a replacement session for the same account UUID. It
  /// is stored only after checking that UUID, so a wrong response can never
  /// move this device's notebook, cursor or tokens to another account. The
  /// notebook is not switched and the sync cursor is kept.
  Future<bool> completePhoneChange(OtpChallenge challenge, String code) async {
    if (_busy || !isSignedIn) return false;
    if (hasPendingDeletion) {
      _lastError =
          'Confirm your pending account deletion before changing your number.';
      _lastFailureStatus = -1;
      notifyListeners();
      return false;
    }
    final owner = _accountId;
    _busy = true;
    _lastError = null;
    _lastFailureStatus = null;
    notifyListeners();
    try {
      await _sync.suspend();
      final session = await _authApi.confirmPhoneChange(challenge, code);
      if (owner == null || session.accountId != owner) {
        _lastFailureStatus = -1;
        _lastError =
            'Veea could not confirm the change belongs to this account, so nothing on this device was changed. Sign in again with your new number; your notebook stays here.';
        return false;
      }
      await _authApi.commitSession(session);
      _identifier = session.identifier;
      _profile = null;
      _phoneAccount = true;
      _lastMessage =
          'Phone number changed to ${session.identifier}. Your other devices will need to sign in again with it.';
      return true;
    } on ApiException catch (error) {
      _lastFailureStatus = error.statusCode;
      final uncertain =
          error is OfflineException ||
          error.statusCode == 408 ||
          (error.statusCode ?? 0) >= 500;
      if (uncertain) {
        _lastFailureStatus =
            -1; // Don't retry an OTP the server may have consumed.
        try {
          final current = await _authApi.profile();
          if (current.id == owner && current.phone == challenge.phone) {
            await _tokens.clear();
            _clearSession();
            _lastError =
                'Number changed to ${current.phone}. Please sign in with the new number. Your notebook stays on this device.';
            return false;
          }
        } on ApiException {
          // Still unknown: preserve local data and offer fresh sign-in recovery.
        }
        _lastError =
            'The change was not confirmed. If it completed, sign in with the new number. Your notebook stays on this device.';
      } else {
        _lastError = phoneChangeError(error, finalStep: true);
      }
      return false;
    } catch (error, stack) {
      debugPrint('Phone change failed: $error\n$stack');
      _lastError =
          'Could not change your number. Your account and notebook are unchanged.';
      return false;
    } finally {
      if (isSignedIn && _accountId != null && !hasPendingDeletion) {
        _sync.resumeForAccount(_accountId!);
      }
      _busy = false;
      notifyListeners();
    }
  }

  /// Error copy shared by every phone-change step.
  static String phoneChangeError(ApiException error, {bool finalStep = false}) {
    return switch (error) {
      OfflineException() when finalStep =>
        'Could not reach Veea, so the change was not confirmed. If your number did change, sign in with the new number. Your notebook stays on this device.',
      OfflineException() => 'Could not connect. Please check your connection.',
      _ when error.statusCode == 429 =>
        'Too many attempts. Please wait a minute and try again.',
      _ when error.statusCode == 503 =>
        'Phone verification is unavailable right now. Please try again later.',
      _ when error.statusCode == 401 =>
        'Your session ended. Sign in again, then change your number.',
      _ => error.message,
    };
  }

  // ── Account deletion with a recoverable outcome ────────────────────────

  PendingDeletion? _pendingDeletion;

  /// A deletion was sent but its outcome is not yet known.
  bool get hasPendingDeletion => _pendingDeletion != null;

  /// Deletes the phone account with a fresh code.
  ///
  /// Local data is wiped only after the server confirms, either with 204 or,
  /// when the response is lost, with a deletion receipt for this exact
  /// challenge. A 401 or network failure on its own is never treated as
  /// proof: the notebook stays on the device until the receipt says so.
  Future<bool> deletePhoneAccount(
    OtpChallenge challenge,
    String code, {
    DateTime? codeExpiresAt,
  }) async {
    if (_busy) return false;
    if (hasPendingDeletion) {
      _lastError =
          'Still confirming your earlier deletion. Check its status before trying again.';
      notifyListeners();
      return false;
    }
    final owner = _accountId;
    if (!isSignedIn || owner == null) {
      _lastError = 'Sign in again before deleting your account.';
      notifyListeners();
      return false;
    }
    _busy = true;
    _lastError = null;
    _lastMessage = null;
    notifyListeners();
    try {
      await _sync.suspend();
      _pendingDeletion = PendingDeletion(
        accountId: owner,
        challengeId: challenge.id,
        // A missing receipt is not final while a previously sent deletion may
        // still validate this code. Include a grace period for in-flight work.
        confirmUntil:
            (codeExpiresAt ??
                    _now().add(Duration(seconds: challenge.expiresIn)))
                .add(const Duration(minutes: 1)),
      );
      await _tokens.savePendingDeletion(_pendingDeletion!);
      try {
        await _authApi.deleteWithOtp(challenge, code);
      } on ApiException catch (error) {
        final status = error.statusCode;
        final refused =
            error is! OfflineException &&
            status != null &&
            status >= 400 &&
            status < 500 &&
            status != 401 &&
            status != 404 &&
            status != 408;
        if (refused) {
          // Wrong/expired code, rate limit or mismatch: definitely not deleted.
          _pendingDeletion = null;
          await _tokens.clearPendingDeletion();
          _lastError = switch (status) {
            429 => 'Too many attempts. Please wait a minute and try again.',
            403 =>
              'This code does not match your account. Request a new code and try again.',
            _ => error.message,
          };
          return false;
        }
        // Outcome unknown. Ask for the receipt rather than guessing.
        final outcome = await _resolvePendingDeletion();
        return outcome == DeletionOutcome.deleted;
      }
      await _finishDeletedAccount();
      return true;
    } catch (error, stack) {
      debugPrint('Account deletion failed: $error\n$stack');
      _lastError =
          'Could not delete your account. Your notebook is still on this device.';
      return false;
    } finally {
      if (isSignedIn && _accountId != null && !hasPendingDeletion) {
        _sync.resumeForAccount(_accountId!);
      }
      _busy = false;
      notifyListeners();
    }
  }

  /// Re-checks an unresolved deletion, e.g. from a "Check again" button.
  Future<DeletionOutcome> checkPendingDeletion() async {
    if (_busy || _pendingDeletion == null) return DeletionOutcome.none;
    _busy = true;
    _lastError = null;
    notifyListeners();
    try {
      await _sync.suspend();
      return await _resolvePendingDeletion();
    } finally {
      if (isSignedIn && _accountId != null && !hasPendingDeletion) {
        _sync.resumeForAccount(_accountId!);
      }
      _busy = false;
      notifyListeners();
    }
  }

  Future<DeletionOutcome> _resolvePendingDeletion() async {
    final pending = _pendingDeletion;
    if (pending == null) return DeletionOutcome.none;
    bool deleted;
    try {
      deleted = await _authApi.deletionConfirmed(pending);
    } on ApiException {
      _lastError =
          'Veea could not confirm whether your account was deleted. Your notebook is still on this device. Check again when you are online.';
      return DeletionOutcome.unknown;
    }
    if (deleted) {
      if (isSignedIn && _accountId != pending.accountId) {
        // Never wipe a different account's active notebook.
        _lastError =
            'Your previous account was deleted. Sign out and back in to finish cleaning up this device.';
        return DeletionOutcome.unknown;
      }
      await _finishDeletedAccount();
      return DeletionOutcome.deleted;
    }
    final until = pending.confirmUntil;
    if (until == null || _now().isBefore(until)) {
      _lastError =
          'Still confirming your deletion. Your notebook is kept on this device while Veea checks. Please check again shortly.';
      return DeletionOutcome.unknown;
    }
    _pendingDeletion = null;
    await _tokens.clearPendingDeletion();
    _lastError = isSignedIn
        ? 'Veea has no confirmation of deletion. Your notebook is still on this device; you can try again.'
        : 'Veea has no confirmation of deletion. Your notebook is still on this device. Sign in again if you still want to delete your account.';
    return DeletionOutcome.notDeleted;
  }

  /// Wipes the deleted account's active notebook and its archive, restoring
  /// an empty guest workspace. Other accounts' archived notebooks are kept.
  Future<void> _finishDeletedAccount() async {
    await _repository.deleteAll();
    await _sync.resetCursor();
    await _tokens.clear();
    await _tokens.clearLastAccount();
    await _tokens.clearPendingDeletion();
    _pendingDeletion = null;
    _clearSession();
    _lastError = null;
    _lastMessage =
        'Your account and its notebook were deleted. You can keep learning on this device without an account.';
  }

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
      if (isSignedIn &&
          !hasPendingDeletion &&
          (_accountId ?? _identifier) != null) {
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
