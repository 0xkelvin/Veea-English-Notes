import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/theme/pixel_metrics.dart';
import '../core/theme/pixel_palette.dart';
import '../data/cartridges_data.dart';
import '../models/cartridge.dart';
import '../providers/cartridge_provider.dart';
import '../providers/vocabulary_provider.dart';
import '../services/tts_service.dart';
import '../widgets/pixel/pixel_box.dart';
import '../widgets/pixel/pixel_button.dart';
import '../widgets/pixel/pixel_icon.dart';

/// 8-Bit Retro Career Cartridge Library & Expansion Store.
class CartridgeLibraryScreen extends StatefulWidget {
  const CartridgeLibraryScreen({super.key});

  @override
  State<CartridgeLibraryScreen> createState() => _CartridgeLibraryScreenState();
}

class _CartridgeLibraryScreenState extends State<CartridgeLibraryScreen> {
  String _selectedModule = 'All';
  CartridgeWord? _expandedWord;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final theme = Theme.of(context);
    final cartridge = CartridgesData.siliconValleyTech;
    final cartridgeProvider = context.watch<CartridgeProvider>();
    final isInstalled = cartridgeProvider.isInstalled(cartridge.id);

    final filteredWords = _selectedModule == 'All'
        ? cartridge.words
        : cartridge.words.where((w) => w.module == _selectedModule).toList();

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
                  PixelIcon(PixelGlyph.gamepad, color: palette.accent, scale: 2),
                  const SizedBox(width: PixelMetrics.space2),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'CARTRIDGE LIBRARY',
                          style: theme.textTheme.titleMedium,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          'CAREER & INDUSTRY VOCABULARY',
                          style: TextStyle(
                            fontFamily: 'Handjet',
                            fontSize: 10,
                            color: palette.inkMuted,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: PixelMetrics.space2),
                  PixelIconButton(
                    glyph: PixelGlyph.close,
                    semanticLabel: 'Close Library',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),

            // Scrollable Content
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(PixelMetrics.space4),
                children: [
                  // Cartridge Hero Banner
                  _buildCartridgeHero(cartridge, isInstalled, palette, theme),

                  const SizedBox(height: PixelMetrics.space4),

                  // Module Filter Pills
                  Text(
                    'EXPLORE MODULES (${filteredWords.length} WORDS)',
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: PixelMetrics.space2),

                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        _moduleChip('All', palette),
                        const SizedBox(width: 4),
                        ...cartridge.modules.map((m) {
                          return Padding(
                            padding: const EdgeInsets.only(right: 4),
                            child: _moduleChip(m, palette),
                          );
                        }),
                      ],
                    ),
                  ),

                  const SizedBox(height: PixelMetrics.space4),

                  // Word Cards List
                  for (final word in filteredWords) ...[
                    _buildWordCard(word, palette, theme),
                    const SizedBox(height: PixelMetrics.space3),
                  ],
                ],
              ),
            ),

            // Bottom Sticky Install / Status Bar
            Container(
              padding: const EdgeInsets.all(PixelMetrics.space4),
              decoration: BoxDecoration(
                color: palette.surface,
                border: Border(
                  top: BorderSide(
                    color: palette.border,
                    width: PixelMetrics.border,
                  ),
                ),
              ),
              child: Row(
                children: [
                  if (isInstalled) ...[
                    Expanded(
                      child: PixelButton(
                        label: 'Cartridge Active in Notebook ★',
                        glyph: PixelGlyph.check,
                        filled: true,
                        onPressed: null,
                      ),
                    ),
                    const SizedBox(width: PixelMetrics.space2),
                    PixelButton(
                      label: 'Remove',
                      danger: true,
                      onPressed: () => _confirmUninstall(context, cartridge.id),
                    ),
                  ] else ...[
                    Expanded(
                      child: PixelButton(
                        label: 'Insert Cartridge into Notebook',
                        glyph: PixelGlyph.plus,
                        filled: true,
                        expand: true,
                        onPressed: () => _showInstallModal(context, cartridge),
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

  Widget _buildCartridgeHero(
    Cartridge cartridge,
    bool isInstalled,
    PixelPalette palette,
    ThemeData theme,
  ) {
    return PixelBox(
      raised: true,
      color: palette.surface,
      padding: const EdgeInsets.all(PixelMetrics.space4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Retro 8-bit Cartridge Plastic Notch
              Container(
                width: 44,
                height: 52,
                decoration: BoxDecoration(
                  color: palette.accent,
                  border: Border.all(color: palette.border, width: 2),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    PixelIcon(PixelGlyph.gamepad, color: palette.onAccent, scale: 2),
                    const SizedBox(height: 2),
                    Text(
                      'VOL.1',
                      style: TextStyle(
                        fontFamily: 'Handjet',
                        fontSize: 8,
                        fontWeight: FontWeight.bold,
                        color: palette.onAccent,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: PixelMetrics.space3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 4, vertical: 1),
                          decoration: BoxDecoration(
                            color: palette.paper,
                            border: Border.all(color: palette.border, width: 1),
                          ),
                          child: Text(
                            cartridge.badgeLabel,
                            style: TextStyle(
                              fontFamily: 'Handjet',
                              fontSize: 9,
                              fontWeight: FontWeight.bold,
                              color: palette.accent,
                            ),
                          ),
                        ),
                        const Spacer(),
                        Text(
                          isInstalled ? 'INSTALLED ★' : cartridge.priceLabel,
                          style: TextStyle(
                            fontFamily: 'Handjet',
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: isInstalled ? palette.accent : palette.ink,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      cartridge.title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      cartridge.subtitle,
                      style: TextStyle(
                        fontFamily: 'Handjet',
                        fontSize: 11,
                        color: palette.inkMuted,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: PixelMetrics.space3),
          Text(
            cartridge.description,
            style: theme.textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }

  Widget _moduleChip(String label, PixelPalette palette) {
    final active = _selectedModule == label;
    return GestureDetector(
      onTap: () => setState(() => _selectedModule = label),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: active ? palette.accent : palette.surface,
          border: Border.all(color: palette.border, width: 1),
        ),
        child: Text(
          label.toUpperCase(),
          style: TextStyle(
            fontFamily: 'Handjet',
            fontSize: 11,
            fontWeight: FontWeight.bold,
            color: active ? palette.onAccent : palette.ink,
          ),
        ),
      ),
    );
  }

  Widget _buildWordCard(
    CartridgeWord word,
    PixelPalette palette,
    ThemeData theme,
  ) {
    final isExpanded = _expandedWord?.id == word.id;
    final tts = context.read<TtsService>();

    return PixelBox(
      raised: true,
      color: palette.surface,
      padding: const EdgeInsets.all(PixelMetrics.space3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Word Header Row
          Row(
            children: [
              Text(
                word.word.toUpperCase(),
                style: TextStyle(
                  fontFamily: 'Handjet',
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: palette.accent,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                word.pronunciation,
                style: TextStyle(
                  fontFamily: 'Handjet',
                  fontSize: 13,
                  color: palette.inkMuted,
                ),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                  color: palette.paper,
                  border: Border.all(color: palette.border, width: 1),
                ),
                child: Text(
                  word.module.toUpperCase(),
                  style: TextStyle(
                    fontFamily: 'Handjet',
                    fontSize: 9,
                    fontWeight: FontWeight.bold,
                    color: palette.ink,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              PixelIconButton(
                glyph: PixelGlyph.headphones,
                semanticLabel: 'Speak ${word.word}',
                onPressed: () => tts.speak(word.word),
              ),
            ],
          ),

          const SizedBox(height: 4),

          // Vietnamese Translation
          Text(
            word.meaning,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),

          const SizedBox(height: PixelMetrics.space2),

          // PR Review Sentence
          Container(
            padding: const EdgeInsets.all(PixelMetrics.space2),
            decoration: BoxDecoration(
              color: palette.paper,
              border: Border.all(color: palette.border.withValues(alpha: 0.5)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '💻 PR REVIEW USAGE:',
                  style: TextStyle(
                    fontFamily: 'Handjet',
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: palette.accent,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '“${word.prExample}”',
                  style: theme.textTheme.bodyMedium,
                ),
              ],
            ),
          ),

          // Expand / Collapse Details (Standup, Collocations, Interview Strategy)
          if (isExpanded) ...[
            const SizedBox(height: PixelMetrics.space2),
            Container(
              padding: const EdgeInsets.all(PixelMetrics.space2),
              decoration: BoxDecoration(
                color: palette.paper,
                border: Border.all(color: palette.border.withValues(alpha: 0.5)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '🗣️ STANDUP PHRASING:',
                    style: TextStyle(
                      fontFamily: 'Handjet',
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: palette.accent,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '“${word.standupExample}”',
                    style: theme.textTheme.bodyMedium,
                  ),
                ],
              ),
            ),
            const SizedBox(height: PixelMetrics.space2),
            Text(
              '⚡ COLLOCATIONS: ${word.collocations.join(' • ')}',
              style: TextStyle(
                fontFamily: 'Handjet',
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: palette.ink,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              '💡 INTERVIEW STRATEGY: ${word.interviewNuance}',
              style: TextStyle(
                fontFamily: 'Handjet',
                fontSize: 11,
                color: palette.inkMuted,
              ),
            ),
          ],

          const SizedBox(height: PixelMetrics.space2),

          GestureDetector(
            onTap: () {
              setState(() {
                _expandedWord = isExpanded ? null : word;
              });
            },
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Text(
                  isExpanded ? '▲ LESS DETAILS' : '▼ STANDUP & INTERVIEW NUANCES',
                  style: TextStyle(
                    fontFamily: 'Handjet',
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: palette.accent,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _showInstallModal(BuildContext context, Cartridge cartridge) {
    final palette = context.palette;
    final theme = Theme.of(context);
    final vocabProvider = context.read<VocabularyProvider>();
    final cartridgeProvider = context.read<CartridgeProvider>();

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
                PixelIcon(PixelGlyph.gamepad, color: palette.accent, scale: 2),
                const SizedBox(width: PixelMetrics.space2),
                Text(
                  'INSERT CARTRIDGE',
                  style: theme.textTheme.titleMedium,
                ),
                const Spacer(),
                PixelIconButton(
                  glyph: PixelGlyph.close,
                  semanticLabel: 'Close',
                  onPressed: () => Navigator.of(sheetContext).pop(),
                ),
              ],
            ),
            const SizedBox(height: PixelMetrics.space3),
            Text(
              'Choose how you want to ingest the ${cartridge.words.length} technical vocabulary words into your notebook:',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: PixelMetrics.space4),
            PixelButton(
              label: '🚀 Instant Import (All ${cartridge.words.length} Words for Today)',
              filled: true,
              expand: true,
              onPressed: () async {
                Navigator.of(sheetContext).pop();
                final count = await cartridgeProvider.installCartridge(
                  cartridge.id,
                  vocabProvider: vocabProvider,
                  mode: IngestMode.full,
                );
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        'Successfully inserted $count words into your notebook!',
                        style: const TextStyle(fontFamily: 'Handjet'),
                      ),
                    ),
                  );
                }
              },
            ),
            const SizedBox(height: PixelMetrics.space3),
            PixelButton(
              label: '📅 Daily Sprint (5 Words/Day for 6 Days)',
              expand: true,
              onPressed: () async {
                Navigator.of(sheetContext).pop();
                final count = await cartridgeProvider.installCartridge(
                  cartridge.id,
                  vocabProvider: vocabProvider,
                  mode: IngestMode.dailySprint,
                );
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        'Scheduled $count words across your daily sprint calendar!',
                        style: const TextStyle(fontFamily: 'Handjet'),
                      ),
                    ),
                  );
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  void _confirmUninstall(BuildContext context, String cartridgeId) {
    final vocabProvider = context.read<VocabularyProvider>();
    final cartridgeProvider = context.read<CartridgeProvider>();

    showDialog<void>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: context.palette.paper,
        shape: const RoundedRectangleBorder(),
        title: const Text(
          'REMOVE CARTRIDGE WORDS?',
          style: TextStyle(fontFamily: 'Handjet', fontWeight: FontWeight.bold),
        ),
        content: const Text(
          'This will remove the cartridge words from your notebook. Any notes you edited by hand will remain untouched.',
          style: TextStyle(fontFamily: 'Handjet', fontSize: 13),
        ),
        actions: [
          PixelButton(
            label: 'Cancel',
            onPressed: () => Navigator.of(dialogCtx).pop(),
          ),
          PixelButton(
            label: 'Remove',
            danger: true,
            onPressed: () async {
              Navigator.of(dialogCtx).pop();
              final removed = await cartridgeProvider.uninstallCartridge(
                cartridgeId,
                vocabProvider: vocabProvider,
              );
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      'Removed $removed cartridge words.',
                      style: const TextStyle(fontFamily: 'Handjet'),
                    ),
                  ),
                );
              }
            },
          ),
        ],
      ),
    );
  }
}
