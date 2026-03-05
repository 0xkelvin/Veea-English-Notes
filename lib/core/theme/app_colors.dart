import 'package:flutter/material.dart';

class AppColors {
  AppColors._();

  // Primary palette from Figma design
  static const Color primary = Color(0xFFFF5722);
  static const Color primaryForeground = Color(0xFFFFFFFF);

  // Accent (purple)
  static const Color accent = Color(0xFF7C3AED);
  static const Color accentForeground = Color(0xFFFFFFFF);

  // Backgrounds
  static const Color background = Color(0xFF0A0A0F);
  static const Color card = Color(0xFF1A1A24);
  static const Color secondary = Color(0xFF2A2A38);

  // Foregrounds
  static const Color foreground = Color(0xFFFFFFFF);
  static const Color cardForeground = Color(0xFFFFFFFF);
  static const Color secondaryForeground = Color(0xFFFFFFFF);
  static const Color mutedForeground = Color(0xFF8F8F9D);

  // Input
  static const Color inputBackground = Color(0xFF2A2A38);
  static const Color inputBorder = Colors.transparent;

  // Border
  static final Color border = Colors.white.withValues(alpha: 0.1);

  // Destructive
  static const Color destructive = Color(0xFFFF5722);

  // Chart colors
  static const Color chart1 = Color(0xFFFF5722); // orange
  static const Color chart2 = Color(0xFF7C3AED); // purple
  static const Color chart3 = Color(0xFF10B981); // green
  static const Color chart4 = Color(0xFF3B82F6); // blue
  static const Color chart5 = Color(0xFFF59E0B); // amber

  // Gradients
  static const LinearGradient primaryGradient = LinearGradient(
    colors: [Color(0xFFFF5722), Color(0xFFFF7043)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient accentGradient = LinearGradient(
    colors: [Color(0xFF7C3AED), Color(0xFF9333EA)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
}
