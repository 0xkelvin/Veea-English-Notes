import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/widget_service.dart';

/// Manages native Home Screen Widget and Daily Notification settings.
class WidgetProvider extends ChangeNotifier {
  static const String _widgetKey = 'widget_enabled';
  static const String _reminderKey = 'daily_reminder_enabled';
  static const String _rotationIntervalKey = 'widget_rotation_interval_minutes';
  static const String _rotateOnAppOpenKey = 'widget_rotate_on_app_open';
  static const String _pronounceOnTapKey = 'widget_pronounce_on_tap';

  bool _isWidgetEnabled = true;
  bool _isDailyReminderEnabled = true;
  int _rotationIntervalMinutes = 15;
  bool _rotateOnAppOpen = true;
  bool _pronounceOnTap = true;
  bool _isDisposed = false;

  bool get isWidgetEnabled => _isWidgetEnabled;
  bool get isDailyReminderEnabled => _isDailyReminderEnabled;
  int get rotationIntervalMinutes => _rotationIntervalMinutes;
  bool get rotateOnAppOpen => _rotateOnAppOpen;
  bool get pronounceOnTap => _pronounceOnTap;

  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _isWidgetEnabled = prefs.getBool(_widgetKey) ?? true;
      _isDailyReminderEnabled = prefs.getBool(_reminderKey) ?? true;
      _rotationIntervalMinutes = prefs.getInt(_rotationIntervalKey) ?? 15;
      _rotateOnAppOpen = prefs.getBool(_rotateOnAppOpenKey) ?? true;
      _pronounceOnTap = prefs.getBool(_pronounceOnTapKey) ?? true;

      // Sync native widget interval preference
      await WidgetService.setRotationInterval(_rotationIntervalMinutes);
      notifyListeners();
    } catch (error, stack) {
      debugPrint('Could not load widget preferences: $error\n$stack');
    }
  }

  Future<void> setWidgetEnabled(bool value) async {
    if (_isWidgetEnabled == value) return;
    _isWidgetEnabled = value;
    notifyListeners();

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_widgetKey, value);
      if (!value) {
        await WidgetService.clearWidgetData();
      }
    } catch (error, stack) {
      debugPrint('Could not save widget setting: $error\n$stack');
    }
  }

  Future<void> setDailyReminderEnabled(bool value) async {
    if (_isDailyReminderEnabled == value) return;
    _isDailyReminderEnabled = value;
    notifyListeners();

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_reminderKey, value);
    } catch (error, stack) {
      debugPrint('Could not save daily reminder setting: $error\n$stack');
    }
  }

  Future<void> setRotationIntervalMinutes(int value) async {
    if (_rotationIntervalMinutes == value) return;
    _rotationIntervalMinutes = value;
    notifyListeners();

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_rotationIntervalKey, value);
      await WidgetService.setRotationInterval(value);
    } catch (error, stack) {
      debugPrint('Could not save rotation interval setting: $error\n$stack');
    }
  }

  Future<void> setRotateOnAppOpen(bool value) async {
    if (_rotateOnAppOpen == value) return;
    _rotateOnAppOpen = value;
    notifyListeners();

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_rotateOnAppOpenKey, value);
    } catch (error, stack) {
      debugPrint('Could not save rotate-on-app-open setting: $error\n$stack');
    }
  }

  Future<void> setPronounceOnTap(bool value) async {
    if (_pronounceOnTap == value) return;
    _pronounceOnTap = value;
    notifyListeners();

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_pronounceOnTapKey, value);
    } catch (error, stack) {
      debugPrint('Could not save pronounce-on-tap setting: $error\n$stack');
    }
  }

  @override
  void notifyListeners() {
    if (_isDisposed) return;
    super.notifyListeners();
  }

  @override
  void dispose() {
    _isDisposed = true;
    super.dispose();
  }
}
