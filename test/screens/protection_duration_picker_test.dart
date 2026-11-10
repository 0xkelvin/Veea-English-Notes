import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:veea_english_app/core/theme/pixel_theme.dart';
import 'package:veea_english_app/models/protection_duration.dart';
import 'package:veea_english_app/widgets/protection_duration_picker.dart';

void main() {
  test('launch duration bounds and labels', () {
    for (final valid in [5, 6, 14, 15, 16, 59, 60, 90, 1439, 1440]) {
      expect(ProtectionDuration.isValid(valid), isTrue);
    }
    for (final invalid in [-1, 0, 4, 1441, 10080]) {
      expect(ProtectionDuration.isValid(invalid), isFalse);
    }
    expect(ProtectionDuration.label(5), '5 min');
    expect(ProtectionDuration.label(15), '15 min');
    expect(ProtectionDuration.label(60), '1 hour');
    expect(ProtectionDuration.label(90), '1 hr 30 min');
    expect(ProtectionDuration.label(1440), '24 hours');
  });

  Future<void> open(
    WidgetTester tester,
    int initial,
    ValueChanged<int?> result, {
    double scale = 1,
    bool dark = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: dark ? PixelTheme.dark() : PixelTheme.light(),
        builder: (_, child) => MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async =>
                  result(await showProtectionDurationPicker(context, initial)),
              child: const Text('Choose duration'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Choose duration'));
    await tester.pumpAndSettle();
  }

  testWidgets('save starts at minimum; cancel does not change the setting', (
    tester,
  ) async {
    int? result;
    await open(tester, 5, (value) => result = value);
    expect(find.text('5 min'), findsOneWidget);
    await tester.tap(find.byKey(const Key('save_protection_duration')));
    await tester.pumpAndSettle();
    expect(result, 5);
    await open(tester, 90, (value) => result = value);
    expect(find.text('1 hr 30 min'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(result, isNull);
  });

  testWidgets(
    'hour and minute wheels clamp both boundaries and save exact duration',
    (tester) async {
      int? result;
      await open(tester, 90, (value) => result = value);
      final hours = tester
          .widget<CupertinoPicker>(find.byType(CupertinoPicker).first)
          .scrollController!;
      hours.jumpToItem(24);
      await tester.pumpAndSettle();
      expect(find.text('24 hours'), findsOneWidget);
      expect(
        tester
            .widget<CupertinoPicker>(find.byType(CupertinoPicker).last)
            .childDelegate
            .estimatedChildCount,
        1,
      );
      hours.jumpToItem(0);
      await tester.pumpAndSettle();
      expect(find.text('5 min'), findsOneWidget);
      final minutes = tester
          .widget<CupertinoPicker>(find.byType(CupertinoPicker).last)
          .scrollController!;
      minutes.jumpToItem(40); // 5 + 40 = 45; zero-hour wheel excludes 0–4.
      await tester.pumpAndSettle();
      hours.jumpToItem(2);
      await tester.pumpAndSettle();
      expect(find.text('2 hr 45 min'), findsOneWidget);
      await tester.tap(find.byKey(const Key('save_protection_duration')));
      await tester.pumpAndSettle();
      expect(result, 165);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('small screen with large text can reach Save in dark mode', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await open(tester, 1440, (_) {}, scale: 2, dark: true);
    await tester.ensureVisible(
      find.byKey(const Key('save_protection_duration')),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const Key('save_protection_duration')));
    await tester.pumpAndSettle();
    expect(find.text('Choose duration'), findsOneWidget);
  });
}
