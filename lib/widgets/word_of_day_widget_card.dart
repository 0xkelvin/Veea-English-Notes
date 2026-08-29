import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/theme/pixel_metrics.dart';
import '../core/theme/pixel_palette.dart';
import '../models/vocabulary_word.dart';
import '../providers/vocabulary_provider.dart';
import '../providers/widget_provider.dart';
import '../services/pronunciation_service.dart';
import '../services/tts_service.dart';
import '../services/widget_service.dart';
import 'pixel/pixel_box.dart';
import 'pixel/pixel_icon.dart';

/// Interactive Word of the Day Widget Card displayed directly on the Homepage.
///
/// Tapping directly anywhere on the widget card immediately pronounces the word
/// in English audio via [TtsService] and rotates to the next word in the review list.
class WordOfDayWidgetCard extends StatefulWidget {
  const WordOfDayWidgetCard({super.key});

  @override
  State<WordOfDayWidgetCard> createState() => _WordOfDayWidgetCardState();
}

class _WordOfDayWidgetCardState extends State<WordOfDayWidgetCard> {
  int _rotationIndex = 0;

  void _pronounceAndRotate(VocabularyWord word, int totalWords) {
    // 1. Play pronunciation of the word
    try {
      context.read<TtsService>().speak(word.word);
    } catch (_) {}

    // 2. Advance to next word
    setState(() {
      _rotationIndex = (_rotationIndex + 1) % totalWords;
    });

    // 3. Update native widget data
    WidgetService.rotateToNextWord();
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<VocabularyProvider>();
    final widgetProvider = context.watch<WidgetProvider>();
    if (!widgetProvider.isWidgetEnabled) return const SizedBox.shrink();

    final words = provider.words;
    if (words.isEmpty) return const SizedBox.shrink();

    final safeIndex = _rotationIndex % words.length;
    final word = words[safeIndex];
    final palette = context.palette;
    final theme = Theme.of(context);
    final tts = context.watch<TtsService>();
    final isSpeaking = tts.isSpeaking && tts.currentWord == word.word;

    final raw = word.pronunciation;
    final normalised = raw == null ? '' : PronunciationService.normalise(raw);
    final formattedIpa = normalised.isEmpty ? null : PronunciationService.format(normalised);

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        PixelMetrics.space4,
        PixelMetrics.space2,
        PixelMetrics.space4,
        PixelMetrics.space1,
      ),
      child: Semantics(
        button: true,
        label: 'Word of the Day Widget: ${word.word}. Tap to pronounce and rotate.',
        child: GestureDetector(
          onTap: () => _pronounceAndRotate(word, words.length),
          behavior: HitTestBehavior.opaque,
          child: PixelBox(
            raised: true,
            color: palette.surface,
            padding: const EdgeInsets.all(PixelMetrics.space3),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Header Bar: "WORD OF THE DAY" + Streak Badge + Rotate Hint
                Row(
                  children: [
                    PixelIcon(
                      PixelGlyph.bolt,
                      color: palette.accent,
                      scale: 1.8,
                    ),
                    const SizedBox(width: PixelMetrics.space1),
                    Text(
                      'WORD OF THE DAY WIDGET',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: palette.inkMuted,
                        letterSpacing: 0.8,
                        fontSize: 10,
                      ),
                    ),
                    const Spacer(),
                    if (provider.stats.streakDays > 0)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(
                          color: palette.paper,
                          border: Border.all(color: palette.border, width: 1),
                        ),
                        child: Text(
                          '🔥 ${provider.stats.streakDays} STREAK',
                          style: theme.textTheme.labelSmall?.copyWith(
                            fontSize: 9,
                            fontWeight: FontWeight.bold,
                            color: palette.accent,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: PixelMetrics.space2),

                // Main Word & Speaker row
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      word.word,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontFamily: 'Handjet',
                        fontSize: 26,
                        fontWeight: FontWeight.bold,
                        color: isSpeaking ? palette.accent : palette.ink,
                      ),
                    ),
                    if (word.partOfSpeech != null) ...[
                      const SizedBox(width: PixelMetrics.space2),
                      Text(
                        word.partOfSpeech!.short,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: palette.accent,
                        ),
                      ),
                    ],
                    if (formattedIpa != null) ...[
                      const SizedBox(width: PixelMetrics.space2),
                      Text(
                        formattedIpa,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: palette.inkFaint,
                        ),
                      ),
                    ],
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: isSpeaking ? palette.accent : palette.paper,
                        border: Border.all(color: palette.border, width: 1),
                      ),
                      child: PixelIcon(
                        PixelGlyph.speaker,
                        color: isSpeaking ? palette.onAccent : palette.ink,
                        scale: 1.8,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: PixelMetrics.space1),

                // Meaning
                Text(
                  word.meaning,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),

                if (word.examples.isNotEmpty) ...[
                  const SizedBox(height: PixelMetrics.space1),
                  Text(
                    '“${word.examples.first}”',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: palette.inkMuted,
                      fontStyle: FontStyle.italic,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],

                const SizedBox(height: PixelMetrics.space2),

                // Footer Prompt
                Row(
                  children: [
                    Text(
                      isSpeaking ? '🔊 PRONOUNCING…' : 'TAP WIDGET TO PRONOUNCE & ROTATE ❯',
                      style: TextStyle(
                        fontFamily: 'Handjet',
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: isSpeaking ? palette.accent : palette.inkFaint,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '${safeIndex + 1}/${words.length}',
                      style: TextStyle(
                        fontFamily: 'Handjet',
                        fontSize: 11,
                        color: palette.inkFaint,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
