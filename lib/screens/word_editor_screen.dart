import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/theme/pixel_metrics.dart';
import '../core/theme/pixel_palette.dart';
import '../models/part_of_speech.dart';
import '../models/vocabulary_word.dart';
import '../providers/vocabulary_provider.dart';
import '../services/pronunciation_service.dart';
import '../widgets/pixel/context_wizard_sheet.dart';
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
  late final TextEditingController _source;
  late final TextEditingController _tags;
  final List<TextEditingController> _examples = [];

  PartOfSpeech? _partOfSpeech;
  bool _saving = false;

  /// Looked up from the bundled dictionary as the word is typed.
  String? _pronunciation;

  /// Set when the user has overridden the automatic value, which then stops
  /// being replaced on every keystroke.
  bool _pronunciationIsManual = false;

  /// Guards against an earlier, slower lookup landing after a later one and
  /// showing the pronunciation of a word that has since been edited.
  int _lookupToken = 0;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _word = TextEditingController(text: existing?.word ?? '');
    _meaning = TextEditingController(text: existing?.meaning ?? '');
    _source = TextEditingController(text: existing?.source ?? '');
    _tags = TextEditingController(text: existing?.tags.join(', ') ?? '');
    _partOfSpeech = existing?.partOfSpeech;
    for (final example in existing?.examples ?? const <String>[]) {
      _examples.add(TextEditingController(text: example));
    }

    _pronunciation = existing?.pronunciation;
    // An existing word already carries a transcription, but it may predate the
    // dictionary, so treat it as automatic and let a fresh lookup refresh it.
    _pronunciationIsManual = false;
    if (existing != null) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _refreshPronunciation(existing.word),
      );
    }
  }

  @override
  void dispose() {
    for (final controller in [_word, _meaning, _source, _tags, ..._examples]) {
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

  /// Fills the pronunciation from the bundled dictionary.
  ///
  /// A manual override wins: once the user has corrected it, typing in the
  /// word field must not silently undo their correction.
  Future<void> _refreshPronunciation(String word) async {
    if (_pronunciationIsManual) return;

    final token = ++_lookupToken;
    final found = await context.read<PronunciationService>().lookup(word);

    // A later keystroke already started its own lookup; this result is stale.
    if (!mounted || token != _lookupToken) return;
    setState(() => _pronunciation = found);
  }

  /// Lets the user type a transcription themselves.
  ///
  /// Rarely needed, so it is a dialog rather than a permanent field competing
  /// with the word and its meaning.
  Future<void> _editPronunciation() async {
    final result = await showDialog<String>(
      context: context,
      builder: (_) => _PronunciationDialog(initialValue: _pronunciation ?? ''),
    );

    if (result == null || !mounted) return;
    setState(() {
      // Users type the slashes they see; store the canonical form without.
      final trimmed = PronunciationService.normalise(result);
      _pronunciation = trimmed.isEmpty ? null : trimmed;
      _pronunciationIsManual = trimmed.isNotEmpty;
    });
  }

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
        pronunciation: _pronunciation,
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
        pronunciation: _pronunciation,
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

  void _openContextWizard() {
    final targetWord =
        _word.text.trim().isNotEmpty ? _word.text.trim() : 'resilient';
    ContextWizardSheet.show(
      context: context,
      word: targetWord,
      meaning: _meaning.text.trim(),
      onSelectSentence: (sentence) {
        setState(() {
          if (_examples.isEmpty) {
            _examples.add(TextEditingController(text: sentence));
          } else {
            _examples.first.text = sentence;
          }
        });
      },
      onAddTag: (tag) {
        setState(() {
          final current = _tags.text.trim();
          if (current.isEmpty) {
            _tags.text = tag;
          } else {
            _tags.text = '$current, $tag';
          }
        });
      },
    );
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
                    onChanged: (value) {
                      setState(() {});
                      _refreshPronunciation(value);
                    },
                  ),
                  const SizedBox(height: PixelMetrics.space2),
                  _PronunciationLine(
                    ipa: _pronunciation,
                    isManual: _pronunciationIsManual,
                    hasWord: _word.text.trim().isNotEmpty,
                    onEdit: _editPronunciation,
                    onReset: _pronunciationIsManual
                        ? () {
                            setState(() {
                              _pronunciationIsManual = false;
                              _pronunciation = null;
                            });
                            _refreshPronunciation(_word.text);
                          }
                        : null,
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
                    onOpenWizard: _openContextWizard,
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

/// Shows the pronunciation the app worked out, rather than asking for it.
///
/// Every character in an IPA transcription is off a phone keyboard, so a text
/// field here would sit empty on nearly every word. The override exists only
/// for the cases the dictionary misses or gets wrong.
class _PronunciationLine extends StatelessWidget {
  const _PronunciationLine({
    required this.ipa,
    required this.isManual,
    required this.hasWord,
    required this.onEdit,
    required this.onReset,
  });

  final String? ipa;
  final bool isManual;
  final bool hasWord;
  final VoidCallback onEdit;
  final VoidCallback? onReset;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final theme = Theme.of(context);
    final value = ipa;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                isManual
                    ? 'PRONUNCIATION · YOURS'
                    : 'PRONUNCIATION · AUTOMATIC',
                style: theme.textTheme.labelSmall,
              ),
              const SizedBox(height: 2),
              if (value != null && value.isNotEmpty)
                Text(
                  PronunciationService.format(value),
                  style: theme.textTheme.bodyLarge,
                )
              else
                Text(
                  hasWord ? 'Not in the dictionary' : '—',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: palette.inkFaint,
                  ),
                ),
            ],
          ),
        ),
        if (onReset != null) ...[
          PixelIconButton(
            glyph: PixelGlyph.close,
            semanticLabel: 'Use the automatic pronunciation',
            onPressed: onReset,
          ),
          const SizedBox(width: PixelMetrics.space1),
        ],
        PixelIconButton(
          glyph: PixelGlyph.pencil,
          semanticLabel: 'Set the pronunciation by hand',
          onPressed: onEdit,
        ),
      ],
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
    required this.onOpenWizard,
  });

  final List<TextEditingController> controllers;
  final VoidCallback onAdd;
  final ValueChanged<int> onRemove;
  final VoidCallback onOpenWizard;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = context.palette;

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
            GestureDetector(
              onTap: onOpenWizard,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                decoration: BoxDecoration(
                  color: palette.accent,
                  border: Border.all(color: palette.border, width: 1),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    PixelIcon(
                      PixelGlyph.wand,
                      color: palette.onAccent,
                      scale: 1.2,
                    ),
                    const SizedBox(width: 3),
                    Text(
                      'AI WIZARD',
                      style: TextStyle(
                        fontFamily: 'Handjet',
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: palette.onAccent,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 6),
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

/// Owns its own controller.
///
/// The parent used to create one and dispose it as soon as `showDialog`
/// returned, which tore the field down while the dialog was still on screen.
class _PronunciationDialog extends StatefulWidget {
  const _PronunciationDialog({required this.initialValue});

  final String initialValue;

  @override
  State<_PronunciationDialog> createState() => _PronunciationDialogState();
}

class _PronunciationDialogState extends State<_PronunciationDialog> {
  late final TextEditingController controller = TextEditingController(
    text: widget.initialValue,
  );

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    return Dialog(
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
              'PRONUNCIATION',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: PixelMetrics.space2),
            Text(
              'Only if the automatic one is wrong. Leave it empty to go back '
              'to automatic.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: PixelMetrics.space4),
            PixelField(
              controller: controller,
              label: 'Your transcription',
              hint: 'rɪˈzɪljənt',
              autofocus: true,
            ),
            const SizedBox(height: PixelMetrics.space4),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                PixelButton(
                  label: 'Cancel',
                  onPressed: () => Navigator.of(context).pop(),
                ),
                const SizedBox(width: PixelMetrics.space2),
                PixelButton(
                  label: 'Use this',
                  filled: true,
                  onPressed: () => Navigator.of(context).pop(controller.text),
                ),
              ],
            ),
          ],
        ),
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
