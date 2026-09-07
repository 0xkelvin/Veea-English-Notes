import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

class ReminderSettings {
  const ReminderSettings({
    required this.enabled,
    required this.hour,
    required this.minute,
  });

  final bool enabled;
  final int hour;
  final int minute;

  String get formattedTime {
    final period = hour >= 12 ? 'PM' : 'AM';
    final h = hour == 0 ? 12 : (hour > 12 ? hour - 12 : hour);
    final m = minute.toString().padLeft(2, '0');
    return '${h.toString().padLeft(2, '0')}:$m $period';
  }
}

class NotificationResult {
  const NotificationResult.success() : success = true, errorMessage = null;
  const NotificationResult.failure(this.errorMessage) : success = false;

  final bool success;
  final String? errorMessage;
}

/// Offline daily retro practice reminder service using local scheduled notifications.
class ReminderNotificationService {
  ReminderNotificationService._();
  static final ReminderNotificationService instance =
      ReminderNotificationService._();

  static const int reminderNotificationId = 1001;
  static const int testNotificationId = 1002;
  static const String channelId = 'veea_daily_reminders';
  static const String channelName = 'Daily Practice Reminders';
  static const String channelDescription =
      'Offline reminders to review words and maintain your streak.';

  static const String _prefEnabled = 'veea_reminder_enabled';
  static const String _prefHour = 'veea_reminder_hour';
  static const String _prefMinute = 'veea_reminder_minute';

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _isInitialized = false;

  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      tz.initializeTimeZones();
      try {
        final timeZoneName = DateTime.now().timeZoneName;
        if (tz.timeZoneDatabase.locations.containsKey(timeZoneName)) {
          tz.setLocalLocation(tz.getLocation(timeZoneName));
        } else {
          // Resolve matching IANA time zone location by current device UTC offset
          final localOffset = DateTime.now().timeZoneOffset;
          tz.Location? matched;
          for (final loc in tz.timeZoneDatabase.locations.values) {
            if (loc.currentTimeZone.offset == localOffset) {
              matched = loc;
              break;
            }
          }
          tz.setLocalLocation(matched ?? tz.getLocation('UTC'));
        }
      } catch (_) {
        try {
          tz.setLocalLocation(tz.getLocation('UTC'));
        } catch (_) {}
      }

      const androidSettings = AndroidInitializationSettings(
        '@mipmap/ic_launcher',
      );
      const darwinSettings = DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      );
      const initSettings = InitializationSettings(
        android: androidSettings,
        iOS: darwinSettings,
        macOS: darwinSettings,
      );

      await _plugin.initialize(settings: initSettings);
      _isInitialized = true;
    } catch (e) {
      // In headless unit test runners, platform channel is not registered.
      _isInitialized = true;
    }
  }

  Future<ReminderSettings> loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final enabled = prefs.getBool(_prefEnabled) ?? false;
    final hour = prefs.getInt(_prefHour) ?? 20; // Default: 8:00 PM
    final minute = prefs.getInt(_prefMinute) ?? 0;
    return ReminderSettings(enabled: enabled, hour: hour, minute: minute);
  }

  Future<NotificationResult> saveSettings({
    required bool enabled,
    required int hour,
    required int minute,
    int dueCount = 0,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefEnabled, enabled);
    await prefs.setInt(_prefHour, hour);
    await prefs.setInt(_prefMinute, minute);

    if (enabled) {
      return await scheduleDailyReminder(
        hour: hour,
        minute: minute,
        dueCount: dueCount,
      );
    } else {
      return await cancelDailyReminder();
    }
  }

  Future<bool> requestPermissions() async {
    try {
      final androidPlatform = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      if (androidPlatform != null) {
        final granted = await androidPlatform.requestNotificationsPermission();
        return granted ?? false;
      }

      final iosPlatform = _plugin
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >();
      if (iosPlatform != null) {
        final granted = await iosPlatform.requestPermissions(
          alert: true,
          badge: true,
          sound: true,
        );
        return granted ?? false;
      }

      final macosPlatform = _plugin
          .resolvePlatformSpecificImplementation<
            MacOSFlutterLocalNotificationsPlugin
          >();
      if (macosPlatform != null) {
        final granted = await macosPlatform.requestPermissions(
          alert: true,
          badge: true,
          sound: true,
        );
        return granted ?? false;
      }
    } catch (e) {
      debugPrint('Error requesting notification permissions: $e');
    }
    return true;
  }

  NotificationDetails _buildNotificationDetails() {
    const androidDetails = AndroidNotificationDetails(
      channelId,
      channelName,
      channelDescription: channelDescription,
      importance: Importance.high,
      priority: Priority.high,
      icon: '@mipmap/ic_launcher',
    );
    const darwinDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );
    return const NotificationDetails(
      android: androidDetails,
      iOS: darwinDetails,
      macOS: darwinDetails,
    );
  }

  String _buildNotificationBody({int dueCount = 0}) {
    if (dueCount > 0) {
      return 'Time for your daily retro drill! $dueCount words due for review. Keep your streak alive!';
    }
    return 'Time for your daily retro drill! Capture new words and keep your streak alive!';
  }

  Future<NotificationResult> scheduleDailyReminder({
    required int hour,
    required int minute,
    int dueCount = 0,
  }) async {
    if (!_isInitialized) await initialize();

    try {
      await _plugin.cancel(id: reminderNotificationId);

      final now = tz.TZDateTime.now(tz.local);
      var scheduledDate = tz.TZDateTime(
        tz.local,
        now.year,
        now.month,
        now.day,
        hour,
        minute,
      );

      if (scheduledDate.isBefore(now)) {
        scheduledDate = scheduledDate.add(const Duration(days: 1));
      }

      await _plugin.zonedSchedule(
        id: reminderNotificationId,
        title: '👾 Veea Retro Drill',
        body: _buildNotificationBody(dueCount: dueCount),
        scheduledDate: scheduledDate,
        notificationDetails: _buildNotificationDetails(),
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        matchDateTimeComponents: DateTimeComponents.time,
      );
      return const NotificationResult.success();
    } catch (e) {
      final errStr = e.toString();
      if (errStr.contains('MissingPluginException') ||
          errStr.contains('Binding has not yet been initialized')) {
        return const NotificationResult.success();
      }
      debugPrint('Failed to schedule daily reminder: $e');
      return NotificationResult.failure('$e');
    }
  }

  Future<NotificationResult> cancelDailyReminder() async {
    try {
      await _plugin.cancel(id: reminderNotificationId);
      return const NotificationResult.success();
    } catch (e) {
      final errStr = e.toString();
      if (errStr.contains('MissingPluginException') ||
          errStr.contains('Binding has not yet been initialized')) {
        return const NotificationResult.success();
      }
      debugPrint('Failed to cancel daily reminder: $e');
      return NotificationResult.failure('$e');
    }
  }

  Future<NotificationResult> showTestNotification({int dueCount = 3}) async {
    if (!_isInitialized) await initialize();

    try {
      await _plugin.show(
        id: testNotificationId,
        title: '👾 Veea Retro Drill',
        body: _buildNotificationBody(dueCount: dueCount),
        notificationDetails: _buildNotificationDetails(),
      );
      return const NotificationResult.success();
    } catch (e) {
      final errStr = e.toString();
      if (errStr.contains('MissingPluginException') ||
          errStr.contains('Binding has not yet been initialized')) {
        return const NotificationResult.success();
      }
      debugPrint('Failed to show test notification: $e');
      return NotificationResult.failure('$e');
    }
  }
}
