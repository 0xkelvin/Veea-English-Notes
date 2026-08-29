import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:veea_english_app/providers/widget_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('default settings are loaded when no preferences exist', () async {
    final provider = WidgetProvider();
    await provider.init();

    expect(provider.isWidgetEnabled, isTrue);
    expect(provider.isDailyReminderEnabled, isTrue);
    expect(provider.rotationIntervalMinutes, equals(15));
    expect(provider.rotateOnAppOpen, isTrue);
    expect(provider.pronounceOnTap, isTrue);
  });

  test('loads existing preferences from SharedPreferences', () async {
    SharedPreferences.setMockInitialValues({
      'widget_enabled': false,
      'daily_reminder_enabled': false,
      'widget_rotation_interval_minutes': 30,
      'widget_rotate_on_app_open': false,
      'widget_pronounce_on_tap': false,
    });

    final provider = WidgetProvider();
    await provider.init();

    expect(provider.isWidgetEnabled, isFalse);
    expect(provider.isDailyReminderEnabled, isFalse);
    expect(provider.rotationIntervalMinutes, equals(30));
    expect(provider.rotateOnAppOpen, isFalse);
    expect(provider.pronounceOnTap, isFalse);
  });

  test('updating rotation interval saves to SharedPreferences and notifies', () async {
    final provider = WidgetProvider();
    await provider.init();

    var notified = false;
    provider.addListener(() => notified = true);

    await provider.setRotationIntervalMinutes(60);

    expect(provider.rotationIntervalMinutes, equals(60));
    expect(notified, isTrue);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('widget_rotation_interval_minutes'), equals(60));
  });

  test('updating rotateOnAppOpen saves to SharedPreferences and notifies', () async {
    final provider = WidgetProvider();
    await provider.init();

    var notified = false;
    provider.addListener(() => notified = true);

    await provider.setRotateOnAppOpen(false);

    expect(provider.rotateOnAppOpen, isFalse);
    expect(notified, isTrue);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('widget_rotate_on_app_open'), isFalse);
  });

  test('updating pronounceOnTap saves to SharedPreferences and notifies', () async {
    final provider = WidgetProvider();
    await provider.init();

    var notified = false;
    provider.addListener(() => notified = true);

    await provider.setPronounceOnTap(false);

    expect(provider.pronounceOnTap, isFalse);
    expect(notified, isTrue);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('widget_pronounce_on_tap'), isFalse);
  });

  test('disabling widget saves to SharedPreferences and notifies', () async {
    final provider = WidgetProvider();
    await provider.init();

    var notified = false;
    provider.addListener(() => notified = true);

    await provider.setWidgetEnabled(false);

    expect(provider.isWidgetEnabled, isFalse);
    expect(notified, isTrue);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('widget_enabled'), isFalse);
  });
}
