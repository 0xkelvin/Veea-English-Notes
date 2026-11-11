import 'package:flutter/material.dart';
import '../providers/app_gate_provider.dart';
import '../screens/learning_rules_screen.dart';
import 'native_gate_settings.dart';

/// First-launch protection is exclusively native Screen Time with timed access.
class GuidedProtectionSettings extends StatelessWidget {
  const GuidedProtectionSettings({
    super.key,
    required this.gate,
    required this.totalWords,
    required this.onAddWord,
    this.legacySettings,
    this.enableUniversalSetup = false,
  });
  final AppGateProvider gate;
  final int totalWords;
  final VoidCallback onAddWord;
  // Compatibility parameters for older callers; never rendered or executed.
  final Widget? legacySettings;
  final bool enableUniversalSetup;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (!gate.nativeStatus.supported)
        const Text(
          'App protection is available on iPhone. You can still save and review your vocabulary here.',
        ),
      if (gate.nativeStatus.supported)
        NativeGateSettings(
          gate: gate,
          totalWords: totalWords,
          onAddWord: onAddWord,
        ),
      const SizedBox(height: 16),
      OutlinedButton.icon(
        icon: const Icon(Icons.school_outlined),
        label: const Text('Learning rules'),
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => LearningRulesScreen(gate: gate),
          ),
        ),
      ),
    ],
  );
}
