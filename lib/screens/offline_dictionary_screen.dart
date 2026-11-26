import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../data/word_suggestion_store.dart';
import '../services/word_suggestion_service.dart';
import '../widgets/pixel/pixel_box.dart';

class OfflineDictionaryScreen extends StatefulWidget {
  const OfflineDictionaryScreen({super.key});
  @override
  State<OfflineDictionaryScreen> createState() =>
      _OfflineDictionaryScreenState();
}

class _OfflineDictionaryScreenState extends State<OfflineDictionaryScreen> {
  late Future<int> _count;
  late Future<String> _notice;
  bool _clearing = false;

  @override
  void initState() {
    super.initState();
    _count = WordSuggestionService.savedLookupCount();
    _notice = rootBundle.loadString(SqliteWordSuggestionStore.noticePath);
  }

  Future<void> _clear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear saved lookups?'),
        content: const Text(
          'Removes saved online meanings from this phone. Your notebook words and the bundled dictionary stay available.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const Key('confirm_clear_saved_lookups'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear saved lookups'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _clearing = true);
    try {
      await WordSuggestionService.clearSavedLookups();
      if (mounted) {
        setState(() => _count = WordSuggestionService.savedLookupCount());
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not clear saved lookups. Please try again.'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Offline dictionary')),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          PixelBox(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'English → Vietnamese',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                const Text(
                  '110,986 entries included with Veea. No download, account or internet connection is needed to look them up.',
                ),
                const SizedBox(height: 8),
                const Text(
                  'Your own saved meanings take priority. Suggestions are a starting point; choose the meaning that fits your context.',
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'Saved online lookups',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          const Text(
            'When you approve an online lookup, successful results are saved on this phone for later offline use, including after restarting Veea. They stay separate from your notebook and are not synced to an account.',
          ),
          const SizedBox(height: 8),
          FutureBuilder<int>(
            future: _count,
            builder: (context, snapshot) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  snapshot.hasError
                      ? 'Saved lookup count is unavailable.'
                      : '${snapshot.data ?? 0} saved ${snapshot.data == 1 ? 'lookup' : 'lookups'}',
                  key: const Key('saved_lookup_count'),
                ),
                TextButton.icon(
                  key: const Key('clear_saved_lookups'),
                  onPressed:
                      _clearing || !snapshot.hasData || snapshot.data == 0
                      ? null
                      : _clear,
                  icon: const Icon(Icons.delete_outline),
                  label: Text(_clearing ? 'Clearing…' : 'Clear saved lookups'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'Dictionary sources and licence',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          FutureBuilder<String>(
            future: _notice,
            builder: (context, snapshot) => SelectableText(
              snapshot.data ??
                  (snapshot.hasError
                      ? 'Could not load dictionary credits. Please reopen this page.'
                      : 'Loading credits…'),
            ),
          ),
          const SizedBox(height: 8),
          TextButton.icon(
            key: const Key('dictionary_full_licence'),
            icon: const Icon(Icons.description_outlined),
            label: const Text('Read full licence'),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const _DictionaryLicenceScreen(),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class _DictionaryLicenceScreen extends StatefulWidget {
  const _DictionaryLicenceScreen();
  @override
  State<_DictionaryLicenceScreen> createState() =>
      _DictionaryLicenceScreenState();
}

class _DictionaryLicenceScreenState extends State<_DictionaryLicenceScreen> {
  late final Future<String> _text = rootBundle.loadString(
    SqliteWordSuggestionStore.licencePath,
  );
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('CC BY-SA 4.0')),
    body: SafeArea(
      child: FutureBuilder<String>(
        future: _text,
        builder: (context, snapshot) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            SelectableText(
              snapshot.data ??
                  (snapshot.hasError
                      ? 'Could not load the licence. Please reopen this page.'
                      : 'Loading licence…'),
            ),
          ],
        ),
      ),
    ),
  );
}
