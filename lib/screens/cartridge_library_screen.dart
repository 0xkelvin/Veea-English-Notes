import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../data/cartridges/cartridge_api.dart';
import '../data/cartridges_data.dart';
import '../data/remote/api_client.dart';
import '../providers/auth_provider.dart';
import '../providers/cartridge_provider.dart';
import '../providers/vocabulary_provider.dart';

/// Bundled offline starter and authenticated server metadata, never a bundled Premium catalog.
class CartridgeLibraryScreen extends StatefulWidget {
  const CartridgeLibraryScreen({super.key});
  @override
  State<CartridgeLibraryScreen> createState() => _CartridgeLibraryScreenState();
}

class _CartridgeLibraryScreenState extends State<CartridgeLibraryScreen> {
  String? _account;
  bool _reviewing = false;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final owner = context.watch<AuthProvider>().accountId ?? 'guest';
    if (_account != owner) {
      _account = owner;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) context.read<CartridgeProvider>().refreshCatalog();
      });
    }
  }

  Future<void> _install(CartridgeMetadata pack) async {
    final owner = context.read<AuthProvider>().accountId;
    final provider = context.read<CartridgeProvider>();
    final pending = await provider.pending(pack.id);
    Map<String, Object?>? capacity;
    try {
      if (pending?['needs_confirmation'] == 1) {
        capacity = await provider.refreshCapacity();
      }
    } on Object catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Connect to refresh capacity before confirming.'),
          ),
        );
      }
      return;
    }
    final version = pending?['pending_version'] as int? ?? pack.version;
    if (!mounted) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          pending?['needs_confirmation'] == 1
              ? 'Confirm refreshed capacity?'
              : pending?['pending_body'] != null
              ? 'Retry saved installation?'
              : pack.installedVersion > 0
              ? 'Update ${pack.title}?'
              : 'Install ${pack.title}?',
        ),
        content: Text(
          '${pending?['pending_body'] != null ? 'Retry the saved installation' : 'Install up to ${pack.wordCount} entries'} in version $version. Only new entries are added; your edited and deleted entries stay untouched. The pack must fit your current vocabulary quota.\n${capacity != null ? 'Currently used: ${capacity['live_words']} words, ${capacity['content_bytes']} bytes.' : provider.message ?? ''}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Confirm'),
          ),
        ],
      ),
    );
    if (confirm != true ||
        !mounted ||
        context.read<AuthProvider>().accountId != owner) {
      return;
    }
    try {
      await provider.installServer(pack, confirmedCapacity: capacity);
      if (mounted) await context.read<VocabularyProvider>().init();
    } on Object catch (_) {
      /* Fixed, secret-free message is owned by the provider. */
    }
  }

  void _reviewError(Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          error is ApiException
              ? error.message
              : 'Connect and try reviewing this installation again.',
        ),
      ),
    );
  }

  Future<void> _discard(BlockedCartridgeInstall request) async {
    try {
      await context.read<CartridgeProvider>().discardBlocked(request);
    } on Object catch (e) {
      _reviewError(e);
    }
  }

  Future<void> _newInstall(BlockedCartridgeInstall request) async {
    final provider = context.read<CartridgeProvider>();
    setState(() => _reviewing = true);
    try {
      final review = await provider.prepareNewInstall(request);
      if (!mounted || context.read<AuthProvider>().accountId != request.owner) {
        return;
      }
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => Consumer<AuthProvider>(
          builder: (ctx, auth, _) {
            if (!auth.isSignedIn || auth.accountId != request.owner) {
              return AlertDialog(
                title: const Text('Account changed'),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('Close'),
                  ),
                ],
              );
            }
            return AlertDialog(
              title: const Text('Start a new install?'),
              content: Text(
                'Discard the saved pre-restore request for ${request.id} v${request.version} and install ${review.pack.title} v${review.pack.version} for this account.\n'
                'Currently used: ${review.capacity['live_words']} words, ${review.capacity['content_bytes']} bytes. Up to ${review.pack.wordCount} entries must fit the current quota.\n'
                'This is a new request. Previously edited and deleted entries stay untouched.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  key: const Key('confirm-new-install'),
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Confirm new install'),
                ),
              ],
            );
          },
        ),
      );
      if (confirmed != true ||
          !mounted ||
          context.read<AuthProvider>().accountId != request.owner) {
        return;
      }
      await provider.startNewInstall(review);
      if (mounted) await context.read<VocabularyProvider>().init();
    } on Object catch (e) {
      _reviewError(e);
    } finally {
      if (mounted) setState(() => _reviewing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.watch<CartridgeProvider>();
    final auth = context.watch<AuthProvider>();
    final starter = CartridgesData.starter;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Cartridge Library'),
        actions: [
          IconButton(
            tooltip: 'Refresh catalog',
            onPressed: p.busy ? null : p.refreshCatalog,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (p.busy) const LinearProgressIndicator(),
          if (p.message != null && p.loadedOwner == auth.accountId)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(p.message!, key: const Key('cartridge-message')),
            ),
          if (auth.isSignedIn &&
              p.loadedOwner == auth.accountId &&
              p.blockedInstalls.isNotEmpty) ...[
            Text(
              'Installations needing review',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const Text(
              'These saved requests were blocked after a restore. They will stay here until you discard them or confirm a new installation.',
            ),
            for (final request in p.blockedInstalls)
              Card(
                key: Key('blocked-${request.id}'),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${request.id} · saved version ${request.version}'),
                      const Text(
                        'Discard only removes this saved request. Your installed words stay in your notebook.',
                      ),
                      Wrap(
                        spacing: 8,
                        children: [
                          TextButton(
                            key: Key('discard-${request.id}'),
                            onPressed: p.busy || _reviewing
                                ? null
                                : () => _discard(request),
                            child: const Text('Discard'),
                          ),
                          FilledButton(
                            key: Key('new-install-${request.id}'),
                            onPressed: p.busy || _reviewing
                                ? null
                                : () => _newInstall(request),
                            child: const Text('Start a new install'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
          ],
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    starter.title,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  Text(starter.description),
                  const Text('Free · available offline'),
                  for (final word in starter.words)
                    Text('${word.word} — ${word.meaning}'),
                  FilledButton(
                    key: const Key('install-starter'),
                    onPressed: p.busy
                        ? null
                        : () async {
                            await p.installCartridge(
                              starter.id,
                              vocabProvider: context.read<VocabularyProvider>(),
                            );
                          },
                    child: const Text('Add starter words'),
                  ),
                ],
              ),
            ),
          ),
          if (!auth.isSignedIn)
            const Text(
              'Sign in to browse Free and Premium server packs. Your notebook works offline.',
            ),
          if (auth.isSignedIn && p.catalog.isEmpty)
            const Text('No server catalog loaded. Refresh when online.'),
          if (auth.isSignedIn && p.loadedOwner == auth.accountId)
            for (final pack in p.catalog)
              Card(
                child: ListTile(
                  title: Text(pack.title),
                  subtitle: Text(
                    '${pack.plan == 'premium' ? 'Premium' : 'Free'} · v${pack.version} · ${pack.wordCount} entries\nInstalled version: ${pack.installedVersion}',
                  ),
                  trailing: TextButton(
                    key: Key('install-${pack.id}'),
                    onPressed:
                        p.busy ||
                            _reviewing ||
                            p.blockedInstalls.any((r) => r.id == pack.id)
                        ? null
                        : () => _install(pack),
                    child: Text(
                      p.blockedInstalls.any((r) => r.id == pack.id)
                          ? 'Review required'
                          : pack.installedVersion == 0
                          ? 'Install'
                          : pack.installedVersion < pack.version
                          ? 'Update'
                          : 'Check / retry',
                    ),
                  ),
                ),
              ),
          const Padding(
            padding: EdgeInsets.all(8),
            child: Text(
              'Installed words belong to your notebook and remain usable offline after Premium ends.',
            ),
          ),
        ],
      ),
    );
  }
}
