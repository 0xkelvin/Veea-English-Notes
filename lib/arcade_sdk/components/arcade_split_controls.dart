import 'dart:async';
import 'package:flutter/material.dart';

import '../../core/theme/pixel_metrics.dart';
import '../../core/theme/pixel_palette.dart';
import '../../widgets/pixel/pixel_box.dart';

/// Reusable ergonomic two-handed arcade controller bar.
///
/// Left thumb handles movement / D-pad with continuous tap-and-hold repeating.
/// Right thumb handles main action triggers (FIRE, JUMP, CATCH, BOOST).
class ArcadeSplitControls extends StatelessWidget {
  const ArcadeSplitControls({
    super.key,
    this.onLeft,
    this.onRight,
    this.onUp,
    this.onDown,
    this.onAction,
    this.actionLabel = 'FIRE',
    this.actionIcon,
    this.actionColor,
    this.secondaryAction,
    this.secondaryLabel,
  });

  final VoidCallback? onLeft;
  final VoidCallback? onRight;
  final VoidCallback? onUp;
  final VoidCallback? onDown;

  final VoidCallback? onAction;
  final String actionLabel;
  final Widget? actionIcon;
  final Color? actionColor;

  final VoidCallback? secondaryAction;
  final String? secondaryLabel;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: PixelMetrics.space3,
        vertical: PixelMetrics.space2,
      ),
      decoration: BoxDecoration(
        color: palette.surface,
        border: Border(
          top: BorderSide(color: palette.border, width: PixelMetrics.border),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // Left thumb navigation buttons
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (onLeft != null)
                _HoldButton(
                  label: '◀',
                  onTrigger: onLeft!,
                  semanticLabel: 'Move Left',
                ),
              if (onRight != null) ...[
                const SizedBox(width: PixelMetrics.space2),
                _HoldButton(
                  label: '▶',
                  onTrigger: onRight!,
                  semanticLabel: 'Move Right',
                ),
              ],
              if (onUp != null) ...[
                const SizedBox(width: PixelMetrics.space2),
                _HoldButton(
                  label: '▲',
                  onTrigger: onUp!,
                  semanticLabel: 'Move Up',
                ),
              ],
              if (onDown != null) ...[
                const SizedBox(width: PixelMetrics.space2),
                _HoldButton(
                  label: '▼',
                  onTrigger: onDown!,
                  semanticLabel: 'Move Down',
                ),
              ],
            ],
          ),

          // Right thumb action buttons
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (secondaryAction != null && secondaryLabel != null) ...[
                _ActionButton(
                  label: secondaryLabel!,
                  onPressed: secondaryAction!,
                  color: palette.paper,
                ),
                const SizedBox(width: PixelMetrics.space2),
              ],
              if (onAction != null)
                _ActionButton(
                  label: actionLabel,
                  icon: actionIcon,
                  onPressed: onAction!,
                  color: actionColor ?? palette.accent,
                  textColor: palette.onAccent,
                  isPrimary: true,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _HoldButton extends StatefulWidget {
  const _HoldButton({
    required this.label,
    required this.onTrigger,
    required this.semanticLabel,
  });

  final String label;
  final VoidCallback onTrigger;
  final String semanticLabel;

  @override
  State<_HoldButton> createState() => _HoldButtonState();
}

class _HoldButtonState extends State<_HoldButton> {
  Timer? _repeatTimer;
  bool _pressed = false;

  void _startHolding() {
    widget.onTrigger();
    setState(() => _pressed = true);
    _repeatTimer?.cancel();
    _repeatTimer = Timer.periodic(const Duration(milliseconds: 75), (_) {
      widget.onTrigger();
    });
  }

  void _stopHolding() {
    _repeatTimer?.cancel();
    _repeatTimer = null;
    if (_pressed) setState(() => _pressed = false);
  }

  @override
  void dispose() {
    _repeatTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    return GestureDetector(
      onTapDown: (_) => _startHolding(),
      onTapUp: (_) => _stopHolding(),
      onTapCancel: _stopHolding,
      child: Semantics(
        button: true,
        label: widget.semanticLabel,
        child: PixelBox(
          raised: !_pressed,
          color: _pressed ? palette.accent : palette.surface,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Text(
            widget.label,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: _pressed ? palette.onAccent : palette.ink,
            ),
          ),
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.label,
    required this.onPressed,
    this.icon,
    this.color,
    this.textColor,
    this.isPrimary = false,
  });

  final String label;
  final VoidCallback onPressed;
  final Widget? icon;
  final Color? color;
  final Color? textColor;
  final bool isPrimary;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    return GestureDetector(
      onTap: onPressed,
      child: PixelBox(
        raised: true,
        color: color ?? palette.surface,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              icon!,
              const SizedBox(width: 6),
            ],
            Text(
              label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                fontFamily: 'Handjet',
                color: textColor ?? (isPrimary ? palette.onAccent : palette.ink),
                letterSpacing: 0.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
