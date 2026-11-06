import 'package:flutter_test/flutter_test.dart';
import 'package:veea_english_app/core/theme/pixel_theme.dart';

void main() {
  group('PixelTheme Typography Modes', () {
    test('Hybrid mode configures readable body text', () {
      final theme = PixelTheme.light(typographyMode: TypographyMode.hybrid);

      expect(theme.textTheme.bodyLarge?.fontFamily, isNot('Handjet'));
      expect(theme.textTheme.bodyLarge?.fontSize, equals(16.0));

      // Titles and display retain Handjet
      expect(theme.textTheme.titleLarge?.fontFamily, equals('Handjet'));
      expect(theme.textTheme.labelMedium?.fontFamily, equals('Handjet'));
    });

    test('Pixel mode configures Handjet font across all text styles', () {
      final theme = PixelTheme.light(typographyMode: TypographyMode.pixel);

      expect(theme.textTheme.bodyLarge?.fontFamily, equals('Handjet'));
      expect(theme.textTheme.titleLarge?.fontFamily, equals('Handjet'));
      expect(theme.textTheme.labelSmall?.fontFamily, equals('Handjet'));
    });
  });
}
