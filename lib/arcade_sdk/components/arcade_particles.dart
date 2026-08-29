import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Single 8-bit square pixel particle for explosion effects.
class ArcadeParticle {
  ArcadeParticle({
    required this.x,
    required this.y,
    required this.vx,
    required this.vy,
    required this.color,
    this.size = 4.0,
    this.life = 1.0,
  });

  double x;
  double y;
  double vx;
  double vy;
  Color color;
  double size;
  double life;

  /// Creates a radial explosion of retro square particles at (originX, originY).
  static List<ArcadeParticle> createExplosion({
    required double originX,
    required double originY,
    required Color color,
    int count = 18,
    double speed = 120.0,
  }) {
    final rnd = math.Random();
    return List.generate(count, (_) {
      final angle = rnd.nextDouble() * 2 * math.pi;
      final spd = (0.4 + rnd.nextDouble() * 0.8) * speed;
      return ArcadeParticle(
        x: originX,
        y: originY,
        vx: math.cos(angle) * spd,
        vy: math.sin(angle) * spd,
        color: color,
        size: 3.0 + rnd.nextDouble() * 3.0,
        life: 0.6 + rnd.nextDouble() * 0.4,
      );
    });
  }

  /// Updates position and fades life. Returns false when particle is dead.
  bool update(double dt) {
    x += vx * dt;
    y += vy * dt;
    life -= 1.8 * dt;
    return life > 0;
  }
}

/// Custom painter for fast rendering of retro square pixel particles.
class ArcadeParticlesPainter extends CustomPainter {
  const ArcadeParticlesPainter({required this.particles});

  final List<ArcadeParticle> particles;

  @override
  void paint(Canvas canvas, Size size) {
    if (particles.isEmpty) return;

    for (final p in particles) {
      if (p.life <= 0) continue;
      final paint = Paint()
        ..color = p.color.withValues(alpha: p.life.clamp(0.0, 1.0))
        ..style = PaintingStyle.fill;

      canvas.drawRect(
        Rect.fromCenter(
          center: Offset(p.x, p.y),
          width: p.size,
          height: p.size,
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant ArcadeParticlesPainter oldDelegate) => true;
}
