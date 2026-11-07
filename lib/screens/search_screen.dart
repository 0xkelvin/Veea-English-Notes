import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../core/theme/pixel_metrics.dart';
import '../core/theme/pixel_palette.dart';
import '../models/vocabulary_word.dart';
import '../providers/vocabulary_provider.dart';
import '../widgets/pixel/pixel_button.dart';
import '../widgets/pixel/pixel_field.dart';
import '../widgets/pixel/pixel_icon.dart';
import '../widgets/word_row.dart';
import 'word_editor_screen.dart';

/// Searches every word ever captured.
///
/// Without this the app could only reach a word by navigating to the exact
/// day it was added, which made anything older than a few days effectively
/// unreachable.
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _controller = TextEditingController();
  Timer? _debounce;
  List<VocabularyWord> _results = const [];
  String _query = '';
  bool _searching = false;
  int _searchToken = 0;
  String? _error;
  bool _includeNotes = false;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value, {bool? includeNotes}) {
    _debounce?.cancel();
    ++_searchToken;
    setState(() {
      _includeNotes = includeNotes ?? _includeNotes;
      _query = value.trim();
      _results = const [];
      _error = null;
      _searching = _query.isNotEmpty;
    });
    if (_query.isNotEmpty) {
      _debounce = Timer(const Duration(milliseconds: 180), () => _run(value));
    }
  }

  Future<void> _run(String value) async {
    if (!mounted) return;
    final token = ++_searchToken;
    final trimmed = value.trim();
    if (trimmed.isEmpty) return;
    setState(() {
      _query = trimmed;
      _searching = true;
      _error = null;
    });
    try {
      final results = await context.read<VocabularyProvider>().search(
        trimmed,
        includeNotes: _includeNotes,
      );
      if (!mounted || token != _searchToken) return;
      setState(() {
        _results = results;
        _searching = false;
      });
    } catch (_) {
      if (!mounted || token != _searchToken) return;
      setState(() {
        _error = 'Could not search your words. Please try again.';
        _searching = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(PixelMetrics.space2),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color: palette.border,
                    width: PixelMetrics.border,
                  ),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      PixelIconButton(
                        glyph: PixelGlyph.arrowLeft,
                        semanticLabel: 'Back',
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                      const SizedBox(width: PixelMetrics.space2),
                      Expanded(
                        child: PixelSearchField(
                          controller: _controller,
                          onChanged: _onChanged,
                          hint: _includeNotes
                              ? 'Search words, meanings or notes'
                              : 'Search English words',
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: PixelMetrics.space2),
                  FilterChip(
                    key: const Key('search_include_notes'),
                    label: const Text('Meanings & notes'),
                    tooltip:
                        'Also search translations, examples, sources and tags',
                    selected: _includeNotes,
                    onSelected: (value) =>
                        _onChanged(_controller.text, includeNotes: value),
                  ),
                ],
              ),
            ),
            _ResultCount(
              query: _query,
              count: _results.length,
              searching: _searching,
            ),
            Expanded(child: _buildResults()),
          ],
        ),
      ),
    );
  }

  Widget _buildResults() {
    if (_error != null) {
      return Center(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(PixelMetrics.space6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(_error!, textAlign: TextAlign.center),
                const SizedBox(height: PixelMetrics.space3),
                PixelButton(label: 'Try again', onPressed: () => _run(_query)),
              ],
            ),
          ),
        ),
      );
    }
    if (_query.isEmpty) return _SearchHint(includeNotes: _includeNotes);
    if (_searching) return const Center(child: CircularProgressIndicator());
    if (_results.isEmpty) {
      return Center(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(PixelMetrics.space6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'No words match “$_query”',
                  style: Theme.of(context).textTheme.titleMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: PixelMetrics.space2),
                Text(
                  _includeNotes
                      ? 'Try part of a word, its meaning, or a tag.'
                      : 'Try another spelling, or search meanings and notes too.',
                  textAlign: TextAlign.center,
                ),
                if (!_includeNotes) ...[
                  const SizedBox(height: PixelMetrics.space3),
                  PixelButton(
                    label: 'Search meanings & notes',
                    onPressed: () =>
                        _onChanged(_controller.text, includeNotes: true),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    }

    return ListView.builder(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.only(bottom: PixelMetrics.space12),
      itemCount: _results.length,
      itemBuilder: (context, index) {
        final word = _results[index];
        return WordRow(
          word: word,
          dateLabel: _formatDate(word.date),
          onTap: () => _openEditor(word),
        );
      },
    );
  }

  Future<void> _openEditor(VocabularyWord word) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => WordEditorScreen(existing: word)),
    );
    // The word may have been edited or deleted while the editor was open.
    if (mounted && _query.isNotEmpty) await _run(_query);
  }

  static String _formatDate(String key) {
    final parsed = DateTime.tryParse(key);
    return parsed == null ? key : DateFormat('EEE d MMM yyyy').format(parsed);
  }
}

class _ResultCount extends StatelessWidget {
  const _ResultCount({
    required this.query,
    required this.count,
    required this.searching,
  });

  final String query;
  final int count;
  final bool searching;

  @override
  Widget build(BuildContext context) {
    if (query.isEmpty) return const SizedBox.shrink();

    final palette = context.palette;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: PixelMetrics.space4,
        vertical: PixelMetrics.space2,
      ),
      decoration: BoxDecoration(
        color: palette.surface,
        border: Border(
          bottom: BorderSide(color: palette.border, width: PixelMetrics.border),
        ),
      ),
      child: Text(
        searching
            ? 'Searching…'
            : '$count ${count == 1 ? 'word found' : 'words found'}',
        style: Theme.of(context).textTheme.labelSmall,
      ),
    );
  }
}

class _SearchHint extends StatelessWidget {
  const _SearchHint({required this.includeNotes});

  final bool includeNotes;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(PixelMetrics.space6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Find a saved word',
                style: theme.textTheme.labelSmall,
                textAlign: TextAlign.center,
              ),
              Text(
                includeNotes
                    ? 'Search words, meanings, examples, sources or tags.'
                    : 'Type an English word or part of one.',
                style: theme.textTheme.labelSmall,
                textAlign: TextAlign.center,
              ),
              if (includeNotes) ...[
                const SizedBox(height: PixelMetrics.space4),
                // Accents are optional, which matters when typing on a keyboard
                // without Vietnamese input enabled.
                Text(
                  'kien cuong  finds  kiên cường',
                  style: theme.textTheme.bodyMedium,
                  textAlign: TextAlign.center,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
