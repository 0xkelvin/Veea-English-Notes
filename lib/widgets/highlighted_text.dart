import 'package:flutter/material.dart';

/// Renders a sentence or paragraph while highlighting occurrences of [targetWord].
///
/// Matches whole words and common English inflections (e.g. plurals, past tense, -ing, -ly).
class HighlightedText extends StatelessWidget {
  const HighlightedText({
    super.key,
    required this.text,
    required this.targetWord,
    this.style,
    this.highlightStyle,
    this.maxLines,
    this.overflow,
  });

  final String text;
  final String targetWord;
  final TextStyle? style;
  final TextStyle? highlightStyle;
  final int? maxLines;
  final TextOverflow? overflow;

  @override
  Widget build(BuildContext context) {
    final cleanWord = targetWord.trim();
    if (cleanWord.isEmpty || text.isEmpty) {
      return Text(text, style: style, maxLines: maxLines, overflow: overflow);
    }

    // Escape any regex special characters in the target word
    final escaped = RegExp.escape(cleanWord);
    // Match root word with common inflections on word boundaries
    final pattern = RegExp(
      r'\b' + escaped + r'(s|es|ed|ing|ly|d|tion|er)?\b',
      caseSensitive: false,
    );

    final matches = pattern.allMatches(text).toList();
    if (matches.isEmpty) {
      return Text(text, style: style, maxLines: maxLines, overflow: overflow);
    }

    final spans = <InlineSpan>[];
    int lastEnd = 0;

    for (final match in matches) {
      if (match.start > lastEnd) {
        spans.add(
          TextSpan(
            text: text.substring(lastEnd, match.start),
            style: style,
          ),
        );
      }

      spans.add(
        TextSpan(
          text: text.substring(match.start, match.end),
          style: highlightStyle ??
              (style ?? const TextStyle()).copyWith(
                fontWeight: FontWeight.bold,
              ),
        ),
      );

      lastEnd = match.end;
    }

    if (lastEnd < text.length) {
      spans.add(
        TextSpan(
          text: text.substring(lastEnd),
          style: style,
        ),
      );
    }

    return Text.rich(
      TextSpan(children: spans),
      style: style,
      maxLines: maxLines,
      overflow: overflow,
    );
  }
}
