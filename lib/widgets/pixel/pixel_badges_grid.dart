import 'package:flutter/material.dart';

import '../../core/theme/pixel_metrics.dart';
import '../../core/theme/pixel_palette.dart';
import '../../models/gamification_badge.dart';
import 'pixel_box.dart';
import 'pixel_button.dart';
import 'pixel_icon.dart';

enum _BadgeFilter { all, unlocked, locked }

/// 8-bit Retro Milestone Badges expandable dropdown list.
///
/// Designed to save vertical space with a compact collapsed bar that expands
/// on tap to reveal all badge progress, categories, and criteria.
class PixelBadgesGrid extends StatefulWidget {
  const PixelBadgesGrid({super.key, required this.badges});

  final List<GamificationBadge> badges;

  @override
  State<PixelBadgesGrid> createState() => _PixelBadgesGridState();
}

class _PixelBadgesGridState extends State<PixelBadgesGrid> {
  bool _isExpanded = false;
  _BadgeFilter _currentFilter = _BadgeFilter.all;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final theme = Theme.of(context);
    final badges = widget.badges;
    final unlockedCount = badges.where((b) => b.isUnlocked).length;

    final filteredBadges = badges.where((b) {
      if (_currentFilter == _BadgeFilter.unlocked) return b.isUnlocked;
      if (_currentFilter == _BadgeFilter.locked) return !b.isUnlocked;
      return true;
    }).toList();

    return PixelBox(
      raised: true,
      color: palette.surface,
      padding: const EdgeInsets.all(PixelMetrics.space3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header / Dropdown Trigger
          GestureDetector(
            onTap: () {
              setState(() {
                _isExpanded = !_isExpanded;
              });
            },
            behavior: HitTestBehavior.opaque,
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: palette.accent,
                    border: Border.all(color: palette.border, width: 1),
                  ),
                  child: PixelIcon(
                    PixelGlyph.target,
                    color: palette.onAccent,
                    scale: 1.5,
                  ),
                ),
                const SizedBox(width: PixelMetrics.space2),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'RETRO MILESTONES & BADGES',
                        style: theme.textTheme.labelSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.5,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _isExpanded
                            ? 'Tap header to collapse list'
                            : 'Tap to view achievement progression',
                        style: TextStyle(
                          fontFamily: 'Handjet',
                          fontSize: 11,
                          color: palette.inkMuted,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: palette.paper,
                    border: Border.all(color: palette.border, width: 1),
                  ),
                  child: Text(
                    '★ $unlockedCount / ${badges.length}',
                    style: TextStyle(
                      fontFamily: 'Handjet',
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: palette.accent,
                    ),
                  ),
                ),
                const SizedBox(width: PixelMetrics.space2),
                Text(
                  _isExpanded ? '▲' : '▼',
                  style: TextStyle(
                    fontFamily: 'Handjet',
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: palette.ink,
                  ),
                ),
              ],
            ),
          ),

          // Mini Unlocked Badges Preview when collapsed
          if (!_isExpanded && unlockedCount > 0) ...[
            const SizedBox(height: PixelMetrics.space2),
            Row(
              children: [
                for (final b in badges.where((b) => b.isUnlocked).take(6)) ...[
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Container(
                      padding: const EdgeInsets.all(2),
                      decoration: BoxDecoration(
                        color: palette.accent,
                        border: Border.all(color: palette.border, width: 1),
                      ),
                      child: PixelIcon(
                        b.iconGlyph,
                        color: palette.onAccent,
                        scale: 1.2,
                      ),
                    ),
                  ),
                ],
                if (unlockedCount > 6) ...[
                  Text(
                    '+${unlockedCount - 6} more',
                    style: TextStyle(
                      fontFamily: 'Handjet',
                      fontSize: 10,
                      color: palette.inkFaint,
                    ),
                  ),
                ],
              ],
            ),
          ],

          // Expanded Dropdown List
          if (_isExpanded) ...[
            const SizedBox(height: PixelMetrics.space3),
            const Divider(height: 1, thickness: 1),
            const SizedBox(height: PixelMetrics.space3),

            // Filter Tabs
            Row(
              children: [
                _filterChip('ALL (${badges.length})', _BadgeFilter.all, palette),
                const SizedBox(width: 4),
                _filterChip('UNLOCKED ($unlockedCount)', _BadgeFilter.unlocked, palette),
                const SizedBox(width: 4),
                _filterChip('LOCKED (${badges.length - unlockedCount})', _BadgeFilter.locked, palette),
              ],
            ),

            const SizedBox(height: PixelMetrics.space3),

            // Badges Grid List
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: filteredBadges.length,
              separatorBuilder: (_, _) =>
                  const SizedBox(height: PixelMetrics.space2),
              itemBuilder: (context, index) {
                final badge = filteredBadges[index];
                return _BadgeRowTile(badge: badge);
              },
            ),
          ],
        ],
      ),
    );
  }

  Widget _filterChip(String label, _BadgeFilter filter, PixelPalette palette) {
    final active = _currentFilter == filter;
    return GestureDetector(
      onTap: () => setState(() => _currentFilter = filter),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        decoration: BoxDecoration(
          color: active ? palette.accent : palette.paper,
          border: Border.all(color: palette.border, width: 1),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontFamily: 'Handjet',
            fontSize: 10,
            fontWeight: FontWeight.bold,
            color: active ? palette.onAccent : palette.ink,
          ),
        ),
      ),
    );
  }
}

class _BadgeRowTile extends StatelessWidget {
  const _BadgeRowTile({required this.badge});

  final GamificationBadge badge;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final theme = Theme.of(context);
    final isUnlocked = badge.isUnlocked;

    return GestureDetector(
      onTap: () => _showBadgeDetails(context, badge),
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.all(PixelMetrics.space2),
        decoration: BoxDecoration(
          color: isUnlocked ? palette.paper : palette.surface,
          border: Border.all(
            color: isUnlocked
                ? palette.border
                : palette.border.withValues(alpha: 0.35),
            width: 1,
          ),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: isUnlocked ? palette.accent : palette.paper,
                border: Border.all(
                  color: isUnlocked ? palette.border : palette.inkFaint,
                  width: 1,
                ),
              ),
              child: PixelIcon(
                badge.iconGlyph,
                color: isUnlocked ? palette.onAccent : palette.inkFaint,
                scale: 1.8,
              ),
            ),
            const SizedBox(width: PixelMetrics.space3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        badge.title,
                        style: theme.textTheme.labelSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                          color: isUnlocked ? palette.ink : palette.inkFaint,
                        ),
                      ),
                      const Spacer(),
                      if (isUnlocked)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 4, vertical: 1),
                          decoration: BoxDecoration(
                            color: palette.accent,
                            border: Border.all(color: palette.border, width: 1),
                          ),
                          child: Text(
                            'UNLOCKED ★',
                            style: TextStyle(
                              fontFamily: 'Handjet',
                              fontSize: 9,
                              fontWeight: FontWeight.bold,
                              color: palette.onAccent,
                            ),
                          ),
                        )
                      else
                        Text(
                          '${badge.currentValue}/${badge.target} (${badge.percentage}%)',
                          style: TextStyle(
                            fontFamily: 'Handjet',
                            fontSize: 10,
                            color: palette.inkFaint,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    badge.description,
                    style: TextStyle(
                      fontFamily: 'Handjet',
                      fontSize: 11,
                      color: palette.inkMuted,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (!isUnlocked) ...[
                    const SizedBox(height: 4),
                    ClipRect(
                      child: Container(
                        height: 4,
                        decoration: BoxDecoration(
                          color: palette.paper,
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
                  ],
                ],
              ),
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
                    border: Border.all(
                        color: palette.border, width: PixelMetrics.border),
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
                border: Border.all(
                    color: palette.border, width: PixelMetrics.border),
              ),
              child: Row(
                children: [
                  Text(
                    badge.isUnlocked
                        ? 'STATUS: UNLOCKED ★'
                        : 'STATUS: IN PROGRESS',
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
