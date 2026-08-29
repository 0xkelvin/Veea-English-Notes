import 'package:flutter/material.dart';

import '../../core/theme/pixel_metrics.dart';
import '../../core/theme/pixel_palette.dart';
import '../../core/theme/pixel_theme.dart';
import 'pixel_box.dart';
import 'pixel_icon.dart';

/// A blocky button that physically sinks when held.
///
/// There is no ripple and no colour fade: the face drops onto its drop block,
/// which is the whole feedback vocabulary of a sprite interface.
class PixelButton extends StatefulWidget {
  const PixelButton({
    super.key,
    required this.label,
    this.onPressed,
    this.glyph,
    this.filled = false,
    this.danger = false,
    this.expand = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final PixelGlyph? glyph;

  /// Fills with the accent colour. Reserved for the single primary action on
  /// a screen.
  final bool filled;

  final bool danger;
  final bool expand;

  bool get isEnabled => onPressed != null;

  @override
  State<PixelButton> createState() => _PixelButtonState();
}

class _PixelButtonState extends State<PixelButton> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (!widget.isEnabled || _pressed == value) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    final Color background;
    final Color foreground;
    if (!widget.isEnabled) {
      background = palette.surface;
      foreground = palette.inkFaint;
    } else if (widget.danger) {
      background = palette.danger;
      foreground = palette.onAccent;
    } else if (widget.filled) {
      background = palette.accent;
      foreground = palette.onAccent;
    } else {
      background = palette.surface;
      foreground = palette.ink;
    }

    final border = widget.isEnabled ? palette.border : palette.inkFaint;

    return Semantics(
      button: true,
      enabled: widget.isEnabled,
      label: widget.label,
      child: GestureDetector(
        onTapDown: (_) => _setPressed(true),
        onTapUp: (_) => _setPressed(false),
        onTapCancel: () => _setPressed(false),
        onTap: widget.onPressed,
        behavior: HitTestBehavior.opaque,
        child: PixelBox(
          raised: true,
          pressed: _pressed,
          color: background,
          borderColor: border,
          padding: const EdgeInsets.symmetric(
            horizontal: PixelMetrics.space4,
            vertical: PixelMetrics.space3,
          ),
          child: Row(
            mainAxisSize: widget.expand ? MainAxisSize.max : MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (widget.glyph != null) ...[
                PixelIcon(widget.glyph!, color: foreground),
                const SizedBox(width: PixelMetrics.space2),
              ],
              Flexible(
                child: Text(
                  widget.label.toUpperCase(),
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: foreground,
                    fontSize: PixelTheme.sizeLabel,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A square icon-only button, used for the compact controls in the top bar
/// and on each word row.
class PixelIconButton extends StatefulWidget {
  const PixelIconButton({
    super.key,
    required this.glyph,
    required this.semanticLabel,
    this.onPressed,
    this.color,
    this.active = false,
  });

  final PixelGlyph glyph;
  final String semanticLabel;
  final VoidCallback? onPressed;
  final Color? color;

  /// Inverts the button — how a sprite UI shows a live/selected state, in
  /// place of a colour tint.
  final bool active;

  @override
  State<PixelIconButton> createState() => _PixelIconButtonState();
}

class _PixelIconButtonState extends State<PixelIconButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final enabled = widget.onPressed != null;
    final background = widget.active ? palette.accent : palette.surface;
    final foreground = widget.active
        ? palette.onAccent
        : (widget.color ?? (enabled ? palette.ink : palette.inkFaint));

    return Semantics(
      button: true,
      enabled: enabled,
      label: widget.semanticLabel,
      child: GestureDetector(
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: widget.onPressed,
        behavior: HitTestBehavior.opaque,
        child: SizedBox(
          width: PixelMetrics.tapTarget,
          height: PixelMetrics.tapTarget,
          child: Center(
            child: PixelBox(
              raised: true,
              pressed: _pressed,
              color: background,
              padding: const EdgeInsets.all(PixelMetrics.space2),
              child: PixelIcon(widget.glyph, color: foreground),
            ),
          ),
        ),
      ),
    );
  }
}
