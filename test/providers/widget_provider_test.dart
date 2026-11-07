import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:veea_english_app/models/vocabulary_word.dart';
import 'package:veea_english_app/providers/widget_provider.dart';
import 'package:veea_english_app/services/tts_service.dart';
import 'package:veea_english_app/services/widget_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'paused widgets stay disabled even with legacy enabled preferences',
    () async {
      SharedPreferences.setMockInitialValues({
        'widget_enabled': true,
        'widget_rotation_interval_minutes': 30,
        'widget_rotate_on_tap': true,
      });
      final provider = WidgetProvider();
      await provider.init();
      expect(provider.isWidgetEnabled, isFalse);
      expect(provider.rotateOnTap, isFalse);
      expect(await WidgetService.isWidgetEnabled(), isFalse);
      expect(provider.rotationIntervalMinutes, 30);
      var notified = false;
      provider.addListener(() => notified = true);
      await provider.setWidgetEnabled(false);
      await provider.setWidgetEnabled(true);
      await provider.setRotationIntervalMinutes(60);
      await provider.setRotateOnTap(false);
      expect(notified, isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('widget_enabled'), isTrue);
      expect(prefs.getInt('widget_rotation_interval_minutes'), 30);
      expect(prefs.getBool('widget_rotate_on_tap'), isTrue);
      provider.dispose();
    },
  );

  test(
    'widget pause does not disable or overwrite daily reminder settings',
    () async {
      final provider = WidgetProvider();
      await provider.init();
      expect(provider.isWidgetEnabled, isFalse);
      expect(provider.isDailyReminderEnabled, isTrue);
      var notified = false;
      provider.addListener(() => notified = true);
      await provider.setDailyReminderEnabled(false);
      expect(provider.isDailyReminderEnabled, isFalse);
      expect(notified, isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('daily_reminder_enabled'), isFalse);
      provider.dispose();
    },
  );

  test(
    'widget sync, interval, reads and taps never call the native bridge while paused',
    () async {
      final calls = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(const MethodChannel('home_widget'), (
        call,
      ) async {
        calls.add(call);
        return null;
      });
      messenger.setMockMethodCallHandler(
        const MethodChannel('flutter_tts'),
        (call) async => 1,
      );
      addTearDown(() {
        messenger.setMockMethodCallHandler(
          const MethodChannel('home_widget'),
          null,
        );
        messenger.setMockMethodCallHandler(
          const MethodChannel('flutter_tts'),
          null,
        );
      });
      final provider = WidgetProvider();
      final tts = TtsService();
      await provider.init();
      final word = VocabularyWord.create(
        id: 'a',
        word: 'resilient',
        meaning: 'Strong',
        date: '2026-11-07',
        now: DateTime(2026, 11, 7),
      );
      await WidgetService.setRotationInterval(15);
      await WidgetService.updateWidgetWords(words: [word], streakDays: 1);
      await WidgetService.updateWidgetData(word: word, streakDays: 1);
      await WidgetService.clearWidgetData();
      await WidgetService.rotateToNextWord();
      expect(await WidgetService.getCurrentWidgetWord(), isNull);
      await WidgetService.handleWidgetClick(
        widgetProvider: provider,
        ttsService: tts,
      );
      await WidgetService.processWidgetTap(widgetProvider: provider);
      expect(calls, isEmpty);
      tts.dispose();
      provider.dispose();
    },
  );
}
