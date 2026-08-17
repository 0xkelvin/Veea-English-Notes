import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../core/config/app_config.dart';
import '../core/theme/pixel_metrics.dart';
import '../core/theme/pixel_palette.dart';
import '../providers/auth_provider.dart';
import '../providers/vocabulary_provider.dart';
import '../services/sync_service.dart';
import '../widgets/pixel/pixel_button.dart';
import '../widgets/pixel/pixel_field.dart';
import '../widgets/pixel/pixel_icon.dart';

/// Account and sync.
///
/// Framed so the local-only state reads as a legitimate choice rather than a
/// setup step the user has failed to finish.
class AccountScreen extends StatefulWidget {
  const AccountScreen({super.key});

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _registering = false;

  @override
  void initState() {
    super.initState();
    context.read<SyncService>().refreshPendingCount();
  }

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  bool get _canSubmit =>
      _email.text.trim().contains('@') && _password.text.length >= 8;

  Future<void> _submit() async {
    final auth = context.read<AuthProvider>();
    final sync = context.read<SyncService>();

    final ok = _registering
        ? await auth.register(
            email: _email.text.trim(),
            password: _password.text,
          )
        : await auth.signIn(
            email: _email.text.trim(),
            password: _password.text,
          );

    if (!ok || !mounted) return;

    // This device has never seen the account's history.
    await sync.resetCursor();
    await sync.synchronise();
    if (mounted) await context.read<VocabularyProvider>().init();
  }

  Future<void> _syncNow() async {
    final sync = context.read<SyncService>();
    await sync.synchronise();
    // Words may have arrived from another device.
    if (mounted) await context.read<VocabularyProvider>().init();
  }

  Future<void> _signOut() async {
    await context.read<AuthProvider>().signOut();
    if (mounted) await context.read<SyncService>().refreshPendingCount();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(
                PixelMetrics.space4,
                PixelMetrics.space2,
                PixelMetrics.space2,
                PixelMetrics.space2,
              ),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color: palette.border,
                    width: PixelMetrics.border,
                  ),
                ),
              ),
              child: Row(
                children: [
                  Text(
                    'ACCOUNT',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const Spacer(),
                  PixelIconButton(
                    glyph: PixelGlyph.close,
                    semanticLabel: 'Close',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(PixelMetrics.space4),
                children: [
                  if (!AppConfig.isCloudEnabled)
                    const _Explainer(
                      lines: [
                        'THIS BUILD HAS NO SERVER CONFIGURED.',
                        'EVERYTHING IS STORED ON THIS DEVICE.',
                      ],
                    )
                  else ...[
                    const _SyncStatus(),
                    const SizedBox(height: PixelMetrics.space6),
                    Consumer<AuthProvider>(
                      builder: (context, auth, _) => auth.isSignedIn
                          ? _SignedIn(
                              email: auth.email,
                              onSyncNow: _syncNow,
                              onSignOut: _signOut,
                            )
                          : _buildSignInForm(auth),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSignInForm(AuthProvider auth) {
    final palette = context.palette;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _registering ? 'CREATE AN ACCOUNT' : 'SIGN IN TO SYNC',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: PixelMetrics.space2),
        Text(
          'Your words already work without an account. '
          'Signing in keeps them on every device you use.',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: PixelMetrics.space4),
        PixelField(
          controller: _email,
          label: 'Email',
          hint: 'you@example.com',
          textInputAction: TextInputAction.next,
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: PixelMetrics.space4),
        PixelField(
          controller: _password,
          label: 'Password',
          hint: 'at least 8 characters',
          onChanged: (_) => setState(() {}),
        ),
        if (auth.lastError != null) ...[
          const SizedBox(height: PixelMetrics.space3),
          Text(
            auth.lastError!.toUpperCase(),
            style: Theme.of(
              context,
            ).textTheme.labelSmall?.copyWith(color: palette.danger),
          ),
        ],
        const SizedBox(height: PixelMetrics.space5),
        PixelButton(
          label: auth.isBusy
              ? 'Working…'
              : (_registering ? 'Create account' : 'Sign in'),
          filled: true,
          expand: true,
          onPressed: _canSubmit && !auth.isBusy ? _submit : null,
        ),
        const SizedBox(height: PixelMetrics.space3),
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

class _SignedIn extends StatelessWidget {
  const _SignedIn({
    required this.email,
    required this.onSyncNow,
    required this.onSignOut,
  });

  final String? email;
  final Future<void> Function() onSyncNow;
  final Future<void> Function() onSignOut;

  @override
  Widget build(BuildContext context) {
    final sync = context.watch<SyncService>();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('SIGNED IN AS', style: Theme.of(context).textTheme.labelSmall),
        const SizedBox(height: PixelMetrics.space1),
        Text(email ?? '—', style: Theme.of(context).textTheme.bodyLarge),
        const SizedBox(height: PixelMetrics.space5),
        PixelButton(
          label: sync.isSyncing ? 'Syncing…' : 'Sync now',
          filled: true,
          expand: true,
          onPressed: sync.isSyncing ? null : onSyncNow,
        ),
        const SizedBox(height: PixelMetrics.space3),
        PixelButton(label: 'Sign out', expand: true, onPressed: onSignOut),
      ],
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
        'SYNCING…'
      else if (lastSynced != null)
        'LAST SYNCED ${DateFormat('d MMM HH:mm').format(lastSynced).toUpperCase()}'
      else
        'NOT SYNCED YET',
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

class _Explainer extends StatelessWidget {
  const _Explainer({required this.lines});

  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
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
            Text(line, style: Theme.of(context).textTheme.labelSmall),
        ],
      ),
    );
  }
}
