import 'dart:async';

import '../data/remote/api_client.dart';
import '../data/remote/auth_api.dart';
import '../data/remote/go/api_client.dart';
import '../data/remote/go/auth_api.dart';
import '../data/remote/go/session_store.dart';
import '../data/vocabulary_repository.dart';
import '../services/sync_service.dart';
import 'auth_provider.dart';

/// Production Go account coordinator. The inherited compatibility adapter
/// remains for legacy-only callers/tests; this implementation never calls its flows.
class GoAuthProvider extends AuthProvider {
  GoAuthProvider({
    required GoAuthApi super.authApi,
    required GoTokenStore super.tokens,
    required GoApiClient client,
    required super.repository,
    required super.sync,
  }) : goApi = authApi,
       store = tokens,
       _repo = repository,
       _sync = sync,
       super(client: client) {
    client.onSessionExpired = _expired;
    // Only the Go transport's generation-fenced callback may end a session.
    // A late sync result for a closed notebook must not log out its successor.
    _sync.onSessionExpired = null;
  }
  final GoAuthApi goApi;
  final GoTokenStore store;
  final VocabularyRepository _repo;
  final SyncService _sync;
  GoSession? _session;
  GoDeletionReceipt? _receipt;
  AccountProfile? _accountProfile;
  bool _working = false;
  int _intent = 0;
  String? _error, _message;
  Future<void> _transition = Future.value();
  Future<void> _notebookLane = Future.value();
  Future<DeletionOutcome>? _poll;

  Future<T> _notebook<T>(Future<T> Function() action) {
    final done = Completer<void>();
    final previous = _notebookLane;
    _notebookLane = done.future;
    final result = previous.then((_) => action()).whenComplete(done.complete);
    _transition = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  @override
  Future<void> get notebookSettled => _transition;
  @override
  AuthState get state =>
      _session == null ? AuthState.signedOut : AuthState.signedIn;
  @override
  bool get isSignedIn => _session != null;
  @override
  bool get isBusy => _working;
  @override
  bool get isPhoneAccount => false;
  @override
  String? get accountId => _session?.userId;
  @override
  String? get identifier => _accountProfile?.email ?? _session?.email;
  @override
  AccountProfile? get profile => _accountProfile;
  @override
  String? get lastError => _error;
  @override
  String? get lastMessage => _message;
  @override
  GoAuthApi get api => goApi;
  @override
  bool get hasPendingDeletion =>
      _receipt != null &&
      !['completed', 'expired', 'canceled'].contains(_receipt!.state);
  @override
  bool get blocksCloudSync =>
      _receipt?.submitted == true &&
      _receipt?.locallyCleared != true &&
      _receipt?.userId == accountId;
  GoDeletionReceipt? get deletionReceipt => _receipt;

  @override
  Future<void> restore() async {
    final intent = ++_intent;
    await _notebook(() async {
      await _sync.suspend();
      _receipt = await store.readReceipt();
      final saved = await store.readSession();
      if (saved?.refreshState == 'ready') {
        _session = saved;
      } else {
        await store.clear();
        _session = null;
        if (saved != null) {
          _error = 'A previous refresh did not finish safely. Sign in again.';
        }
      }
      if (intent != _intent) return;
      final pendingForSession =
          _receipt?.submitted == true &&
          _receipt?.userId == _session?.userId &&
          _receipt?.locallyCleared != true;
      if (pendingForSession) {
        await store.clearIf(_session!.generation);
        _session = null;
      }
      await _repo.activateNotebook(_session?.userId);
      if (_session != null && !pendingForSession) {
        _sync.resumeForAccount(_session!.userId);
      }
    });
    if (_receipt?.data['accepted_at'] != null &&
        _receipt?.locallyCleared != true) {
      await _clearDeletedCache();
    }
    if (_receipt != null) await checkPendingDeletion();
    notifyListeners();
  }

  Future<EmailChallenge?> startEmail(
    String email, {
    bool signup = false,
    String? password,
  }) async {
    if (_working) return null;
    _working = true;
    _error = null;
    notifyListeners();
    try {
      return await goApi.startEmail(
        email.trim(),
        signup: signup,
        password: password,
      );
    } on ApiException catch (e) {
      _error = e.message;
      return null;
    } finally {
      _working = false;
      notifyListeners();
    }
  }

  Future<bool> verifyEmail(EmailChallenge challenge, String code) =>
      _authenticateGo(() => goApi.verifyEmail(challenge, code));
  @override
  Future<bool> signIn({required String identifier, required String password}) =>
      _authenticateGo(
        () => goApi.passwordSession(
          identifier: identifier.trim(),
          password: password,
        ),
      );
  @override
  Future<bool> register({
    required String identifier,
    required String password,
  }) async {
    _error = 'Request and verify an email signup code.';
    notifyListeners();
    return false;
  }

  Future<bool> _authenticateGo(Future<GoSignIn> Function() request) async {
    if (_working) return false;
    final intent = ++_intent;
    _working = true;
    _error = null;
    _message = null;
    // Clear before waiting for old sync/HTTP work. Late refresh responses
    // cannot restore an account the user is switching away from.
    await store.clear();
    _session = null;
    _accountProfile = null;
    notifyListeners();
    try {
      await _notebook(() async {
        await _sync.suspend();
        await _repo.activateNotebook(null);
      });
      final result = await request();
      if (intent != _intent) return false;
      if (_receipt?.submitted == true &&
          _receipt?.locallyCleared != true &&
          _receipt?.userId == result.accountId) {
        _error = 'Check the pending deletion before reopening this account.';
        return false;
      }
      return await _notebook(() async {
        if (intent != _intent) return false;
        await _repo.activateNotebook(result.accountId);
        if (intent != _intent) return false;
        final saved = await store.establish(result.response);
        if (intent != _intent) return false;
        _session = saved;
        _accountProfile = AccountProfile.fromJson(
          (result.response['user']! as Map).cast<String, Object?>(),
        );
        _sync.resumeForAccount(saved.userId);
        return true;
      });
    } on ApiException catch (e) {
      if (intent == _intent) {
        _error = e.message;
        await _notebook(() async {
          await _sync.suspend();
          await _repo.activateNotebook(null);
        });
      }
      return false;
    } finally {
      if (intent == _intent) {
        _working = false;
        notifyListeners();
      }
    }
  }

  void _expired() {
    ++_intent;
    _session = null;
    _accountProfile = null;
    _working = false;
    _error =
        'Your session ended or a refresh outcome was unknown. Sign in again.';
    unawaited(
      _notebook(() async {
        await _sync.suspend();
        await _repo.activateNotebook(null);
      }).then((_) => notifyListeners()),
    );
    notifyListeners();
  }

  @override
  Future<void> signOut() async {
    ++_intent;
    _working = false;
    final logout = goApi
        .logout(); // invalidates credentials before its HTTP call
    _session = null;
    _accountProfile = null;
    final closed = _notebook(() async {
      await _sync.suspend();
      await _repo.activateNotebook(null);
    });
    notifyListeners();
    await closed;
    await logout;
    notifyListeners();
  }

  Future<void> signOutAll() async {
    final old = await store.readSession();
    try {
      await goApi.logoutAll();
      _message =
          'All preceding sessions were signed out, including this device.';
    } on ApiException {
      _error =
          'Could not confirm sign-out on every device. This device is signed out.';
    } finally {
      if (old != null && await store.clearIf(old.generation)) {
        ++_intent;
        _session = null;
        _accountProfile = null;
        await _notebook(() async {
          await _sync.suspend();
          await _repo.activateNotebook(null);
        });
        notifyListeners();
      }
      await notebookSettled;
    }
  }

  @override
  Future<void> loadProfile() async {
    final owner = accountId;
    if (owner == null) return;
    try {
      final result = await goApi.profile();
      if (accountId != owner) return;
      if (result.id != owner) {
        await signOut();
        return;
      }
      _accountProfile = result;
      notifyListeners();
    } on ApiException catch (e) {
      _error = e.message;
      await notebookSettled;
      notifyListeners();
    }
  }

  /// Owner identity comes from /v1/me, never a typed email. Rights proof may
  /// act on an inactive account, but this normal-session screen binds local
  /// erasure only to the UUID the Go session authenticated.
  Future<bool> requestDeletion() async {
    if (_working || !isSignedIn) return false;
    if (_receipt != null &&
        _receipt!.submitted &&
        (!_receipt!.locallyCleared ||
            (_receipt!.state != 'completed' && _receipt!.state != 'expired'))) {
      _error = 'Check the existing deletion request first.';
      notifyListeners();
      return false;
    }
    _working = true;
    _error = null;
    notifyListeners();
    final owner = accountId;
    try {
      final user = await goApi.profile();
      if (accountId != owner || user.id != owner || user.email == null) {
        return false;
      }
      final receipt = await goApi.startDelete(user.email!, owner!);
      // Persist capability BEFORE the UI can submit the code. No OTP is saved.
      await store.saveReceipt(receipt);
      _receipt = receipt;
      return true;
    } on ApiException catch (e) {
      _error = e.message;
      return false;
    } finally {
      _working = false;
      notifyListeners();
    }
  }

  Future<bool> confirmDeletion(String code) async {
    final receipt = _receipt;
    if (_working || receipt == null || receipt.locallyCleared) return false;
    _working = true;
    _error = null;
    notifyListeners();
    try {
      _receipt = receipt.withValues({'submitted': true});
      await store.saveReceipt(_receipt!);
      await _sync.suspend();
      try {
        final status = await goApi.completeDelete(_receipt!, code);
        if (status.accepted) {
          await _accept(status);
          return true;
        }
      } on ApiException catch (e) {
        _error = e.message;
        if (!receipt.submitted &&
            e.statusCode != null &&
            e.statusCode! >= 400 &&
            e.statusCode! < 500 &&
            e.statusCode != 408) {
          // An explicit FIRST proof refusal is not deletion confirmation.
          _receipt = _receipt!.withValues({'submitted': false});
          await store.saveReceipt(_receipt!);
          if (_session != null) _sync.resumeForAccount(_session!.userId);
          return false;
        }
      }
      // Unknown completion: close the account but keep its data and receipt.
      final current = await store.readSession();
      if (current?.userId == receipt.userId) {
        await store.clearIf(current!.generation);
        _session = null;
        _accountProfile = null;
        await _notebook(() => _repo.activateNotebook(null));
      }
      return await _pollReceipt() == DeletionOutcome.deleted;
    } finally {
      _working = false;
      notifyListeners();
    }
  }

  @override
  Future<DeletionOutcome> checkPendingDeletion() {
    if (_poll != null) return _poll!;
    if (_working) return Future.value(DeletionOutcome.none);
    final intent = _intent;
    _working = true;
    notifyListeners();
    return _poll = _pollReceipt().whenComplete(() {
      _poll = null;
      if (intent == _intent) _working = false;
      notifyListeners();
    });
  }

  Future<DeletionOutcome> _pollReceipt() async {
    final receipt = _receipt;
    if (receipt == null) return DeletionOutcome.none;
    try {
      if (receipt.locallyCleared && receipt.state == 'completed') {
        return DeletionOutcome.deleted;
      }
      final status = await goApi.deletionStatus(receipt);
      if (_receipt?.operationId != receipt.operationId) {
        return DeletionOutcome.none;
      }
      if (status.accepted) {
        await _accept(status);
        return DeletionOutcome.deleted;
      }
      _receipt = receipt.withValues({'state': status.state});
      await store.saveReceipt(_receipt!);
      return status.state == 'expired' || status.state == 'canceled'
          ? DeletionOutcome.notDeleted
          : DeletionOutcome.unknown;
    } on ApiException {
      _error =
          'Deletion is not confirmed. Your account cache is kept closed. Check the receipt again when online.';
      return DeletionOutcome.unknown;
    } finally {
      notifyListeners();
    }
  }

  Future<void> _accept(DeleteStatus status) async {
    final receipt = _receipt!;
    if (!status.accepted || status.id != receipt.operationId) return;
    // Persist acceptance before local erasure: a crash may safely finish this
    // boundary offline at restore, without guessing from a generic 401.
    _receipt = receipt.withValues({
      'state': status.state,
      'accepted_at': status.body['accepted_at'],
      'expires_at': status.body['expires_at'],
      'backup_expiry_due_at': status.body['backup_expiry_due_at'],
      'completed_at': status.body['completed_at'],
    });
    await store.saveReceipt(_receipt!);
    await _clearDeletedCache();
  }

  Future<void> _clearDeletedCache() async {
    final receipt = _receipt!;
    if (!receipt.locallyCleared) {
      await _notebook(() async {
        final current = await store.readSession();
        if (current?.userId == receipt.userId) {
          await store.clearIf(current!.generation);
          _session = null;
          _accountProfile = null;
          await _sync.suspend();
        }
        await _repo.deleteAll(accountId: receipt.userId);
      });
      _receipt = _receipt!.withValues({'locally_cleared': true});
      await store.saveReceipt(_receipt!);
    }
    _message = _receipt!.state == 'completed'
        ? 'Account data was erased. Backup copies expire under the retention policy.'
        : 'Deletion accepted. Access has ended; data cleanup is pending.';
    notifyListeners();
  }
}
