import 'package:flutter/material.dart';

import '../models/shortcut_setup.dart';
import '../providers/app_gate_provider.dart';
import '../providers/shortcut_setup_controller.dart';

/// A guided handoff, not a replica of Apple's permission screen.
class ShortcutSetupScreen extends StatefulWidget {
  const ShortcutSetupScreen({
    super.key,
    required this.gate,
    required this.template,
    required this.totalWords,
    this.controller,
  });

  final AppGateProvider gate;
  final ShortcutTemplate template;
  final int totalWords;
  final ShortcutSetupController? controller;

  @override
  State<ShortcutSetupScreen> createState() => _ShortcutSetupScreenState();
}

class _ShortcutSetupScreenState extends State<ShortcutSetupScreen>
    with WidgetsBindingObserver {
  late final ShortcutSetupController controller;
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    controller =
        widget.controller ??
        ShortcutSetupController(gate: widget.gate, template: widget.template);
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
    _scroll.dispose();
    if (widget.controller == null) controller.dispose();
    super.dispose();
  }

  Widget _card(BuildContext context, List<Widget> children) => Card(
    margin: EdgeInsets.zero,
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) const SizedBox(height: 14),
            children[i],
          ],
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final app = widget.template.app;
    final theme = Theme.of(context);
    final tested = controller.tested;
    final title = tested
        ? 'Your shortcut check works'
        : 'Learn before opening $app';
    return Scaffold(
      appBar: AppBar(title: Text('Protect $app')),
      body: SafeArea(
        top: false,
        child: SingleChildScrollView(
          controller: _scroll,
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                tested ? 'Test successful' : 'Every open',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(height: 12),
              Text(title, style: theme.textTheme.headlineSmall),
              const SizedBox(height: 12),
              Text(
                tested
                    ? 'Veea received the check for $app. Your Every Open setup is ready.'
                    : 'Everything is prepared. In Apple Shortcuts, turn on Automation and tap Add Shortcut.',
              ),
              const SizedBox(height: 24),
              _card(context, [
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    tested ? Icons.verified_outlined : Icons.layers_outlined,
                  ),
                  title: Text(widget.template.name),
                  subtitle: const Text('Every open · Your learning rules'),
                ),
                if (!tested) ...[
                  const ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.toggle_on_outlined),
                    title: Text('Turn on Automation → Add Shortcut'),
                    subtitle: Text('Apple asks you to approve this once.'),
                  ),
                  const Text('No actions to build or links to copy.'),
                  if (widget.gate.nativeStatus.enabled)
                    const Text(
                      'Continuing switches timed Screen Time protection to Every Open. Other apps need their own enabled shortcut.',
                    ),
                  if (controller.openedInstaller)
                    Text(
                      'After adding it, open $app from your iPhone’s Home Screen. Your vocabulary challenge should appear.',
                    ),
                  const Text(
                    'Already set up? Test your existing shortcut below. Keep only one enabled automation for this app.',
                  ),
                ],
                if (tested)
                  const Text(
                    'If you later change or disable the automation in Shortcuts, test it again here.',
                  ),
              ]),
              if (controller.error case final error?) ...[
                const SizedBox(height: 16),
                Text(
                  error,
                  style: TextStyle(color: theme.colorScheme.error),
                  semanticsLabel: error,
                ),
              ],
              const SizedBox(height: 28),
              if (tested) ...[
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Done'),
                ),
                TextButton(
                  onPressed: () {
                    controller.reviewSetup();
                    if (_scroll.hasClients) _scroll.jumpTo(0);
                  },
                  child: const Text('Review or test setup again'),
                ),
              ] else ...[
                FilledButton.icon(
                  onPressed: controller.busy
                      ? null
                      : () async {
                          await controller.addShortcut(
                            totalWords: widget.totalWords,
                          );
                        },
                  icon: Icon(
                    controller.busy ? Icons.hourglass_top : Icons.open_in_new,
                  ),
                  label: Text(
                    controller.busy
                        ? 'Preparing…'
                        : 'Set up in Apple Shortcuts',
                  ),
                ),
                TextButton.icon(
                  onPressed: controller.busy
                      ? null
                      : () => controller.test(totalWords: widget.totalWords),
                  icon: const Icon(Icons.play_arrow),
                  label: Text('Test: open $app'),
                ),
                if (controller.openedInstaller)
                  TextButton(
                    onPressed: controller.busy
                        ? null
                        : controller.openAutomation,
                    child: const Text('Need help? Open Shortcuts'),
                  ),
                if (controller.testing)
                  const Text(
                    'Not verified yet. If you cancelled import, try setup again. A successful check appears only after the shortcut runs.',
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
