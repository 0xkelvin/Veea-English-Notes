import 'package:flutter/material.dart';

import '../../core/theme/pixel_metrics.dart';
import '../../core/theme/pixel_palette.dart';

/// A text input framed by a hard outline that switches to the accent colour
/// when focused. No fill animation, no floating label.
class PixelField extends StatefulWidget {
  const PixelField({
    super.key,
    required this.controller,
    required this.label,
    this.hint,
    this.optional = false,
    this.autofocus = false,
    this.maxLines = 1,
    this.textInputAction,
    this.onSubmitted,
    this.onChanged,
    this.textCapitalization = TextCapitalization.none,
    this.trailing,
    this.obscure = false,
  });

  final TextEditingController controller;
  final String label;
  final String? hint;
  final bool optional;
  final bool autofocus;
  final int maxLines;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onSubmitted;
  final ValueChanged<String>? onChanged;
  final TextCapitalization textCapitalization;

  /// Optional control rendered beside the field, e.g. a remove button.
  final Widget? trailing;

  /// Hides the text, for passwords.
  final bool obscure;

  @override
  State<PixelField> createState() => _PixelFieldState();
}

class _PixelFieldState extends State<PixelField> {
  final _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final theme = Theme.of(context);
    final focused = _focusNode.hasFocus;

    final field = Container(
      decoration: BoxDecoration(
        color: palette.surface,
        border: Border.all(
          color: focused ? palette.accent : palette.border,
          width: PixelMetrics.border,
        ),
      ),
      child: TextField(
        controller: widget.controller,
        focusNode: _focusNode,
        autofocus: widget.autofocus,
        // A password field must stay on one line; obscured text cannot wrap.
        maxLines: widget.obscure ? 1 : widget.maxLines,
        obscureText: widget.obscure,
        textInputAction: widget.textInputAction,
        onSubmitted: widget.onSubmitted,
        onChanged: widget.onChanged,
        textCapitalization: widget.textCapitalization,
        cursorWidth: PixelMetrics.border,
        cursorRadius: Radius.zero,
        style: theme.textTheme.bodyLarge,
        decoration: InputDecoration(
          isDense: true,
          hintText: widget.hint,
          hintStyle: theme.textTheme.bodyLarge?.copyWith(
            color: palette.inkFaint,
          ),
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: PixelMetrics.space3,
            vertical: PixelMetrics.space3,
          ),
        ),
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              widget.label.toUpperCase(),
              style: theme.textTheme.labelSmall?.copyWith(
                color: focused ? palette.accent : palette.inkFaint,
              ),
            ),
            if (widget.optional) ...[
              const SizedBox(width: PixelMetrics.space1),
              Text(
                '(OPTIONAL)',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: palette.inkFaint,
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: PixelMetrics.space1),
        if (widget.trailing == null)
          field
        else
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: field),
              const SizedBox(width: PixelMetrics.space2),
              widget.trailing!,
            ],
          ),
      ],
    );
  }
}

/// The search input: a single bordered row with no label above it.
class PixelSearchField extends StatelessWidget {
  const PixelSearchField({
    super.key,
    required this.controller,
    required this.onChanged,
    this.autofocus = true,
    this.hint = 'Search every word',
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final bool autofocus;
  final String hint;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Container(
      decoration: BoxDecoration(
        color: palette.surface,
        border: Border.all(color: palette.border, width: PixelMetrics.border),
      ),
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        autofocus: autofocus,
        textInputAction: TextInputAction.search,
        cursorWidth: PixelMetrics.border,
        cursorRadius: Radius.zero,
        style: Theme.of(context).textTheme.bodyLarge,
        decoration: InputDecoration(
          isDense: true,
          hintText: hint,
          hintStyle: Theme.of(
            context,
          ).textTheme.bodyLarge?.copyWith(color: palette.inkFaint),
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: PixelMetrics.space3,
            vertical: PixelMetrics.space3,
          ),
        ),
      ),
    );
  }
}

/// Strips the platform overscroll effect.
///
/// Android's stretch and the glow indicator both bend the layout's hard
/// edges, which reads as wrong against square-cornered blocks.
class PixelScrollBehavior extends MaterialScrollBehavior {
  const PixelScrollBehavior();

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    return child;
  }
}
