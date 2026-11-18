import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../providers/pro_provider.dart';
import 'account_screen.dart';

class ProScreen extends StatelessWidget {
  const ProScreen({super.key});
  static Future<void> open(BuildContext context) => Navigator.of(
    context,
  ).push<void>(MaterialPageRoute(builder: (_) => const ProScreen()));
  @override
  Widget build(BuildContext context) {
    final pro = context.watch<ProProvider>();
    final auth = context.watch<AuthProvider>();
    return Scaffold(
      appBar: AppBar(title: const Text('Veea Pro')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Icon(
            pro.hasPro ? Icons.verified_outlined : Icons.auto_awesome_outlined,
            size: 48,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 16),
          Text(
            pro.hasPro ? 'You have Pro' : 'Make learning part of your day',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 12),
          const Text('Pay once. No subscription.', textAlign: TextAlign.center),
          const SizedBox(height: 24),
          const ListTile(
            leading: Icon(Icons.menu_book_outlined),
            title: Text('Always free'),
            subtitle: Text(
              'Unlimited saved words, Listen, Review, learning rules, and one app lock.',
            ),
          ),
          const ListTile(
            leading: Icon(Icons.lock_outline),
            title: Text('More apps with Pro'),
            subtitle: Text(
              'Lock multiple apps and set a custom unlock time for each.',
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'Your vocabulary stays on this device. Your Veea account keeps your Pro purchase. Export a backup to keep a separate copy of your words.',
          ),
          const SizedBox(height: 24),
          if (pro.hasPro && !auth.isSignedIn)
            const Padding(
              padding: EdgeInsets.only(bottom: 16),
              child: Text(
                'Pro is available offline. Sign in again to manage or restore your purchase.',
              ),
            ),
          if (pro.message != null) ...[
            Text(
              pro.message!,
              key: const Key('pro_message'),
              semanticsLabel: pro.message,
            ),
            const SizedBox(height: 16),
          ],
          if (!pro.hasLifetime && !auth.isSignedIn)
            FilledButton(
              onPressed: pro.isBusy
                  ? null
                  : () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const AccountScreen(),
                      ),
                    ),
              child: const Text('Sign in to get Pro'),
            )
          else if (!pro.hasLifetime)
            FilledButton(
              key: const Key('buy_pro'),
              onPressed: pro.canPurchase ? pro.purchase : null,
              child: Text(
                pro.isBusy
                    ? 'Please wait…'
                    : pro.price == null
                    ? 'Purchase unavailable'
                    : 'Get lifetime Pro · ${pro.price}',
              ),
            ),
          if ((!pro.isConfigured || !pro.purchasesReady) && !pro.hasPro) ...[
            const SizedBox(height: 12),
            const Text(
              'Pro purchases are not available in this build yet. All free features remain available.',
            ),
          ],
          const SizedBox(height: 8),
          TextButton(
            key: const Key('restore_pro'),
            onPressed: pro.isBusy
                ? null
                : () async {
                    if (!auth.isSignedIn) {
                      await Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const AccountScreen(),
                        ),
                      );
                    }
                    if (context.mounted && auth.isSignedIn) await pro.restore();
                  },
            child: const Text('Restore purchases'),
          ),
          if (pro.isBusy) const Center(child: CircularProgressIndicator()),
        ],
      ),
    );
  }
}
