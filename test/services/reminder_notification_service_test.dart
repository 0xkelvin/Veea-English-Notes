import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:veea_english_app/services/reminder_notification_service.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('ReminderSettings formats time correctly', () {
    const morning = ReminderSettings(enabled: true, hour: 9, minute: 5);
    expect(morning.formattedTime, '09:05 AM');

    const noon = ReminderSettings(enabled: true, hour: 12, minute: 0);
    expect(noon.formattedTime, '12:00 PM');

    const evening = ReminderSettings(enabled: true, hour: 20, minute: 30);
    expect(evening.formattedTime, '08:30 PM');

    const midnight = ReminderSettings(enabled: false, hour: 0, minute: 15);
    expect(midnight.formattedTime, '12:15 AM');
  });

  test(
    'ReminderNotificationService loads default and saves settings in SharedPreferences',
    () async {
      final service = ReminderNotificationService.instance;
      final defaults = await service.loadSettings();

      expect(defaults.enabled, isFalse);
      expect(defaults.hour, 20);
      expect(defaults.minute, 0);

      // Save custom settings
      await service.saveSettings(enabled: true, hour: 8, minute: 45);

      final updated = await service.loadSettings();
      expect(updated.enabled, isTrue);
      expect(updated.hour, 8);
      expect(updated.minute, 45);
      expect(updated.formattedTime, '08:45 AM');
    },
  );
}
