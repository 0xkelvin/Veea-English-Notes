import 'package:flutter/material.dart';

/// Data class tracking one falling Vietnamese meaning badge in game space.
class ArcadeFallingBadgeData {
  ArcadeFallingBadgeData({
    required this.id,
    required this.meaning,
    required this.x,
    required this.y,
    this.vy = 40.0,
    this.opacity = 1.0,
  });

  final String id;
  final String meaning;
  double x;
  double y;
  double vy;
  double opacity;

  /// Updates physics: gravity acceleration and fade out. Returns false when expired.
  bool update(double dt) {
    y += vy * dt;
    vy += 90.0 * dt; // gravity
    opacity -= 0.6 * dt; // fade out
    return opacity > 0;
  }
}

/// Overlay painter or widget rendering falling meaning badges.
class ArcadeFallingBadgesOverlay extends StatelessWidget {
  const ArcadeFallingBadgesOverlay({
    super.key,
    required this.badges,
  });

  final List<ArcadeFallingBadgeData> badges;

  @override
  Widget build(BuildContext context) {
    if (badges.isEmpty) return const SizedBox.shrink();

    return IgnorePointer(
      child: Stack(
        children: [
          for (final badge in badges)
            Positioned(
              left: badge.x - 80,
              top: badge.y,
              child: Opacity(
                opacity: badge.opacity.clamp(0.0, 1.0),
                child: Container(
                  width: 160,
                  alignment: Alignment.center,
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: const Color(0xFFCBE32B).withValues(alpha: 0.92),
                    border: Border.all(color: Colors.black, width: 1.5),
                  ),
                  child: Text(
                    badge.meaning,
                    style: const TextStyle(
                      fontFamily: 'Handjet',
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF1C1E17),
                    ),
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
