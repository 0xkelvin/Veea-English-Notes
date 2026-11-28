import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../core/config/app_config.dart';
import '../data/pro_repository.dart';
import '../data/remote/api_client.dart';
import 'auth_provider.dart';

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
  String? get _entitlementOwner => auth.isSignedIn ? auth.accountId : null;
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
  bool get hasLocalApple => _store.localApple;
  bool get hasLocalSandbox => _store.localSandbox;
  bool get hasServerApple => _store.serverApple;
  bool get hasManualPremium => _store.manualPremium;
  bool get isBusy => _busy;
  String? get price => _store.price;
  String? get message => _message;
  bool get isConfigured => AppConfig.appleProProductId.isNotEmpty;
  bool get canPurchase =>
      !AppConfig.isFreeLaunch &&
      isConfigured &&
      price != null &&
      !_busy &&
      !hasLifetime;

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
    final local = _store.localApple || _store.localSandbox;
    _store = ProStoreState(
      hasPro: local,
      hasLifetime: local,
      localApple: _store.localApple,
      localSandbox: _store.localSandbox,
      price: _store.price,
    );
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
    final explicit = purchase || restore;
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
      PlatformException? restoreError;
      String? outcome;
      final signedIn =
          AppConfig.isCloudEnabled && auth.isSignedIn && owner != null;
      if (purchase && signedIn && !configured.hasLifetime) {
        // Account status can prevent a duplicate lifetime purchase. Failure
        // here must not prevent StoreKit from delivering a local purchase.
        try {
          server = await repository.entitlement(owner);
          if (!_current(epoch, owner)) return;
          _serverPurchaseAvailable = server['apple_purchase_available'] == true;
          _serverChecked = true;
        } on ApiException {
          if (!_current(epoch, owner)) return;
        }
      }
      final alreadyLifetime =
          purchase && (_store.hasLifetime || _serverHasLifetimeApple(server));
      if (purchase && !alreadyLifetime) {
        if (!isConfigured || _store.price == null) {
          _message = 'Purchases are not available in this build yet.';
          return;
        }
        final state = await repository.purchase();
        if (!_current(epoch, owner)) return;
        _store = state;
        outcome = state.outcome;
      } else if (restore) {
        try {
          final state = await repository.restore();
          if (!_current(epoch, owner)) return;
          _store = state;
          outcome = state.outcome;
        } on PlatformException catch (error) {
          // A StoreKit sync failure can still have a verified account result.
          restoreError = error;
        }
      }
      if (!_current(epoch, owner)) return;
      // Publish StoreKit delivery before finishing. An interruption is
      // recoverable through StoreKit's unfinished transaction sequence.
      _notify();
      for (final id in _store.localFinishTransactions) {
        await repository.finishLocal(id);
        if (!_current(epoch, owner)) return;
      }
      if (!_current(epoch, owner)) return;
      ApiException? claimError;
      var confirmedApplePurchase = false;
      var confirmedSandboxAcknowledgement = false;
      var confirmedRevocation = false;
      var verificationPending = false;
      if (signedIn) {
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
            final pending = server['purchase_verification_pending'] == true;
            verificationPending |= pending;
            final revoked = server['purchase_revoked'];
            final environment = server['purchase_environment'];
            final recorded = server['purchase_recorded'];
            if (revoked is! bool ||
                !(environment == 'Production' && recorded == true ||
                    environment == 'Sandbox' && recorded is bool)) {
              verificationPending = true;
              continue;
            }
            confirmedApplePurchase |= !revoked && recorded == true;
            confirmedSandboxAcknowledgement |= !revoked && recorded == false;
            confirmedRevocation |= revoked;
            await repository.recordVerification(
              id,
              revoked: revoked,
              recorded: recorded == true,
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
      if (server == null && signedIn) {
        try {
          server = await repository.entitlement(owner);
        } on ApiException {
          // Preserve a specific claim refusal if the separate account read fails.
          if (!confirmedApplePurchase &&
              !confirmedSandboxAcknowledgement &&
              !_store.localApple &&
              !_store.localSandbox &&
              outcome != 'revoked' &&
              !confirmedRevocation &&
              claimError == null) {
            rethrow;
          }
        }
        if (!_current(epoch, owner)) return;
      }
      if (server != null) {
        final pending = server['purchase_verification_pending'] == true;
        verificationPending |= pending;
        confirmedApplePurchase |= _serverHasLifetimeApple(server);
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
          clearServer: !premium && !pending,
          serverLifetime: pending
              ? (expiry != null ? false : null)
              : _serverHasLifetimeApple(server),
        );
        if (!_current(epoch, owner)) return;
        _store = ProStoreState(
          hasPro: state.hasPro,
          hasLifetime: state.hasLifetime,
          localApple: state.localApple,
          localSandbox: state.localSandbox,
          serverApple: state.serverApple,
          manualPremium: state.manualPremium,
          pendingTransactions: state.pendingTransactions,
          price: state.price,
          transactions: state.transactions,
        );
      }
      if (restore &&
          (confirmedApplePurchase ||
              confirmedSandboxAcknowledgement ||
              _store.localApple ||
              _store.localSandbox)) {
        _message = confirmedApplePurchase || _store.localApple
            ? 'Pro restored.'
            : 'Pro restored on this device (Apple Sandbox).';
        return;
      }
      if (explicit &&
          !alreadyLifetime &&
          !confirmedApplePurchase &&
          !confirmedSandboxAcknowledgement &&
          !_store.localApple &&
          !_store.localSandbox &&
          (outcome == 'revoked' || (outcome == null && confirmedRevocation))) {
        _message =
            'Apple reports that this Pro purchase was refunded or revoked.';
        return;
      }
      if (claimError != null) {
        if (!explicit && claimError.code == 'purchase_unavailable') return;
        _message =
            (_store.localApple || _store.localSandbox) && claimError.isTransient
            ? 'Pro is available on this device. Account confirmation will retry when you are online.'
            : _purchaseError(claimError);
        return;
      }
      if (restoreError != null && !verificationPending) throw restoreError;
      _message = alreadyLifetime
          ? 'Lifetime Pro is already available. No purchase needed.'
          : switch (outcome) {
              'cancelled' => 'Purchase cancelled. You have not been charged.',
              'pending' =>
                'Waiting for Apple approval. Pro will update when approved.',
              _ =>
                restore
                    ? (verificationPending
                          ? 'Purchase verification is temporarily unavailable. Please try restoring again later.'
                          : 'No Pro purchase found to restore.')
                    : purchase && hasPro
                    ? 'Pro is ready. Thank you for supporting Veea!'
                    : null,
            };
    } on ApiException catch (error) {
      if (_current(epoch, owner) &&
          (explicit || error.code != 'purchase_unavailable')) {
        _message = _purchaseError(error);
      }
    } on MissingPluginException {
      if (_current(epoch, owner)) {
        _message = 'Purchases are available in the iPhone app.';
      }
    } on PlatformException catch (e) {
      if (_current(epoch, owner)) {
        _message = _storeKitError(e, purchase: purchase, restore: restore);
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

  // The owner entitlement API reserves a null Premium expiry for Apple's
  // lifetime proof. Its pending fallback reports manual access only.
  bool _serverHasLifetimeApple(Map<String, Object?>? server) =>
      server != null &&
      server['plan'] == 'premium' &&
      server.containsKey('plan_expires_at') &&
      server['plan_expires_at'] == null &&
      server['purchase_verification_pending'] != true;

  String _purchaseError(ApiException error) => switch (error.code) {
    'purchase_ownership_conflict' =>
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

  String _storeKitError(
    PlatformException error, {
    required bool purchase,
    required bool restore,
  }) => switch (error.code) {
    'STORE_UNAVAILABLE' => 'Connect to the App Store before purchasing.',
    'UNVERIFIED_PURCHASE' =>
      'Apple could not verify the purchase. Please try restoring purchases.',
    'UNKNOWN_PAYMENT_RESULT' =>
      'Apple returned an unknown payment result. Try restoring purchases.',
    'ACCOUNT_CHANGED' => 'Your account changed. Open Pro again to continue.',
    'INCOMPATIBLE_INSTALLATION' =>
      'The App Store could not verify this installation. Please try again or restore purchases.',
    _ when restore =>
      'Apple could not restore your purchases. Please try again.',
    _ when purchase =>
      'Apple could not complete the purchase. Please try again.',
    _ => 'Apple could not complete this request. Please try again.',
  };

  String? localizedMessage({required bool vietnamese}) {
    if (!vietnamese) return message;
    return switch (message) {
      null => null,
      'Pro restored.' => 'Đã khôi phục Pro.',
      'Pro restored on this device (Apple Sandbox).' =>
        'Đã khôi phục Pro trên thiết bị này (Apple Sandbox).',
      'No Pro purchase found to restore.' =>
        'Không tìm thấy giao dịch Pro để khôi phục.',
      'Purchase cancelled. You have not been charged.' =>
        'Đã hủy giao dịch. Bạn chưa bị tính phí.',
      'Waiting for Apple approval. Pro will update when approved.' =>
        'Đang chờ Apple phê duyệt. Quyền Pro sẽ được cập nhật sau khi phê duyệt.',
      'Pro is ready. Thank you for supporting Veea!' =>
        'Bạn đã có Pro. Cảm ơn bạn đã ủng hộ Veea!',
      'Lifetime Pro is already available. No purchase needed.' =>
        'Bạn đã có Pro trọn đời. Không cần mua lại.',
      'Apple reports that this Pro purchase was refunded or revoked.' =>
        'Apple cho biết giao dịch Pro đã được hoàn tiền hoặc bị thu hồi.',
      'Pro is available on this device. Account confirmation will retry when you are online.' =>
        'Bạn có thể dùng Pro trên thiết bị này. Veea sẽ thử xác nhận giao dịch cho tài khoản của bạn khi có mạng.',
      'This release is free. No purchase is needed.' =>
        'Phiên bản này miễn phí. Bạn không cần mua.',
      'Purchases are not available in this build yet.' =>
        'Phiên bản này hiện chưa hỗ trợ mua Pro.',
      'Purchases are available in the iPhone app.' =>
        'Bạn có thể mua Pro trong ứng dụng trên iPhone.',
      'Purchase verification is temporarily unavailable. Please try restoring again later.' =>
        'Tạm thời không thể xác minh giao dịch. Vui lòng thử khôi phục lại sau.',
      'Purchase verification is temporarily unavailable. Please try again later.' =>
        'Tạm thời không thể xác minh giao dịch. Vui lòng thử lại sau.',
      'Could not check your purchase. Please connect to the internet and try again.' =>
        'Không thể kiểm tra giao dịch. Vui lòng kết nối Internet rồi thử lại.',
      'This purchase could not be linked to this Veea account. Sign in to the account used for the original purchase or contact support.' =>
        'Không thể liên kết giao dịch này với tài khoản Veea hiện tại. Hãy đăng nhập vào tài khoản đã dùng khi mua hoặc liên hệ bộ phận hỗ trợ.',
      'Apple purchase verification was not accepted by the account service. Please contact support before trying to buy again.' =>
        'Hệ thống tài khoản Veea không chấp nhận kết quả xác minh giao dịch Apple. Vui lòng liên hệ bộ phận hỗ trợ trước khi mua lại.',
      'Sign in again to manage your purchase.' =>
        'Hãy đăng nhập lại để quản lý giao dịch của bạn.',
      'The account service could not verify this purchase. Please contact support before trying to buy again.' =>
        'Hệ thống tài khoản Veea không thể xác minh giao dịch này. Vui lòng liên hệ bộ phận hỗ trợ trước khi mua lại.',
      'Connect to the App Store before purchasing.' =>
        'Hãy kết nối với App Store trước khi mua.',
      'Apple could not verify the purchase. Please try restoring purchases.' =>
        'Apple không thể xác minh giao dịch. Vui lòng thử khôi phục giao dịch.',
      'Apple returned an unknown payment result. Try restoring purchases.' =>
        'Chưa rõ kết quả thanh toán từ Apple. Hãy thử khôi phục giao dịch.',
      'Your account changed. Open Pro again to continue.' =>
        'Tài khoản của bạn đã thay đổi. Hãy mở lại màn hình Pro để tiếp tục.',
      'The App Store could not verify this installation. Please try again or restore purchases.' =>
        'App Store không thể xác minh bản cài đặt này. Vui lòng thử lại hoặc khôi phục giao dịch.',
      'Apple could not restore your purchases. Please try again.' =>
        'Apple không thể khôi phục giao dịch của bạn. Vui lòng thử lại.',
      'Apple could not complete the purchase. Please try again.' =>
        'Apple không thể hoàn tất giao dịch mua. Vui lòng thử lại.',
      'Apple could not complete this request. Please try again.' =>
        'Apple không thể hoàn tất yêu cầu này. Vui lòng thử lại.',
      _ => 'Không thể hoàn tất yêu cầu Pro lúc này. Vui lòng thử lại.',
    };
  }

  @override
  void dispose() {
    _disposed = true;
    ++_epoch;
    auth.removeListener(_accountChanged);
    repository.onChange = null;
    super.dispose();
  }
}
