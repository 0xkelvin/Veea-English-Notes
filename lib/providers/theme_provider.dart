import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/theme/pixel_theme.dart';

enum AppThemeMode {
  system(label: 'System Default'),
  classicLight(label: 'Liquid Light'),
  classicDark(label: 'Liquid Dark'),
  matrixGreen(label: 'Liquid Dark'),
  cyberpunkNeon(label: 'Liquid Dark'),
  oledBlack(label: 'Liquid Dark');

  const AppThemeMode({required this.label});

  final String label;
}

/// Manages active modern app theme (defaults to clean modern light/system).
class ThemeProvider extends ChangeNotifier {
  static const String _key = 'app_theme_mode_v2';
  static const String _typographyKey = 'app_typography_mode';

  AppThemeMode _mode = AppThemeMode.classicLight;
  TypographyMode _typographyMode = TypographyMode.hybrid;
  bool _isDisposed = false;

  AppThemeMode get mode => _mode;
  TypographyMode get typographyMode => _typographyMode;

  ThemeMode get themeMode => switch (_mode) {
    AppThemeMode.system => ThemeMode.system,
    AppThemeMode.classicLight => ThemeMode.light,
    _ => ThemeMode.dark,
  };

  ThemeData get activeTheme => switch (_mode) {
    AppThemeMode.system =>
      PixelTheme.light(typographyMode: _typographyMode),
    AppThemeMode.classicLight =>
      PixelTheme.light(typographyMode: _typographyMode),
    _ => PixelTheme.dark(typographyMode: _typographyMode),
  };

  ThemeData get darkTheme => PixelTheme.dark(typographyMode: _typographyMode);

  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_key);
      if (saved != null) {
        _mode = AppThemeMode.values.firstWhere(
          (e) => e.name == saved,
          orElse: () => AppThemeMode.classicLight,
        );
      }
      final savedTypography = prefs.getString(_typographyKey);
      if (savedTypography != null) {
        _typographyMode = TypographyMode.values.firstWhere(
          (e) => e.name == savedTypography,
          orElse: () => TypographyMode.hybrid,
        );
      }
      notifyListeners();
    } catch (error, stack) {
      debugPrint('Could not load theme setting: $error\n$stack');
    }
  }

  Future<void> setMode(AppThemeMode mode) async {
    if (_mode == mode) return;
    _mode = mode;
    notifyListeners();

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, mode.name);
    } catch (error, stack) {
      debugPrint('Could not save theme setting: $error\n$stack');
    }
  }

  Future<void> setTypographyMode(TypographyMode mode) async {
    if (_typographyMode == mode) return;
    _typographyMode = mode;
    notifyListeners();

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_typographyKey, mode.name);
    } catch (error, stack) {
      debugPrint('Could not save typography setting: $error\n$stack');
    }
  }

  @override
  void notifyListeners() {
    if (_isDisposed) return;
    super.notifyListeners();
  }

  @override
  void dispose() {
    _isDisposed = true;
    super.dispose();
  }
}
