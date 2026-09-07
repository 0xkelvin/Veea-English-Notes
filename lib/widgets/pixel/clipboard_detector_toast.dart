import 'package:flutter/material.dart';

import '../../core/theme/pixel_metrics.dart';
import '../../core/theme/pixel_palette.dart';
import 'pixel_box.dart';
import 'pixel_button.dart';
import 'pixel_icon.dart';

/// An unobtrusive 8-bit retro toast displayed when valid English vocabulary
/// is detected on the system clipboard upon app launch or resume.
///
/// Provides a one-tap action to automatically resolve Vietnamese meaning
/// and IPA pronunciation and save the word directly to today's journal.
class ClipboardDetectorToast extends StatelessWidget {
  const ClipboardDetectorToast({
    super.key,
    required this.word,
    required this.onAdd,
    required this.onDismiss,
    this.isAdding = false,
  });

  final String word;
  final VoidCallback onAdd;
  final VoidCallback onDismiss;
  final bool isAdding;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    return Container(
      margin: const EdgeInsets.symmetric(
        horizontal: PixelMetrics.space3,
        vertical: PixelMetrics.space1,
      ),
      child: PixelBox(
        raised: true,
        color: palette.surface,
        padding: const EdgeInsets.symmetric(
          horizontal: PixelMetrics.space3,
          vertical: PixelMetrics.space2,
        ),
        child: Row(
          children: [
            PixelIcon(PixelGlyph.clipboard, color: palette.accent, scale: 2),
            const SizedBox(width: PixelMetrics.space2),
            Expanded(
              child: Text.rich(
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                TextSpan(
                  style: TextStyle(
                    fontFamily: 'Handjet',
                    fontSize: 15,
                    color: palette.ink,
                  ),
                  children: [
                    TextSpan(
                      text: '"$word"',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    TextSpan(
                      text: ' found on clipboard.',
                      style: TextStyle(
                        color: palette.inkMuted,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: PixelMetrics.space2),
            PixelButton(
              label: isAdding ? 'ADDING…' : 'ADD TO TODAY',
              onPressed: isAdding ? null : onAdd,
            ),
            const SizedBox(width: PixelMetrics.space1),
            PixelIconButton(
              glyph: PixelGlyph.close,
              semanticLabel: 'Dismiss clipboard word',
              onPressed: onDismiss,
            ),
          ],
        ),
      ),
    );
  }
}
