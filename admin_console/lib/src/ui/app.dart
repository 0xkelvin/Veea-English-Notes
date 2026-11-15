import 'package:flutter/material.dart';

import '../console_controller.dart';
import 'console_page.dart';

class ConsoleApp extends StatelessWidget {
  const ConsoleApp({super.key, required this.controller});
  final ConsoleController controller;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Veea Admin Console',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF2F5D8A),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: const Color(0xFF2F5D8A),
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: ListenableBuilder(
        listenable: controller,
        builder: (context, _) => switch (controller.phase) {
          Phase.signedOut => SignInPage(controller: controller),
          Phase.noAccess => NoAccessPage(controller: controller),
          Phase.ready => ConsolePage(controller: controller),
        },
      ),
    );
  }
}

class NoticeBanner extends StatelessWidget {
  const NoticeBanner({super.key, required this.controller});
  final ConsoleController controller;

  @override
  Widget build(BuildContext context) {
    final n = controller.notice;
    if (n == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      liveRegion: true,
      child: Container(
        key: const Key('notice'),
        width: double.infinity,
        margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
        decoration: BoxDecoration(
          color: n.error ? scheme.errorContainer : scheme.secondaryContainer,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Icon(
              n.error ? Icons.error_outline : Icons.check_circle_outline,
              color: n.error
                  ? scheme.onErrorContainer
                  : scheme.onSecondaryContainer,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                n.text,
                key: const Key('notice-text'),
                style: TextStyle(
                  color: n.error
                      ? scheme.onErrorContainer
                      : scheme.onSecondaryContainer,
                ),
              ),
            ),
            IconButton(
              tooltip: 'Dismiss',
              icon: const Icon(Icons.close),
              onPressed: controller.clearNotice,
            ),
          ],
        ),
      ),
    );
  }
}

class SignInPage extends StatefulWidget {
  const SignInPage({super.key, required this.controller});
  final ConsoleController controller;
  @override
  State<SignInPage> createState() => _SignInPageState();
}

class _SignInPageState extends State<SignInPage> {
  final _email = TextEditingController(),
      _password = TextEditingController(),
      _code = TextEditingController();
  bool _useCode = false;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final challenge = c.codeChallenge;
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: AutofillGroup(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Veea Admin Console',
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Sign in with an Admin or Super Admin account.',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      NoticeBanner(controller: c),
                      const SizedBox(height: 16),
                      TextField(
                        key: const Key('signin-email'),
                        controller: _email,
                        enabled: challenge == null,
                        autofillHints: const [AutofillHints.email],
                        keyboardType: TextInputType.emailAddress,
                        decoration: const InputDecoration(
                          labelText: 'Email',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      if (!_useCode) ...[
                        TextField(
                          key: const Key('signin-password'),
                          controller: _password,
                          obscureText: true,
                          autofillHints: const [AutofillHints.password],
                          onSubmitted: (_) => _submit(),
                          decoration: const InputDecoration(
                            labelText: 'Password',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ] else if (challenge != null) ...[
                        TextField(
                          key: const Key('signin-code'),
                          controller: _code,
                          keyboardType: TextInputType.number,
                          autofillHints: const [AutofillHints.oneTimeCode],
                          onSubmitted: (_) => _submit(),
                          decoration: const InputDecoration(
                            labelText: '6-digit code',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ],
                      const SizedBox(height: 16),
                      FilledButton(
                        key: const Key('signin-submit'),
                        onPressed: c.signingIn ? null : _submit,
                        child: c.signingIn
                            ? const SizedBox.square(
                                dimension: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : Text(
                                !_useCode
                                    ? 'Sign in'
                                    : (challenge == null
                                          ? 'Send code'
                                          : 'Verify code'),
                              ),
                      ),
                      TextButton(
                        onPressed: c.signingIn
                            ? null
                            : () {
                                c.cancelCode();
                                setState(() => _useCode = !_useCode);
                              },
                        child: Text(
                          _useCode
                              ? 'Use a password instead'
                              : 'Use an email code instead',
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _submit() {
    final c = widget.controller;
    if (!_useCode) {
      c.signInWithPassword(_email.text, _password.text);
    } else if (c.codeChallenge == null) {
      c.requestCode(_email.text);
    } else {
      c.verifyCode(_code.text);
    }
  }
}

class NoAccessPage extends StatelessWidget {
  const NoAccessPage({super.key, required this.controller});
  final ConsoleController controller;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.lock_outline, size: 48),
                const SizedBox(height: 12),
                Text(
                  'No admin access',
                  key: const Key('no-access'),
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                NoticeBanner(controller: controller),
                const SizedBox(height: 16),
                FilledButton(
                  key: const Key('no-access-signout'),
                  onPressed: () => controller.signOut(),
                  child: const Text('Sign out'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
