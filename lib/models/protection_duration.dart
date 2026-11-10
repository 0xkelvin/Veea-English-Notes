/// Launch policy for the exact interval-end DeviceActivity relock schedule.
abstract final class ProtectionDuration {
  static const minimumMinutes = 5;
  static const maximumMinutes = 24 * 60;

  static bool isValid(int minutes) =>
      minutes >= minimumMinutes && minutes <= maximumMinutes;

  static String label(int minutes) {
    final hours = minutes ~/ 60;
    final remainder = minutes % 60;
    if (hours == 0) return '$remainder min';
    if (remainder == 0) return '$hours ${hours == 1 ? 'hour' : 'hours'}';
    return '$hours hr $remainder min';
  }
}
