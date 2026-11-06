import 'package:flutter/material.dart';

import 'pixel_metrics.dart';
import 'pixel_palette.dart';

/// Typography mode selection: Clean Modern (default) or Compact.
enum TypographyMode {
  hybrid(label: 'Clean Modern'),
  pixel(label: 'Compact Clear');

  const TypographyMode({required this.label});

  final String label;
}

/// Builds the app theme using clean, modern, liquid-elevated styling and
/// high-legibility system typography.
class PixelTheme {
  PixelTheme._();

  /// Modern system sans-serif font family used across the app.
  static const String fontFamily = 'SF Pro Text';

  /// Clean, modern system font stack for maximum clarity and native rendering
  /// of English, IPA phonetics, and Vietnamese diacritics.
  static const List<String> _fallback = [
    'SF Pro Display',
    'SF Pro Text', // iOS / macOS
    'Inter',
    'Roboto', // Android
    'Noto Sans',
    'Helvetica Neue',
    'Arial',
    'sans-serif',
  ];

  /// Clean, readable typographic scale.
  static const double sizeCaption = 12;
  static const double sizeLabel = 14;
  static const double sizeBody = 16;
  static const double sizeTitle = 20;
  static const double sizeDisplay = 28;

  static TextStyle _readableStyle(
    double size,
    FontWeight weight,
    Color color, {
    double height = 1.4,
    double letterSpacing = 0.0,
  }) {
    return TextStyle(
      fontFamily: fontFamily,
      fontFamilyFallback: _fallback,
      fontSize: size,
      fontWeight: weight,
      height: height,
      color: color,
      letterSpacing: letterSpacing,
    );
  }

  static ThemeData light({
    TypographyMode typographyMode = TypographyMode.hybrid,
  }) => _build(
    PixelPalette.light,
    Brightness.light,
    typographyMode: typographyMode,
  );

  static ThemeData dark({
    TypographyMode typographyMode = TypographyMode.hybrid,
  }) =>
      _build(PixelPalette.dark, Brightness.dark, typographyMode: typographyMode);

  static ThemeData matrixGreen({
    TypographyMode typographyMode = TypographyMode.hybrid,
  }) => _build(
    PixelPalette.dark,
    Brightness.dark,
    typographyMode: typographyMode,
  );

  static ThemeData cyberpunkNeon({
    TypographyMode typographyMode = TypographyMode.hybrid,
  }) => _build(
    PixelPalette.dark,
    Brightness.dark,
    typographyMode: typographyMode,
  );

  static ThemeData oledBlack({
    TypographyMode typographyMode = TypographyMode.hybrid,
  }) => _build(
    PixelPalette.dark,
    Brightness.dark,
    typographyMode: typographyMode,
  );

  static ThemeData _build(
    PixelPalette palette,
    Brightness brightness, {
    TypographyMode typographyMode = TypographyMode.hybrid,
  }) {
    final textTheme = TextTheme(
      displayLarge: _readableStyle(
        sizeDisplay + 6,
        FontWeight.w700,
        palette.ink,
        height: 1.2,
        letterSpacing: -0.4,
      ),
      displayMedium: _readableStyle(
        sizeDisplay + 2,
        FontWeight.w700,
        palette.ink,
        height: 1.2,
        letterSpacing: -0.3,
      ),
      displaySmall: _readableStyle(
        sizeDisplay,
        FontWeight.w700,
        palette.ink,
        height: 1.25,
        letterSpacing: -0.3,
      ),
      headlineMedium: _readableStyle(
        sizeDisplay - 2,
        FontWeight.w700,
        palette.ink,
        height: 1.25,
        letterSpacing: -0.2,
      ),
      titleLarge: _readableStyle(
        sizeTitle,
        FontWeight.w700,
        palette.ink,
        height: 1.3,
        letterSpacing: -0.2,
      ),
      titleMedium: _readableStyle(
        17,
        FontWeight.w600,
        palette.ink,
        height: 1.3,
        letterSpacing: -0.1,
      ),
      titleSmall: _readableStyle(
        15,
        FontWeight.w600,
        palette.ink,
        height: 1.3,
      ),
      bodyLarge: _readableStyle(
        sizeBody,
        FontWeight.w400,
        palette.ink,
        height: 1.45,
      ),
      bodyMedium: _readableStyle(
        14.5,
        FontWeight.w400,
        palette.inkMuted,
        height: 1.4,
      ),
      bodySmall: _readableStyle(
        13,
        FontWeight.w400,
        palette.inkFaint,
        height: 1.35,
      ),
      labelSmall: _readableStyle(
        sizeCaption,
        FontWeight.w600,
        palette.inkMuted,
        height: 1.25,
        letterSpacing: 0.2,
      ),
      labelMedium: _readableStyle(
        sizeLabel,
        FontWeight.w600,
        palette.ink,
        height: 1.25,
        letterSpacing: 0.1,
      ),
      labelLarge: _readableStyle(
        sizeBody,
        FontWeight.w600,
        palette.ink,
        height: 1.25,
        letterSpacing: 0.1,
      ),
    );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      fontFamily: fontFamily,
      fontFamilyFallback: _fallback,
      scaffoldBackgroundColor: palette.paper,
      canvasColor: palette.paper,
      splashFactory: InkSparkle.splashFactory,
      highlightColor: palette.accent.withValues(alpha: 0.06),
      splashColor: palette.accent.withValues(alpha: 0.08),
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
      dialogTheme: DialogThemeData(
        backgroundColor: palette.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(PixelMetrics.radiusLg),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: palette.ink,
        contentTextStyle: TextStyle(
          fontFamily: fontFamily,
          color: palette.surface,
          fontWeight: FontWeight.w600,
        ),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(PixelMetrics.radius),
        ),
      ),
      textTheme: textTheme,
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: palette.accent,
        selectionColor: palette.accent.withValues(alpha: 0.22),
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
