import 'package:flutter/material.dart';

import '../models/shortcut_setup.dart';
import '../providers/app_gate_provider.dart';
import '../screens/learning_rules_screen.dart';
import '../screens/shortcut_setup_screen.dart';
import 'native_gate_settings.dart';

class GuidedProtectionSettings extends StatefulWidget {
  const GuidedProtectionSettings({
    super.key,
    required this.gate,
    required this.totalWords,
    required this.onAddWord,
    required this.legacySettings,
  });
  final AppGateProvider gate;
  final int totalWords;
  final VoidCallback onAddWord;
  final Widget legacySettings;

  @override
  State<GuidedProtectionSettings> createState() =>
      _GuidedProtectionSettingsState();
}

class _GuidedProtectionSettingsState extends State<GuidedProtectionSettings>
    with WidgetsBindingObserver {
  bool? timed;
  ShortcutSetupStatus status = const ShortcutSetupStatus();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      final value = await widget.gate.service.getShortcutSetupStatus();
      if (mounted) setState(() => status = value);
    } catch (_) {}
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.gate,
    builder: (context, _) {
      final gate = widget.gate;
      final useTimed = timed ?? gate.nativeStatus.enabled;
      final theme = Theme.of(context);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Learn before you scroll', style: theme.textTheme.headlineSmall),
          const SizedBox(height: 12),
          const Text(
            'Choose when you want to practise. We’ll guide you through the setup.',
          ),
          const SizedBox(height: 20),
          DropdownButtonFormField<bool>(
            key: ValueKey(useTimed),
            initialValue: useTimed,
            decoration: const InputDecoration(labelText: 'When to practise'),
            isExpanded: true,
            items: const [
              DropdownMenuItem(
                value: false,
                child: Text('Every time I open an app'),
              ),
              DropdownMenuItem(
                value: true,
                child: Text('Earn 15 or 30 minutes of access'),
              ),
            ],
            onChanged: (value) => setState(() => timed = value),
          ),
          const SizedBox(height: 24),
          if (useTimed)
            NativeGateSettings(
              gate: gate,
              totalWords: widget.totalWords,
              onAddWord: widget.onAddWord,
            )
          else ...[
            if (gate.config.enabled && gate.config.passDurationMinutes > 0)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Text(
                  'Your existing shortcuts currently grant ${gate.config.passDurationMinutes} minutes of access. The Every Open setup changes this when you test it.',
                ),
              ),
            if (!gate.canEnable(widget.totalWords)) ...[
              const Text(
                'Save at least 3 words and choose your practice words before turning on protection.',
              ),
              TextButton(
                onPressed: widget.onAddWord,
                child: const Text('Add a word'),
              ),
            ],
            for (final template in ShortcutTemplate.available)
              Card(
                margin: const EdgeInsets.only(bottom: 12),
                child: ListTile(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 10,
                  ),
                  leading: const Icon(Icons.apps_outlined),
                  title: Text(template.app),
                  subtitle: Text(
                    gate.nativeStatus.enabled
                        ? 'Every Open setup · Timed protection is currently on'
                        : !gate.config.enabled ||
                              gate.config.passDurationMinutes != 0 ||
                              !gate.config.gatedApps.contains(template.app)
                        ? 'Set up Every Open'
                        : status.wasTested(template.app)
                        ? 'Every open · Test successful'
                        : 'Every open · Test setup',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () async {
                    await Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => ShortcutSetupScreen(
                          gate: gate,
                          template: template,
                          totalWords: widget.totalWords,
                        ),
                      ),
                    );
                    await _refresh();
                  },
                ),
              ),
            const Text(
              'Ready-made setup is available for X. Existing shortcuts for other apps can be managed below.',
            ),
          ],
          const SizedBox(height: 16),
          OutlinedButton.icon(
            icon: const Icon(Icons.school_outlined),
            label: Text(
              'Learning rules · ${gate.requiredWords} ${gate.requiredWords == 1 ? 'word' : 'words'}',
            ),
            onPressed: () async {
              await gate.prepareChallenge();
              if (!context.mounted) return;
              await Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => LearningRulesScreen(gate: gate),
                ),
              );
            },
          ),
          const SizedBox(height: 12),
          ExpansionTile(
            title: const Text('Manage existing shortcuts'),
            subtitle: const Text('Other apps and manual setup'),
            children: [widget.legacySettings],
          ),
        ],
      );
    },
  );
}
