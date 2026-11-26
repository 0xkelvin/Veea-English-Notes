import 'dart:async';
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
    'apple_purchase_available': true,
  };
  Map<String, Object?> claimResult = {'plan': 'premium'};
  ProStoreState? purchaseResult;
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
    lastServerUntil = serverUntil;
    lastClearServer = clearServer;
    lastServerLifetime = serverLifetime;
    return owner == null
        ? const ProStoreState()
        : ProStoreState(
            hasPro: state.hasPro || serverUntil != null,
            hasLifetime: state.hasLifetime || serverLifetime == true,
            price: state.price,
            transactions: state.transactions,
            pendingTransactions: state.pendingTransactions,
            outcome: state.outcome,
          );
  }

  @override
  Future<Map<String, Object?>> entitlement(String owner) {
    if (offline) throw const OfflineException();
    return waiting?.future ?? Future.value(plan);
  }

  @override
  Future<ProStoreState> purchase() async {
    purchased++;
    onPurchase?.call();
    return purchaseResult ?? state;
  }

  @override
  Future<ProStoreState> restore() async {
    restored++;
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
  Future<void> recordVerification(String id, {required bool revoked}) async {
    if (revoked) {
      state = ProStoreState(
        price: state.price,
        transactions: state.transactions,
      );
    }
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
      expect(pro.message, 'Pro restored.');
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
  test('signed out cannot buy or restore', () async {
    await pro.purchase();
    await pro.restore();
    expect(repo.purchased, 0);
    expect(repo.restored, 0);
    expect(pro.hasPro, isFalse);
    expect(pro.message, contains('Sign in'));
  });
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
        code: 'purchase_ownership',
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
  test('unknown outcome does not open the Apple payment sheet', () async {
    repo.offline = true;
    auth.select('a');
    await Future<void>.delayed(Duration.zero);
    await pro.purchase();
    expect(repo.purchased, 0);
    expect(pro.hasPro, isFalse);
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
      pending.complete({'plan': 'premium'});
      await Future<void>.delayed(Duration.zero);
      expect(pro.hasPro, isFalse);
      expect(repo.finished, 0);
    },
  );
  test('restoring a different account never activates Pro', () async {
    repo.state = const ProStoreState(outcome: 'account_mismatch');
    auth.select('b');
    await Future<void>.delayed(Duration.zero);
    await pro.restore();
    expect(pro.hasPro, isFalse);
    expect(pro.message, contains('different Veea account'));
    expect(repo.claims, 0);
  });
  test(
    'restore waits behind sign-in refresh instead of disappearing',
    () async {
      final pending = repo.waiting = Completer<Map<String, Object?>>();
      auth.select('a');
      await Future<void>.delayed(Duration.zero);
      await pro.restore();
      expect(repo.restored, 0);
      repo.waiting = null;
      pending.complete({'plan': 'free'});
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
      pending.complete({'plan': 'free'});
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
    pending.complete({'plan': 'free'});
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
    repo.plan = {'plan': 'free'};
    await pro.purchase();
    expect(repo.purchased, 0);
    expect(pro.hasPro, isTrue);
  });
  test(
    'checkout uncertainty still applies the independent manual grant',
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
      expect(repo.purchased, 0);
      expect(pro.hasPro, isTrue);
      expect(pro.message, contains('temporarily unavailable'));
      expect(repo.lastServerLifetime, isFalse);
      expect(pro.hasLifetime, isFalse);
    },
  );
  test(
    'backend disabled or older backend never opens a payment sheet',
    () async {
      repo.state = const ProStoreState(price: '99.000 ₫');
      repo.plan = {'plan': 'free'};
      auth.select('a');
      await Future<void>.delayed(Duration.zero);
      await pro.purchase();
      expect(repo.purchased, 0);
      expect(pro.purchasesReady, isFalse);
      expect(pro.message, contains('not available yet'));
    },
  );
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
  test('uncertain Free response cannot create a paid offline lease', () async {
    repo.state = const ProStoreState(price: '99.000 ₫');
    auth.select('a');
    await Future<void>.delayed(Duration.zero);
    repo.plan = {
      'plan': 'free',
      'apple_purchase_available': true,
      'purchase_verification_pending': true,
    };
    await pro.purchase();
    expect(pro.hasPro, isFalse);
    expect(repo.purchased, 0);
  });
}
