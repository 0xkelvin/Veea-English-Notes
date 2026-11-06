import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/theme/pixel_metrics.dart';
import '../core/theme/pixel_palette.dart';
import '../models/part_of_speech.dart';
import '../models/vocabulary_word.dart';
import '../services/pronunciation_service.dart';
import '../services/tts_service.dart';
import 'highlighted_text.dart';
import 'pixel/pixel_button.dart';
import 'pixel/pixel_icon.dart';

/// One captured word rendered as a clean, modern liquid-elevated card.
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
          margin: const EdgeInsets.symmetric(
            horizontal: PixelMetrics.space3,
            vertical: PixelMetrics.space2,
          ),
          padding: const EdgeInsets.all(PixelMetrics.space4),
          decoration: BoxDecoration(
            color: palette.surface,
            borderRadius: BorderRadius.circular(PixelMetrics.radius),
            border: Border.all(
              color: palette.border,
              width: PixelMetrics.border,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.04),
                offset: const Offset(0, 4),
                blurRadius: 12,
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header row: Word title, POS chip, pronunciation, and speaker button
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _WordHeadline(word: word, dateLabel: dateLabel),
                  ),
                  const SizedBox(width: PixelMetrics.space2),
                  _SpeakButton(word: word.word),
                ],
              ),
              const SizedBox(height: PixelMetrics.space2),

              // Definition / Vietnamese meaning in clean, comfortable body face
              Text(
                word.meaning,
                style: theme.textTheme.bodyLarge?.copyWith(
                  fontWeight: FontWeight.w500,
                  fontSize: 16,
                  height: 1.4,
                ),
              ),

              // Example sentences with keyword highlighting & quotation accent bar
              if (word.hasExamples) ...[
                const SizedBox(height: PixelMetrics.space2),
                for (final example in word.examples)
                  Container(
                    margin: const EdgeInsets.only(bottom: PixelMetrics.space1),
                    padding: const EdgeInsets.symmetric(
                      horizontal: PixelMetrics.space3,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: palette.paper.withValues(alpha: 0.75),
                      borderRadius: const BorderRadius.only(
                        topRight: Radius.circular(8),
                        bottomRight: Radius.circular(8),
                      ),
                      border: Border(
                        left: BorderSide(
                          color: palette.accent,
                          width: 3,
                        ),
                      ),
                    ),
                    child: HighlightedText(
                      text: '“$example”',
                      targetWord: word.word,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontStyle: FontStyle.italic,
                        height: 1.35,
                      ),
                      highlightStyle: theme.textTheme.bodyMedium?.copyWith(
                        fontStyle: FontStyle.italic,
                        fontWeight: FontWeight.w700,
                        color: palette.accent,
                      ),
                    ),
                  ),
              ],

              // Footer: Source and Tag micro-chips
              if (word.source != null || word.hasTags) ...[
                const SizedBox(height: PixelMetrics.space2),
                Wrap(
                  spacing: PixelMetrics.space2,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (word.source != null && word.source!.isNotEmpty)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: palette.paper,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: palette.border,
                            width: 1,
                          ),
                        ),
                        child: Text(
                          'FROM ${word.source!.toUpperCase()}',
                          style: theme.textTheme.labelSmall?.copyWith(
                            fontSize: 10.5,
                            letterSpacing: 0.3,
                          ),
                        ),
                      ),
                    for (final tag in word.tags)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: palette.accent.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          '#$tag',
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                            color: palette.accent,
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// The word headline with date label, POS badge, and pronunciation.
class _WordHeadline extends StatelessWidget {
  const _WordHeadline({required this.word, this.dateLabel});

  final VocabularyWord word;
  final String? dateLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = context.palette;

    final raw = word.pronunciation;
    final normalised = raw == null ? '' : PronunciationService.normalise(raw);
    final pronunciation = normalised.isEmpty ? null : normalised;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (dateLabel != null) ...[
          Text(
            dateLabel!.toUpperCase(),
            style: theme.textTheme.labelSmall,
          ),
          const SizedBox(height: PixelMetrics.space1),
        ],
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: PixelMetrics.space2,
          runSpacing: 6,
          children: [
            Text(
              word.word,
              style: theme.textTheme.titleLarge?.copyWith(
                fontSize: 21,
                fontWeight: FontWeight.w700,
              ),
            ),
            if (word.partOfSpeech != null)
              _PartOfSpeechChip(partOfSpeech: word.partOfSpeech!),
            if (pronunciation != null)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: palette.paper,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: palette.border,
                    width: 1,
                  ),
                ),
                child: Text(
                  PronunciationService.format(pronunciation),
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: palette.inkMuted,
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// Colorful modern pill badge identifying grammatical category.
class _PartOfSpeechChip extends StatelessWidget {
  const _PartOfSpeechChip({required this.partOfSpeech});

  final PartOfSpeech partOfSpeech;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final color = palette.posColor(partOfSpeech);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        partOfSpeech.short.toUpperCase(),
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: color,
          letterSpacing: 0.3,
        ),
      ),
    );
  }
}

/// Speak button, highlighted while this word is the one being read aloud.
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
