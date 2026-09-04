import 'package:flutter/material.dart';

/// A 7x7 bitmap icon, painted one square at a time.
///
/// Material's icon font is anti-aliased vector art and reads as smooth and
/// modern next to a pixel typeface. These are drawn as literal grids instead,
/// with anti-aliasing off, so every edge is hard.
class PixelIcon extends StatelessWidget {
  const PixelIcon(this.glyph, {super.key, required this.color, this.scale = 2});

  final PixelGlyph glyph;
  final Color color;

  /// Logical size of one square in the grid. Whole numbers keep the squares
  /// aligned to device pixels.
  final double scale;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: glyph.columns * scale,
      height: glyph.rows.length * scale,
      child: CustomPaint(
        painter: _PixelIconPainter(glyph: glyph, color: color, scale: scale),
      ),
    );
  }
}

class _PixelIconPainter extends CustomPainter {
  const _PixelIconPainter({
    required this.glyph,
    required this.color,
    required this.scale,
  });

  final PixelGlyph glyph;
  final Color color;
  final double scale;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..isAntiAlias = false
      ..style = PaintingStyle.fill;

    for (var y = 0; y < glyph.rows.length; y++) {
      final row = glyph.rows[y];
      for (var x = 0; x < row.length; x++) {
        if (row[x] == '.') continue;
        canvas.drawRect(
          Rect.fromLTWH(x * scale, y * scale, scale, scale),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_PixelIconPainter old) =>
      old.glyph != glyph || old.color != color || old.scale != scale;
}

/// A bitmap glyph. `#` marks a filled square, `.` an empty one.
class PixelGlyph {
  const PixelGlyph(this.rows);

  final List<String> rows;

  int get columns => rows.isEmpty ? 0 : rows.first.length;

  static const plus = PixelGlyph([
    '...#...',
    '...#...',
    '...#...',
    '#######',
    '...#...',
    '...#...',
    '...#...',
  ]);

  static const close = PixelGlyph([
    '#.....#',
    '##...##',
    '.##.##.',
    '..###..',
    '.##.##.',
    '##...##',
    '#.....#',
  ]);

  static const arrowUp = PixelGlyph([
    '...#...',
    '..###..',
    '.#####.',
    '#######',
    '...#...',
    '...#...',
    '...#...',
  ]);

  static const arrowDown = PixelGlyph([
    '...#...',
    '...#...',
    '...#...',
    '#######',
    '.#####.',
    '..###..',
    '...#...',
  ]);

  static const arrowLeft = PixelGlyph([
    '...#...',
    '..##...',
    '.###...',
    '#######',
    '.###...',
    '..##...',
    '...#...',
  ]);

  static const arrowRight = PixelGlyph([
    '...#...',
    '...##..',
    '...###.',
    '#######',
    '...###.',
    '...##..',
    '...#...',
  ]);

  static const search = PixelGlyph([
    '.####..',
    '#....#.',
    '#....#.',
    '#....#.',
    '.####..',
    '...#.#.',
    '....##.',
  ]);

  static const speaker = PixelGlyph([
    '...#...',
    '..##.#.',
    '.###..#',
    '####..#',
    '.###..#',
    '..##.#.',
    '...#...',
  ]);

  static const pencil = PixelGlyph([
    '....###',
    '...###.',
    '..###..',
    '.###...',
    '###....',
    '##.....',
    '###....',
  ]);

  static const trash = PixelGlyph([
    '..###..',
    '#######',
    '.#####.',
    '.#.#.#.',
    '.#.#.#.',
    '.#.#.#.',
    '.#####.',
  ]);

  static const check = PixelGlyph([
    '.....##',
    '....##.',
    '...##..',
    '#.##...',
    '####...',
    '.##....',
    '.......',
  ]);

  /// Account and sync. A cloud rather than a person: what the screen is
  /// really about is whether the words have left the device.
  static const cloud = PixelGlyph([
    '.......',
    '...##..',
    '..####.',
    '.######',
    '#######',
    '#######',
    '.......',
  ]);

  static const calendar = PixelGlyph([
    '.#...#.',
    '#######',
    '#.....#',
    '#.##..#',
    '#.....#',
    '#...##.',
    '#######',
  ]);

  static const cards = PixelGlyph([
    '.#####.',
    '#.....#',
    '#.###.#',
    '#.#.#.#',
    '#.###.#',
    '#.....#',
    '.#####.',
  ]);

  static const sword = PixelGlyph([
    '......#',
    '.....##',
    '....##.',
    '.##.#..',
    '####...',
    '#..##..',
    '#......',
  ]);

  static const flame = PixelGlyph([
    '...#...',
    '..###..',
    '.#.#.#.',
    '##.#.##',
    '#######',
    '.#####.',
    '..###..',
  ]);

  static const trophy = PixelGlyph([
    '#######',
    '#.#.#.#',
    '.#####.',
    '..###..',
    '...#...',
    '..###..',
    '.#####.',
  ]);

  static const star = PixelGlyph([
    '...#...',
    '..###..',
    '#######',
    '.#####.',
    '.##.##.',
    '##...##',
    '.......',
  ]);

  static const gamepad = PixelGlyph([
    '.......',
    '.#####.',
    '#######',
    '##.#.##',
    '#######',
    '#.....#',
    '.......',
  ]);

  static const heart = PixelGlyph([
    '.#...#.',
    '#######',
    '#######',
    '#######',
    '.#####.',
    '..###..',
    '...#...',
  ]);

  static const shield = PixelGlyph([
    '#######',
    '#######',
    '#######',
    '.#####.',
    '.#####.',
    '..###..',
    '...#...',
  ]);

  static const skull = PixelGlyph([
    '.#####.',
    '#.#.#.#',
    '#######',
    '.#####.',
    '.#.#.#.',
    '..###..',
    '.......',
  ]);

  static const bolt = PixelGlyph([
    '....##.',
    '...##..',
    '..##...',
    '.######',
    '...##..',
    '..##...',
    '.##....',
  ]);

  static const link = PixelGlyph([
    '.####..',
    '#....#.',
    '#..##..',
    '..##..#',
    '.#....#',
    '..####.',
    '.......',
  ]);

  static const gear = PixelGlyph([
    '.#.##.#',
    '#######',
    '.##.##.',
    '##...##',
    '.##.##.',
    '#######',
    '.#.##.#',
  ]);

  static const alien = PixelGlyph([
    '.#...#.',
    '..#.#..',
    '.#####.',
    '##.#.##',
    '#######',
    '#.#.#.#',
    '#.....#',
  ]);

  static const brick = PixelGlyph([
    '#######',
    '#..#..#',
    '#######',
    '..#..#.',
    '#######',
    '#..#..#',
    '#######',
  ]);

  static const frog = PixelGlyph([
    '#.....#',
    '##...##',
    '.#####.',
    '#######',
    '.#####.',
    '##.#.##',
    '#.....#',
  ]);

  static const pacman = PixelGlyph([
    '.#####.',
    '#######',
    '####...',
    '###....',
    '####...',
    '#######',
    '.#####.',
  ]);

  static const tetris = PixelGlyph([
    '...#...',
    '..###..',
    '..###..',
    '#######',
    '#######',
    '#..#..#',
    '#..#..#',
  ]);

  static const fish = PixelGlyph([
    '....#..',
    '.#..##.',
    '######.',
    '#######',
    '######.',
    '.#..##.',
    '....#..',
  ]);

  static const target = PixelGlyph([
    '..###..',
    '.#...#.',
    '#..#..#',
    '#.#.#.#',
    '#..#..#',
    '.#...#.',
    '..###..',
  ]);

  static const fire = PixelGlyph([
    '...#...',
    '..###..',
    '.#####.',
    '#######',
    '##.#.##',
    '.#...#.',
    '.......',
  ]);

  static const headphones = PixelGlyph([
    '..###..',
    '.#...#.',
    '#.....#',
    '##...##',
    '##...##',
    '##...##',
    '.......',
  ]);

  static const cassette = PixelGlyph([
    '#######',
    '#.#.#.#',
    '#######',
    '#.###.#',
    '#.###.#',
    '#######',
    '.......',
  ]);

  static const pet = PixelGlyph([
    '.#...#.',
    '##...##',
    '#######',
    '#.#.#.#',
    '#######',
    '.#.#.#.',
    '.#...#.',
  ]);


  static const food = PixelGlyph([
    '...##..',
    '..####.',
    '.######',
    '#######',
    '.######',
    '..#..#.',
    '.......',
  ]);

  static const camera = PixelGlyph([
    '..###..',
    '#######',
    '#.###.#',
    '#.#.#.#',
    '#.###.#',
    '#######',
    '.......',
  ]);

  static const wand = PixelGlyph([
    '.....#.',
    '....#.#',
    '...#.#.',
    '..#....',
    '.#.....',
    '#......',
    '.......',
  ]);

  static const scan = PixelGlyph([
    '##...##',
    '#.....#',
    '..###..',
    '..#.#..',
    '..###..',
    '#.....#',
    '##...##',
  ]);

  @override
  bool operator ==(Object other) =>
      other is PixelGlyph && identical(other.rows, rows);

  @override
  int get hashCode => rows.hashCode;
}
