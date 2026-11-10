import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../models/protection_duration.dart';

Future<int?> showProtectionDurationPicker(BuildContext context, int minutes) =>
    showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _DurationSheet(minutes: minutes),
    );

class _DurationSheet extends StatefulWidget {
  const _DurationSheet({required this.minutes});
  final int minutes;
  @override
  State<_DurationSheet> createState() => _DurationSheetState();
}

class _DurationSheetState extends State<_DurationSheet> {
  late int hours;
  late int minutes;
  late final FixedExtentScrollController _hours;
  @override
  void initState() {
    super.initState();
    final initial = widget.minutes.clamp(
      ProtectionDuration.minimumMinutes,
      ProtectionDuration.maximumMinutes,
    );
    hours = initial ~/ 60;
    minutes = initial % 60;
    _hours = FixedExtentScrollController(initialItem: hours);
  }

  @override
  void dispose() {
    _hours.dispose();
    super.dispose();
  }

  int get total => hours * 60 + minutes;
  @override
  Widget build(BuildContext context) {
    final minimum = hours == 0 ? ProtectionDuration.minimumMinutes : 0;
    final count = hours == 24 ? 1 : 60 - minimum;
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Access duration',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            const Text(
              'How long each app stays unlocked after a challenge. From 5 minutes to 24 hours.',
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: Column(
                    children: [
                      const Text('Hours'),
                      SizedBox(
                        height: 190,
                        child: CupertinoPicker(
                          scrollController: _hours,
                          itemExtent: 44,
                          onSelectedItemChanged: (value) => setState(() {
                            hours = value;
                            minutes = hours == 24
                                ? 0
                                : hours == 0
                                ? minutes.clamp(
                                    ProtectionDuration.minimumMinutes,
                                    59,
                                  )
                                : minutes;
                          }),
                          children: [
                            for (var i = 0; i <= 24; i++)
                              Center(
                                child: Text(
                                  '$i',
                                  semanticsLabel:
                                      '$i ${i == 1 ? 'hour' : 'hours'}',
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Column(
                    children: [
                      const Text('Minutes'),
                      _MinuteWheel(
                        key: ValueKey(
                          hours == 0
                              ? 'minimum'
                              : hours == 24
                              ? 'maximum'
                              : 'normal',
                        ),
                        minimum: minimum,
                        count: count,
                        selected: minutes,
                        onChanged: (value) => setState(() => minutes = value),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(ProtectionDuration.label(total), textAlign: TextAlign.center),
            const SizedBox(height: 8),
            const Text(
              'Applies to your next unlock. Access already earned keeps its original end time.',
            ),
            const SizedBox(height: 16),
            FilledButton(
              key: const Key('save_protection_duration'),
              onPressed: () => Navigator.pop(context, total),
              child: const Text('Save duration'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
          ],
        ),
      ),
    );
  }
}

class _MinuteWheel extends StatefulWidget {
  const _MinuteWheel({
    super.key,
    required this.minimum,
    required this.count,
    required this.selected,
    required this.onChanged,
  });
  final int minimum, count, selected;
  final ValueChanged<int> onChanged;
  @override
  State<_MinuteWheel> createState() => _MinuteWheelState();
}

class _MinuteWheelState extends State<_MinuteWheel> {
  late final FixedExtentScrollController controller =
      FixedExtentScrollController(
        initialItem: widget.selected - widget.minimum,
      );
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 190,
    child: CupertinoPicker(
      scrollController: controller,
      itemExtent: 44,
      onSelectedItemChanged: (index) =>
          widget.onChanged(index + widget.minimum),
      children: [
        for (var i = 0; i < widget.count; i++)
          Center(
            child: Text(
              '${i + widget.minimum}',
              semanticsLabel:
                  '${i + widget.minimum} ${i + widget.minimum == 1 ? 'minute' : 'minutes'}',
            ),
          ),
      ],
    ),
  );
}
