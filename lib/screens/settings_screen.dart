import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../core/config/app_config.dart';
import '../core/theme/pixel_metrics.dart';
import '../core/theme/pixel_palette.dart';
import '../models/account_identifier.dart';
import '../providers/auth_provider.dart';
import '../providers/cartridge_provider.dart';
import '../providers/theme_provider.dart';
import '../providers/vocabulary_provider.dart';
import '../providers/widget_provider.dart';
import '../services/sync_service.dart';
import '../widgets/pixel/pixel_badges_grid.dart';
import '../widgets/pixel/pixel_box.dart';
import '../widgets/pixel/pixel_button.dart';
import '../widgets/pixel/pixel_field.dart';
import '../widgets/pixel/pixel_heatmap.dart';
import '../widgets/pixel/pixel_icon.dart';
import 'cartridge_library_screen.dart';

/// Unified Settings, Appearance, Stats, and Cloud Sync screen.
///
/// Designed to work 100% offline without requiring internet or a backend
/// connection. Local themes, widget preferences, and gamification stats are
/// fully functional immediately.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _identifier = TextEditingController();
  final _password = TextEditingController();
  bool _registering = false;

  @override
  void initState() {
    super.initState();
    // Refresh cloud session and sync status gracefully in the background.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (AppConfig.isCloudEnabled) {
        context.read<SyncService>().refreshPendingCount();
        context.read<AuthProvider>().loadProfile();
      }
    });
  }

  @override
  void dispose() {
    _identifier.dispose();
    _password.dispose();
    super.dispose();
  }

  AccountIdentifier get _parsed => AccountIdentifier.parse(_identifier.text);

  bool get _canSubmit => _parsed.isValid && _password.text.length >= 8;

  Future<void> _submit() async {
    final auth = context.read<AuthProvider>();
    final sync = context.read<SyncService>();
    final value = _parsed.value;

    final ok = _registering
        ? await auth.register(identifier: value, password: _password.text)
        : await auth.signIn(identifier: value, password: _password.text);

    if (!ok || !mounted) return;
    _password.clear();

    await sync.resetCursor();
    await sync.synchronise();
    if (mounted) await context.read<VocabularyProvider>().init();
  }

  Future<void> _syncNow() async {
    await context.read<SyncService>().synchronise();
    if (mounted) await context.read<VocabularyProvider>().init();
  }

  Future<void> _signOut() async {
    await context.read<AuthProvider>().signOut();
    if (mounted) await context.read<SyncService>().refreshPendingCount();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final provider = context.watch<VocabularyProvider>();
    final gamification = provider.gamificationStats;

    return Scaffold(
      backgroundColor: palette.paper,
      body: SafeArea(
        child: Column(
          children: [
            _TopBar(onClose: () => Navigator.of(context).pop()),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(PixelMetrics.space4),
                children: [
                  if (!AppConfig.isCloudEnabled)
                    const _Notice(
                      lines: [
                        'THIS BUILD RUNS IN FULLY LOCAL STORAGE MODE.',
                        'EVERYTHING IS STORED SAFELY ON THIS DEVICE.',
                      ],
                    )
                  else ...[
                    const _SyncStatus(),
                    const SizedBox(height: PixelMetrics.space5),
                    Consumer<AuthProvider>(
                      builder: (context, auth, _) {
                        if (auth.lastMessage != null) {
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _Notice(
                                lines: [auth.lastMessage!.toUpperCase()],
                                tone: palette.accent,
                              ),
                              const SizedBox(height: PixelMetrics.space5),
                              if (auth.isSignedIn)
                                _SignedIn(
                                  onSyncNow: _syncNow,
                                  onSignOut: _signOut,
                                )
                              else
                                _buildAuthForm(auth),
                            ],
                          );
                        }
                        return auth.isSignedIn
                            ? _SignedIn(
                                onSyncNow: _syncNow,
                                onSignOut: _signOut,
                              )
                            : _buildAuthForm(auth);
                      },
                    ),
                  ],
                  const SizedBox(height: PixelMetrics.space5),

                  // Activity Consistency Heatmap
                  PixelHeatmap(
                    dailyCounts: gamification.dailyCounts,
                    weeks: 16,
                  ),
                  const SizedBox(height: PixelMetrics.space5),

                  // Retro Milestones & Badges
                  PixelBadgesGrid(badges: gamification.badges),
                  const SizedBox(height: PixelMetrics.space5),

                  // Career DLC Cartridges Library
                  const _CartridgeLibrarySection(),
                  const SizedBox(height: PixelMetrics.space5),

                  // Theme Appearance
                  const _ThemePickerSection(),
                  const SizedBox(height: PixelMetrics.space5),

                  // Widget & Lock Screen Settings
                  const _WidgetSettingsSection(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAuthForm(AuthProvider auth) {
    final palette = context.palette;
    final parsed = _parsed;
    final showIdentifierError =
        _identifier.text.trim().isNotEmpty && parsed.error != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _registering ? 'CREATE AN ACCOUNT' : 'SIGN IN TO SYNC',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: PixelMetrics.space2),
        Text(
          'Your notes work completely offline without an account. '
          'Signing in keeps them on every device you use.',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: PixelMetrics.space4),
        PixelField(
          controller: _identifier,
          label: parsed.kindLabel,
          hint: 'you@example.com or +84901234567',
          textInputAction: TextInputAction.next,
          onChanged: (_) => setState(() {}),
        ),
          if (showIdentifierError) ...[
            const SizedBox(height: PixelMetrics.space1),
            Text(
              parsed.error!.toUpperCase(),
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(color: palette.danger),
            ),
          ],
          const SizedBox(height: PixelMetrics.space3),
          PixelField(
            controller: _password,
            label: 'Password',
            hint: 'at least 8 characters',
            obscure: true,
            onChanged: (_) => setState(() {}),
          ),
          if (auth.lastError != null) ...[
            const SizedBox(height: PixelMetrics.space2),
            Text(
              auth.lastError!.toUpperCase(),
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(color: palette.danger),
            ),
          ],
          const SizedBox(height: PixelMetrics.space4),
          PixelButton(
            label: auth.isBusy
                ? 'Working…'
                : (_registering ? 'Create account' : 'Sign in'),
            filled: true,
            expand: true,
            onPressed: _canSubmit && !auth.isBusy ? _submit : null,
          ),
          const SizedBox(height: PixelMetrics.space2),
          PixelButton(
            label: _registering
                ? 'I already have an account'
                : 'Create one instead',
            expand: true,
            onPressed: () {
              auth.consumeError();
              setState(() => _registering = !_registering);
            },
          ),
        ],
      );
  }
}

/// Backward compatibility alias.
typedef AccountScreen = SettingsScreen;

class _TopBar extends StatelessWidget {
  const _TopBar({required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    return Container(
      padding: const EdgeInsets.fromLTRB(
        PixelMetrics.space4,
        PixelMetrics.space2,
        PixelMetrics.space2,
        PixelMetrics.space2,
      ),
      decoration: BoxDecoration(
        color: palette.surface,
        border: Border(
          bottom: BorderSide(color: palette.border, width: PixelMetrics.border),
        ),
      ),
      child: Row(
        children: [
          Text('SETTINGS', style: Theme.of(context).textTheme.titleMedium),
          const Spacer(),
          PixelIconButton(
            glyph: PixelGlyph.close,
            semanticLabel: 'Close settings',
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}

class _SignedIn extends StatelessWidget {
  const _SignedIn({required this.onSyncNow, required this.onSignOut});

  final Future<void> Function() onSyncNow;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final sync = context.watch<SyncService>();
    final profile = auth.profile;
    final primary = profile?.primary ?? auth.identifier;
    final secondary = profile?.email != null && profile?.phone != null
        ? (primary == profile?.email ? profile?.phone : profile?.email)
        : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (primary != null) ...[
          _ProfileRow(label: 'ACCOUNT', value: primary),
          const SizedBox(height: PixelMetrics.space2),
        ],
        if (secondary != null) ...[
          _ProfileRow(label: 'BACKUP', value: secondary),
          const SizedBox(height: PixelMetrics.space2),
        ],
        const SizedBox(height: PixelMetrics.space2),
        PixelButton(
          label: sync.isSyncing ? 'Syncing…' : 'Sync now',
          glyph: PixelGlyph.cloud,
          filled: true,
          expand: true,
          onPressed: sync.isSyncing ? null : onSyncNow,
        ),
        const SizedBox(height: PixelMetrics.space2),
        PixelButton(
          label: 'Export vocabulary',
          expand: true,
          onPressed: () => _openDialog(context, const _ExportDialog()),
        ),
        const SizedBox(height: PixelMetrics.space2),
        PixelButton(
          label: 'Change password',
          expand: true,
          onPressed: () => _openDialog(context, const _ChangePasswordDialog()),
        ),
        const SizedBox(height: PixelMetrics.space2),
        PixelButton(
          label: 'Sign out',
          expand: true,
          onPressed: onSignOut,
        ),
        const SizedBox(height: PixelMetrics.space2),
        PixelButton(
          label: 'Delete account',
          expand: true,
          onPressed: () => _openDialog(context, const _DeleteAccountDialog()),
        ),
      ],
    );
  }
}

class _ProfileRow extends StatelessWidget {
  const _ProfileRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: PixelMetrics.space3,
        vertical: PixelMetrics.space2,
      ),
      decoration: BoxDecoration(
        color: palette.surface,
        border: Border.all(color: palette.border, width: PixelMetrics.border),
      ),
      child: Row(
        children: [
          Text(label, style: theme.textTheme.labelSmall),
          const SizedBox(width: PixelMetrics.space3),
          Expanded(
            child: Text(
              value,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _SyncStatus extends StatelessWidget {
  const _SyncStatus();

  @override
  Widget build(BuildContext context) {
    final sync = context.watch<SyncService>();
    final palette = context.palette;
    final theme = Theme.of(context);
    final lastSynced = sync.lastSyncedAt;

    final lines = <String>[
      if (sync.isSyncing)
        'SYNCING IN BACKGROUND…'
      else if (lastSynced != null)
        'LAST SYNCED ${DateFormat('d MMM HH:mm').format(lastSynced).toUpperCase()}'
      else
        'LOCAL MODE (NOT SYNCED YET)',
      if (sync.pendingCount > 0)
        '${sync.pendingCount} WORD${sync.pendingCount == 1 ? '' : 'S'} WAITING TO UPLOAD',
    ];

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(PixelMetrics.space3),
      decoration: BoxDecoration(
        color: palette.surface,
        border: Border.all(color: palette.border, width: PixelMetrics.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final line in lines)
            Text(line, style: theme.textTheme.labelSmall),
          if (sync.lastError != null) ...[
            const SizedBox(height: PixelMetrics.space1),
            Text(
              sync.lastError!.toUpperCase(),
              style: theme.textTheme.labelSmall?.copyWith(
                color: palette.danger,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.lines, this.tone});

  final List<String> lines;
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(PixelMetrics.space3),
      decoration: BoxDecoration(
        color: palette.surface,
        border: Border.all(
          color: tone ?? palette.border,
          width: PixelMetrics.border,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final line in lines)
            Text(
              line,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(color: tone),
            ),
        ],
      ),
    );
  }
}

class _ThemePickerSection extends StatelessWidget {
  const _ThemePickerSection();

  @override
  Widget build(BuildContext context) {
    final themeProvider = context.watch<ThemeProvider>();
    final palette = context.palette;
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('RETRO PIXEL THEME', style: theme.textTheme.labelSmall),
        const SizedBox(height: PixelMetrics.space2),
        Wrap(
          spacing: PixelMetrics.space2,
          runSpacing: PixelMetrics.space2,
          children: [
            for (final mode in AppThemeMode.values)
              GestureDetector(
                onTap: () => themeProvider.setMode(mode),
                behavior: HitTestBehavior.opaque,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: PixelMetrics.space3,
                    vertical: PixelMetrics.space2,
                  ),
                  decoration: BoxDecoration(
                    color: themeProvider.mode == mode
                        ? palette.accent
                        : palette.surface,
                    border: Border.all(
                      color: palette.border,
                      width: PixelMetrics.border,
                    ),
                  ),
                  child: Text(
                    mode.label.toUpperCase(),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: themeProvider.mode == mode
                          ? palette.onAccent
                          : palette.ink,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _WidgetSettingsSection extends StatelessWidget {
  const _WidgetSettingsSection();

  static const List<({int minutes, String label})> _intervals = [
    (minutes: 15, label: '15 MIN'),
    (minutes: 30, label: '30 MIN'),
    (minutes: 60, label: '1 HOUR'),
    (minutes: 0, label: 'STATIC'),
  ];

  @override
  Widget build(BuildContext context) {
    final widgetProvider = context.watch<WidgetProvider>();
    final palette = context.palette;
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('HOME SCREEN & LOCK SCREEN WIDGET', style: theme.textTheme.labelSmall),
        const SizedBox(height: PixelMetrics.space2),
        _ToggleTile(
          title: 'WORD OF THE DAY WIDGET',
          subtitle: 'Displays daily review words on iOS & Android widgets',
          enabled: widgetProvider.isWidgetEnabled,
          onChanged: (value) => widgetProvider.setWidgetEnabled(value),
        ),
        if (widgetProvider.isWidgetEnabled) ...[
          const SizedBox(height: PixelMetrics.space3),
          Text('WORD ROTATION INTERVAL', style: theme.textTheme.labelSmall),
          const SizedBox(height: PixelMetrics.space2),
          Wrap(
            spacing: PixelMetrics.space2,
            runSpacing: PixelMetrics.space2,
            children: [
              for (final opt in _intervals)
                GestureDetector(
                  onTap: () => widgetProvider.setRotationIntervalMinutes(opt.minutes),
                  behavior: HitTestBehavior.opaque,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: PixelMetrics.space3,
                      vertical: PixelMetrics.space2,
                    ),
                    decoration: BoxDecoration(
                      color: widgetProvider.rotationIntervalMinutes == opt.minutes
                          ? palette.accent
                          : palette.surface,
                      border: Border.all(
                        color: palette.border,
                        width: PixelMetrics.border,
                      ),
                    ),
                    child: Text(
                      opt.label,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: widgetProvider.rotationIntervalMinutes == opt.minutes
                            ? palette.onAccent
                            : palette.ink,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: PixelMetrics.space3),
          _ToggleTile(
            title: 'ROTATE ON WIDGET TAP',
            subtitle: 'Rotates to next word when widget is clicked',
            enabled: widgetProvider.rotateOnTap,
            onChanged: (value) => widgetProvider.setRotateOnTap(value),
          ),
        ],
        const SizedBox(height: PixelMetrics.space3),
        _ToggleTile(
          title: 'DAILY RECALL REMINDER',
          subtitle: 'Receive a subtle notification to record your daily words',
          enabled: widgetProvider.isDailyReminderEnabled,
          onChanged: (value) => widgetProvider.setDailyReminderEnabled(value),
        ),
      ],
    );
  }
}

class _ToggleTile extends StatelessWidget {
  const _ToggleTile({
    required this.title,
    required this.subtitle,
    required this.enabled,
    required this.onChanged,
  });

  final String title;
  final String subtitle;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.all(PixelMetrics.space3),
      decoration: BoxDecoration(
        color: palette.surface,
        border: Border.all(color: palette.border, width: PixelMetrics.border),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.labelSmall),
                const SizedBox(height: 2),
                Text(subtitle, style: theme.textTheme.bodyMedium),
              ],
            ),
          ),
          const SizedBox(width: PixelMetrics.space2),
          PixelButton(
            label: enabled ? 'ON' : 'OFF',
            filled: enabled,
            onPressed: () => onChanged(!enabled),
          ),
        ],
      ),
    );
  }
}

void _openDialog(BuildContext context, Widget dialog) {
  showDialog<void>(
    context: context,
    builder: (_) => dialog,
  );
}

class _ExportDialog extends StatefulWidget {
  const _ExportDialog();

  @override
  State<_ExportDialog> createState() => _ExportDialogState();
}

class _ExportDialogState extends State<_ExportDialog> {
  bool _busy = false;
  String? _jsonString;
  bool _copied = false;

  Future<void> _export() async {
    setState(() => _busy = true);
    final data = await context.read<AuthProvider>().exportWords();
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (data != null) {
        _jsonString = const JsonEncoder.withIndent('  ').convert(data);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final theme = Theme.of(context);

    return Dialog(
      backgroundColor: palette.paper,
      shape: const RoundedRectangleBorder(),
      child: Padding(
        padding: const EdgeInsets.all(PixelMetrics.space4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('EXPORT VOCABULARY', style: theme.textTheme.titleSmall),
            const SizedBox(height: PixelMetrics.space3),
            if (_jsonString == null) ...[
              Text(
                'Generate a complete JSON backup of all your vocabulary words.',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: PixelMetrics.space4),
              PixelButton(
                label: _busy ? 'Exporting…' : 'Generate Export',
                filled: true,
                expand: true,
                onPressed: _busy ? null : _export,
              ),
            ] else ...[
              Text('READY TO COPY', style: theme.textTheme.labelSmall),
              const SizedBox(height: PixelMetrics.space2),
              PixelButton(
                label: _copied ? 'Copied to clipboard!' : 'Copy to clipboard',
                glyph: PixelGlyph.cards,
                filled: true,
                expand: true,
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: _jsonString!));
                  setState(() => _copied = true);
                },
              ),
            ],
            const SizedBox(height: PixelMetrics.space2),
            PixelButton(
              label: 'Close',
              expand: true,
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChangePasswordDialog extends StatefulWidget {
  const _ChangePasswordDialog();

  @override
  State<_ChangePasswordDialog> createState() => _ChangePasswordDialogState();
}

class _ChangePasswordDialogState extends State<_ChangePasswordDialog> {
  final _current = TextEditingController();
  final _newPass = TextEditingController();

  @override
  void dispose() {
    _current.dispose();
    _newPass.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final theme = Theme.of(context);
    final auth = context.watch<AuthProvider>();

    return Dialog(
      backgroundColor: palette.paper,
      shape: const RoundedRectangleBorder(),
      child: Padding(
        padding: const EdgeInsets.all(PixelMetrics.space4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('CHANGE PASSWORD', style: theme.textTheme.titleSmall),
            const SizedBox(height: PixelMetrics.space3),
            PixelField(
              controller: _current,
              label: 'Current Password',
              obscure: true,
            ),
            const SizedBox(height: PixelMetrics.space3),
            PixelField(
              controller: _newPass,
              label: 'New Password',
              hint: 'at least 8 characters',
              obscure: true,
            ),
            const SizedBox(height: PixelMetrics.space4),
            PixelButton(
              label: auth.isBusy ? 'Changing…' : 'Update password',
              filled: true,
              expand: true,
              onPressed: () async {
                final ok = await auth.changePassword(
                  currentPassword: _current.text,
                  newPassword: _newPass.text,
                );
                if (ok && context.mounted) {
                  Navigator.of(context).pop();
                }
              },
            ),
            const SizedBox(height: PixelMetrics.space2),
            PixelButton(
              label: 'Cancel',
              expand: true,
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        ),
      ),
    );
  }
}

class _DeleteAccountDialog extends StatefulWidget {
  const _DeleteAccountDialog();

  @override
  State<_DeleteAccountDialog> createState() => _DeleteAccountDialogState();
}

class _DeleteAccountDialogState extends State<_DeleteAccountDialog> {
  final _pass = TextEditingController();

  @override
  void dispose() {
    _pass.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final theme = Theme.of(context);
    final auth = context.watch<AuthProvider>();

    return Dialog(
      backgroundColor: palette.paper,
      shape: const RoundedRectangleBorder(),
      child: Padding(
        padding: const EdgeInsets.all(PixelMetrics.space4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'DELETE ACCOUNT',
              style: theme.textTheme.titleSmall?.copyWith(color: palette.danger),
            ),
            const SizedBox(height: PixelMetrics.space2),
            Text(
              'WARNING: This will delete your account and remove all words from the cloud and this device.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: PixelMetrics.space3),
            PixelField(
              controller: _pass,
              label: 'Confirm Password',
              obscure: true,
            ),
            const SizedBox(height: PixelMetrics.space4),
            PixelButton(
              label: auth.isBusy ? 'Deleting…' : 'Permanently Delete',
              filled: true,
              expand: true,
              onPressed: () async {
                final ok = await auth.deleteAccount(password: _pass.text);
                if (ok && context.mounted) {
                  Navigator.of(context).pop();
                }
              },
            ),
            const SizedBox(height: PixelMetrics.space2),
            PixelButton(
              label: 'Cancel',
              expand: true,
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        ),
      ),
    );
  }
}

class _CartridgeLibrarySection extends StatelessWidget {
  const _CartridgeLibrarySection();

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final theme = Theme.of(context);
    final cartridgeProvider = context.watch<CartridgeProvider>();
    final isInstalled = cartridgeProvider.isInstalled('silicon_valley_tech_vol1');

    return PixelBox(
      raised: true,
      color: palette.surface,
      padding: const EdgeInsets.all(PixelMetrics.space4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              PixelIcon(PixelGlyph.gamepad, color: palette.accent, scale: 1.8),
              const SizedBox(width: PixelMetrics.space2),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'CAREER & TECH CARTRIDGES',
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Curated vocabulary for PR reviews & FAANG standups',
                      style: TextStyle(
                        fontFamily: 'Handjet',
                        fontSize: 11,
                        color: palette.inkMuted,
                      ),
                    ),
                  ],
                ),
              ),
              if (isInstalled)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                  decoration: BoxDecoration(
                    color: palette.accent,
                    border: Border.all(color: palette.border, width: 1),
                  ),
                  child: Text(
                    'ACTIVE ★',
                    style: TextStyle(
                      fontFamily: 'Handjet',
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: palette.onAccent,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: PixelMetrics.space3),
          PixelButton(
            label: isInstalled ? 'Manage Tech Cartridge' : 'Explore Tech Cartridge',
            glyph: PixelGlyph.gamepad,
            filled: !isInstalled,
            expand: true,
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const CartridgeLibraryScreen(),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

