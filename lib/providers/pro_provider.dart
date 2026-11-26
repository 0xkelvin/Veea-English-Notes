import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../core/config/app_config.dart';
import '../data/pro_repository.dart';
import '../data/remote/api_client.dart';
import 'auth_provider.dart';
import 'go_auth_provider.dart';

class ProProvider extends ChangeNotifier {
  ProProvider({required this.auth, required this.repository}) {
    auth.addListener(_accountChanged);
    repository.onChange = () => unawaited(refresh());
    repository.listen();
    _owner = _entitlementOwner;
    _signedIn = auth.isSignedIn;
  }
  final AuthProvider auth;
  final ProRepository repository;
  String? _owner;
  late bool _signedIn;
  String? get _entitlementOwner => auth is GoAuthProvider
      ? (auth as GoAuthProvider).purchaseOwner
      : auth.accountId;
  int _epoch = 0;
  bool _disposed = false, _busy = false;
  bool _refreshRequested = false, _restoreRequested = false;
  final Map<String, DateTime> _confirmedAt = {};
  ProStoreState _store = const ProStoreState();
  String? _message;
  bool _serverPurchaseAvailable = false;
  bool _serverChecked = false;
  bool get purchaseAvailabilityChecked => _serverChecked;
  bool get purchasesReady => _serverPurchaseAvailable;
  bool get hasPro => _store.hasPro;
  bool get hasLifetime => _store.hasLifetime;
  bool get isBusy => _busy;
  String? get price => _store.price;
  String? get message => _message;
  bool get isConfigured =>
      AppConfig.isCloudEnabled && AppConfig.appleProProductId.isNotEmpty;
  bool get canPurchase =>
      !AppConfig.isFreeLaunch &&
      isConfigured &&
      auth.isSignedIn &&
      price != null &&
      !_busy &&
      !hasLifetime &&
      _serverPurchaseAvailable;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _accountChanged() {
    if (_owner == _entitlementOwner && _signedIn == auth.isSignedIn) return;
    _owner = _entitlementOwner;
    _signedIn = auth.isSignedIn;
    _restoreRequested = false;
    _refreshRequested = false;
    ++_epoch;
    _store = const ProStoreState();
    _confirmedAt.clear();
    _serverPurchaseAvailable = false;
    _serverChecked = false;
    _message = null;
    _busy = false;
    _notify();
    unawaited(refresh());
  }

  bool _current(int epoch, String? owner) =>
      !_disposed && epoch == _epoch && owner == _entitlementOwner;
  Future<void> initializeDevice() async {
    if (AppConfig.isFreeLaunch && AppConfig.appleProProductId.isEmpty) return;
    final epoch = _epoch, owner = _entitlementOwner;
    try {
      final state = await repository.configure(owner, loadProduct: false);
      if (_current(epoch, owner) && !_busy) {
        _store = state;
        _notify();
      }
    } on MissingPluginException {
      /* iPhone purchases are optional on other platforms. */
    } on PlatformException {
      /* Keep the free notebook available. */
    }
  }

  Future<void> refresh() => _run();
  Future<void> purchase() => _run(purchase: true);
  Future<void> restore() => _run(restore: true);
  Future<void> _run({bool purchase = false, bool restore = false}) async {
    if (_disposed) return;
    if (purchase && AppConfig.isFreeLaunch) {
      _message = 'This release is free. No purchase is needed.';
      _notify();
      return;
    }
    if (!restore &&
        AppConfig.isFreeLaunch &&
        AppConfig.appleProProductId.isEmpty) {
      return;
    }
    if (_busy) {
      if (restore) {
        _restoreRequested = true;
      } else if (!purchase) {
        _refreshRequested = true;
      }
      return;
    }
    final epoch = _epoch, owner = _entitlementOwner;
    if ((purchase || restore) && (!auth.isSignedIn || owner == null)) {
      _message = 'Sign in to link Pro to your Veea account.';
      _notify();
      return;
    }
    _busy = true;
    _message = null;
    _notify();
    try {
      final configured = await repository.configure(
        owner,
        loadProduct: !AppConfig.isFreeLaunch,
      );
      if (!_current(epoch, owner)) return;
      _store = configured;
      Map<String, Object?>? server;
      if (purchase &&
          AppConfig.isCloudEnabled &&
          auth.isSignedIn &&
          owner != null) {
        // Confirm account availability BEFORE displaying Apple's payment sheet.
        server = await repository.entitlement(owner);
        if (!_current(epoch, owner)) return;
        _serverPurchaseAvailable = server['apple_purchase_available'] == true;
        _serverChecked = true;
      }
      final alreadyLifetime =
          purchase &&
          (_store.hasLifetime ||
              (server?['plan'] == 'premium' &&
                  server?['plan_expires_at'] == null));
      if (purchase && server?['purchase_verification_pending'] == true) {
        if (server?['plan'] != 'premium') {
          _message =
              'Purchase verification is temporarily unavailable. Please try again later.';
          return;
        }
        final expiry = DateTime.tryParse(
          server?['plan_expires_at']?.toString() ?? '',
        );
        var until = DateTime.now().toUtc().add(const Duration(hours: 24));
        if (expiry != null && expiry.isBefore(until)) until = expiry;
        final state = await repository.configure(owner, serverUntil: until);
        if (!_current(epoch, owner)) return;
        _store = state;
        _message =
            'Your Pro access is active. Purchase verification is temporarily unavailable; try again later.';
        return;
      }
      if (purchase && !alreadyLifetime) {
        if (!_serverPurchaseAvailable) {
          _message =
              'Pro purchases are not available yet. Your free features remain available.';
          return;
        }
        if (!isConfigured || _store.price == null) {
          _message = 'Purchases are not available in this build yet.';
          return;
        }
        _store = await repository.purchase();
      } else if (restore) {
        _store = await repository.restore();
      }
      if (!_current(epoch, owner)) return;
      ApiException? claimError;
      if (owner != null && auth.isSignedIn) {
        for (final id in _store.transactions) {
          final confirmed = _confirmedAt[id];
          if (!purchase &&
              !restore &&
              !_store.pendingTransactions.contains(id) &&
              confirmed != null &&
              DateTime.now().difference(confirmed) <
                  const Duration(minutes: 5)) {
            continue;
          }
          try {
            server = await repository.claim(owner, id);
            if (!_current(epoch, owner)) return;
            await repository.recordVerification(
              id,
              revoked: server['purchase_revoked'] == true,
            );
            if (!_current(epoch, owner)) return;
            await repository.finish(id);
            if (!_current(epoch, owner)) return;
            _confirmedAt[id] = DateTime.now();
          } on ApiException catch (error) {
            if (!_current(epoch, owner)) return;
            // A refused/pending proof must remain unfinished. It must not
            // prevent unrelated owned transactions from being reconciled.
            claimError ??= error;
          }
        }
      }
      if (server == null &&
          AppConfig.isCloudEnabled &&
          auth.isSignedIn &&
          owner != null) {
        server = await repository.entitlement(owner);
        if (!_current(epoch, owner)) return;
      }
      if (server != null) {
        _serverPurchaseAvailable = server['apple_purchase_available'] == true;
        _serverChecked = true;
        final premium = server['plan'] == 'premium';
        final expiry = DateTime.tryParse(
          server['plan_expires_at']?.toString() ?? '',
        );
        // Server-only grants use a bounded offline lease; StoreKit lifetime
        // purchases remain independently available offline to their owner.
        var until = DateTime.now().toUtc().add(const Duration(hours: 24));
        if (expiry != null && expiry.isBefore(until)) until = expiry;
        final state = await repository.configure(
          owner,
          serverUntil: premium ? until : null,
          clearServer: !premium,
          serverLifetime: server['purchase_verification_pending'] == true
              ? null
              : premium && server['plan_expires_at'] == null,
        );
        if (!_current(epoch, owner)) return;
        _store = ProStoreState(
          hasPro: state.hasPro,
          hasLifetime: state.hasLifetime,
          pendingTransactions: state.pendingTransactions,
          price: state.price,
          transactions: state.transactions,
          outcome: _store.outcome,
        );
      }
      if (claimError != null) {
        _message = _purchaseError(claimError);
        return;
      }
      _message = alreadyLifetime
          ? 'Lifetime Pro is already linked to your account. No purchase needed.'
          : switch (_store.outcome) {
              'cancelled' => 'Purchase cancelled. You have not been charged.',
              'pending' =>
                'Waiting for Apple approval. Pro will update when approved.',
              'account_mismatch' when purchase || restore =>
                'This purchase belongs to a different Veea account. Sign in to that account to restore it.',
              _ =>
                restore
                    ? (hasPro
                          ? 'Pro restored to your account.'
                          : 'No Pro purchase found for this account.')
                    : purchase && hasPro
                    ? 'Pro is ready. Thank you for supporting Veea!'
                    : null,
            };
    } on ApiException catch (error) {
      if (_current(epoch, owner)) _message = _purchaseError(error);
    } on MissingPluginException {
      if (_current(epoch, owner)) {
        _message = 'Purchases are available in the iPhone app.';
      }
    } on PlatformException catch (e) {
      if (_current(epoch, owner)) {
        _message =
            e.message ??
            'Apple could not complete this request. Please try again.';
      }
    } catch (_) {
      if (_current(epoch, owner)) {
        _message = hasPro
            ? 'Pro is available on this device. Account confirmation will retry when you are online.'
            : 'Could not check your purchase. Please connect to the internet and try again.';
      }
    } finally {
      if (_current(epoch, owner)) {
        _busy = false;
        _notify();
        if (_restoreRequested) {
          _restoreRequested = false;
          _refreshRequested = false;
          unawaited(_run(restore: true));
        } else if (_refreshRequested) {
          _refreshRequested = false;
          unawaited(refresh());
        }
      }
    }
  }

  String _purchaseError(ApiException error) => switch (error.code) {
    'purchase_ownership' =>
      'This purchase could not be linked to this Veea account. Sign in to the account used for the original purchase or contact support.',
    'purchase_invalid' =>
      'Apple purchase verification was not accepted by the account service. Please contact support before trying to buy again.',
    'purchase_unavailable' =>
      'Purchase verification is temporarily unavailable. Please try again later.',
    _ when error.isAuthFailure => 'Sign in again to manage your purchase.',
    _ when !error.isTransient =>
      'The account service could not verify this purchase. Please contact support before trying to buy again.',
    _ =>
      hasPro
          ? 'Pro is available on this device. Account confirmation will retry when you are online.'
          : 'Could not check your purchase. Please connect to the internet and try again.',
  };

  @override
  void dispose() {
    _disposed = true;
    ++_epoch;
    auth.removeListener(_accountChanged);
    repository.onChange = null;
    super.dispose();
  }
}
