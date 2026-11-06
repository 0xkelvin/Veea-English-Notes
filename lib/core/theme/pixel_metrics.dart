/// Geometry constants for the clean modern liquid theme.
class PixelMetrics {
  PixelMetrics._();

  /// Base spacing unit.
  static const double unit = 4;

  static const double space1 = unit; // 4
  static const double space2 = unit * 2; // 8
  static const double space3 = unit * 3; // 12
  static const double space4 = unit * 4; // 16
  static const double space5 = unit * 5; // 20
  static const double space6 = unit * 6; // 24
  static const double space8 = unit * 8; // 32
  static const double space12 = unit * 12; // 48

  /// Subtle 1px hairline border for modern liquid cards and inputs.
  static const double border = 1;

  /// Legacy raise offset (replaced by soft diffused shadows).
  static const double raise = 0;

  /// Minimum accessible tap target.
  static const double tapTarget = 44;

  /// Smooth rounded corner radii.
  static const double radiusSm = 10;
  static const double radius = 14;
  static const double radiusLg = 18;
  static const double radiusPill = 999;
}
