import 'package:flutter/material.dart';

import '../../core/theme/pixel_metrics.dart';
import '../../core/theme/pixel_palette.dart';

/// Reusable 8-bit CRT monitor frame with scanlines and bezel.
class ArcadeCrtScreen extends StatelessWidget {
  const ArcadeCrtScreen({
    super.key,
    required this.child,
    this.scoreText,
    this.livesCount,
    this.statusBadge,
  });

  final Widget child;
  final String? scoreText;
  final int? livesCount;
  final String? statusBadge;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final theme = Theme.of(context);

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF0F110C),
        border: Border.all(color: palette.border, width: PixelMetrics.border),
      ),
      child: Stack(
        children: [
          // Game Content
          child,

          // CRT Scanline Shader / Grid lines
          IgnorePointer(
            child: CustomPaint(
              size: Size.infinite,
              painter: _ScanlinesPainter(),
            ),
          ),

          // Top Heads-Up Display (HUD) overlay if provided
          if (scoreText != null || livesCount != null || statusBadge != null)
            Positioned(
              top: 8,
              left: 12,
              right: 12,
              child: Row(
                children: [
                  if (scoreText != null)
                    Text(
                      scoreText!,
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: palette.accent,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  const Spacer(),
                  if (statusBadge != null)
                    Text(
                      statusBadge!,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: const Color(0xFFE0DFD5),
                        fontSize: 11,
                      ),
                    ),
                  if (livesCount != null) ...[
                    const SizedBox(width: 8),
                    Text(
                      '♥ ' * livesCount!,
                      style: const TextStyle(color: Color(0xFFE53935), fontSize: 13),
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _ScanlinesPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.black.withValues(alpha: 0.08)
      ..strokeWidth = 1.0;

    for (double y = 0; y < size.height; y += 4.0) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
