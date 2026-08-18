import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/theme/pixel_metrics.dart';
import '../core/theme/pixel_palette.dart';
import '../models/vocabulary_word.dart';
import '../services/pronunciation_service.dart';
import '../services/tts_service.dart';
import 'pixel/pixel_button.dart';
import 'pixel/pixel_icon.dart';

/// One captured word.
///
/// The row is the tap target for editing, so the only control competing with
/// the text is the speak button. Deleting lives inside the editor — the old
/// card put a delete button one tap from every word.
class WordRow extends StatelessWidget {
  const WordRow({
    super.key,
    required this.word,
    required this.onTap,
    this.dateLabel,
  });

  final VocabularyWord word;
  final VoidCallback onTap;

  /// Shown in search results, where the day is no longer implied by context.
  final String? dateLabel;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final theme = Theme.of(context);

    return Semantics(
      button: true,
      label: '${word.word}, ${word.meaning}',
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.fromLTRB(
            PixelMetrics.space4,
            PixelMetrics.space3,
            PixelMetrics.space2,
            PixelMetrics.space3,
          ),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: palette.border,
                width: PixelMetrics.border,
              ),
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (dateLabel != null) ...[
                      Text(
                        dateLabel!.toUpperCase(),
                        style: theme.textTheme.labelSmall,
                      ),
                      const SizedBox(height: PixelMetrics.space1),
                    ],
                    _WordHeadline(word: word),
                    const SizedBox(height: PixelMetrics.space1),
                    Text(word.meaning, style: theme.textTheme.bodyLarge),
                    if (word.hasExamples) ...[
                      const SizedBox(height: PixelMetrics.space2),
                      for (final example in word.examples)
                        Padding(
                          padding: const EdgeInsets.only(
                            bottom: PixelMetrics.space1,
                          ),
                          child: Text(
                            '“$example”',
                            style: theme.textTheme.bodyMedium,
                          ),
                        ),
                    ],
                    if (word.source != null) ...[
                      const SizedBox(height: PixelMetrics.space2),
                      Text(
                        'FROM ${word.source!.toUpperCase()}',
                        style: theme.textTheme.labelSmall,
                      ),
                    ],
                    if (word.hasTags) ...[
                      const SizedBox(height: PixelMetrics.space2),
                      Text(
                        word.tags.map((t) => '#$t').join('  '),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: palette.accent,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: PixelMetrics.space2),
              _SpeakButton(word: word.word),
            ],
          ),
        ),
      ),
    );
  }
}

/// The word itself, with its pronunciation and part of speech inline.
class _WordHeadline extends StatelessWidget {
  const _WordHeadline({required this.word});

  final VocabularyWord word;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = context.palette;

    // Stored transcriptions are canonical — no slashes — so they are wrapped
    // for display here. Normalising first also drops values that are nothing
    // but punctuation, which early hand-typed entries can be.
    final raw = word.pronunciation;
    final normalised = raw == null ? '' : PronunciationService.normalise(raw);
    final pronunciation = normalised.isEmpty ? null : normalised;

    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.end,
      spacing: PixelMetrics.space2,
      children: [
        Text(word.word, style: theme.textTheme.titleLarge),
        if (word.partOfSpeech != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Text(
              word.partOfSpeech!.short,
              style: theme.textTheme.labelSmall?.copyWith(
                color: palette.accent,
              ),
            ),
          ),
        if (pronunciation != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Text(
              PronunciationService.format(pronunciation),
              style: theme.textTheme.labelSmall,
            ),
          ),
      ],
    );
  }
}

/// Speak button, inverted while this word is the one being read aloud.
class _SpeakButton extends StatelessWidget {
  const _SpeakButton({required this.word});

  final String word;

  @override
  Widget build(BuildContext context) {
    final tts = context.watch<TtsService>();
    final speakingThis = tts.isSpeaking && tts.currentWord == word;

    return PixelIconButton(
      glyph: PixelGlyph.speaker,
      semanticLabel: 'Pronounce $word',
      active: speakingThis,
      onPressed: () => context.read<TtsService>().speak(word),
    );
  }
}
