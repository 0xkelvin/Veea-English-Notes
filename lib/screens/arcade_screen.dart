import 'package:flutter/material.dart';

import '../arcade_sdk/arcade_sdk.dart';
import '../core/theme/pixel_metrics.dart';
import '../core/theme/pixel_palette.dart';
import '../widgets/pixel/pixel_box.dart';
import '../widgets/pixel/pixel_button.dart';
import '../widgets/pixel/pixel_icon.dart';
import 'cartridge_library_screen.dart';
import 'pixel_link_screen.dart';

/// 8-Bit Retro Arcade Center for Vocabulary Practice & Mini-Games.
///
/// Fully powered by the Veea Arcade SDK and [ArcadeRegistry].
class ArcadeScreen extends StatelessWidget {
  const ArcadeScreen({super.key});

  void _launchGame(BuildContext context, ArcadeGameManifest manifest) {
    final gameContext = DefaultArcadeContext(context);
    final gameWidget = manifest.builder(gameContext);

    Navigator.of(context).push(
      PageRouteBuilder<void>(
        pageBuilder: (_, _, _) => gameWidget,
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    ArcadeDefaults.registerDefaults();
    final games = ArcadeRegistry.allGames;
    final palette = context.palette;
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: palette.paper,
      body: SafeArea(
        child: Column(
          children: [
            // Top Bar
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: PixelMetrics.space4,
                vertical: PixelMetrics.space2,
              ),
              decoration: BoxDecoration(
                color: palette.surface,
                border: Border(
                  bottom: BorderSide(
                    color: palette.border,
                    width: PixelMetrics.border,
                  ),
                ),
              ),
              child: Row(
                children: [
                  PixelIconButton(
                    glyph: PixelGlyph.arrowLeft,
                    semanticLabel: 'Back to journal',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  const SizedBox(width: PixelMetrics.space2),
                  Text(
                    'ARCADE CENTER',
                    style: theme.textTheme.titleMedium,
                  ),
                  const Spacer(),
                  GestureDetector(
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const CartridgeLibraryScreen(),
                        ),
                      );
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: palette.surface,
                        border: Border.all(
                          color: palette.border,
                          width: PixelMetrics.border,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          PixelIcon(PixelGlyph.gamepad,
                              color: palette.accent, scale: 1.2),
                          const SizedBox(width: 3),
                          Text(
                            'CARTRIDGES',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: palette.ink,
                              fontWeight: FontWeight.bold,
                              fontSize: 10,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: palette.accent,
                      border: Border.all(
                        color: palette.border,
                        width: PixelMetrics.border,
                      ),
                    ),
                    child: Text(
                      '${games.length} GAMES',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: palette.onAccent,
                        fontWeight: FontWeight.bold,
                        fontSize: 10,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // 2P Game Link Duels Banner
            Padding(
              padding: const EdgeInsets.fromLTRB(
                PixelMetrics.space4,
                PixelMetrics.space3,
                PixelMetrics.space4,
                0,
              ),
              child: _PixelLinkDuelBanner(
                onTap: () {
                  Navigator.of(context).push(
                    PageRouteBuilder<void>(
                      pageBuilder: (_, _, _) => const PixelLinkScreen(),
                      transitionDuration: Duration.zero,
                      reverseTransitionDuration: Duration.zero,
                    ),
                  );
                },
              ),
            ),

            // Game Cards List
            Expanded(
              child: ListView.separated(
                padding: const EdgeInsets.all(PixelMetrics.space4),
                itemCount: games.length,
                separatorBuilder: (_, _) =>
                    const SizedBox(height: PixelMetrics.space4),
                itemBuilder: (context, index) {
                  final game = games[index];
                  return _GameCabinetCard(
                    manifest: game,
                    onPlay: () => _launchGame(context, game),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PixelLinkDuelBanner extends StatelessWidget {
  const _PixelLinkDuelBanner({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    return Container(
      decoration: BoxDecoration(
        color: palette.surface,
        border: Border.all(color: palette.border, width: PixelMetrics.border),
        boxShadow: [
          BoxShadow(
            color: palette.border.withValues(alpha: 0.4),
            offset: const Offset(3, 3),
            blurRadius: 0,
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(PixelMetrics.space3),
            child: Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  color: palette.accent.withValues(alpha: 0.15),
                  alignment: Alignment.center,
                  child: PixelIcon(PixelGlyph.link, color: palette.accent, scale: 2.2),
                ),
                const SizedBox(width: PixelMetrics.space3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                            color: palette.accent,
                            child: Text(
                              '2P VERSUS',
                              style: TextStyle(
                                fontFamily: 'Handjet',
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                color: palette.onAccent,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            'PIXEL LINK DUELS',
                            style: TextStyle(
                              fontFamily: 'Handjet',
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                              color: palette.ink,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Bắn từ thách đấu pop-up với bạn bè',
                        style: TextStyle(
                          fontFamily: 'Handjet',
                          fontSize: 12,
                          color: palette.inkMuted,
                        ),
                      ),
                    ],
                  ),
                ),
                PixelButton(
                  label: 'ĐẤU ⚡',
                  onPressed: onTap,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _GameCabinetCard extends StatelessWidget {
  const _GameCabinetCard({
    required this.manifest,
    required this.onPlay,
  });

  final ArcadeGameManifest manifest;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final theme = Theme.of(context);
    final isCommunity = manifest.category == ArcadeGameCategory.community;

    return PixelBox(
      raised: true,
      padding: const EdgeInsets.all(PixelMetrics.space4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(PixelMetrics.space2),
                decoration: BoxDecoration(
                  color: isCommunity ? palette.paper : palette.accent,
                  border: Border.all(
                    color: palette.border,
                    width: PixelMetrics.border,
                  ),
                ),
                child: PixelIcon(
                  manifest.glyph,
                  color: isCommunity ? palette.accent : palette.onAccent,
                  scale: 2.5,
                ),
              ),
              const SizedBox(width: PixelMetrics.space3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            manifest.title,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.bold,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),
                        if (manifest.badge.isNotEmpty) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 4,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: isCommunity
                                  ? const Color(0xFFCBE32B)
                                  : palette.paper,
                              border: Border.all(
                                color: palette.border,
                                width: 1,
                              ),
                            ),
                            child: Text(
                              manifest.badge,
                              style: TextStyle(
                                fontSize: 8,
                                fontWeight: FontWeight.bold,
                                color: isCommunity
                                    ? const Color(0xFF1C1E17)
                                    : palette.inkMuted,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'by ${manifest.author} • v${manifest.version}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: palette.inkFaint,
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: PixelMetrics.space3),
          Text(
            manifest.tagline,
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: PixelMetrics.space3),
          PixelButton(
            label: 'Play Game',
            glyph: PixelGlyph.gamepad,
            filled: true,
            expand: true,
            onPressed: onPlay,
          ),
        ],
      ),
    );
  }
}
