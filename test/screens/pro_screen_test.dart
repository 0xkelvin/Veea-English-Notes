import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:veea_english_app/core/config/app_config.dart';
import 'package:veea_english_app/data/pro_repository.dart';
import 'package:veea_english_app/providers/auth_provider.dart';
import 'package:veea_english_app/providers/pro_provider.dart';
import 'package:veea_english_app/screens/pro_screen.dart';
import '../providers/pro_provider_test.dart' show TestAuth, TestPro;

class _TestMaterialLocalizations
    extends LocalizationsDelegate<MaterialLocalizations> {
  const _TestMaterialLocalizations();

  @override
  bool isSupported(Locale locale) => locale.languageCode == 'vi';

  @override
  Future<MaterialLocalizations> load(Locale locale) =>
      SynchronousFuture(const DefaultMaterialLocalizations());

  @override
  bool shouldReload(_TestMaterialLocalizations old) => false;
}

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
    Locale locale = const Locale('en'),
  }) => MultiProvider(
    providers: [
      ChangeNotifierProvider<AuthProvider>.value(value: auth),
      ChangeNotifierProvider.value(value: pro),
    ],
    child: MaterialApp(
      theme: ThemeData(brightness: brightness),
      builder: (context, child) => MediaQuery(
        data: MediaQueryData(
          textScaler: TextScaler.linear(scale),
          viewInsets: viewInsets,
        ),
        child: Localizations.override(
          context: context,
          locale: locale,
          delegates: const [_TestMaterialLocalizations()],
          child: child,
        ),
      ),
      home: home,
    ),
  );

  testWidgets(
    'guest sees educational offer, localized StoreKit price and restore',
    (tester) async {
      AppConfig.overrideAppleProduct('app.test.pro');
      repo.state = const ProStoreState(price: '99.000 ₫');
      await pro.refresh();
      await tester.pumpWidget(build());
      expect(find.text('Veea Pro Lifetime'), findsOneWidget);
      expect(find.textContaining('one-word Practice Round'), findsOneWidget);
      expect(find.textContaining('multiple protected apps'), findsNothing);
      expect(find.text('Get Pro · 99.000 ₫'), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.byKey(const Key('buy_pro'))).onPressed,
        isNotNull,
      );
      expect(
        tester
            .widget<OutlinedButton>(find.byKey(const Key('restore_pro')))
            .onPressed,
        isNotNull,
      );
    },
  );

  testWidgets('resolved Vietnamese locale controls paywall and purchase copy', (
    tester,
  ) async {
    tester.binding.platformDispatcher.localeTestValue = const Locale('en');
    addTearDown(tester.binding.platformDispatcher.clearLocaleTestValue);
    AppConfig.overrideAppleProduct('app.test.pro');
    repo.state = const ProStoreState(price: '99.000 ₫');
    repo.purchaseResult = const ProStoreState(
      price: '99.000 ₫',
      outcome: 'pending',
    );
    await pro.refresh();
    await tester.pumpWidget(build(locale: const Locale('vi')));
    expect(find.text('Veea Pro trọn đời'), findsOneWidget);
    expect(find.text('Mua Pro · 99.000 ₫'), findsOneWidget);
    expect(find.text('Khôi phục giao dịch'), findsOneWidget);
    await tester.tap(find.byKey(const Key('buy_pro')));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Đang chờ Apple phê duyệt. Quyền Pro sẽ được cập nhật sau khi phê duyệt.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('resolved English locale controls paywall and restore copy', (
    tester,
  ) async {
    tester.binding.platformDispatcher.localeTestValue = const Locale('vi');
    addTearDown(tester.binding.platformDispatcher.clearLocaleTestValue);
    repo.restoreError = PlatformException(
      code: 'INCOMPATIBLE_INSTALLATION',
      message: 'Không thể xác minh bản cài đặt.',
    );
    await tester.pumpWidget(build());
    expect(find.text('Veea Pro Lifetime'), findsOneWidget);
    expect(find.text('Restore Purchases'), findsOneWidget);
    expect(find.text('Veea Pro trọn đời'), findsNothing);
    await tester.tap(find.byKey(const Key('restore_pro')));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'The App Store could not verify this installation. Please try again or restore purchases.',
      ),
      findsOneWidget,
    );
    expect(find.text('Không thể xác minh bản cài đặt.'), findsNothing);
  });

  testWidgets('ProScreen.open refreshes product and entitlement on open', (
    tester,
  ) async {
    AppConfig.overrideAppleProduct('app.test.pro');
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
    final previousConfigurations = repo.configurations;
    final previousEntitlementReads = repo.entitlementReads;
    repo.state = const ProStoreState(price: '99.000 ₫');

    await tester.tap(find.text('Open Pro'));
    await tester.pumpAndSettle();

    expect(find.byType(ProScreen), findsOneWidget);
    expect(repo.configurations, greaterThan(previousConfigurations));
    expect(repo.entitlementReads, previousEntitlementReads + 1);
    expect(find.text('Get Pro · 99.000 ₫'), findsOneWidget);
  });

  testWidgets(
    'missing product price leaves checkout disabled and restore available',
    (tester) async {
      await tester.pumpWidget(build());
      expect(find.text('Purchase unavailable'), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.byKey(const Key('buy_pro'))).onPressed,
        isNull,
      );
      expect(
        tester
            .widget<OutlinedButton>(find.byKey(const Key('restore_pro')))
            .onPressed,
        isNotNull,
      );
    },
  );

  testWidgets('a verified local purchase hides duplicate checkout', (
    tester,
  ) async {
    repo.state = const ProStoreState(
      hasPro: true,
      hasLifetime: true,
      localApple: true,
    );
    await pro.refresh();
    await tester.pumpWidget(build());
    expect(find.text('Active · Apple purchase'), findsOneWidget);
    expect(find.byKey(const Key('buy_pro')), findsNothing);
    expect(find.byKey(const Key('restore_pro')), findsOneWidget);
  });

  testWidgets('dark compact paywall remains usable with large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(build(scale: 2, brightness: Brightness.dark));
    await tester.scrollUntilVisible(find.byKey(const Key('restore_pro')), 150);
    expect(find.byKey(const Key('restore_pro')).hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('missing Pro provider has harmless disabled actions', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: ProScreen()));
    expect(find.text('Veea Pro Lifetime'), findsOneWidget);
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const Key('restore_pro')))
          .onPressed,
      isNull,
    );
  });
}
