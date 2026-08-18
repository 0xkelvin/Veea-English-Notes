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
  final _identifier = TextEditingController();
  final _password = TextEditingController();
  bool _registering = false;

  @override
  void initState() {
    super.initState();
    // Deferred so the first frame is not blocked on either call.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<SyncService>().refreshPendingCount();
      context.read<AuthProvider>().loadProfile();
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

    // This device has never seen this account's history.
    await sync.resetCursor();
    await sync.synchronise();
    if (mounted) await context.read<VocabularyProvider>().init();
  }

  Future<void> _syncNow() async {
    await context.read<SyncService>().synchronise();
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
            _TopBar(onClose: () => Navigator.of(context).pop()),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(PixelMetrics.space4),
                children: [
                  if (!AppConfig.isCloudEnabled)
                    const _Notice(
                      lines: [
                        'THIS BUILD HAS NO SERVER CONFIGURED.',
                        'EVERYTHING IS STORED ON THIS DEVICE.',
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
          'Your words already work without an account. '
          'Signing in keeps them on every device you use.',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: PixelMetrics.space4),
        PixelField(
          controller: _identifier,
          // The label reflects how the input was read, so there is no
          // email/phone toggle to get wrong.
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
        const SizedBox(height: PixelMetrics.space4),
        PixelField(
          controller: _password,
          label: 'Password',
          hint: 'at least 8 characters',
          obscure: true,
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
        border: Border(
          bottom: BorderSide(color: palette.border, width: PixelMetrics.border),
        ),
      ),
      child: Row(
        children: [
          Text('ACCOUNT', style: Theme.of(context).textTheme.titleMedium),
          const Spacer(),
          PixelIconButton(
            glyph: PixelGlyph.close,
            semanticLabel: 'Close',
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}

/// The signed-in view: who you are, and everything you can do about it.
class _SignedIn extends StatelessWidget {
  const _SignedIn({required this.onSyncNow, required this.onSignOut});

  final Future<void> Function() onSyncNow;
  final Future<void> Function() onSignOut;

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final sync = context.watch<SyncService>();
    final theme = Theme.of(context);
    final profile = auth.profile;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('SIGNED IN AS', style: theme.textTheme.labelSmall),
        const SizedBox(height: PixelMetrics.space1),
        Text(auth.identifier ?? '—', style: theme.textTheme.bodyLarge),

        // Once both identifiers are set, show the one that is not primary so
        // the user can see the account is reachable either way.
        if (profile != null && profile.email != null && profile.phone != null)
          Padding(
            padding: const EdgeInsets.only(top: PixelMetrics.space1),
            child: Text(
              profile.primary == profile.email
                  ? profile.phone!
                  : profile.email!,
              style: theme.textTheme.bodyMedium,
            ),
          ),

        const SizedBox(height: PixelMetrics.space5),
        PixelButton(
          label: sync.isSyncing ? 'Syncing…' : 'Sync now',
          filled: true,
          expand: true,
          onPressed: sync.isSyncing ? null : onSyncNow,
        ),

        const SizedBox(height: PixelMetrics.space6),
        Text('MANAGE', style: theme.textTheme.labelSmall),
        const SizedBox(height: PixelMetrics.space2),
        PixelButton(
          label: 'Change email or phone',
          expand: true,
          onPressed: () => _showChangeIdentifier(context),
        ),
        const SizedBox(height: PixelMetrics.space2),
        PixelButton(
          label: 'Change password',
          expand: true,
          onPressed: () => _showChangePassword(context),
        ),
        const SizedBox(height: PixelMetrics.space2),
        PixelButton(
          label: 'Export my words',
          expand: true,
          onPressed: () => _exportWords(context),
        ),
        const SizedBox(height: PixelMetrics.space2),
        PixelButton(label: 'Sign out', expand: true, onPressed: onSignOut),

        const SizedBox(height: PixelMetrics.space6),
        Text('DANGER', style: theme.textTheme.labelSmall),
        const SizedBox(height: PixelMetrics.space2),
        PixelButton(
          label: 'Delete my account',
          glyph: PixelGlyph.trash,
          danger: true,
          expand: true,
          onPressed: () => _showDeleteAccount(context),
        ),
        const SizedBox(height: PixelMetrics.space2),
        Text(
          'Deleting removes your account and every word on it, here and on the '
          'server. It cannot be undone.',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: PixelMetrics.space6),
      ],
    );
  }
}

/// Sync state, and whether anything is still waiting to leave the device.
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

// ── Account actions ──────────────────────────────────────────────────────────

Future<void> _showChangeIdentifier(BuildContext context) {
  final auth = context.read<AuthProvider>();
  return _showFormSheet(
    context: context,
    title: 'CHANGE EMAIL OR PHONE',
    builder: (sheetContext) => _IdentifierForm(
      auth: auth,
      onDone: () => Navigator.of(sheetContext).pop(),
    ),
  );
}

Future<void> _showChangePassword(BuildContext context) {
  final auth = context.read<AuthProvider>();
  return _showFormSheet(
    context: context,
    title: 'CHANGE PASSWORD',
    builder: (sheetContext) => _PasswordForm(
      auth: auth,
      onDone: () => Navigator.of(sheetContext).pop(),
    ),
  );
}

Future<void> _showDeleteAccount(BuildContext context) async {
  final auth = context.read<AuthProvider>();
  final vocabulary = context.read<VocabularyProvider>();

  await _showFormSheet(
    context: context,
    title: 'DELETE ACCOUNT',
    builder: (sheetContext) =>
        _DeleteForm(auth: auth, onDone: () => Navigator.of(sheetContext).pop()),
  );

  // The local database was wiped along with the account, so the journal has to
  // be re-read or it would keep showing words that no longer exist.
  if (!auth.isSignedIn) await vocabulary.init();
}

Future<void> _exportWords(BuildContext context) async {
  final auth = context.read<AuthProvider>();
  final messenger = ScaffoldMessenger.of(context);
  final palette = context.palette;

  final export = await auth.exportWords();
  if (export == null) return;

  // Copied to the clipboard rather than written to a file: it keeps the export
  // usable without a file-picker dependency and a share sheet, and a personal
  // vocabulary is small enough to paste anywhere.
  final json = const JsonEncoder.withIndent('  ').convert(export);
  await Clipboard.setData(ClipboardData(text: json));

  final count = export['count'];
  messenger.showSnackBar(
    SnackBar(
      backgroundColor: palette.surface,
      behavior: SnackBarBehavior.fixed,
      content: Text(
        '$count WORD${count == 1 ? '' : 'S'} COPIED AS JSON',
        style: TextStyle(color: palette.ink, fontFamily: 'Handjet'),
      ),
    ),
  );
}

/// Shared chrome for the small account forms.
Future<void> _showFormSheet({
  required BuildContext context,
  required String title,
  required Widget Function(BuildContext context) builder,
}) {
  final palette = context.palette;

  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (sheetContext) => Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(sheetContext).viewInsets.bottom,
      ),
      child: Container(
        decoration: BoxDecoration(
          color: palette.paper,
          border: Border(
            top: BorderSide(color: palette.border, width: PixelMetrics.border),
          ),
        ),
        padding: const EdgeInsets.all(PixelMetrics.space4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  title,
                  style: Theme.of(sheetContext).textTheme.titleMedium,
                ),
                const Spacer(),
                PixelIconButton(
                  glyph: PixelGlyph.close,
                  semanticLabel: 'Cancel',
                  onPressed: () => Navigator.of(sheetContext).pop(),
                ),
              ],
            ),
            const SizedBox(height: PixelMetrics.space4),
            builder(sheetContext),
            const SizedBox(height: PixelMetrics.space4),
          ],
        ),
      ),
    ),
  );
}

class _IdentifierForm extends StatefulWidget {
  const _IdentifierForm({required this.auth, required this.onDone});

  final AuthProvider auth;
  final VoidCallback onDone;

  @override
  State<_IdentifierForm> createState() => _IdentifierFormState();
}

class _IdentifierFormState extends State<_IdentifierForm> {
  final _identifier = TextEditingController();
  final _password = TextEditingController();

  @override
  void dispose() {
    _identifier.dispose();
    _password.dispose();
    super.dispose();
  }

  AccountIdentifier get _parsed => AccountIdentifier.parse(_identifier.text);

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final parsed = _parsed;
    final canSubmit =
        parsed.isValid && _password.text.isNotEmpty && !auth.isBusy;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Setting a phone keeps your email, and the other way round — the '
          'account stays reachable both ways.',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: PixelMetrics.space4),
        PixelField(
          controller: _identifier,
          label: parsed.kindLabel,
          hint: 'you@example.com or +84901234567',
          autofocus: true,
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: PixelMetrics.space4),
        PixelField(
          controller: _password,
          label: 'Confirm with your password',
          obscure: true,
          onChanged: (_) => setState(() {}),
        ),
        _ErrorLine(message: auth.lastError),
        const SizedBox(height: PixelMetrics.space4),
        PixelButton(
          label: auth.isBusy ? 'Saving…' : 'Save',
          filled: true,
          expand: true,
          onPressed: canSubmit
              ? () async {
                  final ok = await widget.auth.changeIdentifier(
                    identifier: parsed.value,
                    password: _password.text,
                  );
                  if (ok) widget.onDone();
                }
              : null,
        ),
      ],
    );
  }
}

class _PasswordForm extends StatefulWidget {
  const _PasswordForm({required this.auth, required this.onDone});

  final AuthProvider auth;
  final VoidCallback onDone;

  @override
  State<_PasswordForm> createState() => _PasswordFormState();
}

class _PasswordFormState extends State<_PasswordForm> {
  final _current = TextEditingController();
  final _next = TextEditingController();

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final canSubmit =
        _current.text.isNotEmpty && _next.text.length >= 8 && !auth.isBusy;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Every device signed into this account will be signed out, including '
          'this one.',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: PixelMetrics.space4),
        PixelField(
          controller: _current,
          label: 'Current password',
          obscure: true,
          autofocus: true,
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: PixelMetrics.space4),
        PixelField(
          controller: _next,
          label: 'New password',
          hint: 'at least 8 characters',
          obscure: true,
          onChanged: (_) => setState(() {}),
        ),
        _ErrorLine(message: auth.lastError),
        const SizedBox(height: PixelMetrics.space4),
        PixelButton(
          label: auth.isBusy ? 'Saving…' : 'Change password',
          filled: true,
          expand: true,
          onPressed: canSubmit
              ? () async {
                  final ok = await widget.auth.changePassword(
                    currentPassword: _current.text,
                    newPassword: _next.text,
                  );
                  if (ok) widget.onDone();
                }
              : null,
        ),
      ],
    );
  }
}

class _DeleteForm extends StatefulWidget {
  const _DeleteForm({required this.auth, required this.onDone});

  final AuthProvider auth;
  final VoidCallback onDone;

  @override
  State<_DeleteForm> createState() => _DeleteFormState();
}

class _DeleteFormState extends State<_DeleteForm> {
  final _password = TextEditingController();
  final _confirmation = TextEditingController();

  /// Typed literally, so deletion cannot happen by muscle memory.
  static const String _phrase = 'DELETE';

  @override
  void dispose() {
    _password.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final palette = context.palette;
    final canSubmit =
        _password.text.isNotEmpty &&
        _confirmation.text.trim().toUpperCase() == _phrase &&
        !auth.isBusy;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'This deletes your account and every word on it, on this device and '
          'on the server. There is no way to get them back.',
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: palette.danger),
        ),
        const SizedBox(height: PixelMetrics.space3),
        Text(
          'Export your words first if you want to keep them.',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: PixelMetrics.space4),
        PixelField(
          controller: _password,
          label: 'Your password',
          obscure: true,
          autofocus: true,
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: PixelMetrics.space4),
        PixelField(
          controller: _confirmation,
          label: 'Type $_phrase to confirm',
          hint: _phrase,
          onChanged: (_) => setState(() {}),
        ),
        _ErrorLine(message: auth.lastError),
        const SizedBox(height: PixelMetrics.space4),
        PixelButton(
          label: auth.isBusy ? 'Deleting…' : 'Delete my account',
          glyph: PixelGlyph.trash,
          danger: true,
          expand: true,
          onPressed: canSubmit
              ? () async {
                  final ok = await widget.auth.deleteAccount(
                    password: _password.text,
                  );
                  if (ok) widget.onDone();
                }
              : null,
        ),
      ],
    );
  }
}

class _ErrorLine extends StatelessWidget {
  const _ErrorLine({required this.message});

  final String? message;

  @override
  Widget build(BuildContext context) {
    if (message == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: PixelMetrics.space3),
      child: Text(
        message!.toUpperCase(),
        style: Theme.of(
          context,
        ).textTheme.labelSmall?.copyWith(color: context.palette.danger),
      ),
    );
  }
}
