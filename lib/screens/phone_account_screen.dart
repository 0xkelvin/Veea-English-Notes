import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../core/config/app_config.dart';
import '../providers/phone_auth_controller.dart';
import '../providers/vocabulary_provider.dart';
import '../services/sync_service.dart';
import '../widgets/pixel/pixel_box.dart';

/// Shown wherever support is the only recovery. There is no support URL in
/// the app configuration yet, so none is linked.
const _supportNote =
    'Lost access to your current number? It can’t be changed in the app without it. Please contact Veea support.';

class AccountScreen extends StatefulWidget {
  const AccountScreen({super.key});
  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  PhoneAuthController? _flow;
  final _phone = TextEditingController(), _code = TextEditingController();
  final _codeFocus = FocusNode();
  bool _checkedPending = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_flow != null) return;
    final auth = context.read<AuthProvider>();
    _flow = PhoneAuthController(auth)..initialize();
    // Resolve a deletion whose response was lost as soon as the screen opens.
    if (auth.hasPendingDeletion && !_checkedPending) {
      _checkedPending = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _checkPending());
    }
  }

  @override
  void dispose() {
    _flow?.dispose();
    _phone.dispose();
    _code.dispose();
    _codeFocus.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final sent = await _flow!.send(_phone.text);
    if (sent && mounted) {
      _code.clear();
      _codeFocus.requestFocus();
    }
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

  Future<void> _checkPending() async {
    final auth = context.read<AuthProvider>();
    final outcome = await auth.checkPendingDeletion();
    if (outcome == DeletionOutcome.deleted && mounted) {
      await context.read<VocabularyProvider>().init();
    }
  }

  Future<void> _signOut() async {
    await context.read<AuthProvider>().signOut();
    if (!mounted) return;
    _code.clear();
    _flow!.changePhone();
  }

  Future<void> _changePhone() async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => const PhoneChangeScreen(),
      ),
    );
    if (changed == true && mounted) {
      await context.read<AuthProvider>().loadProfile();
    }
  }

  Future<void> _delete() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('Delete your account?'),
        content: const Text(
          'This deletes your Veea account, its cloud backup, and this account’s notebook on this device. '
          'Notebooks of other accounts on this device are kept. Feedback you already sent is kept separately by the Veea team. '
          'We’ll send a code to your phone to confirm it is you.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep account'),
          ),
          TextButton(
            key: const Key('delete_continue'),
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
        builder: (_) => const DeletePhoneAccountScreen(),
      ),
    );
    if (mounted && (done == true || !context.read<AuthProvider>().isSignedIn)) {
      await context.read<VocabularyProvider>().init();
    }
  }

  Widget _notice(BuildContext context, String text, {bool error = false}) {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Semantics(
        liveRegion: true,
        child: Text(
          text,
          style: error
              ? TextStyle(color: Theme.of(context).colorScheme.error)
              : null,
        ),
      ),
    );
  }

  Widget _pendingDeletion(AuthProvider auth) {
    return PixelBox(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Confirming account deletion',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          const Text(
            'Veea didn’t receive the answer to your deletion request. Your notebook stays on this device until Veea confirms the account was deleted. '
            'If it was, this account’s notebook here will be deleted too, including words added since.',
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            key: const Key('pending_deletion_check'),
            onPressed: auth.isBusy ? null : _checkPending,
            child: Text(auth.isBusy ? 'Checking…' : 'Check again'),
          ),
        ],
      ),
    );
  }

  List<Widget> _signedIn(
    BuildContext context,
    AuthProvider auth,
    SyncService sync,
    int words,
  ) {
    final phone = auth.profile?.phone ?? auth.identifier;
    return [
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
              '$words ${words == 1 ? 'word' : 'words'} on this device',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            if (!AppConfig.isCloudEnabled)
              const Text(
                'Backup is not available in this version. Your words are saved on this device.',
              )
            else ...[
              Semantics(
                liveRegion: true,
                child: Text(
                  sync.isSyncing
                      ? 'Backing up your words…'
                      : sync.lastError != null
                      ? 'Backup could not finish. Your words are saved here.'
                      : sync.pendingCount > 0
                      ? '${sync.pendingCount} changes waiting to back up'
                      : sync.lastSyncedAt != null
                      ? 'Backed up. Your notebook is up to date.'
                      : 'Not backed up yet on this visit. Your words are saved on this device.',
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Sign in with the same phone number on another device to use the same notebook. App protection stays specific to this device.',
              ),
              if (sync.lastError != null) Text(sync.lastError!),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: sync.isSyncing
                    ? null
                    : () async {
                        await sync.synchronise();
                        if (context.mounted) {
                          await context.read<VocabularyProvider>().init();
                        }
                      },
                child: Text(
                  sync.isSyncing ? 'Backing up…' : 'Back up and sync now',
                ),
              ),
            ],
          ],
        ),
      ),
      if (auth.isPhoneAccount && AppConfig.isCloudEnabled) ...[
        const SizedBox(height: 20),
        OutlinedButton(
          key: const Key('change_phone_entry'),
          onPressed: auth.isBusy ? null : _changePhone,
          child: const Text('Change phone number'),
        ),
      ],
      const SizedBox(height: 20),
      OutlinedButton(
        onPressed: auth.isBusy ? null : _signOut,
        child: const Text('Sign out'),
      ),
      Text(
        'Signing out keeps this notebook on this device, and you can keep learning. '
        'Words you add while signed out stay in this notebook and back up to ${phone ?? 'this account'} when you sign in with it again. '
        'Signing in with a different number keeps this notebook aside and opens that account’s own notebook.',
        textAlign: TextAlign.center,
      ),
      const SizedBox(height: 24),
      if (auth.isPhoneAccount && AppConfig.isCloudEnabled)
        TextButton(
          key: const Key('delete_account_entry'),
          style: TextButton.styleFrom(
            foregroundColor: Theme.of(context).colorScheme.error,
          ),
          onPressed: auth.isBusy ? null : _delete,
          child: const Text('Delete account'),
        ),
    ];
  }

  List<Widget> _signedOut(
    BuildContext context,
    PhoneAuthController flow,
    int words,
  ) {
    return [
      const Icon(Icons.cloud_upload_outlined, size: 48),
      const SizedBox(height: 12),
      Text(
        flow.available
            ? 'Back up your notebook'
            : 'Your notebook, on this device',
        style: Theme.of(context).textTheme.headlineSmall,
      ),
      const SizedBox(height: 8),
      Text('$words ${words == 1 ? 'word' : 'words'} saved on this device.'),
      const SizedBox(height: 16),
      if (flow.checking)
        const LinearProgressIndicator()
      else if (!flow.available) ...[
        const Text(
          'Account and backup are coming soon. You can keep learning, and export a backup from Settings, without an account.',
        ),
        if (flow.error != null) _notice(context, flow.error!, error: true),
        if (AppConfig.isCloudEnabled)
          TextButton(
            onPressed: flow.initialize,
            child: const Text('Try again'),
          ),
      ] else ...[
        const Text(
          'Sign in or create an account with your Vietnamese phone number. No password to remember. '
          'Your notebooks stay separate when you change accounts.',
        ),
        const SizedBox(height: 16),
        AutofillGroup(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                flow.challenge == null
                    ? 'Step 1 of 2 · Your phone number'
                    : 'Step 2 of 2 · Verification code',
                style: Theme.of(context).textTheme.labelLarge,
              ),
              const SizedBox(height: 8),
              if (flow.challenge == null) ...[
                const Text('Vietnam (+84)'),
                const SizedBox(height: 8),
                TextField(
                  key: const Key('account_phone'),
                  controller: _phone,
                  enabled: !flow.busy,
                  keyboardType: TextInputType.phone,
                  textInputAction: TextInputAction.send,
                  autofillHints: const [AutofillHints.telephoneNumberNational],
                  decoration: const InputDecoration(
                    labelText: 'Phone number',
                    hintText: '0901234567',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _send(),
                ),
                const SizedBox(height: 16),
                FilledButton(
                  key: const Key('send_account_otp'),
                  onPressed: flow.busy || flow.retryIn > 0 ? null : _send,
                  child: Text(
                    flow.busy
                        ? 'Sending…'
                        : flow.retryIn > 0
                        ? 'Try again in ${flow.retryIn}s'
                        : 'Send verification code',
                  ),
                ),
              ] else ...[
                Text('Enter the code sent to ${flow.challenge!.phone}'),
                if (!flow.expired && flow.expiresIn != null)
                  Text(
                    'Code valid for ${(flow.expiresIn! / 60).ceil()} min',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                const SizedBox(height: 12),
                TextField(
                  key: const Key('account_otp'),
                  controller: _code,
                  focusNode: _codeFocus,
                  autofocus: true,
                  enabled: !flow.busy,
                  keyboardType: TextInputType.number,
                  textInputAction: TextInputAction.done,
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
                  onPressed: flow.busy || flow.expired ? null : _verify,
                  child: Text(flow.busy ? 'Verifying…' : 'Verify and continue'),
                ),
                TextButton(
                  key: const Key('resend_account_otp'),
                  onPressed: flow.busy || flow.retryIn > 0 ? null : _send,
                  child: Text(
                    flow.retryIn > 0
                        ? 'Resend in ${flow.retryIn}s'
                        : flow.expired
                        ? 'Send a new code'
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
                _notice(context, flow.error!, error: true),
            ],
          ),
        ),
      ],
      const SizedBox(height: 24),
      const Text('Learning progress and app protection stay on this device.'),
    ];
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
          builder: (context, _) => _AccountFormScroll(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.all(16),
            children: [
              if (auth.hasPendingDeletion) ...[
                _pendingDeletion(auth),
                const SizedBox(height: 16),
              ],
              if (auth.lastMessage != null) ...[
                _notice(context, auth.lastMessage!),
                const SizedBox(height: 16),
              ],
              if (auth.lastError != null && flow.error == null)
                _notice(context, auth.lastError!, error: true),
              if (!auth.hasPendingDeletion) ...[
                if (auth.isSignedIn)
                  ..._signedIn(context, auth, sync, words)
                else
                  ..._signedOut(context, flow, words),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Verified phone change: current number, new number, new-number code.
class PhoneChangeScreen extends StatefulWidget {
  const PhoneChangeScreen({super.key});
  @override
  State<PhoneChangeScreen> createState() => _PhoneChangeScreenState();
}

class _PhoneChangeScreenState extends State<PhoneChangeScreen> {
  PhoneChangeController? _flow;
  final _code = TextEditingController(), _newPhone = TextEditingController();
  final _codeFocus = FocusNode();
  String _current = '';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_flow != null) return;
    final auth = context.read<AuthProvider>();
    _current = auth.profile?.phone ?? auth.identifier ?? '';
    _flow = PhoneChangeController(auth);
  }

  @override
  void dispose() {
    _flow?.dispose();
    _code.dispose();
    _newPhone.dispose();
    _codeFocus.dispose();
    super.dispose();
  }

  Future<void> _after(Future<bool> action, {bool focusCode = true}) async {
    final ok = await action;
    if (!mounted) return;
    if (ok) {
      _code.clear();
      if (focusCode && _flow!.challenge != null) _codeFocus.requestFocus();
    }
  }

  Widget _codeField(PhoneChangeController flow, Key key, VoidCallback submit) {
    return TextField(
      key: key,
      controller: _code,
      focusNode: _codeFocus,
      autofocus: true,
      enabled: !flow.busy,
      keyboardType: TextInputType.number,
      textInputAction: TextInputAction.done,
      autofillHints: const [AutofillHints.oneTimeCode],
      inputFormatters: [
        FilteringTextInputFormatter.digitsOnly,
        LengthLimitingTextInputFormatter(10),
      ],
      decoration: const InputDecoration(
        labelText: 'Verification code',
        border: OutlineInputBorder(),
      ),
      onSubmitted: (_) => submit(),
    );
  }

  Widget _resend(PhoneChangeController flow, VoidCallback resend) {
    return TextButton(
      onPressed: flow.busy || flow.retryIn > 0 ? null : resend,
      child: Text(
        flow.retryIn > 0
            ? 'Resend in ${flow.retryIn}s'
            : flow.expired
            ? 'Send a new code'
            : 'Resend code',
      ),
    );
  }

  List<Widget> _step(BuildContext context, PhoneChangeController flow) {
    switch (flow.step) {
      case PhoneChangeStep.confirmCurrent:
        void verify() =>
            _after(flow.verifyCurrent(_code.text), focusCode: false);
        return [
          Text(
            'Confirm your current number',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(
            flow.challenge == null
                ? 'First, confirm it’s you. We’ll send a code to $_current.'
                : 'Enter the code sent to $_current.',
          ),
          const SizedBox(height: 16),
          if (flow.challenge == null)
            FilledButton(
              key: const Key('change_current_send'),
              onPressed: flow.busy || flow.retryIn > 0 || flow.blocked
                  ? null
                  : () => _after(flow.sendCurrentCode()),
              child: Text(
                flow.busy
                    ? 'Sending…'
                    : flow.retryIn > 0
                    ? 'Try again in ${flow.retryIn}s'
                    : 'Send code to current number',
              ),
            )
          else ...[
            _codeField(flow, const Key('change_current_code'), verify),
            const SizedBox(height: 16),
            FilledButton(
              key: const Key('change_current_verify'),
              onPressed: flow.busy || flow.expired ? null : verify,
              child: Text(flow.busy ? 'Verifying…' : 'Verify current number'),
            ),
            _resend(flow, () => _after(flow.sendCurrentCode())),
          ],
          const SizedBox(height: 16),
          const Text(_supportNote),
        ];
      case PhoneChangeStep.enterNew:
        void send() => _after(flow.sendNewCode(_newPhone.text));
        return [
          Text(
            'Enter your new number',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          const Text(
            'Your account, notebook and backup stay the same. Other devices signed in to this account will need to sign in again with the new number.',
          ),
          const SizedBox(height: 16),
          const Text('Vietnam (+84)'),
          const SizedBox(height: 8),
          TextField(
            key: const Key('change_new_phone'),
            controller: _newPhone,
            autofocus: true,
            enabled: !flow.busy,
            keyboardType: TextInputType.phone,
            textInputAction: TextInputAction.send,
            autofillHints: const [AutofillHints.telephoneNumberNational],
            decoration: InputDecoration(
              labelText: 'New phone number',
              hintText: '0901234567',
              hintStyle: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              border: const OutlineInputBorder(),
            ),
            onSubmitted: (_) => send(),
          ),
          const SizedBox(height: 16),
          FilledButton(
            key: const Key('change_new_send'),
            onPressed: flow.busy || flow.retryIn > 0 || flow.blocked
                ? null
                : send,
            child: Text(
              flow.busy
                  ? 'Sending…'
                  : flow.retryIn > 0
                  ? 'Try again in ${flow.retryIn}s'
                  : 'Send code to new number',
            ),
          ),
        ];
      case PhoneChangeStep.verifyNew:
        void confirm() => _after(flow.confirm(_code.text), focusCode: false);
        return [
          Text(
            'Verify your new number',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text('Enter the code sent to ${flow.newPhone}.'),
          const SizedBox(height: 16),
          _codeField(flow, const Key('change_new_code'), confirm),
          const SizedBox(height: 16),
          FilledButton(
            key: const Key('change_new_confirm'),
            onPressed: flow.busy || flow.expired || flow.blocked
                ? null
                : confirm,
            child: Text(flow.busy ? 'Changing number…' : 'Change number'),
          ),
          _resend(flow, () => _after(flow.resendNewCode())),
          TextButton(
            onPressed: flow.busy
                ? null
                : () {
                    _code.clear();
                    flow.editNewNumber();
                  },
            child: const Text('Use a different number'),
          ),
        ];
      case PhoneChangeStep.done:
        return [
          Text(
            'Number changed',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(
            'You now sign in with ${context.read<AuthProvider>().identifier}. Your notebook and backup are unchanged. Other devices need to sign in again with the new number.',
          ),
          const SizedBox(height: 16),
          FilledButton(
            key: const Key('change_done'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Done'),
          ),
        ];
    }
  }

  @override
  Widget build(BuildContext context) {
    final flow = _flow!;
    return Scaffold(
      appBar: AppBar(title: const Text('Change phone number')),
      body: SafeArea(
        child: AnimatedBuilder(
          animation: flow,
          builder: (context, _) => AutofillGroup(
            child: _AccountFormScroll(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: const EdgeInsets.all(16),
              children: [
                Semantics(
                  label:
                      'Step ${flow.stepNumber} of ${PhoneChangeController.totalSteps}',
                  child: ExcludeSemantics(
                    child: Text(
                      flow.step == PhoneChangeStep.done
                          ? 'Complete'
                          : 'Step ${flow.stepNumber} of ${PhoneChangeController.totalSteps}',
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                LinearProgressIndicator(
                  color: Theme.of(context).colorScheme.primary,
                  backgroundColor: Theme.of(context).colorScheme.outlineVariant,
                  value: flow.step == PhoneChangeStep.done
                      ? 1
                      : (flow.stepNumber - 1) /
                            PhoneChangeController.totalSteps,
                ),
                const SizedBox(height: 20),
                ..._step(context, flow),
                if (flow.error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Semantics(
                      liveRegion: true,
                      child: Text(
                        flow.error!,
                        key: const Key('change_error'),
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  ),
                if (flow.blocked)
                  TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Close'),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Deletion with a fresh code and an explicit, final, destructive confirmation.
class DeletePhoneAccountScreen extends StatefulWidget {
  const DeletePhoneAccountScreen({super.key});
  @override
  State<DeletePhoneAccountScreen> createState() =>
      _DeletePhoneAccountScreenState();
}

class _DeletePhoneAccountScreenState extends State<DeletePhoneAccountScreen> {
  PhoneAuthController? _flow;
  final _code = TextEditingController();
  final _codeFocus = FocusNode();
  String _phone = '';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_flow != null) return;
    final auth = context.read<AuthProvider>();
    _phone = auth.profile?.phone ?? auth.identifier ?? '';
    // Always a fresh code: deletion never reuses a code from another step.
    _flow = PhoneAuthController(auth, forDeletion: true);
    _flow!.initialize().then((_) async {
      if (!mounted || !_flow!.available) return;
      if (await _flow!.send(_phone) && mounted) _codeFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _flow?.dispose();
    _code.dispose();
    _codeFocus.dispose();
    super.dispose();
  }

  Future<void> _confirm() async {
    final flow = _flow!;
    if (_code.text.trim().isEmpty) {
      await flow.verify(_code.text); // shows the validation message
      return;
    }
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('Delete permanently?'),
        content: const Text(
          'Your account, its cloud backup and this account’s notebook on this device will be deleted. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const Key('delete_final'),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete permanently'),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    final done = await flow.verify(_code.text);
    if (!mounted) return;
    final auth = context.read<AuthProvider>();
    if (done || !auth.isSignedIn) Navigator.pop(context, done);
  }

  @override
  Widget build(BuildContext context) {
    final flow = _flow!;
    final auth = context.watch<AuthProvider>();
    return Scaffold(
      appBar: AppBar(title: const Text('Confirm account deletion')),
      body: SafeArea(
        child: AnimatedBuilder(
          animation: flow,
          builder: (context, _) => _AccountFormScroll(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                flow.checking || (flow.busy && flow.challenge == null)
                    ? 'Sending a code to $_phone…'
                    : flow.challenge == null
                    ? 'We need to send a code to $_phone to confirm deletion. Your account stays active until you verify it.'
                    : 'Enter the code sent to $_phone. Your account stays active until you confirm.',
              ),
              const SizedBox(height: 20),
              TextField(
                key: const Key('delete_code'),
                controller: _code,
                focusNode: _codeFocus,
                enabled: flow.challenge != null && !flow.busy,
                keyboardType: TextInputType.number,
                textInputAction: TextInputAction.done,
                autofillHints: const [AutofillHints.oneTimeCode],
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(10),
                ],
                decoration: const InputDecoration(
                  labelText: 'Verification code',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              FilledButton(
                key: const Key('delete_confirm'),
                style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error,
                  foregroundColor: Theme.of(context).colorScheme.onError,
                ),
                onPressed:
                    flow.busy ||
                        flow.challenge == null ||
                        flow.expired ||
                        auth.hasPendingDeletion
                    ? null
                    : _confirm,
                child: Text(
                  flow.busy && flow.challenge != null
                      ? 'Deleting…'
                      : 'Delete account permanently',
                ),
              ),
              if (!flow.checking && !flow.available)
                const Text(
                  'Phone verification is unavailable. Please try again later. Your account has not been deleted.',
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
              if (flow.error != null)
                Semantics(
                  liveRegion: true,
                  child: Text(
                    flow.error!,
                    key: const Key('delete_error'),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              if (auth.hasPendingDeletion)
                OutlinedButton(
                  key: const Key('delete_check_again'),
                  onPressed: auth.isBusy
                      ? null
                      : () async {
                          final outcome = await auth.checkPendingDeletion();
                          if (!context.mounted) return;
                          if (outcome == DeletionOutcome.deleted) {
                            Navigator.pop(context, true);
                          }
                        },
                  child: Text(
                    auth.isBusy ? 'Checking…' : 'Check whether it was deleted',
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Forms are small: keep every input mounted so focus can reveal it with the
/// keyboard open, even on a compact screen with large accessibility text.
class _AccountFormScroll extends StatelessWidget {
  const _AccountFormScroll({
    required this.children,
    this.padding = EdgeInsets.zero,
    this.keyboardDismissBehavior = ScrollViewKeyboardDismissBehavior.onDrag,
  });
  final List<Widget> children;
  final EdgeInsetsGeometry padding;
  final ScrollViewKeyboardDismissBehavior keyboardDismissBehavior;
  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: padding,
    keyboardDismissBehavior: keyboardDismissBehavior,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    ),
  );
}
