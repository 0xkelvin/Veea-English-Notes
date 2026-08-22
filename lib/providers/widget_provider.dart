import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Manages native Home Screen Widget and Daily Notification settings.
class WidgetProvider extends ChangeNotifier {
  static const String _widgetKey = 'widget_enabled';
  static const String _reminderKey = 'daily_reminder_enabled';

  bool _isWidgetEnabled = true;
  bool _isDailyReminderEnabled = true;
  bool _isDisposed = false;

  bool get isWidgetEnabled => _isWidgetEnabled;
  bool get isDailyReminderEnabled => _isDailyReminderEnabled;

  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _isWidgetEnabled = prefs.getBool(_widgetKey) ?? true;
      _isDailyReminderEnabled = prefs.getBool(_reminderKey) ?? true;
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
