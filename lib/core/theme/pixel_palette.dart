import 'package:flutter/material.dart';

import '../../models/part_of_speech.dart';

/// The app's modern colour tokens, exposed through [Theme] as an extension.
///
/// Designed around a clean, airy "Liquid Modern" aesthetic: soft translucent
/// surfaces, crisp slate typography, subtle borders, and a vibrant ocean-indigo
/// accent.
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

  /// Elevated cards, fields, buttons.
  final Color surface;

  /// Primary text.
  final Color ink;

  /// Secondary text — meanings, metadata.
  final Color inkMuted;

  /// Tertiary text — hints, disabled states.
  final Color inkFaint;

  /// Subtle 1px card and divider outlines.
  final Color border;

  final Color accent;
  final Color onAccent;
  final Color danger;

  /// Semantic tint for grammatical parts of speech, calibrated for this palette.
  Color posColor(PartOfSpeech? pos) {
    if (pos == null) return inkMuted;
    final isDark = ink.computeLuminance() > paper.computeLuminance();
    return switch (pos) {
      PartOfSpeech.noun =>
        isDark ? const Color(0xFF60A5FA) : const Color(0xFF2563EB),
      PartOfSpeech.verb =>
        isDark ? const Color(0xFF34D399) : const Color(0xFF047857),
      PartOfSpeech.adjective =>
        isDark ? const Color(0xFFFBBF24) : const Color(0xFF92400E),
      PartOfSpeech.adverb =>
        isDark ? const Color(0xFFA78BFA) : const Color(0xFF7C3AED),
      PartOfSpeech.phrase =>
        isDark ? const Color(0xFFF472B6) : const Color(0xFFBE185D),
      PartOfSpeech.idiom =>
        isDark ? const Color(0xFFFB923C) : const Color(0xFFC2410C),
      PartOfSpeech.other => accent,
    };
  }

  /// Liquid Modern Light: cool alabaster background, pure white elevated cards,
  /// deep slate ink, and a crisp ocean-blue accent.
  static const light = PixelPalette(
    paper: Color(0xFFF4F7FB),
    surface: Color(0xFFFFFFFF),
    ink: Color(0xFF0F172A),
    inkMuted: Color(0xFF475569),
    inkFaint: Color(0xFF64748B),
    border: Color(0xFFE2E8F0),
    accent: Color(0xFF2563EB),
    onAccent: Color(0xFFFFFFFF),
    danger: Color(0xFFE11D48),
  );

  /// Liquid Modern Dark: deep midnight slate background, elevated translucent
  /// navy-slate cards, crisp white ink, and luminous sky-indigo accent.
  static const dark = PixelPalette(
    paper: Color(0xFF0B0F19),
    surface: Color(0xFF151C2C),
    ink: Color(0xFFF8FAFC),
    inkMuted: Color(0xFF94A3B8),
    inkFaint: Color(0xFF94A3B8),
    border: Color(0xFF1E293B),
    accent: Color(0xFF3B82F6),
    onAccent: Color(0xFF0B0F19),
    danger: Color(0xFFF43F5E),
  );

  /// Kept as aliases to the modern palettes for backward compatibility with tests.
  static const matrixGreen = dark;
  static const cyberpunkNeon = dark;
  static const oledBlack = dark;

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
