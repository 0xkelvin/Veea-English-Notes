import 'package:flutter/material.dart';

import '../providers/app_gate_provider.dart';
import '../providers/universal_shortcut_controller.dart';

class UniversalShortcutSetupScreen extends StatefulWidget {
  const UniversalShortcutSetupScreen({
    super.key,
    required this.gate,
    required this.totalWords,
    this.controller,
  });
  final AppGateProvider gate;
  final int totalWords;
  final UniversalShortcutController? controller;
  // Candidate is available only in the opt-in test flow until device verification.
  static const installLink = String.fromEnvironment(
    'VEEA_UNIVERSAL_SHORTCUT_URL',
    defaultValue:
        'https://www.icloud.com/shortcuts/4b6b6b0d88d9402fa8f050a334bc2d76',
  );
  @override
  State<UniversalShortcutSetupScreen> createState() =>
      _UniversalShortcutSetupScreenState();
}

class _UniversalShortcutSetupScreenState
    extends State<UniversalShortcutSetupScreen>
    with WidgetsBindingObserver {
  late final UniversalShortcutController controller;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    controller =
        widget.controller ??
        UniversalShortcutController(
          gate: widget.gate,
          installUrl: Uri.parse(UniversalShortcutSetupScreen.installLink),
        );
    controller.addListener(_changed);
    controller.refresh();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) controller.refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    controller.removeListener(_changed);
    if (widget.controller == null) controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Choose apps to protect')),
    body: SafeArea(
      top: false,
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            'Learn before you scroll',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 12),
          const Text(
            'Choose your first app in Apple’s setup screen. The shortcut actions are prepared for you.',
          ),
          const SizedBox(height: 20),
          const Card(
            child: Padding(
              padding: EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('1. Choose your first app'),
                  SizedBox(height: 12),
                  Text('2. Turn on Automation'),
                  SizedBox(height: 12),
                  Text('3. Tap Add Shortcut'),
                ],
              ),
            ),
          ),
          if (widget.gate.nativeStatus.enabled)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text(
                'Continuing switches timed Screen Time protection to Every Open.',
              ),
            ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: controller.busy
                ? null
                : () => controller.setup(widget.totalWords),
            icon: const Icon(Icons.open_in_new),
            label: Text(
              controller.busy ? 'Preparing…' : 'Choose apps in Apple Shortcuts',
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'To add more apps, open Veea App Gate in Shortcuts → Edit, then tap + beside the app in the automation. Repeat for each app. Turn off older Veea automations for those same apps. Do not choose Veea or Shortcuts.',
          ),
          if (controller.error case final message?)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text(
                message,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (controller.openedInstaller || controller.status.enabled) ...[
            const SizedBox(height: 24),
            Text(
              'Check your setup',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            const Text(
              'On your iPhone, open each chosen app and finish a challenge. You should return to that same app. Repeat from Home to check Every Open.',
            ),
            const SizedBox(height: 12),
            const Text(
              'Apple keeps the selection in Shortcuts. Apps appear here after their first opening; this is not your complete selection.',
            ),
            for (final app in controller.status.apps)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  app.verifiedAt == null
                      ? Icons.pending_outlined
                      : Icons.check_circle_outline,
                ),
                title: Text(app.name),
                subtitle: Text(
                  app.verifiedAt == null
                      ? 'Return not verified yet'
                      : 'Last challenge and return verified',
                ),
              ),
            TextButton(
              onPressed: controller.manage,
              child: const Text('Change selected apps in Shortcuts'),
            ),
            TextButton(
              onPressed: controller.refresh,
              child: const Text('Refresh check'),
            ),
            TextButton(
              onPressed: controller.busy ? null : controller.turnOff,
              child: const Text('Turn off Every Open'),
            ),
          ],
        ],
      ),
    ),
  );
}
