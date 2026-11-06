import 'package:flutter_test/flutter_test.dart';
import 'package:veea_english_app/core/theme/pixel_theme.dart';

void main() {
  group('PixelTheme Modern Typography', () {
    test('configures clean modern readable typography across all text styles', () {
      final theme = PixelTheme.light();

      expect(theme.textTheme.bodyLarge?.fontFamily, isNot('Handjet'));
      expect(theme.textTheme.titleLarge?.fontFamily, isNot('Handjet'));
      expect(theme.textTheme.labelSmall?.fontFamily, isNot('Handjet'));
      expect(theme.textTheme.bodyLarge?.fontSize, equals(16.0));
      expect(theme.textTheme.titleLarge?.fontSize, equals(20.0));
    });
  });
}
