import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/theme/pixel_metrics.dart';
import '../core/theme/pixel_palette.dart';
import '../models/part_of_speech.dart';
import '../models/vocabulary_word.dart';
import '../providers/vocabulary_provider.dart';
import '../widgets/pixel/pixel_button.dart';
import '../widgets/pixel/pixel_field.dart';
import '../widgets/pixel/pixel_icon.dart';

/// Full-screen capture and edit form.
///
/// This replaces the modal bottom sheet. A sheet capped at 85% height fought
/// the keyboard on small phones, and the form now has more fields than a
/// sheet can show at once.
class WordEditorScreen extends StatefulWidget {
  const WordEditorScreen({super.key, this.existing});

  final VocabularyWord? existing;

  bool get isEditing => existing != null;

  @override
  State<WordEditorScreen> createState() => _WordEditorScreenState();
}

class _WordEditorScreenState extends State<WordEditorScreen> {
  late final TextEditingController _word;
  late final TextEditingController _meaning;
  late final TextEditingController _pronunciation;
  late final TextEditingController _source;
  late final TextEditingController _tags;
  final List<TextEditingController> _examples = [];

  PartOfSpeech? _partOfSpeech;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _word = TextEditingController(text: existing?.word ?? '');
    _meaning = TextEditingController(text: existing?.meaning ?? '');
    _pronunciation = TextEditingController(text: existing?.pronunciation ?? '');
    _source = TextEditingController(text: existing?.source ?? '');
    _tags = TextEditingController(text: existing?.tags.join(', ') ?? '');
    _partOfSpeech = existing?.partOfSpeech;
    for (final example in existing?.examples ?? const <String>[]) {
      _examples.add(TextEditingController(text: example));
    }
  }

  @override
  void dispose() {
    for (final controller in [
      _word,
      _meaning,
      _pronunciation,
      _source,
      _tags,
      ..._examples,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  bool get _canSave =>
      _word.text.trim().isNotEmpty && _meaning.text.trim().isNotEmpty;

  List<String> get _exampleValues =>
      _examples.map((c) => c.text).toList(growable: false);

  List<String> get _tagValues => _tags.text
      .split(RegExp(r'[,\s]+'))
      .map((t) => t.replaceAll('#', '').trim())
      .where((t) => t.isNotEmpty)
      .toList(growable: false);

  void _addExample() {
    setState(() => _examples.add(TextEditingController()));
  }

  void _removeExample(int index) {
    setState(() => _examples.removeAt(index).dispose());
  }

  Future<void> _save() async {
    if (!_canSave || _saving) return;
    setState(() => _saving = true);

    final provider = context.read<VocabularyProvider>();
    final existing = widget.existing;

    if (existing == null) {
      await provider.addWord(
        word: _word.text,
        meaning: _meaning.text,
        pronunciation: _pronunciation.text,
        partOfSpeech: _partOfSpeech,
        source: _source.text,
        examples: _exampleValues,
        tags: _tagValues,
      );
    } else {
      await provider.updateWord(
        existing,
        word: _word.text,
        meaning: _meaning.text,
        pronunciation: _pronunciation.text,
        partOfSpeech: _partOfSpeech,
        source: _source.text,
        examples: _exampleValues,
        tags: _tagValues,
      );
    }

    if (!mounted) return;
    if (provider.lastError != null) {
      // Stay on the form so nothing typed is lost.
      setState(() => _saving = false);
      return;
    }
    Navigator.of(context).pop();
  }

  Future<void> _delete() async {
    final existing = widget.existing;
    if (existing == null) return;

    final confirmed = await _confirmDelete(context, existing.word);
    if (!confirmed || !mounted) return;

    await context.read<VocabularyProvider>().deleteWord(existing.id);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final provider = context.watch<VocabularyProvider>();

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _EditorTopBar(
              title: widget.isEditing ? 'EDIT WORD' : 'NEW WORD',
              onClose: () => Navigator.of(context).pop(),
            ),
            if (provider.lastError != null)
              _ErrorBanner(
                message: provider.lastError!,
                onDismiss: provider.consumeError,
              ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(PixelMetrics.space4),
                children: [
                  PixelField(
                    controller: _word,
                    label: 'English word',
                    hint: 'resilient',
                    autofocus: !widget.isEditing,
                    textInputAction: TextInputAction.next,
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: PixelMetrics.space4),
                  PixelField(
                    controller: _meaning,
                    label: 'What it means',
                    hint: 'kiên cường',
                    textCapitalization: TextCapitalization.sentences,
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: PixelMetrics.space4),
                  _PartOfSpeechPicker(
                    selected: _partOfSpeech,
                    onSelected: (value) =>
                        setState(() => _partOfSpeech = value),
                  ),
                  const SizedBox(height: PixelMetrics.space4),
                  PixelField(
                    controller: _pronunciation,
                    label: 'Pronunciation',
                    hint: '/rɪˈzɪliənt/',
                    optional: true,
                  ),
                  const SizedBox(height: PixelMetrics.space4),
                  PixelField(
                    controller: _source,
                    label: 'Where you met it',
                    hint: 'a PR review, a podcast, a colleague',
                    optional: true,
                    textCapitalization: TextCapitalization.sentences,
                  ),
                  const SizedBox(height: PixelMetrics.space4),
                  _ExamplesSection(
                    controllers: _examples,
                    onAdd: _addExample,
                    onRemove: _removeExample,
                  ),
                  const SizedBox(height: PixelMetrics.space4),
                  PixelField(
                    controller: _tags,
                    label: 'Tags',
                    hint: 'work, tech',
                    optional: true,
                  ),
                  const SizedBox(height: PixelMetrics.space6),
                  if (widget.isEditing) ...[
                    PixelButton(
                      label: 'Delete this word',
                      glyph: PixelGlyph.trash,
                      danger: true,
                      expand: true,
                      onPressed: _delete,
                    ),
                    const SizedBox(height: PixelMetrics.space6),
                  ],
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.all(PixelMetrics.space4),
              decoration: BoxDecoration(
                color: palette.paper,
                border: Border(
                  top: BorderSide(
                    color: palette.border,
                    width: PixelMetrics.border,
                  ),
                ),
              ),
              child: PixelButton(
                label: _saving
                    ? 'Saving…'
                    : (widget.isEditing ? 'Save changes' : 'Save word'),
                glyph: PixelGlyph.check,
                filled: true,
                expand: true,
                onPressed: _canSave && !_saving ? _save : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EditorTopBar extends StatelessWidget {
  const _EditorTopBar({required this.title, required this.onClose});

  final String title;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Container(
      padding: const EdgeInsets.fromLTRB(
        PixelMetrics.space4,
        PixelMetrics.space2,
        PixelMetrics.space2,
        PixelMetrics.space2,
      ),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: palette.border, width: PixelMetrics.border),
        ),
      ),
      child: Row(
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const Spacer(),
          PixelIconButton(
            glyph: PixelGlyph.close,
            semanticLabel: 'Close without saving',
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}

class _PartOfSpeechPicker extends StatelessWidget {
  const _PartOfSpeechPicker({required this.selected, required this.onSelected});

  final PartOfSpeech? selected;
  final ValueChanged<PartOfSpeech?> onSelected;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('PART OF SPEECH (OPTIONAL)', style: theme.textTheme.labelSmall),
        const SizedBox(height: PixelMetrics.space2),
        Wrap(
          spacing: PixelMetrics.space2,
          runSpacing: PixelMetrics.space2,
          children: [
            for (final value in PartOfSpeech.values)
              GestureDetector(
                // Tapping the current choice clears it, so the field stays
                // optional without needing a separate "none" chip.
                onTap: () => onSelected(selected == value ? null : value),
                behavior: HitTestBehavior.opaque,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: PixelMetrics.space3,
                    vertical: PixelMetrics.space2,
                  ),
                  decoration: BoxDecoration(
                    color: selected == value ? palette.accent : palette.surface,
                    border: Border.all(
                      color: palette.border,
                      width: PixelMetrics.border,
                    ),
                  ),
                  child: Text(
                    value.label.toUpperCase(),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: selected == value ? palette.onAccent : palette.ink,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _ExamplesSection extends StatelessWidget {
  const _ExamplesSection({
    required this.controllers,
    required this.onAdd,
    required this.onRemove,
  });

  final List<TextEditingController> controllers;
  final VoidCallback onAdd;
  final ValueChanged<int> onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              'THE SENTENCE YOU HEARD (OPTIONAL)',
              style: theme.textTheme.labelSmall,
            ),
            const Spacer(),
            PixelIconButton(
              glyph: PixelGlyph.plus,
              semanticLabel: 'Add another sentence',
              onPressed: onAdd,
            ),
          ],
        ),
        const SizedBox(height: PixelMetrics.space1),
        for (var index = 0; index < controllers.length; index++)
          Padding(
            padding: const EdgeInsets.only(bottom: PixelMetrics.space2),
            child: PixelField(
              controller: controllers[index],
              label: 'Sentence ${index + 1}',
              hint: 'a resilient distributed system',
              maxLines: 3,
              textCapitalization: TextCapitalization.sentences,
              trailing: PixelIconButton(
                glyph: PixelGlyph.close,
                semanticLabel: 'Remove sentence ${index + 1}',
                onPressed: () => onRemove(index),
              ),
            ),
          ),
      ],
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message, required this.onDismiss});

  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: PixelMetrics.space4,
        vertical: PixelMetrics.space2,
      ),
      color: palette.danger,
      child: Row(
        children: [
          Expanded(
            child: Text(
              message.toUpperCase(),
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(color: palette.onAccent),
            ),
          ),
          PixelIconButton(
            glyph: PixelGlyph.close,
            semanticLabel: 'Dismiss error',
            onPressed: onDismiss,
          ),
        ],
      ),
    );
  }
}

Future<bool> _confirmDelete(BuildContext context, String word) async {
  final palette = context.palette;
  final result = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => Dialog(
      backgroundColor: palette.surface,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: palette.border, width: PixelMetrics.border),
        borderRadius: BorderRadius.zero,
      ),
      child: Padding(
        padding: const EdgeInsets.all(PixelMetrics.space4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'DELETE "${word.toUpperCase()}"?',
              style: Theme.of(dialogContext).textTheme.titleMedium,
            ),
            const SizedBox(height: PixelMetrics.space2),
            Text(
              'You can undo this straight afterwards.',
              style: Theme.of(dialogContext).textTheme.bodyMedium,
            ),
            const SizedBox(height: PixelMetrics.space4),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                PixelButton(
                  label: 'Keep',
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                ),
                const SizedBox(width: PixelMetrics.space2),
                PixelButton(
                  label: 'Delete',
                  danger: true,
                  onPressed: () => Navigator.of(dialogContext).pop(true),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
  return result ?? false;
}
