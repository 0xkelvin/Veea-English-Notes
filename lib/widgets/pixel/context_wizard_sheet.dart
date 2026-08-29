import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/pixel_metrics.dart';
import '../../core/theme/pixel_palette.dart';
import '../../services/context_wizard_service.dart';
import 'pixel_box.dart';
import 'pixel_button.dart';
import 'pixel_icon.dart';

/// 8-Bit Retro AI Context & Collocation Wizard Modal Sheet.
class ContextWizardSheet extends StatelessWidget {
  const ContextWizardSheet({
    super.key,
    required this.word,
    this.meaning,
    required this.onSelectSentence,
    required this.onAddTag,
  });

  final String word;
  final String? meaning;
  final ValueChanged<String> onSelectSentence;
  final ValueChanged<String> onAddTag;

  static void show({
    required BuildContext context,
    required String word,
    String? meaning,
    required ValueChanged<String> onSelectSentence,
    required ValueChanged<String> onAddTag,
  }) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ContextWizardSheet(
        word: word,
        meaning: meaning,
        onSelectSentence: onSelectSentence,
        onAddTag: onAddTag,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final theme = Theme.of(context);
    final result = ContextWizardService.generate(word, meaning: meaning);

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.85,
      ),
      decoration: BoxDecoration(
        color: palette.paper,
        border: Border(
          top: BorderSide(color: palette.border, width: PixelMetrics.border),
        ),
      ),
      child: SafeArea(
        child: Column(
          children: [
            // Top Bar
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: PixelMetrics.space4,
                vertical: PixelMetrics.space2,
              ),
              decoration: BoxDecoration(
                color: palette.surface,
                border: Border(
                  bottom: BorderSide(
                    color: palette.border,
                    width: PixelMetrics.border,
                  ),
                ),
              ),
              child: Row(
                children: [
                  PixelIcon(PixelGlyph.wand, color: palette.accent, scale: 2),
                  const SizedBox(width: PixelMetrics.space2),
                  Text(
                    'AI CONTEXT WIZARD',
                    style: theme.textTheme.titleMedium,
                  ),
                  const Spacer(),
                  PixelIconButton(
                    glyph: PixelGlyph.close,
                    semanticLabel: 'Close Wizard',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),

            // Scrollable Content
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(PixelMetrics.space4),
                children: [
                  // Target Word Banner
                  Container(
                    padding: const EdgeInsets.all(PixelMetrics.space3),
                    decoration: BoxDecoration(
                      color: palette.surface,
                      border: Border.all(color: palette.border, width: 1),
                    ),
                    child: Row(
                      children: [
                        Text(
                          'WORD: ${word.toUpperCase()}',
                          style: TextStyle(
                            fontFamily: 'Handjet',
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: palette.accent,
                          ),
                        ),
                        if (meaning != null && meaning!.isNotEmpty) ...[
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '($meaning)',
                              style: TextStyle(
                                fontFamily: 'Handjet',
                                fontSize: 13,
                                color: palette.inkMuted,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),

                  const SizedBox(height: PixelMetrics.space4),

                  // Section 1: Context Sentences
                  Text(
                    '1. REAL-WORLD CONTEXT SENTENCES (TAP TO INSERT)',
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: PixelMetrics.space2),

                  for (final s in result.sentences) ...[
                    Padding(
                      padding: const EdgeInsets.only(bottom: PixelMetrics.space2),
                      child: GestureDetector(
                        onTap: () {
                          onSelectSentence(s.sentence);
                          Navigator.of(context).pop();
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                'Inserted sentence into example field!',
                                style: TextStyle(fontFamily: 'Handjet'),
                              ),
                              duration: Duration(seconds: 1),
                            ),
                          );
                        },
                        child: PixelBox(
                          raised: true,
                          color: palette.surface,
                          padding: const EdgeInsets.all(PixelMetrics.space3),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 4,
                                      vertical: 1,
                                    ),
                                    decoration: BoxDecoration(
                                      color: palette.accent,
                                      border: Border.all(
                                          color: palette.border, width: 1),
                                    ),
                                    child: Text(
                                      s.domain,
                                      style: TextStyle(
                                        fontFamily: 'Handjet',
                                        fontSize: 9,
                                        fontWeight: FontWeight.bold,
                                        color: palette.onAccent,
                                      ),
                                    ),
                                  ),
                                  const Spacer(),
                                  Text(
                                    'TAP TO INSERT ↵',
                                    style: TextStyle(
                                      fontFamily: 'Handjet',
                                      fontSize: 10,
                                      color: palette.inkFaint,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Text(
                                '“${s.sentence}”',
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],

                  const SizedBox(height: PixelMetrics.space4),

                  // Section 2: Power Collocations
                  Text(
                    '2. POWER COLLOCATIONS & COMMON PAIRS',
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: PixelMetrics.space2),

                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: result.collocations.map((col) {
                      return GestureDetector(
                        onTap: () {
                          Clipboard.setData(ClipboardData(text: col));
                          onAddTag(col);
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                'Added tag & copied: "$col"',
                                style: const TextStyle(fontFamily: 'Handjet'),
                              ),
                              duration: const Duration(seconds: 1),
                            ),
                          );
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: palette.surface,
                            border: Border.all(color: palette.border, width: 1),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                '+ $col',
                                style: TextStyle(
                                  fontFamily: 'Handjet',
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                  color: palette.ink,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }).toList(),
                  ),

                  const SizedBox(height: PixelMetrics.space4),

                  // Section 3: Nuance Matrix
                  if (result.nuances.isNotEmpty) ...[
                    Text(
                      '3. SYNONYM & NUANCE BREAKDOWN',
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: PixelMetrics.space2),

                    for (final n in result.nuances) ...[
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Container(
                          padding: const EdgeInsets.all(PixelMetrics.space2),
                          decoration: BoxDecoration(
                            color: palette.surface,
                            border: Border.all(
                              color: palette.border.withValues(alpha: 0.5),
                              width: 1,
                            ),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'vs ${n.synonym}:',
                                style: TextStyle(
                                  fontFamily: 'Handjet',
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                  color: palette.accent,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  n.difference,
                                  style: TextStyle(
                                    fontFamily: 'Handjet',
                                    fontSize: 12,
                                    color: palette.inkMuted,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
