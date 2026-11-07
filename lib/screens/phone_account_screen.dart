import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../core/config/app_config.dart';
import '../providers/phone_auth_controller.dart';
import '../providers/vocabulary_provider.dart';
import '../services/sync_service.dart';
import '../widgets/pixel/pixel_box.dart';

class AccountScreen extends StatefulWidget {
  const AccountScreen({super.key});
  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  PhoneAuthController? _flow;
  final _phone = TextEditingController(), _code = TextEditingController();
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _flow ??= PhoneAuthController(context.read<AuthProvider>())..initialize();
  }

  @override
  void dispose() {
    _flow?.dispose();
    _phone.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _verify() async {
    final ok = await _flow!.verify(_code.text);
    if (!ok || !mounted) return;
    _code.clear();
    _flow!.changePhone();
    FocusScope.of(context).unfocus();
    TextInput.finishAutofillContext();
    await context.read<VocabularyProvider>().init();
    if (!mounted) return;
    final sync = context.read<SyncService>();
    await sync.refreshPendingCount();
    await sync.synchronise();
    if (mounted) await context.read<VocabularyProvider>().init();
  }

  Future<void> _delete() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete your account?'),
        content: const Text(
          'Your cloud notebook and this account’s saved words on this device will be permanently deleted. We’ll send a code to confirm it is you.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep account'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    final done = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => const _DeletePhoneAccountScreen(),
      ),
    );
    if (done == true && mounted) {
      await context.read<VocabularyProvider>().init();
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final sync = context.watch<SyncService>();
    final words = context.watch<VocabularyProvider>().stats.totalWords;
    final flow = _flow!;
    return Scaffold(
      appBar: AppBar(title: const Text('Account and backup')),
      body: SafeArea(
        child: AnimatedBuilder(
          animation: flow,
          builder: (context, _) => ListView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.all(16),
            children: [
              if (auth.isSignedIn) ...[
                const Icon(Icons.account_circle_outlined, size: 48),
                const SizedBox(height: 12),
                Text(
                  auth.identifier ?? 'Your account',
                  style: Theme.of(context).textTheme.titleLarge,
                  textAlign: TextAlign.center,
                ),
                if (auth.isPhoneAccount)
                  const Text('Phone verified', textAlign: TextAlign.center),
                const SizedBox(height: 24),
                PixelBox(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        '$words words on this device',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        sync.isSyncing
                            ? 'Backing up your words…'
                            : sync.lastError != null
                            ? 'Backup could not finish. Your words are saved here.'
                            : sync.pendingCount > 0
                            ? '${sync.pendingCount} changes waiting to back up'
                            : sync.lastSyncedAt != null
                            ? 'Your notebook is up to date'
                            : 'Your words are saved on this device',
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Sign in with the same phone number on another Veea app to use the same notebook. App protection stays specific to this device.',
                      ),
                      if (sync.lastError != null) Text(sync.lastError!),
                      const SizedBox(height: 12),
                      FilledButton(
                        onPressed: sync.isSyncing
                            ? null
                            : () async {
                                await sync.synchronise();
                                if (context.mounted) {
                                  await context
                                      .read<VocabularyProvider>()
                                      .init();
                                }
                              },
                        child: const Text('Back up and sync now'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                OutlinedButton(
                  onPressed: auth.isBusy
                      ? null
                      : () async {
                          await auth.signOut();
                          if (mounted) setState(() {});
                        },
                  child: const Text('Sign out'),
                ),
                const Text(
                  'Signing out keeps your notebook on this device.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                if (auth.isPhoneAccount)
                  TextButton(
                    onPressed: auth.isBusy ? null : _delete,
                    child: const Text('Delete account'),
                  ),
              ] else ...[
                const Icon(Icons.cloud_done_outlined, size: 48),
                const SizedBox(height: 12),
                Text(
                  'Your notebook, backed up',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                const Text(
                  'Sign in with your Vietnamese phone number. No password to remember.',
                ),
                const SizedBox(height: 8),
                Text(
                  '$words words saved on this device. Your first sign-in backs up this notebook; other accounts keep separate notebooks.',
                ),
                const SizedBox(height: 24),
                if (flow.checking)
                  const LinearProgressIndicator()
                else if (!flow.available) ...[
                  const Text(
                    'Phone sign-in is coming soon. You can keep learning and exporting backups without an account.',
                  ),
                  if (flow.error != null) Text(flow.error!),
                  if (AppConfig.isCloudEnabled)
                    TextButton(
                      onPressed: flow.initialize,
                      child: const Text('Try again'),
                    ),
                ] else
                  AutofillGroup(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (flow.challenge == null) ...[
                          const Text('Vietnam (+84)'),
                          const SizedBox(height: 8),
                          TextField(
                            key: const Key('account_phone'),
                            controller: _phone,
                            keyboardType: TextInputType.phone,
                            autofillHints: const [
                              AutofillHints.telephoneNumberNational,
                            ],
                            decoration: const InputDecoration(
                              labelText: 'Phone number',
                              hintText: '0901234567',
                              border: OutlineInputBorder(),
                            ),
                            onSubmitted: (_) => flow.send(_phone.text),
                          ),
                          const SizedBox(height: 16),
                          FilledButton(
                            key: const Key('send_account_otp'),
                            onPressed: flow.busy || flow.retryIn > 0
                                ? null
                                : () => flow.send(_phone.text),
                            child: Text(
                              flow.busy
                                  ? 'Sending…'
                                  : flow.retryIn > 0
                                  ? 'Try again in ${flow.retryIn}s'
                                  : 'Send verification code',
                            ),
                          ),
                        ] else ...[
                          Text(
                            'Enter the code sent to ${flow.challenge!.phone}',
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            key: const Key('account_otp'),
                            controller: _code,
                            autofocus: true,
                            keyboardType: TextInputType.number,
                            autofillHints: const [AutofillHints.oneTimeCode],
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly,
                              LengthLimitingTextInputFormatter(10),
                            ],
                            decoration: const InputDecoration(
                              labelText: 'Verification code',
                              border: OutlineInputBorder(),
                            ),
                            onSubmitted: (_) => _verify(),
                          ),
                          const SizedBox(height: 16),
                          FilledButton(
                            key: const Key('verify_account_otp'),
                            onPressed: flow.busy ? null : _verify,
                            child: Text(
                              flow.busy ? 'Verifying…' : 'Verify and continue',
                            ),
                          ),
                          TextButton(
                            onPressed: flow.busy || flow.retryIn > 0
                                ? null
                                : () => flow.send(_phone.text),
                            child: Text(
                              flow.retryIn > 0
                                  ? 'Resend in ${flow.retryIn}s'
                                  : 'Resend code',
                            ),
                          ),
                          TextButton(
                            onPressed: flow.busy
                                ? null
                                : () {
                                    _code.clear();
                                    flow.changePhone();
                                  },
                            child: const Text('Use another number'),
                          ),
                        ],
                        if (flow.error != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: Semantics(
                              liveRegion: true,
                              child: Text(flow.error!),
                            ),
                          ),
                      ],
                    ),
                  ),
                const SizedBox(height: 24),
                const Text(
                  'Learning progress and app protection stay on this device.',
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _DeletePhoneAccountScreen extends StatefulWidget {
  const _DeletePhoneAccountScreen();
  @override
  State<_DeletePhoneAccountScreen> createState() =>
      _DeletePhoneAccountScreenState();
}

class _DeletePhoneAccountScreenState extends State<_DeletePhoneAccountScreen> {
  PhoneAuthController? _flow;
  final _code = TextEditingController();
  String _phone = '';
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_flow != null) return;
    final auth = context.read<AuthProvider>();
    _phone = auth.profile?.phone ?? auth.identifier ?? '';
    _flow = PhoneAuthController(auth, forDeletion: true)
      ..initialize().then((_) => _flow!.send(_phone));
  }

  @override
  void dispose() {
    _flow?.dispose();
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final flow = _flow!;
    return Scaffold(
      appBar: AppBar(title: const Text('Confirm account deletion')),
      body: SafeArea(
        child: AnimatedBuilder(
          animation: flow,
          builder: (context, _) => ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                flow.challenge == null
                    ? 'We’ll send a code to $_phone to confirm deletion. Your account stays active until you verify it.'
                    : 'Enter the code sent to $_phone. This permanently deletes your cloud account and its notebook on this device.',
              ),
              const SizedBox(height: 20),
              TextField(
                controller: _code,
                keyboardType: TextInputType.number,
                autofillHints: const [AutofillHints.oneTimeCode],
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(
                  labelText: 'Verification code',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: flow.busy || flow.challenge == null
                    ? null
                    : () async {
                        final done = await flow.verify(_code.text);
                        if (done && context.mounted) {
                          Navigator.pop(context, true);
                        }
                      },
                child: const Text('Delete my account'),
              ),
              if (!flow.checking && !flow.available)
                const Text(
                  'Phone verification is unavailable. Please try again later.',
                ),
              TextButton(
                onPressed: flow.busy || flow.retryIn > 0 || !flow.available
                    ? null
                    : () => flow.send(_phone),
                child: Text(
                  flow.retryIn > 0
                      ? 'Resend in ${flow.retryIn}s'
                      : 'Send a new code',
                ),
              ),
              if (flow.error != null) Text(flow.error!),
            ],
          ),
        ),
      ),
    );
  }
}
