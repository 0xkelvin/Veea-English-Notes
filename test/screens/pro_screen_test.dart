import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:veea_english_app/core/config/app_config.dart';
import 'package:veea_english_app/data/pro_repository.dart';
import 'package:veea_english_app/providers/auth_provider.dart';
import 'package:veea_english_app/providers/pro_provider.dart';
import 'package:veea_english_app/screens/pro_screen.dart';
import '../providers/pro_provider_test.dart' show TestAuth, TestPro;

void main() {
  late TestAuth auth;
  late TestPro repo;
  late ProProvider pro;

  setUp(() {
    AppConfig.overrideFreeLaunch(null);
    AppConfig.overrideBaseUrl('http://localhost');
    AppConfig.overrideAppleProduct(null);
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

  Widget build({
    double scale = 1,
    Brightness brightness = Brightness.light,
    EdgeInsets viewInsets = EdgeInsets.zero,
    Widget home = const ProScreen(),
  }) => MultiProvider(
    providers: [
      ChangeNotifierProvider<AuthProvider>.value(value: auth),
      ChangeNotifierProvider.value(value: pro),
    ],
    child: MaterialApp(
      theme: ThemeData(brightness: brightness),
      builder: (_, child) => MediaQuery(
        data: MediaQueryData(
          textScaler: TextScaler.linear(scale),
          viewInsets: viewInsets,
        ),
        child: child!,
      ),
      home: home,
    ),
  );

  testWidgets(
    'explicit freeLaunch override has no sales or account requirement',
    (tester) async {
      AppConfig.overrideFreeLaunch(true);
      await tester.pumpWidget(build());
      expect(find.text('Veea is free in this release.'), findsOneWidget);
      expect(
        find.textContaining('do not require a purchase or account'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('buy_pro')), findsNothing);
      expect(find.text('Sign in to get Pro'), findsNothing);
      expect(find.byKey(const Key('restore_pro')), findsNothing);
    },
  );

  testWidgets(
    'explicit freeLaunch override keeps earlier purchase restoration reachable',
    (tester) async {
      AppConfig.overrideFreeLaunch(true);
      AppConfig.overrideAppleProduct('app.test.pro');
      await tester.pumpWidget(build(scale: 2, brightness: Brightness.dark));
      await tester.scrollUntilVisible(
        find.byKey(const Key('restore_pro')),
        200,
      );
      expect(find.text('Restore previous purchases'), findsOneWidget);
      expect(find.byKey(const Key('buy_pro')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'default release presents Free 1-app/1-word vs one-time Pro with exact two paid benefits and no invented price',
    (tester) async {
      expect(AppConfig.isFreeLaunch, isFalse);
      AppConfig.overrideAppleProduct('app.test.pro');
      await tester.pumpWidget(build());
      await tester.pumpAndSettle();

      expect(find.text('Pay once. No subscription.'), findsOneWidget);
      expect(find.text('Lock multiple apps'), findsOneWidget);
      expect(find.text('Multiple words per unlock'), findsOneWidget);
      expect(find.text('Always free'), findsOneWidget);
      expect(find.text('One app lock & all unlock times'), findsOneWidget);
      expect(
        find.textContaining('Lock one app with 1 word per unlock'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Unlimited saved words, dictionary lookup'),
        findsOneWidget,
      );
      expect(find.textContaining('99'), findsNothing);
      expect(find.textContaining('VND'), findsNothing);
      expect(find.textContaining('₫'), findsNothing);
      expect(find.byKey(const Key('pro_price_badge')), findsNothing);
      expect(find.textContaining('not available in this build'), findsNothing);

      await tester.scrollUntilVisible(
        find.textContaining('Your vocabulary stays on this device.'),
        200,
      );
      expect(
        find.textContaining('Your vocabulary stays on this device.'),
        findsOneWidget,
      );

      await tester.scrollUntilVisible(
        find.byKey(const Key('sign_in_for_pro')),
        200,
      );
      expect(find.text('Sign in to get Pro'), findsOneWidget);
      expect(find.byKey(const Key('buy_pro')), findsNothing);

      await tester.scrollUntilVisible(
        find.byKey(const Key('restore_pro')),
        200,
      );
      expect(find.text('Restore purchases'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'displays dynamic localized StoreKit price and reflects cancelled/pending outcomes without fabricating Pro',
    (tester) async {
      AppConfig.overrideAppleProduct('app.test.pro');
      repo.state = const ProStoreState(price: '99.000 ₫');
      auth.select('user-1');
      await tester.pumpWidget(build());
      await tester.pumpAndSettle();

      expect(find.text('99.000 ₫ · One-time purchase'), findsOneWidget);
      await tester.scrollUntilVisible(find.byKey(const Key('buy_pro')), 200);
      expect(find.text('Get lifetime Pro · 99.000 ₫'), findsOneWidget);

      // Update StoreKit localized price to another currency and verify dynamic rendering.
      repo.state = const ProStoreState(price: '\$3.99');
      await pro.refresh();
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const Key('pro_price_badge')),
        -200,
      );
      expect(find.text('\$3.99 · One-time purchase'), findsOneWidget);
      await tester.scrollUntilVisible(find.byKey(const Key('buy_pro')), 200);
      expect(find.text('Get lifetime Pro · \$3.99'), findsOneWidget);
      expect(find.textContaining('99.000'), findsNothing);

      // Cancelled purchase shows message and never fabricates Pro.
      repo.purchaseResult = const ProStoreState(
        price: '\$3.99',
        outcome: 'cancelled',
      );
      await tester.tap(find.byKey(const Key('buy_pro')));
      await tester.pumpAndSettle();
      expect(pro.hasPro, isFalse);
      expect(find.byKey(const Key('pro_message')), findsOneWidget);
      expect(find.textContaining('Purchase cancelled'), findsOneWidget);

      // Pending approval shows message and never fabricates Pro.
      repo.purchaseResult = const ProStoreState(
        price: '\$3.99',
        outcome: 'pending',
      );
      await tester.scrollUntilVisible(find.byKey(const Key('buy_pro')), 200);
      await tester.tap(find.byKey(const Key('buy_pro')));
      await tester.pumpAndSettle();
      expect(pro.hasPro, isFalse);
      expect(find.textContaining('Waiting for Apple approval'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'missing StoreKit price disables purchase without inventing 99k price',
    (tester) async {
      AppConfig.overrideAppleProduct('app.test.pro');
      repo.state = const ProStoreState(price: null);
      auth.select('user-1');
      await tester.pumpWidget(build());
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('pro_price_badge')), findsNothing);
      await tester.scrollUntilVisible(find.byKey(const Key('buy_pro')), 200);
      final buyButton = tester.widget<FilledButton>(
        find.byKey(const Key('buy_pro')),
      );
      expect(buyButton.onPressed, isNull);
      expect(find.text('Purchase unavailable'), findsOneWidget);
      expect(find.textContaining('99'), findsNothing);
      expect(find.textContaining('VND'), findsNothing);
      expect(find.textContaining('₫'), findsNothing);
    },
  );

  testWidgets(
    'offline owned lifetime Pro stays active without duplicate purchase button',
    (tester) async {
      AppConfig.overrideAppleProduct('app.test.pro');
      repo.state = const ProStoreState(
        hasPro: true,
        hasLifetime: true,
        price: '99.000 ₫',
        transactions: ['tx-1'],
      );
      repo.offline = true;
      auth.select('user-1');
      await tester.pumpWidget(build());
      await tester.pumpAndSettle();

      expect(find.text('You have Veea Pro'), findsOneWidget);
      expect(find.byKey(const Key('buy_pro')), findsNothing);
      expect(find.byKey(const Key('sign_in_for_pro')), findsNothing);
      await tester.scrollUntilVisible(
        find.byKey(const Key('pro_message')),
        200,
      );
      expect(
        find.textContaining('Pro is available on this device.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('ProScreen.open refreshes product and entitlement on open', (
    tester,
  ) async {
    AppConfig.overrideAppleProduct('app.test.pro');
    repo.state = const ProStoreState(price: '99.000 ₫');
    auth.select('user-1');
    await tester.pumpWidget(
      build(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => ProScreen.open(context),
              child: const Text('Open Pro'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    repo.configurations = 0;

    await tester.tap(find.text('Open Pro'));
    await tester.pumpAndSettle();

    expect(find.byType(ProScreen), findsOneWidget);
    expect(repo.configurations, greaterThanOrEqualTo(1));
    await tester.scrollUntilVisible(find.byKey(const Key('buy_pro')), 200);
    expect(find.text('Get lifetime Pro · 99.000 ₫'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('missing ProProvider fallback renders cleanly without crashing', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: ProScreen()));
    await tester.pumpAndSettle();

    expect(find.text('Veea Pro'), findsOneWidget);
    expect(find.text('Lock multiple apps'), findsOneWidget);
    expect(find.text('Multiple words per unlock'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const Key('pro_unavailable_notice')),
      200,
    );
    expect(find.byKey(const Key('pro_unavailable_notice')), findsOneWidget);
    expect(find.byKey(const Key('buy_pro')), findsNothing);
    expect(find.byKey(const Key('restore_pro')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'small 320px dark screen with 200% text scale and keyboard insets keeps restore reachable without overflow',
    (tester) async {
      AppConfig.overrideAppleProduct('app.test.pro');
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        build(
          scale: 2,
          brightness: Brightness.dark,
          viewInsets: const EdgeInsets.only(bottom: 200),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const Key('restore_pro')),
        120,
      );
      expect(find.byKey(const Key('restore_pro')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
