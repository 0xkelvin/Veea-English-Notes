import 'package:flutter/material.dart';

import '../../core/theme/pixel_metrics.dart';
import '../../core/theme/pixel_palette.dart';

/// A modern liquid-elevated card with smooth rounded corners, subtle border,
/// and soft diffused elevation shadow.
class PixelBox extends StatelessWidget {
  const PixelBox({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(PixelMetrics.space3),
    this.raised = false,
    this.color,
    this.borderColor,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final bool raised;
  final Color? color;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final fill = color ?? palette.surface;
    final stroke = borderColor ?? palette.border;

    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(PixelMetrics.radius),
        border: Border.all(color: stroke, width: PixelMetrics.border),
        boxShadow: raised
            ? [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.05),
                  blurRadius: 16,
                  offset: const Offset(0, 6),
                ),
                BoxShadow(
                  color: palette.accent.withValues(alpha: 0.03),
                  blurRadius: 6,
                  offset: const Offset(0, 2),
                ),
              ]
            : null,
      ),
      child: child,
    );
  }
}
