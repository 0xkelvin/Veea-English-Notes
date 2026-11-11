import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/native_gate_status.dart';

/// Screen Time names and icons stay inside Apple's private token renderer.
class NativeApplicationLabel extends StatelessWidget {
  const NativeApplicationLabel({super.key, required this.application});
  final NativeGateApplication application;

  @override
  Widget build(BuildContext context) {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) {
      return Text(
        application.label,
        style: Theme.of(context).textTheme.titleMedium,
      );
    }
    final dark = Theme.of(context).brightness == Brightness.dark;
    final scale = MediaQuery.textScalerOf(context).scale(17) / 17;
    return SizedBox(
      height: 52 * scale,
      child: UiKitView(
        key: ValueKey('${application.id}:$dark:$scale'),
        viewType: 'app.veea.english/application_label',
        creationParams: {
          'targetApp': application.id,
          'dark': dark,
          'textScale': scale,
        },
        creationParamsCodec: const StandardMessageCodec(),
      ),
    );
  }
}
