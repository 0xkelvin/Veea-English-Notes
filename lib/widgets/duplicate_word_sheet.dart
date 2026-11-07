import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../core/theme/pixel_palette.dart';
import '../models/vocabulary_word.dart';

class DuplicateWordChoice {
  const DuplicateWordChoice.open(this.word) : saveDifferentMeaning = false;
  const DuplicateWordChoice.differentMeaning()
    : word = null,
      saveDifferentMeaning = true;
  final VocabularyWord? word;
  final bool saveDifferentMeaning;
}

Future<DuplicateWordChoice?> showDuplicateWords(
  BuildContext context, {
  required List<VocabularyWord> matches,
  bool saving = false,
  bool allowDifferentMeaning = false,
}) => showModalBottomSheet<DuplicateWordChoice>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  showDragHandle: true,
  backgroundColor: context.palette.surface,
  builder: (context) => ConstrainedBox(
    key: const Key('duplicate_word_sheet'),
    constraints: BoxConstraints(
      maxHeight: MediaQuery.sizeOf(context).height * .85,
    ),
    child: SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Semantics(
                      header: true,
                      child: Text(
                        'Already in your notebook',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Open a saved entry to review or update it. Your new draft will stay here.',
                    ),
                    const SizedBox(height: 16),

                    for (final word in matches)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: OutlinedButton(
                          key: ValueKey('duplicate_open_${word.id}'),
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.all(16),
                          ),
                          onPressed: () => Navigator.of(
                            context,
                          ).pop(DuplicateWordChoice.open(word)),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                word.partOfSpeech == null
                                    ? word.word
                                    : '${word.word} · ${word.partOfSpeech!.label}',
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                word.meaning,
                                style: Theme.of(context).textTheme.bodyMedium,
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'Saved ${DateTime.tryParse(word.date) == null ? word.date : DateFormat.yMMMd().format(DateTime.parse(word.date))}',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                              const SizedBox(height: 8),
                              const Text('Open saved word'),
                            ],
                          ),
                        ),
                      ),
                    if (saving && !allowDifferentMeaning)
                      const Padding(
                        padding: EdgeInsets.only(bottom: 12),
                        child: Text(
                          'This meaning is already saved. Open the word to add examples or notes.',
                        ),
                      ),
                  ],
                ),
              ),
            ),
            if (saving && allowDifferentMeaning)
              TextButton(
                key: const Key('duplicate_save_another'),
                onPressed: () => Navigator.of(
                  context,
                ).pop(const DuplicateWordChoice.differentMeaning()),
                child: const Text('Save as a different meaning'),
              ),
            TextButton(
              key: const Key('duplicate_keep_editing'),
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Keep editing'),
            ),
          ],
        ),
      ),
    ),
  ),
);
