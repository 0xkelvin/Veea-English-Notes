import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:veea_english_app/core/config/app_config.dart';
import 'package:veea_english_app/core/theme/pixel_theme.dart';
import 'package:veea_english_app/data/pro_repository.dart';
import 'package:veea_english_app/providers/auth_provider.dart';
import 'package:veea_english_app/providers/pro_provider.dart';
import 'package:veea_english_app/screens/pro_screen.dart';
import '../providers/pro_provider_test.dart' show TestAuth, TestPro;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const captureDir = String.fromEnvironment('VEEA_UX_CAPTURE_DIR');
  const fontPath = String.fromEnvironment('VEEA_UX_FONT');
  const iconFontPath = String.fromEnvironment('VEEA_UX_ICON_FONT');
  late TestAuth auth;
  late TestPro store;
  late ProProvider pro;

  setUpAll(() async {
    for (final font in [
      ('SF Pro Text', fontPath),
      ('MaterialIcons', iconFontPath),
    ]) {
      if (font.$2.isEmpty) continue;
      await (FontLoader(font.$1)
            ..addFont(File(font.$2).readAsBytes().then(ByteData.sublistView)))
          .load();
    }
  });
  setUp(() {
    AppConfig.overrideFreeLaunch(null);
    AppConfig.overrideBaseUrl('http://localhost');
    AppConfig.overrideAppleProduct('app.test.pro');
    auth = TestAuth()..select('synthetic-layout-owner');
    store = TestPro();
    pro = ProProvider(auth: auth, repository: store);
  });
  tearDown(() {
    pro.dispose();
    auth.dispose();
    AppConfig.overrideFreeLaunch(null);
    AppConfig.overrideBaseUrl(null);
    AppConfig.overrideAppleProduct(null);
  });
  Future<void> capture(WidgetTester tester, String name) async {
    if (captureDir.isEmpty) return;
    await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const Key('offer_capture')),
      );
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('$captureDir/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  for (final variant in [
    (
      name: 'offer_phone',
      size: const Size(390, 844),
      scale: 1.0,
      dark: false,
      paid: false,
    ),
    (
      name: 'offer_large_text',
      size: const Size(320, 568),
      scale: 2.0,
      dark: false,
      paid: false,
    ),
    (
      name: 'offer_dark',
      size: const Size(390, 844),
      scale: 1.0,
      dark: true,
      paid: false,
    ),
    (
      name: 'owned_phone',
      size: const Size(390, 844),
      scale: 1.0,
      dark: false,
      paid: true,
    ),
  ]) {
    testWidgets(
      '${variant.name} shows clear offer and reachable purchase recovery',
      (tester) async {
        store.state = ProStoreState(
          hasPro: variant.paid,
          hasLifetime: variant.paid,
          price: '99.000 ₫',
          transactions: variant.paid ? ['synthetic-layout-proof'] : const [],
        );
        await pro.refresh();
        tester.view.physicalSize = variant.size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          RepaintBoundary(
            key: const Key('offer_capture'),
            child: MultiProvider(
              providers: [
                ChangeNotifierProvider<AuthProvider>.value(value: auth),
                ChangeNotifierProvider.value(value: pro),
              ],
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: variant.dark ? PixelTheme.dark() : PixelTheme.light(),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(variant.scale)),
                  child: child!,
                ),
                home: const ProScreen(),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await capture(tester, variant.name);
        if (!variant.paid) {
          final buy = find.byKey(const Key('buy_pro'));
          await tester.scrollUntilVisible(buy, 180);
          await Scrollable.ensureVisible(tester.element(buy), alignment: 0.5);
          await tester.pumpAndSettle();
          expect(buy.hitTestable(), findsOneWidget);
          expect(tester.widget<FilledButton>(buy).onPressed, isNotNull);
          expect(find.text('Get lifetime Pro · 99.000 ₫'), findsOneWidget);
        } else {
          expect(find.byKey(const Key('buy_pro')), findsNothing);
        }
        final restore = find.byKey(const Key('restore_pro'));
        await tester.scrollUntilVisible(restore, 180);
        await Scrollable.ensureVisible(tester.element(restore), alignment: 0.5);
        await tester.pumpAndSettle();
        expect(restore.hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
        await capture(tester, '${variant.name}_actions');
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
