import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/config/app_config.dart';
import '../data/remote/api_client.dart';
import '../data/remote/go/auth_api.dart';
import '../providers/auth_provider.dart';
import '../providers/go_auth_provider.dart';
import '../providers/vocabulary_provider.dart';
import '../services/sync_service.dart';
import 'sync_review_screen.dart';

class GoAccountScreen extends StatefulWidget {
  const GoAccountScreen({super.key});
  @override
  State<GoAccountScreen> createState() => _GoAccountScreenState();
}

class _GoAccountScreenState extends State<GoAccountScreen> {
  final _email = TextEditingController(),
      _password = TextEditingController(),
      _code = TextEditingController();
  final _deleteCode = TextEditingController();
  EmailChallenge? _challenge;
  bool _signup = false, _usePassword = false;
  Timer? _poll;
  GoAuthProvider get auth => context.read<AuthProvider>() as GoAuthProvider;
  @override
  void initState() {
    super.initState();
    _poll = Timer.periodic(const Duration(seconds: 5), (_) async {
      if (!mounted || auth.isBusy || !auth.hasPendingDeletion) return;
      final receipt = auth.deletionReceipt!;
      if (receipt.submitted &&
          receipt.state != 'completed' &&
          receipt.state != 'expired') {
        await auth.checkPendingDeletion();
        if (mounted) await context.read<VocabularyProvider>().init();
      }
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    _email.dispose();
    _password.dispose();
    _code.dispose();
    _deleteCode.dispose();
    super.dispose();
  }

  Future<void> _signedIn(bool result) async {
    if (!result || !mounted) return;
    _password.clear();
    _code.clear();
    setState(() => _challenge = null);
    await context.read<VocabularyProvider>().init();
    if (!mounted) return;
    await context.read<SyncService>().synchronise();
    if (mounted) await context.read<VocabularyProvider>().init();
  }

  Future<void> _start() async {
    final result = await auth.startEmail(
      _email.text,
      signup: _signup,
      password: _signup && _usePassword ? _password.text : null,
    );
    if (mounted && result != null) {
      setState(() {
        _challenge = result;
        _code.clear();
        _password.clear();
      });
    }
  }

  Future<void> _confirmDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Permanently delete account?'),
        content: const Text(
          'Access ends immediately after confirmation. There is no grace period. '
          'This account’s notebook will be removed from this device after the server confirms acceptance. '
          'Other accounts and guest words are kept. Data cleanup targets 24 hours; the email remains reserved until it finishes.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const Key('go_delete_confirm'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete account'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final pending = auth.confirmDeletion(_deleteCode.text);
    _deleteCode.clear();
    await pending;
    if (mounted) await context.read<VocabularyProvider>().init();
  }

  Future<void> _devices() async {
    try {
      final data = await auth.goApi.sessions();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Signed-in devices'),
          content: SizedBox(
            width: 400,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final raw in data['sessions']! as List)
                    ListTile(
                      title: Text((raw as Map)['device_name']! as String),
                      subtitle: Text(
                        raw['is_current'] == true
                            ? 'This session'
                            : raw['platform']! as String,
                      ),
                      trailing: raw['is_current'] == true
                          ? null
                          : TextButton(
                              onPressed: () async {
                                try {
                                  await auth.goApi.revokeSession(
                                    raw['id']! as String,
                                  );
                                  if (context.mounted) Navigator.pop(context);
                                } on ApiException {
                                  if (context.mounted) Navigator.pop(context);
                                }
                              },
                              child: const Text('Sign out'),
                            ),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        ),
      );
    } on ApiException {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not load sessions. Try again.')),
        );
      }
    }
  }

  Future<void> _logoutAll() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sign out all devices?'),
        content: const Text(
          'This includes the current device. You will need to sign in again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Sign out all'),
          ),
        ],
      ),
    );
    if (yes == true && mounted) {
      await auth.signOutAll();
      if (mounted) await context.read<VocabularyProvider>().init();
    }
  }

  @override
  Widget build(BuildContext context) {
    final account = context.watch<AuthProvider>() as GoAuthProvider;
    final receipt = account.deletionReceipt;
    final busy = account.isBusy;
    final challenge = _challenge;
    return Scaffold(
      appBar: AppBar(title: const Text('Account and backup')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          if (account.lastError != null)
            Text(account.lastError!, key: const Key('go_auth_error')),
          if (account.lastMessage != null) Text(account.lastMessage!),
          if (!AppConfig.isCloudEnabled && !account.isSignedIn)
            const Text(
              'Accounts are not configured. Your guest notebook remains available on this device.',
            )
          else if (account.isSignedIn) ...[
            Text(account.identifier ?? '', key: const Key('go_account_email')),
            const Text(
              'Signing out opens your separate guest notebook. Account words and pending edits stay with this account.',
            ),
            FilledButton(
              onPressed: busy
                  ? null
                  : () async {
                      await context.read<SyncService>().synchronise();
                      if (context.mounted) {
                        await context.read<VocabularyProvider>().init();
                      }
                    },
              child: const Text('Sync now'),
            ),
            OutlinedButton(
              onPressed: busy ? null : _devices,
              child: const Text('Signed-in devices'),
            ),
            OutlinedButton(
              onPressed: busy
                  ? null
                  : () async {
                      await account.signOut();
                      if (context.mounted) {
                        await context.read<VocabularyProvider>().init();
                      }
                    },
              child: const Text('Sign out'),
            ),
            TextButton(
              onPressed: busy ? null : _logoutAll,
              child: const Text('Sign out all devices'),
            ),
            if (context.read<SyncService>().learningEngine case final engine?)
              OutlinedButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => SyncReviewScreen(engine: engine),
                  ),
                ),
                child: const Text('Sync review and local import'),
              ),
            TextButton(
              key: const Key('go_delete_start'),
              onPressed: busy
                  ? null
                  : () async {
                      await account.requestDeletion();
                    },
              child: const Text('Send email code to delete account'),
            ),
          ] else ...[
            Text(_signup ? 'Create an account' : 'Sign in with email'),
            TextField(
              key: const Key('go_email'),
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.email],
              decoration: const InputDecoration(labelText: 'Email'),
            ),
            if (challenge == null) ...[
              SwitchListTile(
                title: const Text('Use password'),
                value: _usePassword,
                onChanged: busy
                    ? null
                    : (v) => setState(() => _usePassword = v),
              ),
              if (_usePassword)
                TextField(
                  key: const Key('go_password'),
                  controller: _password,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'Password'),
                ),
              FilledButton(
                key: const Key('go_signin'),
                onPressed: busy
                    ? null
                    : () async {
                        if (_usePassword && !_signup) {
                          await _signedIn(
                            await account.signIn(
                              identifier: _email.text,
                              password: _password.text,
                            ),
                          );
                        } else {
                          await _start();
                        }
                      },
                child: Text(
                  _usePassword && !_signup
                      ? 'Sign in'
                      : 'Send verification code',
                ),
              ),
              TextButton(
                onPressed: busy
                    ? null
                    : () => setState(() {
                        _signup = !_signup;
                        _password.clear();
                      }),
                child: Text(
                  _signup
                      ? 'Already have an account? Sign in'
                      : 'Create an account',
                ),
              ),
            ] else ...[
              const Text(
                'If eligible, a code was sent to this email. Codes expire after ten minutes.',
              ),
              TextField(
                key: const Key('go_code'),
                controller: _code,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Verification code',
                ),
              ),
              FilledButton(
                key: const Key('go_verify'),
                onPressed: busy
                    ? null
                    : () async {
                        await _signedIn(
                          await account.verifyEmail(challenge, _code.text),
                        );
                      },
                child: const Text('Verify and sign in'),
              ),
              TextButton(
                onPressed:
                    busy || DateTime.now().isBefore(challenge.resendAfter)
                    ? null
                    : _start,
                child: const Text('Resend code'),
              ),
              TextButton(
                onPressed: busy
                    ? null
                    : () => setState(() {
                        _challenge = null;
                        _code.clear();
                      }),
                child: const Text('Use another email'),
              ),
            ],
          ],
          if (receipt != null) ...[
            const Divider(),
            Text(
              'Deletion status: ${receipt.state}',
              key: const Key('go_receipt_status'),
            ),
            if (!receipt.locallyCleared &&
                receipt.state == 'awaiting_proof') ...[
              const Text(
                'Enter the fresh code sent to your verified email. Recovery without that mailbox is not available.',
              ),
              TextField(
                key: const Key('go_delete_code'),
                controller: _deleteCode,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Deletion code'),
              ),
              TextButton(
                onPressed: busy ? null : _confirmDelete,
                child: const Text('Confirm permanent deletion'),
              ),
            ],
            TextButton(
              key: const Key('go_poll_receipt'),
              onPressed: busy
                  ? null
                  : () async {
                      await account.checkPendingDeletion();
                      if (context.mounted) {
                        await context.read<VocabularyProvider>().init();
                      }
                    },
              child: const Text('Check deletion receipt'),
            ),
            const Text(
              'The receipt survives sign-out and app restart. A missing receipt or ordinary 401 does not prove deletion.',
            ),
          ],
        ],
      ),
    );
  }
}
