import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/pixel_metrics.dart';
import '../../core/theme/pixel_palette.dart';
import 'pixel_icon.dart';

/// A modern liquid-style button with smooth rounded corners, subtle tactile
/// scale/opacity feedback, and soft elevation.
class PixelButton extends StatefulWidget {
  const PixelButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.glyph,
    this.filled = false,
    this.danger = false,
    this.expand = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final PixelGlyph? glyph;

  /// Accent fill when true; elevated surface fill when false.
  final bool filled;

  /// Uses the danger colour for the fill when true.
  final bool danger;

  /// Stretches horizontally to fill its parent.
  final bool expand;

  @override
  State<PixelButton> createState() => _PixelButtonState();
}

class _PixelButtonState extends State<PixelButton> {
  bool _pressed = false;

  bool get _enabled => widget.onPressed != null;

  void _setPressed(bool value) {
    if (!_enabled || _pressed == value) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    final Color fill;
    final Color fg;
    final Color borderColor;
    if (!_enabled) {
      fill = palette.paper;
      fg = palette.inkFaint;
      borderColor = palette.border;
    } else if (widget.danger) {
      fill = palette.danger;
      fg = palette.onAccent;
      borderColor = palette.danger;
    } else if (widget.filled) {
      fill = palette.accent;
      fg = palette.onAccent;
      borderColor = palette.accent;
    } else {
      fill = palette.surface;
      fg = palette.ink;
      borderColor = palette.border;
    }

    final content = Row(
      mainAxisSize: widget.expand ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (widget.glyph != null) ...[
          PixelIcon(widget.glyph!, color: fg),
          const SizedBox(width: PixelMetrics.space2),
        ],
        Flexible(
          child: Text(
            widget.label.toUpperCase(),
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: fg,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.4,
            ),
          ),
        ),
      ],
    );

    return Semantics(
      button: true,
      enabled: _enabled,
      label: widget.label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => _setPressed(true),
        onTapUp: (_) => _setPressed(false),
        onTapCancel: () => _setPressed(false),
        onTap: _enabled
            ? () {
                HapticFeedback.selectionClick();
                widget.onPressed!();
              }
            : null,
        child: AnimatedScale(
          scale: _pressed ? 0.97 : 1.0,
          duration: const Duration(milliseconds: 100),
          child: AnimatedOpacity(
            opacity: _pressed ? 0.85 : 1.0,
            duration: const Duration(milliseconds: 100),
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                minHeight: PixelMetrics.tapTarget,
              ),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: PixelMetrics.space4,
                  vertical: PixelMetrics.space2 + 2,
                ),
                decoration: BoxDecoration(
                  color: fill,
                  borderRadius: BorderRadius.circular(PixelMetrics.radiusSm),
                  border: Border.all(
                    color: borderColor,
                    width: PixelMetrics.border,
                  ),
                  boxShadow: _enabled && (widget.filled || widget.danger)
                      ? [
                          BoxShadow(
                            color: fill.withValues(alpha: 0.24),
                            blurRadius: 10,
                            offset: const Offset(0, 3),
                          ),
                        ]
                      : null,
                ),
                child: content,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Modern rounded icon button used in top bars, date navigation, and word cards.
class PixelIconButton extends StatefulWidget {
  const PixelIconButton({
    super.key,
    required this.glyph,
    required this.onPressed,
    required this.semanticLabel,
    this.active = false,
  });

  final PixelGlyph glyph;
  final VoidCallback? onPressed;
  final String semanticLabel;

  /// Highlights the button in the accent colour when true.
  final bool active;

  @override
  State<PixelIconButton> createState() => _PixelIconButtonState();
}

class _PixelIconButtonState extends State<PixelIconButton> {
  bool _pressed = false;

  bool get _enabled => widget.onPressed != null;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    final Color fill;
    final Color fg;
    final Color borderColor;
    if (!_enabled) {
      fill = palette.paper;
      fg = palette.inkFaint;
      borderColor = palette.border.withValues(alpha: 0.5);
    } else if (widget.active || _pressed) {
      fill = palette.accent.withValues(alpha: 0.12);
      fg = palette.accent;
      borderColor = palette.accent.withValues(alpha: 0.35);
    } else {
      fill = palette.paper.withValues(alpha: 0.7);
      fg = palette.ink;
      borderColor = palette.border;
    }

    return Semantics(
      button: true,
      enabled: _enabled,
      label: widget.semanticLabel,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: _enabled ? (_) => setState(() => _pressed = true) : null,
        onTapUp: _enabled ? (_) => setState(() => _pressed = false) : null,
        onTapCancel: _enabled ? () => setState(() => _pressed = false) : null,
        onTap: _enabled
            ? () {
                HapticFeedback.selectionClick();
                widget.onPressed!();
              }
            : null,
        child: SizedBox(
          width: PixelMetrics.tapTarget,
          height: PixelMetrics.tapTarget,
          child: Center(
            child: AnimatedScale(
              scale: _pressed ? 0.92 : 1.0,
              duration: const Duration(milliseconds: 90),
              child: Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: fill,
                  borderRadius: BorderRadius.circular(PixelMetrics.radiusSm),
                  border: Border.all(
                    color: borderColor,
                    width: PixelMetrics.border,
                  ),
                ),
                alignment: Alignment.center,
                child: PixelIcon(widget.glyph, color: fg),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
