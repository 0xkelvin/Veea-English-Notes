import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/config/app_config.dart';
import '../providers/auth_provider.dart';
import '../providers/pro_provider.dart';
import 'account_screen.dart';

class ProScreen extends StatelessWidget {
  const ProScreen({super.key});

  static ProProvider? _maybeReadPro(BuildContext context) {
    try {
      return context.read<ProProvider>();
    } on ProviderNotFoundException {
      return null;
    }
  }

  static AuthProvider? _maybeReadAuth(BuildContext context) {
    try {
      return context.read<AuthProvider>();
    } on ProviderNotFoundException {
      return null;
    }
  }

  static ProProvider? _maybeWatchPro(BuildContext context) {
    try {
      return context.watch<ProProvider>();
    } on ProviderNotFoundException {
      return null;
    }
  }

  static AuthProvider? _maybeWatchAuth(BuildContext context) {
    try {
      return context.watch<AuthProvider>();
    } on ProviderNotFoundException {
      return null;
    }
  }

  static Future<void> open(BuildContext context) {
    final pro = _maybeReadPro(context);
    final auth = _maybeReadAuth(context);
    if (pro != null &&
        !AppConfig.isFreeLaunch &&
        (pro.isConfigured || pro.hasPro || (auth?.isSignedIn ?? false))) {
      unawaited(pro.refresh());
    }
    return Navigator.of(
      context,
    ).push<void>(MaterialPageRoute(builder: (_) => const ProScreen()));
  }

  Future<void> _openAccount(BuildContext context) => Navigator.of(
    context,
  ).push<void>(MaterialPageRoute<void>(builder: (_) => const AccountScreen()));

  Future<void> _restore(
    BuildContext context,
    ProProvider pro,
    AuthProvider auth,
  ) async {
    if (!auth.isSignedIn) {
      await _openAccount(context);
    }
    if (context.mounted && auth.isSignedIn) {
      await pro.restore();
    }
  }

  @override
  Widget build(BuildContext context) {
    final pro = _maybeWatchPro(context);
    final auth = _maybeWatchAuth(context);
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final secondary = colorScheme.onSurfaceVariant;

    if (AppConfig.isFreeLaunch) {
      return Scaffold(
        appBar: AppBar(title: const Text('Previous purchases')),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              const Text('Veea is free in this release.'),
              const SizedBox(height: 12),
              const Text(
                'App locks, custom unlock times, listening and review do not require a purchase or account.',
              ),
              if (pro != null && auth != null && pro.isConfigured) ...[
                const SizedBox(height: 24),
                const Text(
                  'If you previously purchased Pro, you can restore its record using the original Veea account.',
                ),
                const SizedBox(height: 8),
                TextButton(
                  key: const Key('restore_pro'),
                  onPressed: pro.isBusy
                      ? null
                      : () => _restore(context, pro, auth),
                  child: const Text('Restore previous purchases'),
                ),
                if (pro.message != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(pro.message!, key: const Key('pro_message')),
                  ),
              ],
            ],
          ),
        ),
      );
    }

    final hasPro = pro?.hasPro ?? false;
    final hasLifetime = pro?.hasLifetime ?? false;
    final isSignedIn = auth?.isSignedIn ?? false;
    final price = pro?.price;
    final isBusy = pro?.isBusy ?? false;
    final hasProviders = pro != null && auth != null;

    return Scaffold(
      appBar: AppBar(title: const Text('Veea Pro')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
          children: [
            Center(
              child: ExcludeSemantics(
                child: Container(
                  width: 60,
                  height: 60,
                  decoration: BoxDecoration(
                    color: colorScheme.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Icon(
                    hasPro
                        ? Icons.verified_outlined
                        : Icons.auto_awesome_outlined,
                    size: 32,
                    color: colorScheme.primary,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              hasPro ? 'You have Veea Pro' : 'Learn more with every unlock',
              textAlign: TextAlign.center,
              style: theme.textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text(
              'Pay once. No subscription.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(color: secondary),
            ),
            if (!hasLifetime && price != null) ...[
              const SizedBox(height: 12),
              Center(
                child: Container(
                  key: const Key('pro_price_badge'),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: colorScheme.primary.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: colorScheme.primary.withValues(alpha: 0.28),
                    ),
                  ),
                  child: Text(
                    '$price · One-time purchase',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: colorScheme.primary,
                    ),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 24),
            _PlanCard(
              title: hasPro
                  ? 'Included in your Pro plan'
                  : 'One-time Pro upgrade',
              highlighted: true,
              children: const [
                _PlanBenefitRow(
                  icon: Icons.apps_outlined,
                  title: 'Lock multiple apps',
                  subtitle:
                      'Choose multiple apps to protect with vocabulary challenges.',
                ),
                SizedBox(height: 14),
                _PlanBenefitRow(
                  icon: Icons.format_list_numbered_outlined,
                  title: 'Multiple words per unlock',
                  subtitle:
                      'Choose how many vocabulary words to review before unlocking, up to your practice pool.',
                ),
              ],
            ),
            const SizedBox(height: 16),
            const _PlanCard(
              title: 'Always free',
              children: [
                _PlanBenefitRow(
                  icon: Icons.menu_book_outlined,
                  title: 'Full vocabulary learning',
                  subtitle:
                      'Unlimited saved words, dictionary lookup, Listen, Review, custom practice lists, and pronunciation.',
                ),
                SizedBox(height: 14),
                _PlanBenefitRow(
                  icon: Icons.lock_clock_outlined,
                  title: 'One app lock & all unlock times',
                  subtitle:
                      'Lock one app with 1 word per unlock, plus any default, custom, or per-app unlock duration.',
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              'Your vocabulary stays on this device. Your Veea account keeps your Pro purchase. Export a backup to keep a separate copy of your words.',
              style: theme.textTheme.bodySmall?.copyWith(color: secondary),
            ),
            const SizedBox(height: 20),
            if (hasPro && !isSignedIn) ...[
              _StatusBanner(
                icon: Icons.cloud_off_outlined,
                message:
                    'Pro is available offline on this device. Sign in to manage or restore your purchase.',
              ),
              const SizedBox(height: 16),
            ],
            if (hasLifetime && isSignedIn) ...[
              _StatusBanner(
                icon: Icons.check_circle_outline,
                message: 'Lifetime Pro is linked to your account.',
              ),
              const SizedBox(height: 16),
            ],
            if (pro?.message != null) ...[
              Semantics(
                liveRegion: true,
                child: _StatusBanner(
                  key: const Key('pro_message'),
                  icon: Icons.info_outline,
                  message: pro!.message!,
                ),
              ),
              const SizedBox(height: 16),
            ],
            if (!hasProviders) ...[
              const _StatusBanner(
                key: Key('pro_unavailable_notice'),
                icon: Icons.info_outline,
                message:
                    'Pro purchases are not available in this view right now. All free features remain available.',
              ),
            ] else ...[
              if (!hasLifetime && !isSignedIn) ...[
                FilledButton(
                  key: const Key('sign_in_for_pro'),
                  onPressed: isBusy ? null : () => _openAccount(context),
                  child: Text(
                    hasPro ? 'Sign in to manage Pro' : 'Sign in to get Pro',
                  ),
                ),
                if (pro.isConfigured) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Sign in only to buy or restore Pro. All free features work without an account.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: secondary,
                    ),
                  ),
                ],
              ] else if (!hasLifetime) ...[
                FilledButton(
                  key: const Key('buy_pro'),
                  onPressed: pro.canPurchase ? pro.purchase : null,
                  child: Text(
                    isBusy
                        ? 'Please wait…'
                        : price == null
                        ? 'Purchase unavailable'
                        : 'Get lifetime Pro · $price',
                  ),
                ),
              ],
              if ((!pro.isConfigured ||
                      (isSignedIn &&
                          pro.purchaseAvailabilityChecked &&
                          !pro.purchasesReady)) &&
                  !hasPro) ...[
                const SizedBox(height: 12),
                Text(
                  'Pro purchases are not available in this build yet. All free features remain available.',
                  style: theme.textTheme.bodySmall?.copyWith(color: secondary),
                ),
              ],
              const SizedBox(height: 8),
              TextButton(
                key: const Key('restore_pro'),
                onPressed: isBusy ? null : () => _restore(context, pro, auth),
                child: const Text('Restore purchases'),
              ),
              if (isBusy)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Semantics(
                    label: 'Checking purchase status',
                    child: const Center(child: CircularProgressIndicator()),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _PlanCard extends StatelessWidget {
  const _PlanCard({
    required this.title,
    required this.children,
    this.highlighted = false,
  });

  final String title;
  final List<Widget> children;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: highlighted
              ? colorScheme.primary.withValues(alpha: 0.45)
              : colorScheme.outlineVariant,
          width: highlighted ? 1.5 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: theme.textTheme.titleMedium?.copyWith(
              color: highlighted ? colorScheme.primary : colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 14),
          ...children,
        ],
      ),
    );
  }
}

class _PlanBenefitRow extends StatelessWidget {
  const _PlanBenefitRow({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: ExcludeSemantics(
            child: Icon(icon, size: 22, color: colorScheme.primary),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: theme.textTheme.titleSmall?.copyWith(
                  color: colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _StatusBanner extends StatelessWidget {
  const _StatusBanner({super.key, required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colorScheme.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colorScheme.primary.withValues(alpha: 0.25)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: ExcludeSemantics(
              child: Icon(icon, size: 20, color: colorScheme.primary),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
