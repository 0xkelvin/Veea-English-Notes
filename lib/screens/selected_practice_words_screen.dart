import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../core/theme/pixel_metrics.dart';
import '../providers/app_gate_provider.dart';
import '../widgets/practice_word_picker.dart';

/// Reviews the saved practice pool without changing its selection or rotation.
class SelectedPracticeWordsScreen extends StatefulWidget {
  const SelectedPracticeWordsScreen({super.key, required this.gate});
  final AppGateProvider gate;

  @override
  State<SelectedPracticeWordsScreen> createState() =>
      _SelectedPracticeWordsScreenState();
}

class _SelectedPracticeWordsScreenState
    extends State<SelectedPracticeWordsScreen> {
  final _search = TextEditingController();
  String _query = '';
  bool _editing = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  String _dateLabel(String date) {
    final parsed = DateTime.tryParse(date);
    return parsed == null ? date : DateFormat.yMMMd().format(parsed);
  }

  Future<void> _edit() async {
    setState(() => _editing = true);
    try {
      await choosePracticeWords(context, widget.gate);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Could not update your practice words. Please try again.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _editing = false);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.gate,
    builder: (context, _) {
      final words = widget.gate.practiceWords.toList()
        ..sort((a, b) {
          final date = b.date.compareTo(a.date);
          return date != 0
              ? date
              : a.word.toLowerCase().compareTo(b.word.toLowerCase());
        });
      final query = _query.trim().toLowerCase();
      final dateLabels = {
        for (final date in words.map((word) => word.date).toSet())
          date: _dateLabel(date),
      };
      final visible = words
          .where(
            (word) =>
                query.isEmpty ||
                '${word.word} ${word.meaning} ${word.tags.join(' ')} ${word.date} ${dateLabels[word.date]}'
                    .toLowerCase()
                    .contains(query),
          )
          .toList();
      return Scaffold(
        appBar: AppBar(
          title: const Text('Selected words'),
          actions: [
            TextButton(
              key: const Key('edit_selected_practice_words'),
              onPressed: _editing || widget.gate.notebookWords.isEmpty
                  ? null
                  : _edit,
              child: const Text('Edit'),
            ),
          ],
          bottom: PreferredSize(
            preferredSize: Size.fromHeight(
              MediaQuery.textScalerOf(context).scale(16) * 1.5 + 12,
            ),
            child: Padding(
              padding: const EdgeInsets.only(bottom: PixelMetrics.space3),
              child: Text(
                MediaQuery.textScalerOf(context).scale(14) > 18
                    ? '${words.length} selected'
                    : '${words.length} ${words.length == 1 ? 'word' : 'words'} in practice',
                key: const Key('selected_practice_word_count'),
              ),
            ),
          ),
        ),
        body: SafeArea(
          top: false,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(PixelMetrics.space4),
                child: TextField(
                  key: const Key('selected_practice_word_search'),
                  controller: _search,
                  onChanged: (value) => setState(() => _query = value),
                  decoration: InputDecoration(
                    isDense: true,
                    prefixIcon: const Icon(Icons.search),
                    hintText: 'Search selected words',
                    suffixIcon: _query.isEmpty
                        ? null
                        : IconButton(
                            tooltip: 'Clear search',
                            onPressed: () => setState(() {
                              _search.clear();
                              _query = '';
                            }),
                            icon: const Icon(Icons.close),
                          ),
                  ),
                ),
              ),
              if (query.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: PixelMetrics.space2),
                  child: Text(
                    '${visible.length} of ${words.length} selected words shown',
                  ),
                ),
              Expanded(
                child: visible.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(PixelMetrics.space6),
                          child: Text(
                            words.isEmpty
                                ? widget.gate.notebookWords.isEmpty
                                      ? 'Your notebook has no saved words yet.'
                                      : 'No practice words selected. Tap Edit to choose your words.'
                                : 'No selected words match. Try another search.',
                          ),
                        ),
                      )
                    : ListView.builder(
                        key: const Key('selected_practice_word_list'),
                        keyboardDismissBehavior:
                            ScrollViewKeyboardDismissBehavior.onDrag,
                        itemCount: visible.length,
                        itemBuilder: (context, index) {
                          final word = visible[index];
                          final showDate =
                              index == 0 ||
                              visible[index - 1].date != word.date;
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (showDate)
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    PixelMetrics.space4,
                                    PixelMetrics.space3,
                                    PixelMetrics.space4,
                                    PixelMetrics.space1,
                                  ),
                                  child: Semantics(
                                    header: true,
                                    child: Text(
                                      dateLabels[word.date]!,
                                      style: Theme.of(
                                        context,
                                      ).textTheme.titleSmall,
                                    ),
                                  ),
                                ),
                              ListTile(
                                key: ValueKey(
                                  'selected_practice_word_${word.id}',
                                ),
                                title: Text(word.word),
                                subtitle: Text(word.meaning),
                              ),
                            ],
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
