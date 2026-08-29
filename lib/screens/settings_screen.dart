import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../core/config/app_config.dart';
import '../core/theme/pixel_metrics.dart';
import '../core/theme/pixel_palette.dart';
import '../providers/auth_provider.dart';
import '../providers/theme_provider.dart';
import '../providers/vocabulary_provider.dart';
import '../providers/widget_provider.dart';
import '../services/sync_service.dart';
import '../widgets/pixel/pixel_badges_grid.dart';
import '../widgets/pixel/pixel_box.dart';
import '../widgets/pixel/pixel_button.dart';
import '../widgets/pixel/pixel_heatmap.dart';
import '../widgets/pixel/pixel_icon.dart';
import 'account_screen.dart';

/// Comprehensive local Settings, Gamification Stats & Preferences screen.
///
/// Designed to work 100% offline without requiring any backend connection.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  void _openAccount(BuildContext context) {
    Navigator.of(context).push(
      PageRouteBuilder<void>(
        pageBuilder: (_, _, _) => const AccountScreen(),
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final theme = Theme.of(context);
    final provider = context.watch<VocabularyProvider>();
    final gamification = provider.gamificationStats;

    return Scaffold(
      backgroundColor: palette.paper,
      body: SafeArea(
        child: Column(
          children: [
            // Top Bar
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: PixelMetrics.space4,
                vertical: PixelMetrics.space2,
              ),
              decoration: BoxDecoration(
                color: palette.surface,
                border: Border(
                  bottom: BorderSide(
                    color: palette.border,
                    width: PixelMetrics.border,
                  ),
                ),
              ),
              child: Row(
                children: [
                  PixelIconButton(
                    glyph: PixelGlyph.arrowLeft,
                    semanticLabel: 'Back to journal',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  const SizedBox(width: PixelMetrics.space2),
                  Text('SETTINGS & STATS', style: theme.textTheme.titleMedium),
                ],
              ),
            ),

            // Content Body
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(PixelMetrics.space4),
                children: [
                  // Activity Heatmap
                  PixelHeatmap(
                    dailyCounts: gamification.dailyCounts,
                    weeks: 16,
                  ),
                  const SizedBox(height: PixelMetrics.space5),

                  // Retro Milestones & Badges
                  PixelBadgesGrid(badges: gamification.badges),
                  const SizedBox(height: PixelMetrics.space5),

                  // Theme Selection
                  const _ThemePickerSection(),
                  const SizedBox(height: PixelMetrics.space5),

                  // Widget Settings
                  const _WidgetSettingsSection(),
                  const SizedBox(height: PixelMetrics.space5),

                  // Cloud Sync & Account Entry
                  _CloudAccountTile(onOpenAccount: () => _openAccount(context)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CloudAccountTile extends StatelessWidget {
  const _CloudAccountTile({required this.onOpenAccount});

  final VoidCallback onOpenAccount;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final theme = Theme.of(context);
    final auth = context.watch<AuthProvider>();
    final sync = context.watch<SyncService>();

    final isSignedIn = auth.isSignedIn;
    final identifier = auth.identifier;
    final lastSynced = sync.lastSyncedAt;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('CLOUD & CROSS-DEVICE SYNC', style: theme.textTheme.labelSmall),
        const SizedBox(height: PixelMetrics.space2),
        PixelBox(
          raised: true,
          padding: const EdgeInsets.all(PixelMetrics.space4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(PixelMetrics.space2),
                    decoration: BoxDecoration(
                      color: isSignedIn ? palette.accent : palette.surface,
                      border: Border.all(
                        color: palette.border,
                        width: PixelMetrics.border,
                      ),
                    ),
                    child: PixelIcon(
                      PixelGlyph.cloud,
                      color: isSignedIn ? palette.onAccent : palette.ink,
                      scale: 2,
                    ),
                  ),
                  const SizedBox(width: PixelMetrics.space3),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          isSignedIn
                              ? 'SIGNED IN: ${identifier ?? 'ACTIVE'}'
                              : 'LOCAL STORAGE ONLY',
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          isSignedIn
                              ? (lastSynced != null
                                  ? 'LAST SYNCED ${DateFormat('d MMM HH:mm').format(lastSynced).toUpperCase()}'
                                  : 'READY TO SYNC')
                              : (AppConfig.isCloudEnabled
                                  ? 'Sign in to sync your words across all devices'
                                  : 'Everything is saved locally on this device'),
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: palette.inkMuted,
                            fontSize: 10,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: PixelMetrics.space3),
              PixelButton(
                label: isSignedIn ? 'Manage Account & Sync' : 'Configure Cloud Sync',
                glyph: PixelGlyph.cloud,
                expand: true,
                onPressed: onOpenAccount,
              ),
            ],
          ),
        ),
      ],
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
          const SizedBox(height: PixelMetrics.space4),
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
            title: 'ROTATE ON APP OPEN',
            subtitle: 'Advances to next word when opening or returning to Veea',
            enabled: widgetProvider.rotateOnAppOpen,
            onChanged: (value) => widgetProvider.setRotateOnAppOpen(value),
          ),
        ],
        const SizedBox(height: PixelMetrics.space4),
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
