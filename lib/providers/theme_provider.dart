import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/theme/pixel_theme.dart';

enum AppThemeMode {
  system(label: 'System Default'),
  classicLight(label: 'Paper Light'),
  classicDark(label: 'Night Dark'),
  matrixGreen(label: 'GameBoy Matrix Green'),
  cyberpunkNeon(label: 'Cyberpunk Neon'),
  oledBlack(label: 'OLED True Black');

  const AppThemeMode({required this.label});

  final String label;
}

/// Manages active retro pixel themes and persists selection.
class ThemeProvider extends ChangeNotifier {
  static const String _key = 'app_theme_mode';

  AppThemeMode _mode = AppThemeMode.system;
  bool _isDisposed = false;

  AppThemeMode get mode => _mode;

  ThemeMode get themeMode => switch (_mode) {
        AppThemeMode.system => ThemeMode.system,
        AppThemeMode.classicLight => ThemeMode.light,
        _ => ThemeMode.dark,
      };

  ThemeData get activeTheme => switch (_mode) {
        AppThemeMode.system => PixelTheme.light(),
        AppThemeMode.classicLight => PixelTheme.light(),
        AppThemeMode.classicDark => PixelTheme.dark(),
        AppThemeMode.matrixGreen => PixelTheme.matrixGreen(),
        AppThemeMode.cyberpunkNeon => PixelTheme.cyberpunkNeon(),
        AppThemeMode.oledBlack => PixelTheme.oledBlack(),
      };

  ThemeData get darkTheme => switch (_mode) {
        AppThemeMode.matrixGreen => PixelTheme.matrixGreen(),
        AppThemeMode.cyberpunkNeon => PixelTheme.cyberpunkNeon(),
        AppThemeMode.oledBlack => PixelTheme.oledBlack(),
        _ => PixelTheme.dark(),
      };

  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_key);
      if (saved != null) {
        _mode = AppThemeMode.values.firstWhere(
          (e) => e.name == saved,
          orElse: () => AppThemeMode.system,
        );
        notifyListeners();
      }
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
