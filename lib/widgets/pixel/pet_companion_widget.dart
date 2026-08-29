import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/pixel_metrics.dart';
import '../../core/theme/pixel_palette.dart';
import '../../models/pet_companion.dart';
import '../../providers/pet_provider.dart';
import '../../providers/vocabulary_provider.dart';
import '../../services/tts_service.dart';
import 'pixel_box.dart';
import 'pixel_button.dart';
import 'pixel_icon.dart';

/// 8-Bit Virtual Pet Companion ("Veea-chi") Homepage Card & Interactive Widget.
class PetCompanionWidget extends StatefulWidget {
  const PetCompanionWidget({super.key});

  @override
  State<PetCompanionWidget> createState() => _PetCompanionWidgetState();
}

class _PetCompanionWidgetState extends State<PetCompanionWidget> {
  void _openPetModal(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (ctx) => const _PetStatusDialog(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final petProvider = context.watch<PetProvider>();
    final vocabProvider = context.watch<VocabularyProvider>();
    final palette = context.palette;
    final pet = petProvider.pet;
    final mood = pet.calculateMood(
      streakDays: vocabProvider.stats.streakDays,
      dueCount: vocabProvider.dueReviewCount,
    );

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: PixelMetrics.space4,
        vertical: PixelMetrics.space1,
      ),
      child: GestureDetector(
        onTap: () => _openPetModal(context),
        child: PixelBox(
          raised: true,
          color: palette.surface,
          padding: const EdgeInsets.all(PixelMetrics.space3),
          child: Row(
            children: [
              // Pet Sprite
              Container(
                width: 48,
                height: 48,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: palette.paper,
                  border: Border.all(
                    color: palette.border,
                    width: PixelMetrics.border,
                  ),
                ),
                child: CustomPaint(
                  size: const Size(36, 36),
                  painter: _PetSpritePainter(
                    stage: pet.stage,
                    mood: mood,
                    color: palette.accent,
                  ),
                ),
              ),

              const SizedBox(width: PixelMetrics.space3),

              // Pet Info & Speech Bubble
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          '${pet.name} (LV. ${pet.level})',
                          style: TextStyle(
                            fontFamily: 'Handjet',
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            color: palette.ink,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 4, vertical: 1),
                          decoration: BoxDecoration(
                            color: palette.paper,
                            border: Border.all(color: palette.border, width: 1),
                          ),
                          child: Text(
                            pet.stage.displayName,
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
                          '🍖 ${pet.wordsFedToday} FED',
                          style: TextStyle(
                            fontFamily: 'Handjet',
                            fontSize: 11,
                            color: palette.inkMuted,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      petProvider.currentSpeech,
                      style: TextStyle(
                        fontFamily: 'Handjet',
                        fontSize: 12,
                        color: palette.inkFaint,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),

                    // Level XP progress bar
                    ClipRRect(
                      borderRadius: BorderRadius.zero,
                      child: Container(
                        height: 4,
                        width: double.infinity,
                        color: palette.paper,
                        alignment: Alignment.centerLeft,
                        child: FractionallySizedBox(
                          widthFactor: (pet.currentLevelXp / 50.0).clamp(0.05, 1.0),
                          child: Container(color: palette.accent),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PetStatusDialog extends StatelessWidget {
  const _PetStatusDialog();

  void _feedWord(BuildContext context) {
    final vocab = context.read<VocabularyProvider>();
    final pet = context.read<PetProvider>();
    final tts = context.read<TtsService>();

    final words = vocab.words.isNotEmpty ? vocab.words : [];
    if (words.isNotEmpty) {
      final word = words.first;
      pet.feedWord(word.word);
      tts.speak(word.word);
    } else {
      pet.feedWord('resilient');
      tts.speak('resilient');
    }
  }

  void _showRenameDialog(BuildContext context) {
    final petProvider = context.read<PetProvider>();
    final textController =
        TextEditingController(text: petProvider.pet.name);

    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
        title: const Text('RENAME PET',
            style: TextStyle(fontFamily: 'Handjet', fontWeight: FontWeight.bold)),
        content: TextField(
          controller: textController,
          maxLength: 12,
          decoration: const InputDecoration(hintText: 'ENTER PET NAME'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('CANCEL'),
          ),
          TextButton(
            onPressed: () {
              petProvider.rename(textController.text);
              Navigator.of(ctx).pop();
            },
            child: const Text('SAVE'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final petProvider = context.watch<PetProvider>();
    final pet = petProvider.pet;

    return Dialog(
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
      backgroundColor: palette.surface,
      child: Padding(
        padding: const EdgeInsets.all(PixelMetrics.space4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(
              children: [
                PixelIcon(PixelGlyph.pet, color: palette.accent, scale: 2),
                const SizedBox(width: 8),
                Text(
                  '${pet.name} STATUS',
                  style: const TextStyle(
                    fontFamily: 'Handjet',
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close, size: 20),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),

            const SizedBox(height: PixelMetrics.space3),

            // Pet Evolution Showcase
            Container(
              padding: const EdgeInsets.all(PixelMetrics.space3),
              decoration: BoxDecoration(
                color: palette.paper,
                border: Border.all(color: palette.border, width: 1),
              ),
              child: Row(
                children: [
                  Container(
                    width: 54,
                    height: 54,
                    decoration: BoxDecoration(
                      color: palette.surface,
                      border: Border.all(color: palette.border, width: 1),
                    ),
                    child: CustomPaint(
                      size: const Size(40, 40),
                      painter: _PetSpritePainter(
                        stage: pet.stage,
                        mood: PetMood.happy,
                        color: palette.accent,
                      ),
                    ),
                  ),
                  const SizedBox(width: PixelMetrics.space3),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'STAGE ${pet.stage.stageNumber}: ${pet.stage.displayName}',
                          style: TextStyle(
                            fontFamily: 'Handjet',
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: palette.accent,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'LEVEL ${pet.level} • TOTAL XP: ${pet.xp}',
                          style: const TextStyle(
                            fontFamily: 'Handjet',
                            fontSize: 12,
                          ),
                        ),
                        Text(
                          'XP to next level: ${50 - pet.currentLevelXp} XP',
                          style: TextStyle(
                            fontFamily: 'Handjet',
                            fontSize: 11,
                            color: palette.inkFaint,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: PixelMetrics.space3),

            // Action Buttons
            SizedBox(
              width: double.infinity,
              child: PixelButton(
                label: '🍖 Feed Due Vocabulary (+15 XP)',
                filled: true,
                onPressed: () => _feedWord(context),
              ),
            ),
            const SizedBox(height: PixelMetrics.space2),
            SizedBox(
              width: double.infinity,
              child: PixelButton(
                label: '❤️ Pet & Love (+2 XP)',
                filled: false,
                onPressed: petProvider.petTouch,
              ),
            ),
            const SizedBox(height: PixelMetrics.space2),
            SizedBox(
              width: double.infinity,
              child: PixelButton(
                label: '✏️ Rename Pet',
                filled: false,
                onPressed: () => _showRenameDialog(context),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PetSpritePainter extends CustomPainter {
  const _PetSpritePainter({
    required this.stage,
    required this.mood,
    required this.color,
  });

  final PetStage stage;
  final PetMood mood;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    final eyePaint = Paint()
      ..color = Colors.black
      ..style = PaintingStyle.fill;

    final scale = size.width / 12.0;

    switch (stage) {
      case PetStage.egg:
        // Sprout Egg Sprite
        _drawPixel(canvas, 4, 3, 4, 6, paint, scale);
        _drawPixel(canvas, 3, 5, 6, 4, paint, scale);
        // Leaf sprout
        _drawPixel(canvas, 5, 1, 2, 2, paint, scale);
        _drawPixel(canvas, 7, 0, 2, 1, paint, scale);
        // Eyes
        _drawPixel(canvas, 4, 5, 1, 1, eyePaint, scale);
        _drawPixel(canvas, 7, 5, 1, 1, eyePaint, scale);
        break;

      case PetStage.hatchling:
        // Cute Bit Hatchling Blob
        _drawPixel(canvas, 3, 4, 6, 6, paint, scale);
        _drawPixel(canvas, 2, 6, 8, 4, paint, scale);
        // Ears / Horns
        _drawPixel(canvas, 2, 2, 2, 2, paint, scale);
        _drawPixel(canvas, 8, 2, 2, 2, paint, scale);
        // Eyes
        _drawPixel(canvas, 4, 5, 1, 2, eyePaint, scale);
        _drawPixel(canvas, 7, 5, 1, 2, eyePaint, scale);
        break;

      case PetStage.cyberPup:
        // Cyber Pup / Dino
        _drawPixel(canvas, 3, 2, 6, 5, paint, scale);
        _drawPixel(canvas, 4, 7, 5, 4, paint, scale);
        // Ears & Tail
        _drawPixel(canvas, 2, 1, 2, 2, paint, scale);
        _drawPixel(canvas, 8, 1, 2, 2, paint, scale);
        _drawPixel(canvas, 9, 8, 2, 1, paint, scale);
        // Feet
        _drawPixel(canvas, 4, 11, 2, 1, paint, scale);
        _drawPixel(canvas, 7, 11, 2, 1, paint, scale);
        // Eyes
        _drawPixel(canvas, 4, 4, 1, 2, eyePaint, scale);
        _drawPixel(canvas, 7, 4, 1, 2, eyePaint, scale);
        break;

      case PetStage.mechaDragon:
        // Mecha Dragon
        _drawPixel(canvas, 3, 3, 6, 6, paint, scale);
        _drawPixel(canvas, 1, 2, 2, 3, paint, scale); // left horn
        _drawPixel(canvas, 9, 2, 2, 3, paint, scale); // right horn
        _drawPixel(canvas, 0, 5, 2, 3, paint, scale); // left wing
        _drawPixel(canvas, 10, 5, 2, 3, paint, scale); // right wing
        _drawPixel(canvas, 3, 9, 6, 2, paint, scale);
        // Eyes
        _drawPixel(canvas, 4, 5, 1, 2, eyePaint, scale);
        _drawPixel(canvas, 7, 5, 1, 2, eyePaint, scale);
        break;
    }
  }

  void _drawPixel(
    Canvas canvas,
    double x,
    double y,
    double w,
    double h,
    Paint paint,
    double scale,
  ) {
    canvas.drawRect(
      Rect.fromLTWH(x * scale, y * scale, w * scale, h * scale),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _PetSpritePainter oldDelegate) =>
      oldDelegate.stage != stage ||
      oldDelegate.mood != mood ||
      oldDelegate.color != color;
}
