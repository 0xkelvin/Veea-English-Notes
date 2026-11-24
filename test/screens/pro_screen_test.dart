import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:veea_english_app/core/config/app_config.dart';
import 'package:veea_english_app/providers/auth_provider.dart';
import 'package:veea_english_app/providers/pro_provider.dart';
import 'package:veea_english_app/screens/pro_screen.dart';
import '../providers/pro_provider_test.dart' show TestAuth, TestPro;

void main() {
  late TestAuth auth;
  late ProProvider pro;
  setUp(() {
    AppConfig.overrideFreeLaunch(false);
    AppConfig.overrideBaseUrl('http://localhost');
    auth = TestAuth();
    pro = ProProvider(auth: auth, repository: TestPro());
  });
  tearDown(() {
    AppConfig.overrideFreeLaunch(null);
    pro.dispose();
    auth.dispose();
    AppConfig.overrideBaseUrl(null);
    AppConfig.overrideAppleProduct(null);
  });
  Widget build({double scale = 1, Brightness brightness = Brightness.light}) =>
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AuthProvider>.value(value: auth),
          ChangeNotifierProvider.value(value: pro),
        ],
        child: MaterialApp(
          theme: ThemeData(brightness: brightness),
          builder: (_, child) => MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: const ProScreen(),
        ),
      );
  testWidgets('free release has no sales or account requirement', (
    tester,
  ) async {
    AppConfig.overrideFreeLaunch(null);
    await tester.pumpWidget(build());
    expect(find.text('Veea is free in this release.'), findsOneWidget);
    expect(
      find.textContaining('do not require a purchase or account'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('buy_pro')), findsNothing);
    expect(find.text('Sign in to get Pro'), findsNothing);
    expect(find.byKey(const Key('restore_pro')), findsNothing);
  });
  testWidgets('free release keeps earlier purchase restoration reachable', (
    tester,
  ) async {
    AppConfig.overrideFreeLaunch(null);
    AppConfig.overrideAppleProduct('app.test.pro');
    await tester.pumpWidget(build(scale: 2, brightness: Brightness.dark));
    await tester.scrollUntilVisible(find.byKey(const Key('restore_pro')), 200);
    expect(find.text('Restore previous purchases'), findsOneWidget);
    expect(find.byKey(const Key('buy_pro')), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'configured signed-out purchase asks for sign-in without a false outage',
    (tester) async {
      AppConfig.overrideAppleProduct('app.test.pro');
      await tester.pumpWidget(build());
      await tester.pumpAndSettle();
      expect(find.text('Sign in to get Pro'), findsOneWidget);
      expect(find.textContaining('not available in this build'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'clear free features and sign-in before purchase, without invented price',
    (tester) async {
      await tester.pumpWidget(build());
      expect(find.text('Pay once. No subscription.'), findsOneWidget);
      expect(find.text('Sign in to get Pro'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.byKey(const Key('restore_pro')),
        200,
      );
      expect(find.text('Restore purchases'), findsOneWidget);
      expect(
        find.textContaining('Your vocabulary stays on this device.'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('buy_pro')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'small screen with large text keeps restore reachable in dark mode',
    (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(build(scale: 2, brightness: Brightness.dark));
      await tester.scrollUntilVisible(
        find.byKey(const Key('restore_pro')),
        200,
      );
      expect(find.byKey(const Key('restore_pro')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
