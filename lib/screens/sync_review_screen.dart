import 'package:flutter/material.dart';

import '../data/sync/sync_engine.dart';

/// Per-item recovery and explicit guest-import controls (TRD 05 §§8–10).
class SyncReviewScreen extends StatefulWidget {
  const SyncReviewScreen({super.key, required this.engine});
  final SyncEngine engine;
  @override
  State<SyncReviewScreen> createState() => _SyncReviewScreenState();
}

class _SyncReviewScreenState extends State<SyncReviewScreen> {
  List<ReviewItem> _items = [];
  List<Map<String, Object?>> _held = [];
  bool _busy = true;
  String? _message;
  @override
  void initState() {
    super.initState();
    _load(prompt: true);
  }

  Future<void> _load({bool prompt = false}) async {
    try {
      final items = await widget.engine.reviewItems();
      final held = await widget.engine.heldWords();
      final ask = prompt && await widget.engine.shouldPromptImport();
      if (!mounted) return;
      setState(() {
        _items = items;
        _held = held;
        _busy = false;
      });
      if (ask) await _import();
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _message = 'Could not load sync review. Try again.';
        });
      }
    }
  }

  Future<void> _action(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await action();
    } catch (_) {
      if (mounted) {
        setState(
          () => _message =
              'This action is unavailable. Refresh and review the item again.',
        );
      }
    }
    await _load();
  }

  Future<void> _import() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      var reconfirm = await widget.engine.requiresImportConfirmation();
      while (mounted) {
        final plan = await widget.engine.planImport();
        final pending = await widget.engine.pendingImportSelection();
        final locked = pending.isNotEmpty;
        final selected = pending.toSet();
        if (!mounted) return;
        final accepted = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (context) => StatefulBuilder(
            builder: (context, update) => AlertDialog(
              title: Text(
                reconfirm
                    ? 'Capacity changed — confirm again'
                    : 'Import local words',
              ),
              content: SizedBox(
                width: 420,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${plan.remainingWords} words and ${plan.remainingBytes} bytes available. '
                        'Only selected local words will move. Other words stay on this device.',
                      ),
                      if (locked)
                        const Text(
                          'An earlier attempt may have completed. Its original selection is kept while the server resolves it.',
                        ),
                      for (final w in plan.candidates)
                        CheckboxListTile(
                          title: Text(w.word),
                          subtitle: Text(w.meaning),
                          value: selected.contains(w.id),
                          onChanged: locked
                              ? null
                              : (v) => update(() {
                                  v == true
                                      ? selected.add(w.id)
                                      : selected.remove(w.id);
                                }),
                        ),
                      if (plan.duplicates.isNotEmpty)
                        Text(
                          '${plan.duplicates.length} matching words excluded.',
                        ),
                      if (!locked && !plan.fits(selected))
                        const Text(
                          'Choose fewer words to fit the available capacity.',
                        ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: Text(locked ? 'Later' : 'Keep on this device'),
                ),
                FilledButton(
                  onPressed:
                      selected.isEmpty || (!locked && !plan.fits(selected))
                      ? null
                      : () => Navigator.pop(context, true),
                  child: Text(
                    reconfirm ? 'Confirm import again' : 'Import selected',
                  ),
                ),
              ],
            ),
          ),
        );
        if (accepted != true) {
          if (!locked && !reconfirm) await widget.engine.declineImport();
          break;
        }
        final result = reconfirm
            ? await widget.engine.confirmImport(plan, selected.toList())
            : await widget.engine.importWords(plan, selected.toList());
        if (result.needsConfirmation) {
          reconfirm = true;
          continue;
        }
        if (mounted) {
          setState(
            () => _message = result.pending
                ? 'The outcome is pending. The original request is saved for retry.'
                : '${result.imported} words imported. ${result.leftInGuest} kept on this device.',
          );
        }
        break;
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _message =
              'Could not check import capacity. Your words are still on this device.',
        );
      }
    } finally {
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Sync review')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (_message != null) Text(_message!),
        if (_busy) const Text('Working…'),
        FilledButton(
          onPressed: _busy ? null : _import,
          child: const Text('Import local words'),
        ),
        for (final item in _items)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${item.op}: ${item.content?['word'] ?? item.entityId}'),
                  Text(item.reason),
                  if (item.op == 'delete' ||
                      (item.op == 'update' &&
                          item.serverRecord != null &&
                          item.serverRecord?['deleted'] != true) ||
                      (item.op == 'restore' &&
                          item.serverRecord?['deleted'] == true))
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => _action(
                              () => widget.engine.applyReview(item.id),
                            ),
                      child: Text(
                        item.op == 'delete'
                            ? 'Apply delete'
                            : 'Apply this edit',
                      ),
                    ),
                  if (item.op != 'delete' &&
                      (item.serverRecord == null ||
                          item.serverRecord?['deleted'] == true))
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => _action(() async {
                              await widget.engine.addAgainAsNewWord(item.id);
                            }),
                      child: const Text('Add again as new word'),
                    ),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => _action(
                            () => widget.engine.discardReview(item.id),
                          ),
                    child: const Text('Discard'),
                  ),
                ],
              ),
            ),
          ),
        for (final word in _held)
          ListTile(
            title: Text(word['word']! as String),
            subtitle: const Text('Not backed up — account capacity reached'),
            trailing: TextButton(
              onPressed: _busy
                  ? null
                  : () => _action(
                      () => widget.engine.backUpNow(word['id']! as String),
                    ),
              child: const Text('Back up now'),
            ),
          ),
        if (!_busy && _items.isEmpty && _held.isEmpty)
          const Text('No edits need review.'),
      ],
    ),
  );
}
