import 'package:flutter/material.dart';

import '../../core/theme/pixel_metrics.dart';
import '../../core/theme/pixel_palette.dart';

/// A modern rounded text input that highlights with a soft accent ring when focused.
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

    final field = AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(PixelMetrics.radiusSm),
        border: Border.all(
          color: focused ? palette.accent : palette.border,
          width: focused ? 1.5 : PixelMetrics.border,
        ),
        boxShadow: focused
            ? [
                BoxShadow(
                  color: palette.accent.withValues(alpha: 0.12),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ]
            : null,
      ),
      child: Semantics(
        label: widget.label,
        child: TextField(
          controller: widget.controller,
          focusNode: _focusNode,
          autofocus: widget.autofocus,
          maxLines: widget.obscure ? 1 : widget.maxLines,
          obscureText: widget.obscure,
          textInputAction: widget.textInputAction,
          onSubmitted: widget.onSubmitted,
          onChanged: widget.onChanged,
          textCapitalization: widget.textCapitalization,
          cursorWidth: 2.0,
          cursorRadius: const Radius.circular(2),
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
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: PixelMetrics.space1,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              widget.label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: focused ? palette.accent : palette.inkMuted,
              ),
            ),
            if (widget.optional) ...[
              const SizedBox(width: PixelMetrics.space1),
              Text(
                'Optional',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: palette.inkFaint,
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: PixelMetrics.space1 + 2),
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

/// The search input: a clean rounded search bar.
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
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (context, value, _) => Container(
        decoration: BoxDecoration(
          color: palette.surface,
          borderRadius: BorderRadius.circular(PixelMetrics.radiusSm),
          border: Border.all(color: palette.border, width: PixelMetrics.border),
        ),
        child: TextField(
          controller: controller,
          onChanged: onChanged,
          autofocus: autofocus,
          textInputAction: TextInputAction.search,
          style: Theme.of(context).textTheme.bodyLarge,
          decoration: InputDecoration(
            isDense: true,
            prefixIcon: const Icon(Icons.search),
            suffixIcon: value.text.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Clear search',
                    onPressed: () {
                      controller.clear();
                      onChanged('');
                    },
                    icon: const Icon(Icons.close),
                  ),
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
      ),
    );
  }
}

/// Smooth scroll behavior across platforms.
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
