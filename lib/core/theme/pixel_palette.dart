import 'package:flutter/material.dart';

/// The app's colour tokens, exposed through [Theme] as an extension.
///
/// The palette is deliberately tiny: paper, ink, a muted ink, a hard border
/// and one accent. Content is rendered in ink only — the accent is reserved
/// for interactive and selected states, so nothing competes with the words
/// themselves.
@immutable
class PixelPalette extends ThemeExtension<PixelPalette> {
  const PixelPalette({
    required this.paper,
    required this.surface,
    required this.ink,
    required this.inkMuted,
    required this.inkFaint,
    required this.border,
    required this.accent,
    required this.onAccent,
    required this.danger,
  });

  /// Page background.
  final Color paper;

  /// Raised blocks: rows, fields, buttons.
  final Color surface;

  /// Primary text.
  final Color ink;

  /// Secondary text — meanings, metadata.
  final Color inkMuted;

  /// Tertiary text — hints, disabled states.
  final Color inkFaint;

  /// Hard 2px rules and outlines. Near-black by design; a soft grey border
  /// would undo the blocky look.
  final Color border;

  final Color accent;
  final Color onAccent;
  final Color danger;

  /// Warm paper, near-black ink, deep green accent.
  static const light = PixelPalette(
    paper: Color(0xFFEDEAE0),
    surface: Color(0xFFF7F5EE),
    ink: Color(0xFF14140F),
    inkMuted: Color(0xFF5B5A50),
    inkFaint: Color(0xFF8C8A7E),
    border: Color(0xFF14140F),
    accent: Color(0xFF2F6B27),
    onAccent: Color(0xFFF7F5EE),
    danger: Color(0xFF9E2A1F),
  );

  /// Near-black screen with the classic handheld green as the accent.
  static const dark = PixelPalette(
    paper: Color(0xFF12140F),
    surface: Color(0xFF1B1E17),
    ink: Color(0xFFE6E4D8),
    inkMuted: Color(0xFF9A9C8C),
    inkFaint: Color(0xFF6A6C5F),
    border: Color(0xFF3A3E31),
    accent: Color(0xFF9BBC0F),
    onAccent: Color(0xFF12140F),
    danger: Color(0xFFD4674F),
  );

  @override
  PixelPalette copyWith({
    Color? paper,
    Color? surface,
    Color? ink,
    Color? inkMuted,
    Color? inkFaint,
    Color? border,
    Color? accent,
    Color? onAccent,
    Color? danger,
  }) {
    return PixelPalette(
      paper: paper ?? this.paper,
      surface: surface ?? this.surface,
      ink: ink ?? this.ink,
      inkMuted: inkMuted ?? this.inkMuted,
      inkFaint: inkFaint ?? this.inkFaint,
      border: border ?? this.border,
      accent: accent ?? this.accent,
      onAccent: onAccent ?? this.onAccent,
      danger: danger ?? this.danger,
    );
  }

  @override
  PixelPalette lerp(covariant PixelPalette? other, double t) {
    if (other == null) return this;
    return PixelPalette(
      paper: Color.lerp(paper, other.paper, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      ink: Color.lerp(ink, other.ink, t)!,
      inkMuted: Color.lerp(inkMuted, other.inkMuted, t)!,
      inkFaint: Color.lerp(inkFaint, other.inkFaint, t)!,
      border: Color.lerp(border, other.border, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      onAccent: Color.lerp(onAccent, other.onAccent, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
    );
  }
}

/// Convenience accessor: `context.palette.ink`.
extension PixelPaletteAccess on BuildContext {
  PixelPalette get palette => Theme.of(this).extension<PixelPalette>()!;
}
