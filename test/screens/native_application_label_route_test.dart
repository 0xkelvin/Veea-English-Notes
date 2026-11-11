import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:veea_english_app/models/native_gate_status.dart';
import 'package:veea_english_app/widgets/native_application_label.dart';
import 'package:veea_english_app/widgets/unlock_time_sheet.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'only the current route owns native app labels, including custom time',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final active = <int, String>{};
      const channel = MethodChannel('flutter/platform_views');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'create') {
              final args = call.arguments as Map;
              expect(args['viewType'], 'app.veea.english/application_label');
              final params =
                  const StandardMessageCodec().decodeMessage(
                        ByteData.sublistView(args['params'] as Uint8List),
                      )
                      as Map;
              active[args['id'] as int] = params['targetApp'] as String;
            } else if (call.method == 'dispose') {
              active.remove(call.arguments as int);
            }
            return null;
          });
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });
      final nav = GlobalKey<NavigatorState>();
      const settingsApp = NativeGateApplication(
        id: 'settings-app',
        label: 'Settings app',
      );
      const freeform = NativeGateApplication(id: 'freeform', label: 'Freeform');
      const playground = NativeGateApplication(
        id: 'playground',
        label: 'Playground',
      );
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: nav,
          navigatorObservers: [nativeApplicationLabelObserver],
          home: const Scaffold(
            body: NativeApplicationLabel(application: settingsApp),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(active.values, ['settings-app']);
      nav.currentState!.push<void>(
        MaterialPageRoute(
          builder: (_) => const Scaffold(
            body: NativeApplicationLabel(application: freeform),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(active.values, ['freeform']);

      for (final app in [freeform, playground, freeform]) {
        final pageContext = tester.element(
          find.byType(NativeApplicationLabel).last,
        );
        final result = showUnlockTimeSheet(
          pageContext,
          currentMinutes: 15,
          defaultMinutes: 15,
          usesDefault: true,
          applicationLabel: NativeApplicationLabel(application: app),
        );
        await tester.pumpAndSettle();
        expect(active.values, [app.id]);
        expect(find.byType(UiKitView), findsOneWidget);
        await tester.tap(find.text('Custom time'));
        await tester.pump();
        // No underlying Freeform/Settings label may return during the old
        // sheet's reverse transition while the custom sheet is opening.
        expect(active.values.every((id) => id == app.id), isTrue);
        await tester.pump(const Duration(milliseconds: 50));
        expect(active.values.every((id) => id == app.id), isTrue);
        await tester.pumpAndSettle();
        expect(active.values, [app.id]);
        expect(find.byType(UiKitView), findsOneWidget);
        await tester.tap(find.text('Cancel'));
        await tester.pump();
        expect(active, isEmpty);
        await tester.pump(const Duration(milliseconds: 50));
        expect(active, isEmpty);
        await tester.pumpAndSettle();
        expect(await result, isNull);
        expect(active.values, ['freeform']);
      }
      nav.currentState!.pop();
      await tester.pumpAndSettle();
      expect(active.values, ['settings-app']);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(active, isEmpty);
      expect(tester.takeException(), isNull);
      debugDefaultTargetPlatformOverride = null;
    },
  );
}
