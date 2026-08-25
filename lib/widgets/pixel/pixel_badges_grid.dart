import 'package:flutter/material.dart';

import '../../core/theme/pixel_metrics.dart';
import '../../core/theme/pixel_palette.dart';
import '../../models/gamification_badge.dart';
import 'pixel_box.dart';
import 'pixel_button.dart';
import 'pixel_icon.dart';

/// 8-bit Retro Milestone Badges Grid with unlock progression.
class PixelBadgesGrid extends StatelessWidget {
  const PixelBadgesGrid({super.key, required this.badges});

  final List<GamificationBadge> badges;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final theme = Theme.of(context);
    final unlockedCount = badges.where((b) => b.isUnlocked).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              'RETRO MILESTONES & BADGES',
              style: theme.textTheme.labelSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const Spacer(),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: palette.accent,
                border: Border.all(color: palette.border, width: PixelMetrics.border),
              ),
              child: Text(
                '★ $unlockedCount / ${badges.length}',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: palette.onAccent,
                  fontWeight: FontWeight.bold,
                  fontSize: 10,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: PixelMetrics.space3),

        // Grid of badges (2 columns)
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            crossAxisSpacing: PixelMetrics.space2,
            mainAxisSpacing: PixelMetrics.space2,
            childAspectRatio: 1.6,
          ),
          itemCount: badges.length,
          itemBuilder: (context, index) {
            final badge = badges[index];
            return _BadgeTile(badge: badge);
          },
        ),
      ],
    );
  }
}

class _BadgeTile extends StatelessWidget {
  const _BadgeTile({required this.badge});

  final GamificationBadge badge;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final theme = Theme.of(context);
    final isUnlocked = badge.isUnlocked;

    return GestureDetector(
      onTap: () => _showBadgeDetails(context, badge),
      behavior: HitTestBehavior.opaque,
      child: PixelBox(
        color: isUnlocked ? palette.surface : palette.paper,
        borderColor: isUnlocked
            ? palette.border
            : palette.border.withValues(alpha: 0.35),
        padding: const EdgeInsets.all(PixelMetrics.space2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    color: isUnlocked ? palette.accent : palette.surface,
                    border: Border.all(
                      color: isUnlocked ? palette.border : palette.inkFaint,
                      width: 1,
                    ),
                  ),
                  child: PixelIcon(
                    badge.iconGlyph,
                    color: isUnlocked ? palette.onAccent : palette.inkFaint,
                    scale: 1.5,
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    badge.title,
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      fontSize: 11,
                      color: isUnlocked ? palette.ink : palette.inkFaint,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),

            // Progress or Unlocked Banner
            if (isUnlocked)
              Row(
                children: [
                  Text(
                    '★ UNLOCKED',
                    style: TextStyle(
                      fontFamily: 'Handjet',
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: palette.accent,
                    ),
                  ),
                ],
              )
            else
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Progress Bar
                  Row(
                    children: [
                      Expanded(
                        child: ClipRect(
                          child: Container(
                            height: 6,
                            decoration: BoxDecoration(
                              color: palette.surface,
                              border: Border.all(
                                color: palette.border.withValues(alpha: 0.3),
                                width: 1,
                              ),
                            ),
                            child: FractionallySizedBox(
                              alignment: Alignment.centerLeft,
                              widthFactor: badge.progress,
                              child: Container(color: palette.accent),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '${badge.percentage}%',
                        style: TextStyle(
                          fontFamily: 'Handjet',
                          fontSize: 9,
                          color: palette.inkFaint,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 1),
                  Text(
                    '${badge.currentValue}/${badge.target}',
                    style: TextStyle(
                      fontFamily: 'Handjet',
                      fontSize: 9,
                      color: palette.inkFaint,
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  void _showBadgeDetails(BuildContext context, GamificationBadge badge) {
    final palette = context.palette;
    final theme = Theme.of(context);

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => Container(
        decoration: BoxDecoration(
          color: palette.paper,
          border: Border(
            top: BorderSide(color: palette.border, width: PixelMetrics.border),
          ),
        ),
        padding: const EdgeInsets.all(PixelMetrics.space4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: badge.isUnlocked ? palette.accent : palette.surface,
                    border: Border.all(color: palette.border, width: PixelMetrics.border),
                  ),
                  child: PixelIcon(
                    badge.iconGlyph,
                    color: badge.isUnlocked ? palette.onAccent : palette.inkFaint,
                    scale: 2,
                  ),
                ),
                const SizedBox(width: PixelMetrics.space3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        badge.title,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        badge.category,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: palette.inkMuted,
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ),
                ),
                PixelIconButton(
                  glyph: PixelGlyph.close,
                  semanticLabel: 'Close',
                  onPressed: () => Navigator.of(sheetContext).pop(),
                ),
              ],
            ),
            const SizedBox(height: PixelMetrics.space4),
            Text(
              badge.description,
              style: theme.textTheme.bodyLarge,
            ),
            const SizedBox(height: PixelMetrics.space4),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(PixelMetrics.space3),
              decoration: BoxDecoration(
                color: palette.surface,
                border: Border.all(color: palette.border, width: PixelMetrics.border),
              ),
              child: Row(
                children: [
                  Text(
                    badge.isUnlocked ? 'STATUS: UNLOCKED ★' : 'STATUS: IN PROGRESS',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: badge.isUnlocked ? palette.accent : palette.inkMuted,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '${badge.currentValue} / ${badge.target} (${badge.percentage}%)',
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: PixelMetrics.space4),
            PixelButton(
              label: 'Close',
              expand: true,
              onPressed: () => Navigator.of(sheetContext).pop(),
            ),
          ],
        ),
      ),
    );
  }
}
