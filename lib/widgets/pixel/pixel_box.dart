import 'package:flutter/material.dart';

import '../../core/theme/pixel_metrics.dart';
import '../../core/theme/pixel_palette.dart';

/// A hard-edged block: square corners, a solid outline, no shadow.
///
/// When [raised] is set, a second solid rectangle is drawn offset behind the
/// block. That is how sprite interfaces imply depth — a blurred shadow would
/// read as modern material.
class PixelBox extends StatelessWidget {
  const PixelBox({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(PixelMetrics.space3),
    this.color,
    this.borderColor,
    this.raised = false,
    this.pressed = false,
    this.width,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? color;
  final Color? borderColor;
  final bool raised;

  /// Sinks the block onto its drop rectangle, giving a physical press.
  final bool pressed;

  final double? width;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final border = borderColor ?? palette.border;
    final offset = raised && !pressed ? PixelMetrics.raise : 0.0;

    final block = Container(
      width: width,
      padding: padding,
      decoration: BoxDecoration(
        color: color ?? palette.surface,
        border: Border.all(color: border, width: PixelMetrics.border),
        borderRadius: BorderRadius.zero,
      ),
      child: child,
    );

    if (!raised) return block;

    return Stack(
      children: [
        // The drop block, always at full offset so the face appears to sink
        // into it when pressed.
        Positioned.fill(
          left: PixelMetrics.raise,
          top: PixelMetrics.raise,
          child: Container(color: border),
        ),
        Padding(
          padding: EdgeInsets.only(
            left: offset,
            top: offset,
            right: PixelMetrics.raise - offset,
            bottom: PixelMetrics.raise - offset,
          ),
          child: block,
        ),
      ],
    );
  }
}
