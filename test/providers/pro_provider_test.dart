import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:veea_english_app/core/config/app_config.dart';
import 'package:veea_english_app/data/pro_repository.dart';
import 'package:veea_english_app/data/remote/api_client.dart';
import 'package:veea_english_app/data/remote/auth_api.dart';
import 'package:veea_english_app/data/remote/go/api_client.dart';
import 'package:veea_english_app/data/remote/go/session_store.dart';
import 'package:veea_english_app/providers/auth_provider.dart';
import 'package:veea_english_app/providers/pro_provider.dart';
import 'package:veea_english_app/services/sync_service.dart';
import '../support/fake_token_store.dart';
import 'package:veea_english_app/data/vocabulary_repository.dart';

class TestNotebook implements VocabularyRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class TestAuth extends AuthProvider {
  TestAuth()
    : super(
        authApi: AuthApi(
          client: ApiClient(tokenStore: FakeTokenStore()),
          tokens: FakeTokenStore(),
        ),
        tokens: FakeTokenStore(),
        client: ApiClient(tokenStore: FakeTokenStore()),
        repository: TestNotebook(),
        sync: SyncService(repository: TestNotebook()),
      );
  String? owner;
  @override
  String? get accountId => owner;
  @override
  bool get isSignedIn => owner != null;
  void select(String? value) {
    owner = value;
    notifyListeners();
  }
}

class TestPro extends ProRepository {
  TestPro() : super(client: GoApiClient(tokens: GoTokenStore()));
  ProStoreState state = const ProStoreState();
  Map<String, Object?> plan = {
    'plan': 'free',
    'plan_expires_at': null,
    'apple_purchase_available': true,
  };
  Map<String, Object?> claimResult = {
    'plan': 'premium',
    'plan_expires_at': null,
    'apple_purchase_available': true,
    'purchase_environment': 'Production',
    'purchase_recorded': true,
    'purchase_revoked': false,
  };
  ProStoreState? purchaseResult;
  Future<ProStoreState>? pendingPurchase;
  PlatformException? restoreError;
  ApiException? entitlementError;
  void Function()? onPurchase;
  int configurations = 0;
  int purchased = 0, restored = 0, claims = 0, finished = 0;
  bool offline = false;
  DateTime? lastServerUntil;
  bool lastClearServer = false;
  bool? lastServerLifetime;
  final Map<String, ApiException> claimErrors = {};
  final List<String> claimedIds = [];
  final List<String> finishedIds = [];
  final List<String> localFinishedIds = [];
  String? boundOwner;
  String? configuredOwner;
  int entitlementReads = 0;
  Completer<Map<String, Object?>>? waiting;
  @override
  void listen() {}
  @override
  Future<ProStoreState> configure(
    String? owner, {
    DateTime? serverUntil,
    bool clearServer = false,
    bool? serverLifetime,
    bool loadProduct = true,
  }) async {
    configurations++;
    configuredOwner = owner;
    lastServerUntil = serverUntil;
    lastClearServer = clearServer;
    lastServerLifetime = serverLifetime;
    final local = state.localApple || state.localSandbox;
    final canClaim =
        owner != null && (boundOwner == null || boundOwner == owner);
    return ProStoreState(
      hasPro: local || (owner != null && (state.hasPro || serverUntil != null)),
      hasLifetime:
          local ||
          (owner != null && (state.hasLifetime || serverLifetime == true)),
      localApple: state.localApple,
      localSandbox: state.localSandbox,
      serverApple: owner != null && serverLifetime == true,
      manualPremium:
          owner != null && serverUntil != null && serverLifetime != true,
      localFinishTransactions: state.localFinishTransactions,
      price: state.price,
      transactions: canClaim ? state.transactions : const [],
      pendingTransactions: canClaim ? state.pendingTransactions : const [],
      outcome: state.outcome,
    );
  }

  @override
  Future<Map<String, Object?>> entitlement(String owner) {
    entitlementReads++;
    if (offline) throw const OfflineException();
    if (entitlementError case final error?) throw error;
    return waiting?.future ?? Future.value(plan);
  }

  @override
  Future<ProStoreState> purchase() async {
    purchased++;
    onPurchase?.call();
    if (pendingPurchase case final result?) return result;
    return purchaseResult ?? state;
  }

  @override
  Future<ProStoreState> restore() async {
    restored++;
    if (restoreError case final error?) throw error;
    if (boundOwner != null && boundOwner != configuredOwner) {
      return ProStoreState(
        hasPro: state.hasPro,
        hasLifetime: state.hasLifetime,
        localApple: state.localApple,
        localSandbox: state.localSandbox,
        price: state.price,
      );
    }
    return state;
  }

  @override
  Future<Map<String, Object?>> claim(String owner, String id) async {
    claims++;
    claimedIds.add(id);
    if (offline) throw const OfflineException();
    if (claimErrors[id] case final error?) throw error;
    return claimResult;
  }

  @override
  Future<void> recordVerification(
    String id, {
    required bool revoked,
    required bool recorded,
  }) async {
    if (revoked) {
      state = ProStoreState(
        price: state.price,
        transactions: state.transactions,
      );
    }
  }

  @override
  Future<void> finishLocal(String id) async {
    localFinishedIds.add(id);
    state = ProStoreState(
      hasPro: state.hasPro,
      hasLifetime: state.hasLifetime,
      localApple: state.localApple,
      localSandbox: state.localSandbox,
      price: state.price,
      transactions: state.transactions,
    );
  }

  @override
  Future<void> finish(String id) async {
    finished++;
    finishedIds.add(id);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late TestAuth auth;
  late TestPro repo;
  late ProProvider pro;
  setUp(() {
    AppConfig.overrideFreeLaunch(false);
    AppConfig.overrideBaseUrl('http://localhost');
    AppConfig.overrideAppleProduct('app.test.pro');
    auth = TestAuth();
    repo = TestPro();
    pro = ProProvider(auth: auth, repository: repo);
  });
  tearDown(() {
    AppConfig.overrideFreeLaunch(null);
    pro.dispose();
    auth.dispose();
    AppConfig.overrideBaseUrl(null);
    AppConfig.overrideAppleProduct(null);
  });
  test(
    'free launch blocks checkout without inventing purchase ownership',
    () async {
      AppConfig.overrideFreeLaunch(true);
      expect(AppConfig.isFreeLaunch, isTrue);
      await pro.purchase();
      expect(repo.purchased, 0);
      expect(repo.configurations, 0);
      expect(pro.canPurchase, isFalse);
      expect(pro.hasPro, isFalse);
      expect(pro.hasLifetime, isFalse);
      expect(pro.message, contains('No purchase is needed'));
      expect(
        pro.localizedMessage(vietnamese: true),
        'Phiên bản này miễn phí. Bạn không cần mua.',
      );
    },
  );
  test(
    'unavailable checkout tells Vietnamese users that buying is unavailable',
    () async {
      await pro.purchase();
      expect(repo.purchased, 0);
      expect(
        pro.localizedMessage(vietnamese: true),
        'Phiên bản này hiện chưa hỗ trợ mua Pro.',
      );
    },
  );
  test('free launch starts without a configured Apple product', () async {
    AppConfig.overrideFreeLaunch(true);
    AppConfig.overrideAppleProduct('');
    await pro.initializeDevice();
    await pro.refresh();
    expect(repo.configurations, 0);
    expect(repo.purchased, 0);
    expect(pro.hasPro, isFalse);
    expect(pro.message, isNull);
  });
  test(
    'free launch preserves restoration of earlier owned purchases',
    () async {
      AppConfig.overrideFreeLaunch(true);
      repo.state = const ProStoreState(hasPro: true, transactions: ['earlier']);
      auth.select('a');
      await Future<void>.delayed(Duration.zero);
      await pro.restore();
      expect(repo.restored, 1);
      expect(repo.purchased, 0);
      expect(repo.finishedIds, everyElement('earlier'));
      expect(pro.hasPro, isTrue);
      expect(pro.canPurchase, isFalse);
    },
  );
  test(
    'Sandbox checkout succeeds with a Free production account plan',
    () async {
      repo.state = const ProStoreState(price: '99.000 ₫');
      auth.select('owner-a');
      await Future<void>.delayed(Duration.zero);
      repo.onPurchase = () {
        repo.state = const ProStoreState(
          hasPro: true,
          hasLifetime: true,
          price: '99.000 ₫',
          transactions: ['sandbox-new'],
          pendingTransactions: ['sandbox-new'],
        );
      };
      repo.claimResult = {
        'plan': 'free',
        'plan_expires_at': null,
        'apple_purchase_available': true,
        'purchase_environment': 'Sandbox',
        'purchase_recorded': false,
        'purchase_revoked': false,
      };
      await pro.purchase();
      expect(repo.purchased, 1);
      expect(repo.finishedIds, ['sandbox-new']);
      expect(pro.hasPro, isTrue);
      expect(repo.lastServerUntil, isNull);
      expect(repo.lastClearServer, isTrue);
      expect(pro.message, 'Pro is ready. Thank you for supporting Veea!');
    },
  );
  test(
    'Sandbox acknowledgement finishes without granting a server lease',
    () async {
      auth.select('owner-a');
      await Future<void>.delayed(Duration.zero);
      repo.state = const ProStoreState(
        hasPro: true,
        hasLifetime: true,
        price: '99.000 ₫',
        transactions: ['sandbox-1'],
      );
      repo.claimResult = {
        'plan': 'free',
        'plan_expires_at': null,
        'apple_purchase_available': true,
        'purchase_environment': 'Sandbox',
        'purchase_recorded': false,
        'purchase_revoked': false,
      };
      await pro.restore();
      expect(repo.finishedIds, ['sandbox-1']);
      expect(pro.hasPro, isTrue);
      expect(pro.hasLifetime, isTrue);
      expect(repo.lastServerUntil, isNull);
      expect(repo.lastClearServer, isTrue);
      expect(pro.message, 'Pro restored on this device (Apple Sandbox).');
      // A later Production account read remains Free, without removing native
      // ownership that StoreKit supplies only in this test installation.
      await pro.refresh();
      expect(pro.hasPro, isTrue);
      expect(repo.lastServerUntil, isNull);
      expect(repo.lastClearServer, isTrue);
      repo.state = const ProStoreState();
      await pro.refresh();
      expect(pro.hasPro, isFalse);
    },
  );
  test(
    'Sandbox refund is acknowledged and removes device test ownership',
    () async {
      auth.select('owner-a');
      await Future<void>.delayed(Duration.zero);
      repo.state = const ProStoreState(
        hasPro: true,
        hasLifetime: true,
        transactions: ['sandbox-refund'],
      );
      repo.claimResult = {
        'plan': 'free',
        'plan_expires_at': null,
        'apple_purchase_available': true,
        'purchase_environment': 'Sandbox',
        'purchase_recorded': false,
        'purchase_revoked': true,
      };
      await pro.restore();
      expect(repo.finishedIds, ['sandbox-refund']);
      expect(pro.hasPro, isFalse);
      expect(repo.lastServerUntil, isNull);
    },
  );
  test(
    'guest buys and restores through StoreKit without an account claim',
    () async {
      AppConfig.overrideBaseUrl('');
      repo.state = const ProStoreState(price: '99.000 ₫');
      repo.onPurchase = () {
        repo.state = const ProStoreState(
          hasPro: true,
          hasLifetime: true,
          localApple: true,
          localFinishTransactions: ['guest'],
        );
      };
      await pro.refresh();
      expect(pro.canPurchase, isTrue);
      await pro.purchase();
      expect(pro.hasLocalApple, isTrue);
      expect(repo.localFinishedIds, ['guest']);
      expect(repo.finished, 0);
      expect(repo.claims, 0);
      expect(repo.entitlementReads, 0);
      await pro.restore();
      expect(repo.restored, 1);
      expect(pro.message, 'Pro restored.');
    },
  );

  test(
    'sign-in after a guest purchase does not link it to the account',
    () async {
      repo.state = const ProStoreState(
        hasPro: true,
        hasLifetime: true,
        localApple: true,
      );
      await pro.refresh();
      auth.select('a');
      await Future<void>.delayed(Duration.zero);
      expect(pro.hasLocalApple, isTrue);
      expect(pro.hasServerApple, isFalse);
      expect(repo.claims, 0);
    },
  );

  test(
    'deletion, sign-out and account recreation retain local purchase without transferring the claim',
    () async {
      repo.boundOwner = 'original';
      repo.state = const ProStoreState(
        hasPro: true,
        hasLifetime: true,
        localApple: true,
        transactions: ['bound'],
      );
      auth.select('original');
      await Future<void>.delayed(Duration.zero);
      expect(repo.claims, 1);
      auth.select(null);
      await Future<void>.delayed(Duration.zero);
      expect(pro.hasLocalApple, isTrue);
      expect(pro.hasServerApple, isFalse);
      auth.select('recreated');
      await Future<void>.delayed(Duration.zero);
      await pro.restore();
      expect(pro.hasLocalApple, isTrue);
      expect(pro.hasServerApple, isFalse);
      expect(repo.claims, 1);
      expect(pro.message, 'Pro restored.');
    },
  );

  test(
    'matching unfinished claim recovers after provider restart and network recovery',
    () async {
      repo.boundOwner = 'a';
      repo.state = const ProStoreState(price: '99.000 ₫');
      repo.offline = true;
      repo.onPurchase = () {
        repo.state = const ProStoreState(
          hasPro: true,
          hasLifetime: true,
          localApple: true,
          transactions: ['bound'],
          pendingTransactions: ['bound'],
        );
      };
      auth.select('a');
      await Future<void>.delayed(Duration.zero);
      await pro.purchase();
      expect(pro.hasLocalApple, isTrue);
      expect(repo.claimedIds, ['bound']);
      expect(repo.finishedIds, isEmpty);
      expect(
        pro.localizedMessage(vietnamese: true),
        'Bạn có thể dùng Pro trên thiết bị này. Veea sẽ thử xác nhận giao dịch cho tài khoản của bạn khi có mạng.',
      );
      pro.dispose();
      repo.offline = false;
      pro = ProProvider(auth: auth, repository: repo);
      await pro.refresh();
      expect(repo.claimedIds, ['bound', 'bound']);
      expect(repo.finishedIds, ['bound']);
      expect(pro.hasLocalApple, isTrue);
    },
  );

  test(
    'a refused transaction does not block another owned transaction',
    () async {
      repo.state = const ProStoreState(
        hasPro: true,
        transactions: ['refused', 'owned'],
      );
      repo.claimErrors['refused'] = const ApiException(
        'Not accepted',
        statusCode: 400,
        code: 'purchase_invalid',
      );
      auth.select('a');
      await Future<void>.delayed(Duration.zero);
      expect(repo.claimedIds, ['refused', 'owned']);
      expect(repo.finished, 1);
      expect(repo.finishedIds, ['owned']);
      expect(pro.hasPro, isTrue);
      expect(pro.message, contains('verification was not accepted'));
      expect(pro.message, isNot(contains('when you are online')));
    },
  );
  test(
    'ownership refusal explains the account link rather than connectivity',
    () async {
      repo.state = const ProStoreState(hasPro: true, transactions: ['123']);
      repo.claimErrors['123'] = const ApiException(
        'Not accepted',
        statusCode: 409,
        code: 'purchase_ownership_conflict',
      );
      auth.select('a');
      await Future<void>.delayed(Duration.zero);
      expect(repo.finished, 0);
      expect(pro.message, contains('original purchase'));
      expect(pro.message, isNot(contains('when you are online')));
    },
  );
  test(
    'verified owner purchase stays usable offline and is not finished before cloud confirmation',
    () async {
      repo.state = const ProStoreState(hasPro: true, transactions: ['123']);
      repo.offline = true;
      auth.select('a');
      await Future<void>.delayed(Duration.zero);
      expect(pro.hasPro, isTrue);
      expect(repo.finished, 0);
      expect(pro.message, contains('retry'));
    },
  );
  test(
    'restore links first then finishes exactly the owned transaction',
    () async {
      repo.state = const ProStoreState(hasPro: true, transactions: ['123']);
      auth.select('a');
      await Future<void>.delayed(Duration.zero);
      repo.claims = 0;
      repo.finished = 0;
      await pro.restore();
      expect(repo.restored, 1);
      expect(repo.claims, 1);
      expect(repo.finished, 1);
      expect(pro.message, 'Pro restored.');
    },
  );
  test('restore does not report a manual grant as an Apple purchase', () async {
    repo.plan = {
      'plan': 'premium',
      'plan_expires_at': DateTime.now()
          .add(const Duration(hours: 1))
          .toIso8601String(),
    };
    auth.select('a');
    await Future<void>.delayed(Duration.zero);
    await pro.restore();
    expect(pro.hasPro, isTrue);
    expect(repo.claims, 0);
    expect(pro.message, 'No Pro purchase found to restore.');
  });

  test('restore reports pending verification even with manual Pro', () async {
    repo.plan = {
      'plan': 'premium',
      'plan_expires_at': DateTime.now()
          .add(const Duration(hours: 1))
          .toIso8601String(),
      'purchase_verification_pending': true,
    };
    auth.select('a');
    await Future<void>.delayed(Duration.zero);
    await pro.restore();
    expect(pro.hasPro, isTrue);
    expect(repo.finished, 0);
    expect(pro.message, contains('try restoring again later'));
    expect(
      pro.localizedMessage(vietnamese: true),
      'Tạm thời không thể xác minh giao dịch. Vui lòng thử khôi phục lại sau.',
    );
  });

  test('restore does not report a revoked purchase as restored', () async {
    repo.state = const ProStoreState(hasPro: true, transactions: ['123']);
    repo.claimResult = {
      'plan': 'premium',
      'plan_expires_at': DateTime.now()
          .add(const Duration(hours: 1))
          .toIso8601String(),
      'purchase_environment': 'Production',
      'purchase_recorded': true,
      'purchase_revoked': true,
    };
    auth.select('a');
    await Future<void>.delayed(Duration.zero);
    await pro.restore();
    expect(pro.hasPro, isTrue);
    expect(repo.finishedIds, isNotEmpty);
    expect(pro.message, contains('refunded or revoked'));
  });

  test(
    'restore recognizes verified server lifetime without StoreKit IDs',
    () async {
      repo.plan = {
        'plan': 'premium',
        'plan_expires_at': null,
        'apple_purchase_available': true,
      };
      auth.select('a');
      await Future<void>.delayed(Duration.zero);
      await pro.restore();
      expect(repo.claims, 0);
      expect(pro.hasLifetime, isTrue);
      expect(pro.message, 'Pro restored.');
    },
  );

  test(
    'restore recognizes a Sandbox claim despite unrelated pending server proofs',
    () async {
      repo.state = const ProStoreState(
        hasPro: true,
        hasLifetime: true,
        transactions: ['123'],
      );
      repo.claimResult = {
        'plan': 'free',
        'plan_expires_at': null,
        'apple_purchase_available': true,
        'purchase_environment': 'Sandbox',
        'purchase_recorded': false,
        'purchase_revoked': false,
        'purchase_verification_pending': true,
      };
      auth.select('a');
      await Future<void>.delayed(Duration.zero);
      await pro.restore();
      expect(repo.finishedIds, isNotEmpty);
      expect(repo.lastClearServer, isFalse);
      expect(repo.lastServerUntil, isNull);
      expect(repo.lastServerLifetime, isNull);
      expect(pro.hasLifetime, isTrue);
      expect(pro.message, 'Pro restored on this device (Apple Sandbox).');
    },
  );

  test(
    'restore can confirm server lifetime when StoreKit sync fails',
    () async {
      repo.plan = {
        'plan': 'premium',
        'plan_expires_at': null,
        'apple_purchase_available': true,
      };
      repo.restoreError = PlatformException(code: 'storekit_unavailable');
      auth.select('a');
      await Future<void>.delayed(Duration.zero);
      await pro.restore();
      expect(repo.claims, 0);
      expect(pro.message, 'Pro restored.');
    },
  );

  test(
    'StoreKit sync failure without confirmed ownership cannot restore',
    () async {
      repo.restoreError = PlatformException(
        code: 'storekit_unavailable',
        message: 'StoreKit could not sync purchases.',
      );
      auth.select('a');
      await Future<void>.delayed(Duration.zero);
      await pro.restore();
      expect(repo.restored, 1);
      expect(repo.claims, 0);
      expect(pro.hasPro, isFalse);
      expect(pro.hasLifetime, isFalse);
      expect(
        pro.message,
        'Apple could not restore your purchases. Please try again.',
      );
      expect(
        pro.localizedMessage(vietnamese: true),
        'Apple không thể khôi phục giao dịch của bạn. Vui lòng thử lại.',
      );
    },
  );

  test(
    'restore reports ownership conflict and leaves the proof unfinished',
    () async {
      repo.state = const ProStoreState(transactions: ['123']);
      repo.claimErrors['123'] = const ApiException(
        'Conflict',
        statusCode: 409,
        code: 'purchase_ownership_conflict',
      );
      repo.entitlementError = const ApiException(
        'Unavailable',
        statusCode: 503,
        code: 'purchase_unavailable',
      );
      auth.select('a');
      await Future<void>.delayed(Duration.zero);
      await pro.restore();
      expect(repo.finished, 0);
      expect(pro.message, contains('original purchase'));
    },
  );

  test('restore reports no purchase for a verified Free plan', () async {
    auth.select('a');
    await Future<void>.delayed(Duration.zero);
    await pro.restore();
    expect(pro.message, 'No Pro purchase found to restore.');
  });
  test(
    'late response for previous account cannot unlock signed out user',
    () async {
      repo.state = const ProStoreState(hasPro: true);
      final pending = repo.waiting = Completer<Map<String, Object?>>();
      auth.select('a');
      await Future<void>.delayed(Duration.zero);
      expect(pro.hasPro, isTrue);
      auth.select(null);
      await Future<void>.delayed(Duration.zero);
      expect(pro.hasPro, isFalse);
      pending.complete({'plan': 'premium', 'plan_expires_at': null});
      await Future<void>.delayed(Duration.zero);
      expect(pro.hasPro, isFalse);
      expect(repo.finished, 0);
    },
  );
  test(
    'a proof bound to another account cannot fabricate device access',
    () async {
      repo.boundOwner = 'a';
      repo.state = const ProStoreState(transactions: ['bound']);
      auth.select('b');
      await Future<void>.delayed(Duration.zero);
      await pro.restore();
      expect(pro.hasPro, isFalse);
      expect(pro.message, 'No Pro purchase found to restore.');
      expect(repo.claims, 0);
    },
  );
  test(
    'restore waits behind sign-in refresh instead of disappearing',
    () async {
      final pending = repo.waiting = Completer<Map<String, Object?>>();
      auth.select('a');
      await Future<void>.delayed(Duration.zero);
      await pro.restore();
      expect(repo.restored, 0);
      repo.waiting = null;
      pending.complete({'plan': 'free', 'plan_expires_at': null});
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(repo.restored, 1);
      expect(pro.message, contains('No Pro purchase'));
    },
  );
  test(
    'temporary Pro can buy lifetime, already lifetime never opens payment again',
    () async {
      repo.state = const ProStoreState(price: '99.000 ₫');
      repo.plan = {
        'apple_purchase_available': true,
        'plan': 'premium',
        'plan_expires_at': DateTime.now()
            .add(const Duration(days: 30))
            .toIso8601String(),
      };
      auth.select('a');
      await Future<void>.delayed(Duration.zero);
      expect(pro.hasPro, isTrue);
      expect(pro.hasLifetime, isFalse);
      expect(pro.canPurchase, isTrue);
      repo.plan = {'plan': 'premium', 'plan_expires_at': null};
      await pro.purchase();
      expect(repo.purchased, 0);
      expect(pro.hasLifetime, isTrue);
      expect(pro.message, contains('No purchase needed'));
    },
  );
  test(
    'cancelled and pending Apple payments do not finish or grant Pro',
    () async {
      repo.state = const ProStoreState(price: '99.000 ₫');
      auth.select('a');
      await Future<void>.delayed(Duration.zero);
      for (final outcome in ['cancelled', 'pending']) {
        repo.purchaseResult = ProStoreState(
          price: '99.000 ₫',
          outcome: outcome,
        );
        await pro.purchase();
        expect(pro.hasPro, isFalse);
        expect(repo.finished, 0);
        expect(
          pro.message,
          contains(outcome == 'cancelled' ? 'cancelled' : 'Waiting'),
        );
      }
    },
  );
  test(
    'repeated resumes use a recent confirmation but explicit restore verifies again',
    () async {
      repo.state = const ProStoreState(
        hasPro: true,
        hasLifetime: true,
        transactions: ['123'],
      );
      auth.select('a');
      await Future<void>.delayed(Duration.zero);
      expect(repo.claims, 1);
      await pro.refresh();
      await pro.refresh();
      expect(repo.claims, 1);
      await pro.restore();
      expect(repo.claims, 2);
    },
  );
  test(
    'refund clears paid access while a manual grant remains usable',
    () async {
      repo.state = const ProStoreState(
        hasPro: true,
        hasLifetime: true,
        transactions: ['123'],
      );
      repo.claimResult = {
        'plan': 'premium',
        'plan_expires_at': DateTime.now()
            .add(const Duration(days: 1))
            .toIso8601String(),
        'purchase_environment': 'Production',
        'purchase_recorded': true,
        'purchase_revoked': true,
      };
      auth.select('a');
      await Future<void>.delayed(Duration.zero);
      expect(pro.hasPro, isTrue);
      expect(pro.hasLifetime, isFalse);
      expect(repo.finished, 1);
    },
  );
  test(
    'pending approval received during a request is processed afterwards',
    () async {
      final pending = repo.waiting = Completer<Map<String, Object?>>();
      auth.select('a');
      await Future<void>.delayed(Duration.zero);
      repo.state = const ProStoreState(
        hasPro: true,
        hasLifetime: true,
        transactions: ['123'],
        pendingTransactions: ['123'],
      );
      repo.onChange?.call();
      repo.waiting = null;
      pending.complete({'plan': 'free', 'plan_expires_at': null});
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(repo.claims, 1);
      expect(repo.finished, 1);
      expect(pro.hasLifetime, isTrue);
    },
  );
  test('queued restore is cancelled when the account changes', () async {
    final pending = repo.waiting = Completer<Map<String, Object?>>();
    auth.select('a');
    await Future<void>.delayed(Duration.zero);
    await pro.restore();
    repo.waiting = null;
    auth.select(null);
    pending.complete({'plan': 'free', 'plan_expires_at': null});
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(repo.restored, 0);
    expect(pro.hasPro, isFalse);
  });
  test('unclaimed local lifetime never opens another Apple checkout', () async {
    repo.state = const ProStoreState(
      price: '99.000 ₫',
      hasPro: true,
      hasLifetime: true,
      transactions: ['123'],
    );
    auth.select('a');
    await Future<void>.delayed(Duration.zero);
    repo.plan = {'plan': 'free', 'plan_expires_at': null};
    await pro.purchase();
    expect(repo.purchased, 0);
    expect(pro.hasPro, isTrue);
  });
  test(
    'checkout can proceed locally while an independent manual grant is pending',
    () async {
      repo.state = const ProStoreState(price: '99.000 ₫');
      auth.select('a');
      await Future<void>.delayed(Duration.zero);
      repo.plan = {
        'apple_purchase_available': true,
        'plan': 'premium',
        'plan_expires_at': DateTime.now()
            .add(const Duration(days: 1))
            .toIso8601String(),
        'purchase_verification_pending': true,
      };
      await pro.purchase();
      expect(repo.purchased, 1);
      expect(pro.hasPro, isTrue);
      expect(repo.lastServerLifetime, isFalse);
      expect(pro.hasLifetime, isFalse);
    },
  );
  test('backend disabled leaves StoreKit checkout available', () async {
    repo.state = const ProStoreState(price: '99.000 ₫');
    repo.plan = {'plan': 'free', 'plan_expires_at': null};
    auth.select('a');
    await Future<void>.delayed(Duration.zero);
    await pro.purchase();
    expect(repo.purchased, 1);
    expect(pro.purchasesReady, isFalse);
  });
  test(
    'finite manual fallback cannot inherit uncertain lifetime metadata',
    () async {
      repo.plan = {
        'apple_purchase_available': true,
        'plan': 'premium',
        'plan_expires_at': DateTime.now()
            .add(const Duration(hours: 1))
            .toIso8601String(),
        'purchase_verification_pending': true,
      };
      auth.select('owner-a');
      await Future<void>.delayed(Duration.zero);
      await pro.refresh();
      expect(pro.hasPro, isTrue);
      expect(pro.hasLifetime, isFalse);
      expect(repo.lastServerLifetime, isFalse);
    },
  );
  test(
    'unavailable owner verification cannot create a paid offline lease',
    () async {
      repo.state = const ProStoreState(price: '99.000 ₫');
      auth.select('a');
      await Future<void>.delayed(Duration.zero);
      repo.entitlementError = const ApiException(
        'Unavailable',
        statusCode: 503,
        code: 'purchase_unavailable',
      );
      await pro.purchase();
      expect(pro.hasPro, isFalse);
      expect(repo.purchased, 1);
    },
  );
  test(
    'refund outcomes are only shown for explicit purchase or restore',
    () async {
      const revoked = ProStoreState(price: '99.000 ₫', outcome: 'revoked');
      repo.state = revoked;
      await pro.refresh();
      expect(pro.message, isNull);

      await pro.restore();
      expect(pro.message, contains('refunded or revoked'));
      await pro.refresh();
      expect(pro.message, isNull);

      await pro.purchase();
      expect(pro.message, contains('refunded or revoked'));
      repo.state = const ProStoreState(
        localApple: true,
        hasLifetime: true,
        hasPro: true,
      );
      await pro.refresh();
      expect(pro.hasLifetime, isTrue);
      expect(pro.message, isNull);
    },
  );

  test('a late refund result cannot affect the next Veea account', () async {
    repo.state = const ProStoreState(price: '99.000 ₫');
    auth.select('a');
    await Future<void>.delayed(Duration.zero);
    final result = Completer<ProStoreState>();
    repo.pendingPurchase = result.future;
    final purchase = pro.purchase();
    await Future<void>.delayed(Duration.zero);
    expect(repo.purchased, 1);

    repo.state = const ProStoreState(price: 'new price');
    auth.select('b');
    await Future<void>.delayed(Duration.zero);
    result.complete(
      const ProStoreState(price: 'old price', outcome: 'revoked'),
    );
    await purchase;
    expect(pro.price, 'new price');
    expect(pro.message, isNull);
  });

  test(
    'background reconciliation unavailability is quiet and preserves access',
    () async {
      auth.select('a');
      await Future<void>.delayed(Duration.zero);
      const unavailable = ApiException(
        'Unavailable',
        statusCode: 503,
        code: 'purchase_unavailable',
      );
      repo.entitlementError = unavailable;
      repo.state = const ProStoreState(hasPro: true, hasLifetime: true);
      await pro.refresh();
      expect(pro.message, isNull);
      expect(pro.hasLifetime, isTrue);
      expect(repo.lastClearServer, isFalse);

      repo.state = const ProStoreState(
        localApple: true,
        transactions: ['bound'],
      );
      repo.claimErrors['bound'] = unavailable;
      await pro.refresh();
      expect(pro.message, isNull);
      expect(pro.hasLocalApple, isTrue);
      expect(repo.finishedIds, isEmpty);
    },
  );

  test('explicit StoreKit refund feedback survives Go unavailability', () async {
    auth.select('a');
    await Future<void>.delayed(Duration.zero);
    repo.state = const ProStoreState(outcome: 'revoked');
    repo.entitlementError = const ApiException(
      'Unavailable',
      statusCode: 503,
      code: 'purchase_unavailable',
    );
    await pro.restore();
    expect(pro.message, contains('refunded or revoked'));
    await pro.refresh();
    expect(pro.message, isNull);
  });
}
