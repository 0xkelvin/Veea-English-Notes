import 'package:flutter/material.dart';

import '../core/theme/pixel_metrics.dart';
import '../core/theme/pixel_palette.dart';
import 'pixel/pixel_box.dart';

/// Guidance for the system return link, which iOS may show above Veea.
/// This panel does not simulate a link or promise to launch another app.
class NativeGateReturnHint extends StatelessWidget {
  const NativeGateReturnHint({
    super.key,
    required this.remainingAccess,
    required this.onBackToVeea,
  });

  final String remainingAccess;
  final VoidCallback? onBackToVeea;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final theme = Theme.of(context);
    return PixelBox(
      padding: const EdgeInsets.all(PixelMetrics.space4),
      color: palette.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ExcludeSemantics(
            child: Align(
              alignment: Alignment.topLeft,
              child: Icon(Icons.north_west, size: 40, color: palette.accent),
            ),
          ),
          const SizedBox(height: PixelMetrics.space3),
          Semantics(
            header: true,
            child: Text(
              'Your app is unlocked',
              style: theme.textTheme.headlineSmall,
            ),
          ),
          const SizedBox(height: PixelMetrics.space2),
          Text(
            '$remainingAccess remaining',
            style: theme.textTheme.titleMedium?.copyWith(color: palette.accent),
          ),
          const SizedBox(height: PixelMetrics.space4),
          Text('Return to your app', style: theme.textTheme.titleMedium),
          const SizedBox(height: PixelMetrics.space2),
          const Text(
            'Tap the return link in the top-left corner of your screen.',
          ),
          const SizedBox(height: PixelMetrics.space3),
          Text(
            'No return link? Open your app from Home or the app switcher. Your access is already active.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: palette.inkMuted,
            ),
          ),
          if (onBackToVeea != null) ...[
            const SizedBox(height: PixelMetrics.space3),
            TextButton(
              onPressed: onBackToVeea,
              child: const Text('Back to Veea'),
            ),
          ],
        ],
      ),
    );
  }
}
