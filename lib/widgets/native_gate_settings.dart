import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/gate_config.dart';
import '../models/native_gate_status.dart';
import '../models/protection_duration.dart';
import '../providers/app_gate_provider.dart';
import '../screens/app_gate_screen.dart';
import 'native_application_label.dart';
import 'pixel/pixel_box.dart';
import 'unlock_time_sheet.dart';

class NativeGateSettings extends StatefulWidget {
  const NativeGateSettings({
    super.key,
    required this.gate,
    required this.totalWords,
    this.onAddWord,
  });
  final AppGateProvider gate;
  final int totalWords;
  final VoidCallback? onAddWord;

  @override
  State<NativeGateSettings> createState() => _NativeGateSettingsState();
}

class _NativeGateSettingsState extends State<NativeGateSettings> {
  AppGateProvider get gate => widget.gate;
  int get totalWords => widget.totalWords;
  VoidCallback? get onAddWord => widget.onAddWord;
  Timer? _expiryTimer;

  @override
  void initState() {
    super.initState();
    gate.addListener(_scheduleExpiryRefresh);
    _scheduleExpiryRefresh();
  }

  @override
  void didUpdateWidget(covariant NativeGateSettings oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.gate != gate) {
      oldWidget.gate.removeListener(_scheduleExpiryRefresh);
      gate.addListener(_scheduleExpiryRefresh);
    }
    _scheduleExpiryRefresh();
  }

  void _scheduleExpiryRefresh() {
    _expiryTimer?.cancel();
    if (!gate.nativeStatus.enabled) return;
    final expiries =
        gate.nativeStatus.applications
            .map((app) => app.unlockedUntil)
            .whereType<DateTime>()
            .where((expiry) => expiry.isAfter(gate.now))
            .toList()
          ..sort();
    if (expiries.isEmpty) return;
    _expiryTimer = Timer(
      expiries.first.difference(gate.now) + const Duration(milliseconds: 50),
      () {
        if (mounted && !gate.nativeBusy) {
          unawaited(gate.refreshNativeScreenTime());
        }
      },
    );
  }

  @override
  void dispose() {
    gate.removeListener(_scheduleExpiryRefresh);
    _expiryTimer?.cancel();
    super.dispose();
  }

  void _reportFailure(BuildContext context, bool success) {
    if (success || !context.mounted || gate.nativeError == null) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(gate.nativeError!)));
  }

  Future<void> _runAction(
    BuildContext context,
    Future<bool> Function() action,
  ) async {
    final success = await action();
    if (context.mounted) _reportFailure(context, success);
  }

  Future<void> _editDuration(
    BuildContext context, [
    NativeGateApplication? app,
  ]) async {
    final status = gate.nativeStatus;
    final choice = await showUnlockTimeSheet(
      context,
      currentMinutes: app == null
          ? status.passMinutes
          : status.durationFor(app.id),
      defaultMinutes: app == null ? null : status.passMinutes,
      usesDefault: app != null && app.customPassMinutes == null,
      applicationLabel: app == null
          ? null
          : NativeApplicationLabel(application: app),
    );
    if (choice == null) return;
    final success = app == null
        ? await gate.setNativeDuration(choice.minutes!)
        : await gate.setNativeApplicationDuration(app.id, choice.minutes);
    if (context.mounted) _reportFailure(context, success);
  }

  Future<void> _remove(BuildContext context, NativeGateApplication app) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('Remove this app?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            NativeApplicationLabel(application: app),
            const SizedBox(height: 12),
            const Text(
              'Veea will stop locking this app. You can add it again at any time.',
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Remove app'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      final success = await gate.removeNativeApplication(app.id);
      if (context.mounted) _reportFailure(context, success);
    }
  }

  Future<void> _learn(BuildContext context, String target) async {
    try {
      await gate.prepareChallenge();
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not load your words. Please try again.'),
          ),
        );
      }
      return;
    }
    if (!context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChangeNotifierProvider.value(
          value: gate,
          child: AppGateScreen(targetApp: target, openedFromVeea: true),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: gate,
    builder: (context, _) {
      final status = gate.nativeStatus;
      final busy = gate.nativeBusy;
      final theme = Theme.of(context);
      final secondary = theme.colorScheme.onSurfaceVariant;
      final canEnable = gate.canEnable(totalWords);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Choose your apps and how long each stays unlocked after reviewing your words.',
          ),
          const SizedBox(height: 20),
          if (!status.available)
            const _SettingsCard(
              child: Text(
                'Screen Time protection is not available in this build. You can still save and review your vocabulary.',
              ),
            )
          else ...[
            FilledButton.icon(
              key: const Key('add_locked_apps'),
              icon: const Icon(Icons.add),
              label: Text(busy ? 'Updating…' : 'Add Apps'),
              onPressed: busy
                  ? null
                  : () => _runAction(context, gate.chooseNativeApplications),
            ),
            const SizedBox(height: 20),
            _SettingsCard(
              padding: EdgeInsets.zero,
              child: ListTile(
                key: const Key('default_unlock_time'),
                leading: Icon(
                  Icons.timer_outlined,
                  color: theme.colorScheme.primary,
                ),
                title: const Text('Default unlock time'),
                subtitle: Text(ProtectionDuration.label(status.passMinutes)),
                trailing: const Icon(Icons.chevron_right),
                onTap: busy ? null : () => _editDuration(context),
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'Your apps · ${status.applications.length}',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'Apps use the default time unless you choose a different one below.',
              style: TextStyle(color: secondary),
            ),
            const SizedBox(height: 12),
            if (status.applications.isEmpty)
              const _SettingsCard(
                child: Text(
                  'No apps selected. Tap Add Apps to choose which apps Veea will lock.',
                ),
              ),
            for (final app in status.applications) ...[
              Semantics(
                container: true,
                explicitChildNodes: true,
                child: _SettingsCard(
                  key: ValueKey('locked_app_${app.id}'),
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      LayoutBuilder(
                        builder: (context, constraints) {
                          final label = NativeApplicationLabel(
                            application: app,
                          );
                          final remove = Tooltip(
                            message: 'Remove this app from locking',
                            child: TextButton.icon(
                              icon: const Icon(
                                Icons.remove_circle_outline,
                                size: 20,
                              ),
                              label: const Text('Remove'),
                              style: TextButton.styleFrom(
                                foregroundColor: theme.colorScheme.error,
                              ),
                              onPressed: busy
                                  ? null
                                  : () => _remove(context, app),
                            ),
                          );
                          if (constraints.maxWidth < 300 ||
                              MediaQuery.textScalerOf(context).scale(16) > 24) {
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [label, remove],
                            );
                          }
                          return Row(
                            children: [
                              Expanded(child: label),
                              const SizedBox(width: 8),
                              remove,
                            ],
                          );
                        },
                      ),
                      if (!app.lockEnabled)
                        Text(
                          'Locking paused · Enable this app in Settings',
                          style: theme.textTheme.bodySmall,
                        ),
                      const Divider(height: 24),
                      LayoutBuilder(
                        builder: (context, constraints) {
                          final value =
                              '${app.customPassMinutes == null ? 'Default · ' : ''}${ProtectionDuration.label(status.durationFor(app.id))}';
                          final inline =
                              constraints.maxWidth >= 300 &&
                              MediaQuery.textScalerOf(context).scale(16) <= 21;
                          return ListTile(
                            key: ValueKey('unlock_time_${app.id}'),
                            contentPadding: EdgeInsets.zero,
                            title: const Text('Unlock time'),
                            subtitle: inline ? null : Text(value),
                            trailing: inline
                                ? Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        value,
                                        style: theme.textTheme.bodyMedium
                                            ?.copyWith(color: secondary),
                                      ),
                                      const SizedBox(width: 8),
                                      const Icon(Icons.chevron_right),
                                    ],
                                  )
                                : const Icon(Icons.chevron_right),
                            onTap: busy
                                ? null
                                : () => _editDuration(context, app),
                          );
                        },
                      ),
                      if (status.enabled &&
                          app.lockEnabled &&
                          app.unlockedUntil?.isAfter(gate.now) == true)
                        Text(
                          'Unlocked until ${DateUtils.isSameDay(gate.now, app.unlockedUntil) ? '' : '${MaterialLocalizations.of(context).formatShortDate(app.unlockedUntil!)} · '}${MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(app.unlockedUntil!))}',
                          style: TextStyle(color: secondary),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
            ],
            const SizedBox(height: 8),
            if (status.configured && !status.authorized) ...[
              const Text(
                'Screen Time access was removed. Your apps are not locked. Restore access to turn locking back on.',
              ),
              TextButton(
                onPressed: busy || !canEnable
                    ? null
                    : () => _runAction(
                        context,
                        () =>
                            gate.enableNativeProtection(totalWords: totalWords),
                      ),
                child: const Text('Restore Screen Time access'),
              ),
              TextButton(
                onPressed: busy
                    ? null
                    : () => _runAction(context, gate.disableNativeProtection),
                child: const Text('Turn off app locking'),
              ),
            ],
            if (!canEnable) ...[
              Text(
                totalWords < GateConfig.minRequiredWords
                    ? 'Save at least ${GateConfig.minRequiredWords} words before turning on app locking ($totalWords/${GateConfig.minRequiredWords} saved).'
                    : 'Choose at least one practice word in Learning rules before turning on app locking.',
              ),
              if (onAddWord != null && totalWords < GateConfig.minRequiredWords)
                TextButton(
                  onPressed: onAddWord,
                  child: const Text('Add a word'),
                ),
            ],
            _SettingsCard(
              padding: EdgeInsets.zero,
              child: SwitchListTile.adaptive(
                title: const Text('Lock selected apps'),
                subtitle: Text(
                  status.enabled
                      ? 'Each app locks again when its own timer ends.'
                      : 'Off · Turn on when you’re ready to earn screen time.',
                ),
                value: status.enabled,
                onChanged:
                    busy ||
                        (!status.enabled &&
                            (!canEnable || status.applications.isEmpty))
                    ? null
                    : (enabled) {
                        if (enabled) {
                          _runAction(
                            context,
                            () => gate.enableNativeProtection(
                              totalWords: totalWords,
                            ),
                          );
                        } else {
                          _runAction(context, gate.disableNativeProtection);
                        }
                      },
              ),
            ),
            if (status.enabled &&
                status.applications.any((app) => app.lockEnabled))
              TextButton.icon(
                icon: const Icon(Icons.school_outlined),
                label: const Text('Review to unlock an app'),
                onPressed: busy
                    ? null
                    : () async {
                        final target = await gate.manageNativeApplications();
                        if (target == null &&
                            gate.nativeError != null &&
                            context.mounted) {
                          _reportFailure(context, false);
                        }
                        if (target != null && context.mounted) {
                          await _learn(context, target);
                        }
                      },
              ),
            const SizedBox(height: 12),
            Text(
              'Timers keep running when you close Veea. Changing a duration applies to the next unlock.',
              style: TextStyle(color: secondary),
            ),
          ],
          if (status.error != null) ...[
            const SizedBox(height: 12),
            Text(
              status.error!,
              style: TextStyle(color: theme.colorScheme.error),
            ),
            TextButton(
              onPressed: busy
                  ? null
                  : () => _runAction(context, gate.disableNativeProtection),
              child: const Text('Reset protection'),
            ),
          ],
          if (gate.nativeError != null) ...[
            const SizedBox(height: 12),
            Text(
              gate.nativeError!,
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ],
        ],
      );
    },
  );
}

class _SettingsCard extends StatelessWidget {
  const _SettingsCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(12),
  });
  final Widget child;
  final EdgeInsetsGeometry padding;
  @override
  Widget build(BuildContext context) => PixelBox(
    padding: padding,
    child: Material(
      type: MaterialType.transparency,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: child,
    ),
  );
}
