import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../core/theme/pixel_metrics.dart';
import '../providers/app_gate_provider.dart';
import '../screens/app_gate_screen.dart';
import '../screens/selected_practice_words_screen.dart';
import 'pixel/pixel_box.dart';
import 'pixel/pixel_button.dart';
import 'practice_word_picker.dart';

/// Learning rules are shared by native protection and Shortcut protection.
class GateLearningSettings extends StatefulWidget {
  const GateLearningSettings({
    super.key,
    required this.gate,
    required this.totalWords,
  });
  final AppGateProvider gate;
  final int totalWords;

  @override
  State<GateLearningSettings> createState() => _GateLearningSettingsState();
}

class _GateLearningSettingsState extends State<GateLearningSettings> {
  bool _saving = false;

  Future<void> _editCount() async {
    final poolCount = widget.gate.practiceWordCount;
    if (poolCount == 0) return;
    final maximum = widget.gate.maximumWordsPerUnlock;
    if (maximum == 0) return;
    final count = await showDialog<int>(
      context: context,
      builder: (_) => _UnlockCountDialog(
        initial: widget.gate.requiredWords,
        maximum: maximum,
      ),
    );
    if (count != null && mounted) {
      await _save(() => widget.gate.setWordsPerUnlock(count));
    }
  }

  Future<void> _practice() async {
    setState(() => _saving = true);
    try {
      await widget.gate.prepareChallenge();
      if (!mounted) return;
      final nativeApps = widget.gate.nativeStatus.applications;
      final target = nativeApps.isNotEmpty
          ? nativeApps.first.id
          : widget.gate.config.gatedApps.firstOrNull ?? 'Practice';
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ChangeNotifierProvider.value(
            value: widget.gate,
            child: AppGateScreen(targetApp: target, previewMode: true),
          ),
        ),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Could not load the practice challenge. Please try again.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _save(Future<void> Function() action) async {
    setState(() => _saving = true);
    try {
      await action();
    } on PlatformException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            error.message ??
                'Could not save your learning rule. Please try again.',
          ),
        ),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Could not save your learning rule. Please try again.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.gate,
      builder: (context, _) {
        final theme = Theme.of(context);
        final config = widget.gate.config;
        final poolCount = widget.gate.practiceWordCount;
        final maximumWords = widget.gate.maximumWordsPerUnlock;
        final requiredWords = widget.gate.requiredWords;
        final canIncrease = !_saving && requiredWords < maximumWords;
        final selectedWords = widget.gate.practiceWords.toList()
          ..sort((a, b) {
            final date = b.date.compareTo(a.date);
            return date != 0
                ? date
                : a.word.toLowerCase().compareTo(b.word.toLowerCase());
          });
        return PixelBox(
          padding: const EdgeInsets.all(PixelMetrics.space4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Practice words', style: theme.textTheme.titleMedium),
              Text(
                config.practiceWordIds == null
                    ? 'All $poolCount words · new words included automatically.'
                    : '$poolCount of ${widget.totalWords} words selected.',
              ),
              if (selectedWords.isNotEmpty) ...[
                const SizedBox(height: PixelMetrics.space2),
                for (final word in selectedWords.take(3))
                  Padding(
                    key: ValueKey('practice_word_preview_${word.id}'),
                    padding: const EdgeInsets.symmetric(
                      vertical: PixelMetrics.space1,
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: Text(word.word)),
                        const SizedBox(width: PixelMetrics.space2),
                        Flexible(
                          child: Text(
                            DateTime.tryParse(word.date) == null
                                ? word.date
                                : DateFormat.yMMMd().format(
                                    DateTime.parse(word.date),
                                  ),
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ),
                  ),
                TextButton.icon(
                  key: const Key('view_selected_practice_words'),
                  onPressed: _saving
                      ? null
                      : () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) =>
                                SelectedPracticeWordsScreen(gate: widget.gate),
                          ),
                        ),
                  icon: const Icon(Icons.format_list_bulleted),
                  label: Text(
                    'View all ${selectedWords.length} selected ${selectedWords.length == 1 ? 'word' : 'words'}',
                  ),
                ),
              ],
              PixelButton(
                label: 'Edit practice words',
                expand: true,
                onPressed: _saving || widget.totalWords == 0
                    ? null
                    : () => _save(() async {
                        await choosePracticeWords(context, widget.gate);
                      }),
              ),
              const SizedBox(height: PixelMetrics.space3),
              const Text('WORDS PER UNLOCK'),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    tooltip: 'Decrease words per unlock',
                    onPressed: _saving || poolCount == 0 || requiredWords <= 1
                        ? null
                        : () => _save(
                            () => widget.gate.setWordsPerUnlock(
                              requiredWords - 1,
                            ),
                          ),
                    icon: const Icon(Icons.remove),
                  ),
                  TextButton(
                    key: const Key('edit_unlock_count'),
                    onPressed: _saving || poolCount == 0 ? null : _editCount,
                    child: Text(
                      poolCount == 0 ? '—' : '$requiredWords',
                      style: theme.textTheme.headlineMedium,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Increase words per unlock',
                    onPressed: canIncrease
                        ? () => _save(
                            () => widget.gate.setWordsPerUnlock(
                              requiredWords + 1,
                            ),
                          )
                        : null,
                    icon: const Icon(Icons.add),
                  ),
                ],
              ),
              Text(
                poolCount == 0
                    ? 'Choose at least one practice word to set your challenge.'
                    : 'Review $requiredWords ${requiredWords == 1 ? 'word' : 'words'} each time. Tap the number to change it.',
              ),
              const SizedBox(height: PixelMetrics.space2),
              const Text(
                'Veea cycles through your selected words before repeating them. Interrupted progress is saved for each app.',
              ),
              if (widget.gate.poolNotice != null) Text(widget.gate.poolNotice!),
              const SizedBox(height: PixelMetrics.space2),
              Material(
                type: MaterialType.transparency,
                child: SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Auto-play pronunciation'),
                  subtitle: const Text(
                    'Read words aloud after answers and hints. You can always tap Hear it yourself.',
                  ),
                  value: config.autoPronounce,
                  onChanged: _saving
                      ? null
                      : (value) =>
                            _save(() => widget.gate.setAutoPronounce(value)),
                ),
              ),
              PixelButton(
                label: 'Practice challenge',
                expand: true,
                onPressed: _saving || poolCount == 0 ? null : _practice,
              ),
              const Text(
                'Try the challenge without changing your learning progress.',
              ),
            ],
          ),
        );
      },
    );
  }
}

class _UnlockCountDialog extends StatefulWidget {
  const _UnlockCountDialog({required this.initial, required this.maximum});
  final int initial;
  final int maximum;
  @override
  State<_UnlockCountDialog> createState() => _UnlockCountDialogState();
}

class _UnlockCountDialogState extends State<_UnlockCountDialog> {
  late final TextEditingController _input = TextEditingController(
    text: '${widget.initial}',
  );
  String? _error;
  void _submit() {
    final value = int.tryParse(_input.text);
    if (value == null || value < 1 || value > widget.maximum) {
      setState(() => _error = 'Enter a number from 1 to ${widget.maximum}.');
      return;
    }
    Navigator.pop(context, value);
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: const Text('Words per unlock'),
    content: TextField(
      key: const Key('unlock_count_input'),
      controller: _input,
      autofocus: true,
      keyboardType: TextInputType.number,
      textInputAction: TextInputAction.done,
      onSubmitted: (_) => _submit(),
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      decoration: InputDecoration(
        helperText: 'Choose any number from 1 to ${widget.maximum}.',
        errorText: _error,
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      TextButton(onPressed: _submit, child: const Text('Save')),
    ],
  );
}
