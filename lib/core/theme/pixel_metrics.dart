/// Geometry constants for the pixel look.
///
/// Every dimension is a multiple of [unit] so edges land on whole pixels and
/// the layout reads as a grid rather than as free-floating boxes.
class PixelMetrics {
  PixelMetrics._();

  /// Base grid step. All spacing is a multiple of this.
  static const double unit = 4;

  static const double space1 = unit; // 4
  static const double space2 = unit * 2; // 8
  static const double space3 = unit * 3; // 12
  static const double space4 = unit * 4; // 16
  static const double space5 = unit * 5; // 20
  static const double space6 = unit * 6; // 24
  static const double space8 = unit * 8; // 32
  static const double space12 = unit * 12; // 48

  /// Outline thickness. Two logical pixels reads as a deliberate hard edge on
  /// high-density screens, where a 1px hairline looks like an accident.
  static const double border = 2;

  /// Offset of the solid drop block behind a raised element. Not a shadow —
  /// a second hard-edged rectangle, the way sprite UIs fake depth.
  static const double raise = 4;

  /// Minimum tap target. Kept at 44 to stay accessible despite the tight look.
  static const double tapTarget = 44;

  /// Zero, everywhere. Rounded corners would defeat the whole style.
  static const double radius = 0;
}
