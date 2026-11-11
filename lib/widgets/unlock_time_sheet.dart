import 'package:flutter/material.dart';
import '../models/protection_duration.dart';
import 'protection_duration_picker.dart';

class UnlockTimeChoice {
  const UnlockTimeChoice(this.minutes);

  /// Null restores default inheritance; a null choice means cancellation.
  final int? minutes;
}

Future<UnlockTimeChoice?> showUnlockTimeSheet(
  BuildContext context, {
  required int currentMinutes,
  int? defaultMinutes,
  bool usesDefault = false,
  Widget? applicationLabel,
}) async {
  final selection = await showModalBottomSheet<int>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (applicationLabel != null) ...[
              applicationLabel,
              const SizedBox(height: 12),
            ],
            Text(
              defaultMinutes == null ? 'Default unlock time' : 'Unlock time',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            if (defaultMinutes != null)
              ListTile(
                selected: usesDefault,
                title: const Text('Use default'),
                subtitle: Text(ProtectionDuration.label(defaultMinutes)),
                trailing: usesDefault ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(context, 0),
              ),
            for (final minutes in [5, 15, 30])
              ListTile(
                selected: !usesDefault && currentMinutes == minutes,
                title: Text('$minutes minutes'),
                trailing: !usesDefault && currentMinutes == minutes
                    ? const Icon(Icons.check)
                    : null,
                onTap: () => Navigator.pop(context, minutes),
              ),
            ListTile(
              selected: !usesDefault && ![5, 15, 30].contains(currentMinutes),
              title: const Text('Custom time'),
              subtitle: Text(
                !usesDefault && ![5, 15, 30].contains(currentMinutes)
                    ? ProtectionDuration.label(currentMinutes)
                    : 'Choose hours and minutes',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.pop(context, -1),
            ),
            const SizedBox(height: 12),
            Text(
              defaultMinutes == null
                  ? 'Used for apps without a custom time. Changes apply to the next unlock; current timers keep running.'
                  : 'Applies only to this app’s next unlock. Current timers keep running.',
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
          ],
        ),
      ),
    ),
  );
  if (selection == null || !context.mounted) return null;
  if (selection == 0) return const UnlockTimeChoice(null);
  if (selection != -1) return UnlockTimeChoice(selection);
  final minutes = await showProtectionDurationPicker(
    context,
    currentMinutes,
    header: applicationLabel,
  );
  return minutes == null ? null : UnlockTimeChoice(minutes);
}
