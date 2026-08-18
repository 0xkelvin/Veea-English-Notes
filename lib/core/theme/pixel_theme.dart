import 'package:flutter/material.dart';

import 'pixel_metrics.dart';
import 'pixel_palette.dart';

/// Builds the app theme.
///
/// Handjet is a variable pixel font. [_ELSH] selects the solid element shape —
/// at the default of 2 the glyphs are hairline-thin and at 0 they vanish
/// entirely, so it is pinned here rather than left to the font's default.
class PixelTheme {
  PixelTheme._();

  static const String fontFamily = 'Handjet';

  /// Element shape: 16 renders solid, filled pixels.
  static const double _elsh = 16;

  /// Element grid: 1 is the denser, more legible grid.
  static const double _elgr = 1;

  /// Families consulted for glyphs Handjet does not contain.
  ///
  /// No pixel font on Google Fonts carries the IPA block, so a phonetic
  /// transcription like `/rɪˈzɪliənt/` would otherwise paint as empty boxes.
  /// Only the missing characters fall through — everything Handjet covers,
  /// including all Vietnamese diacritics, still renders as pixels.
  static const List<String> _fallback = [
    'SF Pro Text', // iOS / macOS
    'Helvetica Neue',
    'Roboto', // Android
    'Noto Sans',
    'Arial',
  ];

  static List<FontVariation> _axes(double weight) => [
    FontVariation('wght', weight),
    FontVariation('ELGR', _elgr),
    FontVariation('ELSH', _elsh),
  ];

  /// Handjet sits small on the body, so the scale runs larger than a
  /// conventional one — 20px here reads like 15px of a normal text face.
  static const double sizeCaption = 15;
  static const double sizeLabel = 17;
  static const double sizeBody = 20;
  static const double sizeTitle = 25;
  static const double sizeDisplay = 34;

  static TextStyle _style(
    double size,
    double weight,
    Color color, {
    double height = 1.15,
    double letterSpacing = 0,
  }) {
    return TextStyle(
      fontFamily: fontFamily,
      fontFamilyFallback: _fallback,
      fontSize: size,
      height: height,
      color: color,
      letterSpacing: letterSpacing,
      fontVariations: _axes(weight),
      // The font carries its own weight axis; letting the engine synthesise a
      // fake bold would smear the pixel edges.
      fontWeight: FontWeight.normal,
    );
  }

  static ThemeData light() => _build(PixelPalette.light, Brightness.light);

  static ThemeData dark() => _build(PixelPalette.dark, Brightness.dark);

  static ThemeData _build(PixelPalette palette, Brightness brightness) {
    final textTheme = TextTheme(
      displaySmall: _style(sizeDisplay, 700, palette.ink),
      titleLarge: _style(sizeTitle, 700, palette.ink),
      titleMedium: _style(sizeBody, 700, palette.ink),
      bodyLarge: _style(sizeBody, 400, palette.ink, height: 1.3),
      bodyMedium: _style(sizeLabel, 400, palette.inkMuted, height: 1.3),
      // Chrome labels are uppercased and tracked out, the way a status bar in
      // a sprite game is set.
      labelSmall: _style(
        sizeCaption,
        700,
        palette.inkFaint,
        letterSpacing: 1.2,
      ),
      labelMedium: _style(sizeLabel, 700, palette.ink, letterSpacing: 0.5),
    );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      fontFamily: fontFamily,
      scaffoldBackgroundColor: palette.paper,
      canvasColor: palette.paper,
      splashFactory: NoSplash.splashFactory,
      // Ripples are the opposite of a pixel press; buttons swap to a pressed
      // sprite state instead.
      highlightColor: Colors.transparent,
      splashColor: Colors.transparent,
      hoverColor: Colors.transparent,
      colorScheme: ColorScheme(
        brightness: brightness,
        primary: palette.accent,
        onPrimary: palette.onAccent,
        secondary: palette.accent,
        onSecondary: palette.onAccent,
        surface: palette.surface,
        onSurface: palette.ink,
        error: palette.danger,
        onError: palette.onAccent,
      ),
      textTheme: textTheme,
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: palette.accent,
        selectionColor: palette.accent.withValues(alpha: 0.25),
        selectionHandleColor: palette.accent,
      ),
      dividerTheme: DividerThemeData(
        color: palette.border,
        thickness: PixelMetrics.border,
        space: PixelMetrics.border,
      ),
      extensions: [palette],
    );
  }
}
