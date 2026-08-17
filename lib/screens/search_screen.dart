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

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    // Waiting a beat keeps the query off the main thread on every keystroke.
    _debounce = Timer(const Duration(milliseconds: 180), () => _run(value));
  }

  Future<void> _run(String value) async {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      setState(() {
        _query = '';
        _results = const [];
        _searching = false;
      });
      return;
    }

    setState(() => _searching = true);
    final results = await context.read<VocabularyProvider>().search(trimmed);
    if (!mounted) return;
    setState(() {
      _query = trimmed;
      _results = results;
      _searching = false;
    });
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
              child: Row(
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
                    ),
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
    if (_query.isEmpty) {
      return const _SearchHint();
    }
    if (_results.isEmpty && !_searching) {
      return Center(
        child: Text(
          'NOTHING MATCHES “${_query.toUpperCase()}”',
          style: Theme.of(context).textTheme.labelSmall,
          textAlign: TextAlign.center,
        ),
      );
    }

    return ListView.builder(
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
      PageRouteBuilder<void>(
        pageBuilder: (_, _, _) => WordEditorScreen(existing: word),
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
      ),
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
        searching ? 'SEARCHING…' : '$count MATCH${count == 1 ? '' : 'ES'}',
        style: Theme.of(context).textTheme.labelSmall,
      ),
    );
  }
}

class _SearchHint extends StatelessWidget {
  const _SearchHint();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(PixelMetrics.space6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'SEARCH THE WORD, THE MEANING,',
              style: theme.textTheme.labelSmall,
              textAlign: TextAlign.center,
            ),
            Text(
              'A SENTENCE, OR WHERE YOU MET IT',
              style: theme.textTheme.labelSmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: PixelMetrics.space4),
            // Accents are optional, which matters when typing on a keyboard
            // without Vietnamese input enabled.
            Text(
              'kien cuong  finds  kiên cường',
              style: theme.textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
