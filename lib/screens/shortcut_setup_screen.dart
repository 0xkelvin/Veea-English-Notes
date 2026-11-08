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
  int step = 0;
  final _scroll = ScrollController();

  void _showStep(int value) {
    setState(() => step = value);
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

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
        : [
            'Add the ready-made shortcut',
            'Enable it once',
            'Test protection',
          ][step];
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
                tested ? 'Test successful' : 'Step ${step + 1} of 3',
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
                    : [
                        'We’ve built the shortcut for $app. Add it in Apple Shortcuts; there is nothing to assemble.',
                        'In Shortcuts, open Automation and turn on “When $app is opened” for ${widget.template.name}. If you kept both copies, enable the newly added one and leave the old one off. Use Back to reach the Library if needed.',
                        'Open $app from your iPhone’s Home Screen. A vocabulary challenge should appear. Mirroring may not trigger app-open automations.',
                      ][step],
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
                if (!tested && step == 0) ...[
                  const Text(
                    'When the app opens → check Veea → learn to unlock.',
                  ),
                  const Text(
                    'Already have this shortcut? Use the existing copy. Keep only one app-open automation for the same app.',
                  ),
                ],
                if (!tested && step == 1) ...[
                  Text(
                    'When $app is opened',
                    style: theme.textTheme.titleMedium,
                  ),
                  const ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.toggle_on_outlined),
                    title: Text('Automation → On'),
                    subtitle: Text('Make this change in Apple Shortcuts.'),
                  ),
                  const Text(
                    'Allow opening Veea if Apple asks on the first run.',
                  ),
                ],
                if (!tested && step == 2) ...[
                  if (widget.gate.nativeStatus.enabled)
                    const Text(
                      'Testing turns off timed Screen Time protection. Only apps with enabled Shortcuts will use Every Open.',
                    ),
                  if (controller.testing) ...[
                    const Text('Waiting for the shortcut check…'),
                    const Text(
                      'If nothing happens, return to step 2 and check the Automation switch. Remove any older duplicate automation.',
                    ),
                  ] else
                    const Text(
                      'A successful test is recorded only after Veea’s shortcut action runs.',
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
                    _showStep(0);
                  },
                  child: const Text('Review or test setup again'),
                ),
              ] else ...[
                FilledButton.icon(
                  onPressed: controller.busy
                      ? null
                      : () async {
                          if (step == 0) {
                            if (await controller.addShortcut() && mounted) {
                              _showStep(1);
                            }
                          } else if (step == 1) {
                            await controller.openAutomation();
                          } else {
                            await controller.test(
                              totalWords: widget.totalWords,
                            );
                          }
                        },
                  icon: Icon(
                    controller.busy
                        ? Icons.hourglass_top
                        : step == 2
                        ? Icons.play_arrow
                        : Icons.open_in_new,
                  ),
                  label: Text(
                    controller.busy
                        ? 'Opening…'
                        : [
                            'Add shortcut',
                            'Open Apple Shortcuts',
                            'Test: open $app',
                          ][step],
                  ),
                ),
                if (step == 0)
                  TextButton(
                    onPressed: controller.busy ? null : () => _showStep(1),
                    child: const Text('I already have the shortcut'),
                  ),
                if (step == 1)
                  TextButton(
                    onPressed: controller.busy ? null : () => _showStep(2),
                    child: const Text('I’ve enabled it — test now'),
                  ),
                if (step > 0)
                  TextButton(
                    onPressed: controller.busy
                        ? null
                        : () => _showStep(step - 1),
                    child: const Text('Back a step'),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
