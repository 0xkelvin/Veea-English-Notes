import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/config/app_config.dart';
import '../models/gate_config.dart';
import '../models/native_gate_status.dart';
import '../providers/app_gate_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/pro_provider.dart';
import '../screens/pro_screen.dart';
import 'native_application_label.dart';
import 'pixel/pixel_box.dart';

/// Settings overview; app selection and time rules live on the management page.
class AppLocksSettingsSection extends StatelessWidget {
  const AppLocksSettingsSection({
    super.key,
    required this.gate,
    required this.totalWords,
    required this.onManage,
  });
  final AppGateProvider? gate;
  final int totalWords;
  final VoidCallback onManage;

  bool _hasProSupport(BuildContext context) {
    try {
      context.read<ProProvider>();
      context.read<AuthProvider>();
      return true;
    } on ProviderNotFoundException {
      return false;
    }
  }

  ProProvider? _maybeWatchPro(BuildContext context) {
    try {
      return context.watch<ProProvider>();
    } on ProviderNotFoundException {
      return null;
    }
  }

  Future<void> _run(
    BuildContext context,
    Future<bool> operation, {
    bool allowProRedirect = true,
  }) async {
    final success = await operation;
    final error = gate?.nativeError;
    if (!success &&
        allowProRedirect &&
        gate?.nativeRequiresPro == true &&
        !AppConfig.isFreeLaunch &&
        context.mounted) {
      if (_hasProSupport(context)) {
        await ProScreen.open(context);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              error ?? 'Upgrade to Veea Pro to lock multiple apps.',
            ),
          ),
        );
      }
      return;
    }
    if (!success && error != null && context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error)));
    }
  }

  String _summary(NativeGateStatus status) {
    if (!status.available) {
      return status.supported
          ? 'Unavailable in this build'
          : 'Available on iPhone';
    }
    if (status.applications.isEmpty) return 'No apps added';
    if (!status.authorized) return 'Screen Time access needed';
    final count = status.enabledApplicationCount;
    if (count == 0) {
      return 'All locks off';
    }
    if (status.allLocksEnabled) return 'All apps protected';
    return '$count of ${status.applications.length} locks on';
  }

  @override
  Widget build(BuildContext context) {
    final activeGate = gate;
    if (activeGate == null) {
      return _content(context, const NativeGateStatus(), false);
    }
    return AnimatedBuilder(
      animation: activeGate,
      builder: (context, _) =>
          _content(context, activeGate.nativeStatus, activeGate.nativeBusy),
    );
  }

  Widget _content(BuildContext context, NativeGateStatus status, bool busy) {
    final theme = Theme.of(context);
    final pro = _maybeWatchPro(context);
    final isFreePausedMulti =
        !AppConfig.isFreeLaunch &&
        pro != null &&
        !pro.hasPro &&
        status.applications.length > 1 &&
        status.enabledApplicationCount < status.applications.length;
    final canEnable = gate?.canEnable(totalWords) ?? false;
    final canToggle =
        gate != null &&
        status.available &&
        status.applications.isNotEmpty &&
        !busy &&
        (status.allLocksEnabled || canEnable);
    final needsWords = status.applications.isNotEmpty && !canEnable;
    final subtitle = needsWords && status.enabledApplicationCount == 0
        ? totalWords < GateConfig.minRequiredWords
              ? 'Save ${GateConfig.minRequiredWords} words to enable locks'
              : 'Choose practice words in Learning rules'
        : _summary(status);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text('App locks', style: theme.textTheme.titleMedium),
        ),
        _LockCard(
          child: SwitchListTile.adaptive(
            key: const Key('settings_enable_locks'),
            secondary: Icon(
              status.allLocksEnabled ? Icons.lock : Icons.lock_outline,
              color: status.allLocksEnabled
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurfaceVariant,
            ),
            title: const Text('Enable locks'),
            subtitle: Text(subtitle),
            value: status.allLocksEnabled,
            onChanged: canToggle
                ? (enabled) => _run(
                    context,
                    enabled
                        ? gate!.enableNativeProtection(totalWords: totalWords)
                        : gate!.disableNativeProtection(),
                    allowProRedirect: enabled,
                  )
                : null,
          ),
        ),
        if (status.enabledApplicationCount > 0 && !status.allLocksEnabled)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              key: const Key('settings_turn_off_all_locks'),
              icon: const Icon(Icons.lock_open_outlined),
              label: const Text('Turn off all locks'),
              onPressed: busy
                  ? null
                  : () => _run(
                      context,
                      gate!.disableNativeProtection(),
                      allowProRedirect: false,
                    ),
            ),
          ),
        const SizedBox(height: 12),
        if (status.applications.isEmpty)
          const _LockCard(
            child: ListTile(
              leading: Icon(Icons.apps_outlined),
              title: Text('No locks yet'),
              subtitle: Text('Choose an app to get started.'),
            ),
          )
        else
          _LockCard(
            child: Column(
              children: [
                for (var i = 0; i < status.applications.length; i++) ...[
                  if (i > 0)
                    const Divider(height: 1, indent: 16, endIndent: 16),
                  Semantics(
                    container: true,
                    explicitChildNodes: true,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: NativeApplicationLabel(
                              application: status.applications[i],
                            ),
                          ),
                          const SizedBox(width: 12),
                          Semantics(
                            label: 'Lock ${status.applications[i].label}',
                            child: Switch.adaptive(
                              key: ValueKey(
                                'settings_app_lock_${status.applications[i].id}',
                              ),
                              value: status.applications[i].lockEnabled,
                              onChanged:
                                  !busy &&
                                      status.authorized &&
                                      status.available &&
                                      (status.applications[i].lockEnabled ||
                                          canEnable)
                                  ? (enabled) => _run(
                                      context,
                                      gate!.setNativeApplicationLocked(
                                        status.applications[i].id,
                                        enabled,
                                      ),
                                      allowProRedirect: enabled,
                                    )
                                  : null,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        if (isFreePausedMulti) ...[
          const SizedBox(height: 8),
          Text(
            'Free locks 1 app at a time. Turn off an active lock to switch apps, or upgrade to Pro to lock multiple apps.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
        const SizedBox(height: 12),
        _LockCard(
          child: ListTile(
            key: const Key('settings_app_protection'),
            leading: Icon(Icons.tune, color: theme.colorScheme.primary),
            title: const Text('Manage Apps to Lock'),
            subtitle: const Text('Add, remove, and set unlock times'),
            trailing: const Icon(Icons.chevron_right),
            onTap: onManage,
          ),
        ),
        if (status.error != null) ...[
          const SizedBox(height: 8),
          Text(status.error!, style: TextStyle(color: theme.colorScheme.error)),
        ],
      ],
    );
  }
}

class _LockCard extends StatelessWidget {
  const _LockCard({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => PixelBox(
    padding: EdgeInsets.zero,
    child: Material(
      type: MaterialType.transparency,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: child,
    ),
  );
}
