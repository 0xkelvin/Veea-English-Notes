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
import '../services/backup_service.dart';
import '../services/feedback_service.dart';
import '../services/reminder_notification_service.dart';
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
                  const SizedBox(height: PixelMetrics.space5),

                  // Daily Practice Reminder (Local Notifications)
                  const _DailyReminderSection(),
                  const SizedBox(height: PixelMetrics.space5),

                  // 100% Offline Data Backup: Export & Import
                  const _DataBackupSection(),
                  const SizedBox(height: PixelMetrics.space5),

                  // Feedback & Bug Reporting Link
                  const _FeedbackSupportSection(),
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
          onPressed: () => _openDialog(context, const _LocalExportDialog()),
        ),
        const SizedBox(height: PixelMetrics.space2),
        PixelButton(
          label: 'Change password',
          expand: true,
          onPressed: () => _openDialog(context, const _ChangePasswordDialog()),
        ),
        const SizedBox(height: PixelMetrics.space2),
        PixelButton(label: 'Sign out', expand: true, onPressed: onSignOut),
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
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(color: tone),
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
        Text(
          'HOME SCREEN & LOCK SCREEN WIDGET',
          style: theme.textTheme.labelSmall,
        ),
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
                  onTap: () =>
                      widgetProvider.setRotationIntervalMinutes(opt.minutes),
                  behavior: HitTestBehavior.opaque,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: PixelMetrics.space3,
                      vertical: PixelMetrics.space2,
                    ),
                    decoration: BoxDecoration(
                      color:
                          widgetProvider.rotationIntervalMinutes == opt.minutes
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
                        color:
                            widgetProvider.rotationIntervalMinutes ==
                                opt.minutes
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
  showDialog<void>(context: context, builder: (_) => dialog);
}

class _LocalExportDialog extends StatefulWidget {
  const _LocalExportDialog();

  @override
  State<_LocalExportDialog> createState() => _LocalExportDialogState();
}

class _LocalExportDialogState extends State<_LocalExportDialog> {
  bool _isJson = true;
  bool _busy = false;
  String? _exportedContent;
  bool _copied = false;

  Future<void> _generate() async {
    setState(() => _busy = true);
    final provider = context.read<VocabularyProvider>();
    final content = _isJson
        ? await provider.exportBackupJson()
        : await provider.exportBackupCsv();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _exportedContent = content;
      _copied = false;
    });
  }

  Future<void> _share() async {
    if (_exportedContent == null) await _generate();
    if (_exportedContent == null || !mounted) return;

    final ext = _isJson ? 'json' : 'csv';
    final mime = _isJson ? 'application/json' : 'text/csv';
    final date = DateFormat('yyyyMMdd').format(DateTime.now());
    await BackupService.shareBackup(
      content: _exportedContent!,
      filename: 'veea_vocab_backup_$date.$ext',
      mimeType: mime,
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final theme = Theme.of(context);
    final provider = context.watch<VocabularyProvider>();
    final count = provider.stats.totalWords;

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
            const SizedBox(height: PixelMetrics.space2),
            Text(
              'Export $count notes directly from local SQLite storage without requiring internet.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: PixelMetrics.space3),
            Row(
              children: [
                Expanded(
                  child: PixelButton(
                    label: 'JSON FORMAT',
                    filled: _isJson,
                    expand: true,
                    onPressed: () {
                      setState(() {
                        _isJson = true;
                        _exportedContent = null;
                        _copied = false;
                      });
                    },
                  ),
                ),
                const SizedBox(width: PixelMetrics.space2),
                Expanded(
                  child: PixelButton(
                    label: 'CSV FORMAT',
                    filled: !_isJson,
                    expand: true,
                    onPressed: () {
                      setState(() {
                        _isJson = false;
                        _exportedContent = null;
                        _copied = false;
                      });
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: PixelMetrics.space4),
            if (_exportedContent != null) ...[
              Text('READY TO COPY / SHARE', style: theme.textTheme.labelSmall),
              const SizedBox(height: PixelMetrics.space2),
              PixelButton(
                label: _copied ? 'Copied to clipboard!' : 'Copy to clipboard',
                glyph: PixelGlyph.cards,
                filled: true,
                expand: true,
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: _exportedContent!));
                  setState(() => _copied = true);
                },
              ),
              const SizedBox(height: PixelMetrics.space2),
              PixelButton(
                label: 'Share via system sheet',
                glyph: PixelGlyph.cloud,
                expand: true,
                onPressed: _share,
              ),
            ] else ...[
              PixelButton(
                label: _busy ? 'Generating…' : 'Generate Export',
                filled: true,
                expand: true,
                onPressed: _busy ? null : _generate,
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

class _LocalImportDialog extends StatefulWidget {
  const _LocalImportDialog();

  @override
  State<_LocalImportDialog> createState() => _LocalImportDialogState();
}

class _LocalImportDialogState extends State<_LocalImportDialog> {
  final _controller = TextEditingController();
  bool _busy = false;
  BackupImportResult? _result;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData('text/plain');
    if (data?.text != null && mounted) {
      setState(() {
        _controller.text = data!.text!;
      });
    }
  }

  BackupPreviewResult? _preview;

  Future<void> _runPreview() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;

    setState(() => _busy = true);
    final provider = context.read<VocabularyProvider>();
    final preview = await provider.previewBackup(text);

    if (!mounted) return;
    setState(() {
      _busy = false;
      _preview = preview;
    });
  }

  Future<void> _runImport() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;

    setState(() => _busy = true);
    final provider = context.read<VocabularyProvider>();
    final result = await provider.importBackup(text);

    if (!mounted) return;
    setState(() {
      _busy = false;
      _result = result;
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
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'IMPORT BACKUP (JSON / CSV)',
                style: theme.textTheme.titleSmall,
              ),
              const SizedBox(height: PixelMetrics.space2),
              Text(
                'Paste exported JSON or CSV text below. Existing words are automatically detected and merged cleanly.',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: PixelMetrics.space3),
              if (_result == null) ...[
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    PixelButton(
                      label: 'Paste from clipboard',
                      glyph: PixelGlyph.cards,
                      onPressed: () {
                        _pasteFromClipboard();
                        setState(() => _preview = null);
                      },
                    ),
                  ],
                ),
                const SizedBox(height: PixelMetrics.space2),
                PixelField(
                  controller: _controller,
                  label: 'BACKUP DATA',
                  hint: 'Paste JSON or CSV text here…',
                  maxLines: 6,
                  onChanged: (_) => setState(() => _preview = null),
                ),
                if (_preview != null) ...[
                  const SizedBox(height: PixelMetrics.space3),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(PixelMetrics.space3),
                    decoration: BoxDecoration(
                      color: _preview!.isSuccess
                          ? palette.accent.withValues(alpha: 0.1)
                          : palette.danger.withValues(alpha: 0.1),
                      border: Border.all(
                        color: _preview!.isSuccess
                            ? palette.accent
                            : palette.danger,
                        width: 1,
                      ),
                    ),
                    child: Text(
                      _preview!.summary,
                      style: TextStyle(
                        fontFamily: 'Handjet',
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: _preview!.isSuccess
                            ? palette.ink
                            : palette.danger,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: PixelMetrics.space4),
                if (_preview == null || !_preview!.isSuccess)
                  PixelButton(
                    label: _busy ? 'Analyzing…' : 'Preview Import',
                    filled: true,
                    expand: true,
                    onPressed: _controller.text.trim().isNotEmpty && !_busy
                        ? _runPreview
                        : null,
                  )
                else
                  Row(
                    children: [
                      Expanded(
                        child: PixelButton(
                          label: 'Reset',
                          onPressed: _busy
                              ? null
                              : () => setState(() => _preview = null),
                        ),
                      ),
                      const SizedBox(width: PixelMetrics.space2),
                      Expanded(
                        flex: 2,
                        child: PixelButton(
                          label: _busy ? 'Importing…' : 'Confirm Import',
                          filled: true,
                          onPressed: !_busy ? _runImport : null,
                        ),
                      ),
                    ],
                  ),
              ] else ...[
                Container(
                  padding: const EdgeInsets.all(PixelMetrics.space3),
                  decoration: BoxDecoration(
                    color: _result!.isSuccess
                        ? palette.accent.withValues(alpha: 0.1)
                        : palette.danger.withValues(alpha: 0.1),
                    border: Border.all(
                      color: _result!.isSuccess
                          ? palette.accent
                          : palette.danger,
                      width: 1,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _result!.isSuccess
                            ? 'IMPORT COMPLETE'
                            : 'IMPORT FAILED',
                        style: TextStyle(
                          fontFamily: 'Handjet',
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: _result!.isSuccess
                              ? palette.accent
                              : palette.danger,
                        ),
                      ),
                      const SizedBox(height: PixelMetrics.space2),
                      Text(
                        _result!.summary,
                        style: TextStyle(
                          fontFamily: 'Handjet',
                          fontSize: 15,
                          color: palette.ink,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: PixelMetrics.space3),
              PixelButton(
                label: 'Close',
                expand: true,
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
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
              style: theme.textTheme.titleSmall?.copyWith(
                color: palette.danger,
              ),
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
    final isInstalled = cartridgeProvider.isInstalled(
      'silicon_valley_tech_vol1',
    );

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
                  padding: const EdgeInsets.symmetric(
                    horizontal: 5,
                    vertical: 2,
                  ),
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
            label: isInstalled
                ? 'Manage Tech Cartridge'
                : 'Explore Tech Cartridge',
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

class _DailyReminderSection extends StatefulWidget {
  const _DailyReminderSection();

  @override
  State<_DailyReminderSection> createState() => _DailyReminderSectionState();
}

class _DailyReminderSectionState extends State<_DailyReminderSection> {
  ReminderSettings _settings = const ReminderSettings(
    enabled: false,
    hour: 20,
    minute: 0,
  );

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final s = await ReminderNotificationService.instance.loadSettings();
    if (mounted) {
      setState(() {
        _settings = s;
      });
    }
  }

  Future<void> _toggle(bool val) async {
    final provider = context.read<VocabularyProvider>();
    if (val) {
      final granted = await ReminderNotificationService.instance
          .requestPermissions();
      if (!granted) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Please allow notifications in system settings to enable daily reminders.',
              ),
            ),
          );
        }
        await _load();
        return;
      }
    }
    final result = await ReminderNotificationService.instance.saveSettings(
      enabled: val,
      hour: _settings.hour,
      minute: _settings.minute,
      dueCount: provider.dueReviewCount,
    );
    if (mounted) {
      if (!result.success) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not save reminder: ${result.errorMessage}'),
          ),
        );
      }
      await _load();
    }
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: _settings.hour, minute: _settings.minute),
    );
    if (picked != null && mounted) {
      final provider = context.read<VocabularyProvider>();
      final result = await ReminderNotificationService.instance.saveSettings(
        enabled: _settings.enabled,
        hour: picked.hour,
        minute: picked.minute,
        dueCount: provider.dueReviewCount,
      );
      if (mounted) {
        if (!result.success) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Could not save time: ${result.errorMessage}'),
            ),
          );
        }
        await _load();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'DAILY RETRO PRACTICE REMINDER',
          style: theme.textTheme.titleSmall,
        ),
        const SizedBox(height: PixelMetrics.space2),
        Text(
          'Offline local daily reminder to review words and keep your streak alive.',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: PixelMetrics.space3),
        PixelBox(
          padding: const EdgeInsets.all(PixelMetrics.space4),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'DAILY PRACTICE ALARM',
                          style: TextStyle(
                            fontFamily: 'Handjet',
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: palette.ink,
                          ),
                        ),
                        Text(
                          _settings.enabled
                              ? 'Scheduled daily at ${_settings.formattedTime}'
                              : 'Reminder disabled',
                          style: TextStyle(
                            fontFamily: 'Handjet',
                            fontSize: 13,
                            color: palette.inkMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Switch(
                    value: _settings.enabled,
                    activeThumbColor: palette.accent,
                    onChanged: _toggle,
                  ),
                ],
              ),
              if (_settings.enabled) ...[
                const SizedBox(height: PixelMetrics.space3),
                Row(
                  children: [
                    Expanded(
                      child: PixelButton(
                        label: 'Time: ${_settings.formattedTime}',
                        onPressed: _pickTime,
                      ),
                    ),
                    const SizedBox(width: PixelMetrics.space2),
                    PixelButton(
                      label: 'Test Now',
                      glyph: PixelGlyph.star,
                      onPressed: () async {
                        final provider = context.read<VocabularyProvider>();
                        final result = await ReminderNotificationService
                            .instance
                            .showTestNotification(
                              dueCount: provider.dueReviewCount > 0
                                  ? provider.dueReviewCount
                                  : 3,
                            );
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                result.success
                                    ? 'Test notification sent!'
                                    : 'Failed to send notification: ${result.errorMessage}',
                              ),
                              duration: const Duration(seconds: 2),
                            ),
                          );
                        }
                      },
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _DataBackupSection extends StatelessWidget {
  const _DataBackupSection();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('DATA BACKUP & RESTORE', style: theme.textTheme.titleSmall),
        const SizedBox(height: PixelMetrics.space2),
        Text(
          '100% offline data sovereignty. Export your vocabulary notebook to JSON or CSV, or restore notes with automatic duplicate merge.',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: PixelMetrics.space3),
        Row(
          children: [
            Expanded(
              child: PixelButton(
                label: 'Export Backup',
                glyph: PixelGlyph.cards,
                expand: true,
                onPressed: () =>
                    _openDialog(context, const _LocalExportDialog()),
              ),
            ),
            const SizedBox(width: PixelMetrics.space2),
            Expanded(
              child: PixelButton(
                label: 'Import Backup',
                glyph: PixelGlyph.plus,
                expand: true,
                onPressed: () =>
                    _openDialog(context, const _LocalImportDialog()),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _FeedbackSupportSection extends StatelessWidget {
  const _FeedbackSupportSection();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final provider = context.watch<VocabularyProvider>();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('FEEDBACK & SUPPORT', style: theme.textTheme.titleSmall),
        const SizedBox(height: PixelMetrics.space2),
        Text(
          'Have a suggestion, spotted a typo, or encountered a bug? Send us a quick note with system diagnostics.',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: PixelMetrics.space3),
        PixelButton(
          label: 'SEND FEEDBACK / REPORT BUG',
          glyph: PixelGlyph.pencil,
          filled: true,
          expand: true,
          onPressed: () async {
            final launched = await FeedbackService.openFeedbackMail(
              totalWords: provider.stats.totalWords,
              streakDays: provider.stats.streakDays,
            );
            if (!launched && context.mounted) {
              _openDialog(
                context,
                _FeedbackDialog(
                  report: FeedbackService.generateReport(
                    totalWords: provider.stats.totalWords,
                    streakDays: provider.stats.streakDays,
                  ),
                ),
              );
            }
          },
        ),
      ],
    );
  }
}

class _FeedbackDialog extends StatefulWidget {
  const _FeedbackDialog({required this.report});

  final String report;

  @override
  State<_FeedbackDialog> createState() => _FeedbackDialogState();
}

class _FeedbackDialogState extends State<_FeedbackDialog> {
  bool _copied = false;

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
            Text('FEEDBACK & SUPPORT', style: theme.textTheme.titleSmall),
            const SizedBox(height: PixelMetrics.space2),
            Text(
              'No default email app detected. You can copy the diagnostics template below and email us directly at support@veea.app:',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: PixelMetrics.space3),
            Container(
              padding: const EdgeInsets.all(PixelMetrics.space3),
              color: palette.surface,
              child: Text(
                widget.report,
                style: TextStyle(
                  fontFamily: 'Handjet',
                  fontSize: 12,
                  color: palette.inkMuted,
                ),
              ),
            ),
            const SizedBox(height: PixelMetrics.space4),
            PixelButton(
              label: _copied ? 'Copied to clipboard!' : 'Copy to clipboard',
              glyph: PixelGlyph.cards,
              filled: true,
              expand: true,
              onPressed: () {
                Clipboard.setData(ClipboardData(text: widget.report));
                setState(() => _copied = true);
              },
            ),
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
