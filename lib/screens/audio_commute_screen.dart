import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/theme/pixel_metrics.dart';
import '../core/theme/pixel_palette.dart';
import '../providers/vocabulary_provider.dart';
import '../services/audio_commute_service.dart';
import '../services/pronunciation_service.dart';
import '../services/tts_service.dart';
import '../widgets/pixel/pixel_box.dart';
import '../widgets/pixel/pixel_button.dart';
import '../widgets/pixel/pixel_icon.dart';

/// 8-Bit Retro Walkman / Cassette Hands-Free Audio Player Screen.
class AudioCommuteScreen extends StatefulWidget {
  const AudioCommuteScreen({super.key});

  @override
  State<AudioCommuteScreen> createState() => _AudioCommuteScreenState();
}

class _AudioCommuteScreenState extends State<AudioCommuteScreen>
    with SingleTickerProviderStateMixin {
  late final AudioCommuteService _commuteService;
  late final AnimationController _tapeController;

  @override
  void initState() {
    super.initState();
    final tts = context.read<TtsService>();
    _commuteService = AudioCommuteService(ttsService: tts);

    _tapeController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    );

    _commuteService.addListener(_onServiceUpdate);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      final vocab = context.read<VocabularyProvider>();
      final words = vocab.words;
      if (words.isNotEmpty) {
        _commuteService.startPlayback(words);
      }
    });
  }

  void _onServiceUpdate() {
    if (!mounted) return;
    if (_commuteService.isPlaying) {
      if (!_tapeController.isAnimating) _tapeController.repeat();
    } else {
      if (_tapeController.isAnimating) _tapeController.stop();
    }
    setState(() {});
  }

  @override
  void dispose() {
    _commuteService.removeListener(_onServiceUpdate);
    _commuteService.stop();
    _commuteService.dispose();
    _tapeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final theme = Theme.of(context);
    final currentWord = _commuteService.currentWord;

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
                    semanticLabel: 'Back',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  const SizedBox(width: PixelMetrics.space2),
                  Text('COMMUTE PLAYER', style: theme.textTheme.titleMedium),
                  const Spacer(),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: palette.accent,
                      border: Border.all(
                        color: palette.border,
                        width: PixelMetrics.border,
                      ),
                    ),
                    child: Text(
                      '8-BIT WALKMAN',
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

            // Main Cassette & Word Display
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(PixelMetrics.space4),
                children: [
                  // Retro Cassette Deck Widget
                  _RetroCassetteWidget(
                    tapeAnimation: _tapeController,
                    isPlaying: _commuteService.isPlaying,
                    trackInfo: _commuteService.totalWords > 0
                        ? '${_commuteService.currentIndex + 1} / ${_commuteService.totalWords}'
                        : 'NO WORDS',
                  ),

                  const SizedBox(height: PixelMetrics.space4),

                  // Current Word Card
                  if (currentWord != null) ...[
                    _WordDisplayCard(
                      word: currentWord.word,
                      ipa: currentWord.pronunciation != null
                          ? PronunciationService.format(
                              currentWord.pronunciation!)
                          : '',
                      partOfSpeech: currentWord.partOfSpeech?.short ?? '',
                      meaning: currentWord.meaning,
                      example: currentWord.examples.isNotEmpty
                          ? currentWord.examples.first
                          : '',
                      phaseText: _commuteService.currentPhaseText,
                    ),
                  ] else ...[
                    const PixelBox(
                      raised: true,
                      padding: EdgeInsets.all(PixelMetrics.space6),
                      child: Center(
                        child: Text(
                          'NO VOCABULARY LOADED TODAY\nADD WORDS TO START COMMUTE PLAYLIST',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontFamily: 'Handjet', fontSize: 16),
                        ),
                      ),
                    ),
                  ],

                  const SizedBox(height: PixelMetrics.space4),

                  // Commute Playback Settings Section
                  _PlaybackSettingsSection(commuteService: _commuteService),
                ],
              ),
            ),

            // Bottom Transport Control Bar
            _TransportControlsBar(commuteService: _commuteService),
          ],
        ),
      ),
    );
  }
}

class _RetroCassetteWidget extends StatelessWidget {
  const _RetroCassetteWidget({
    required this.tapeAnimation,
    required this.isPlaying,
    required this.trackInfo,
  });

  final Animation<double> tapeAnimation;
  final bool isPlaying;
  final String trackInfo;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    return PixelBox(
      raised: true,
      color: const Color(0xFF1E211A),
      padding: const EdgeInsets.all(PixelMetrics.space4),
      child: Column(
        children: [
          // Cassette Header Label
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'SIDE A • AUTO-REVERSE',
                style: TextStyle(
                  fontFamily: 'Handjet',
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: palette.accent,
                ),
              ),
              Text(
                'TRACK: $trackInfo',
                style: const TextStyle(
                  fontFamily: 'Handjet',
                  fontSize: 12,
                  color: Color(0xFFE0DFD5),
                ),
              ),
            ],
          ),

          const SizedBox(height: PixelMetrics.space3),

          // Cassette Window & Spools
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: const Color(0xFF11130D),
              border: Border.all(color: palette.border, width: 2),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                // Left Spool
                _TapeSpool(animation: tapeAnimation, isPlaying: isPlaying),

                // Center Cassette Tape Window & VU Meters
                Column(
                  children: [
                    Container(
                      width: 80,
                      height: 12,
                      decoration: BoxDecoration(
                        color: const Color(0xFF2B2E24),
                        border: Border.all(color: palette.border, width: 1),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            flex: 4,
                            child: Container(color: const Color(0xFF4A341E)),
                          ),
                          Expanded(
                            flex: 6,
                            child: Container(color: Colors.transparent),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 6),
                    // Animated VU Meter Bars
                    Row(
                      children: List.generate(
                        7,
                        (index) => Container(
                          width: 6,
                          height: isPlaying ? (6.0 + ((index * 3) % 12)) : 4.0,
                          margin: const EdgeInsets.symmetric(horizontal: 1.5),
                          color: index > 4
                              ? const Color(0xFFE53935)
                              : (isPlaying
                                  ? const Color(0xFFCBE32B)
                                  : const Color(0xFF555A48)),
                        ),
                      ),
                    ),
                  ],
                ),

                // Right Spool
                _TapeSpool(animation: tapeAnimation, isPlaying: isPlaying),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TapeSpool extends StatelessWidget {
  const _TapeSpool({required this.animation, required this.isPlaying});

  final Animation<double> animation;
  final bool isPlaying;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, child) {
        final angle = isPlaying ? (animation.value * 2 * math.pi) : 0.0;
        return Transform.rotate(
          angle: angle,
          child: Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xFFE0DFD5),
              border: Border.all(color: Colors.black, width: 2),
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                Container(
                  width: 14,
                  height: 14,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: Color(0xFF11130D),
                  ),
                ),
                for (int i = 0; i < 3; i++)
                  Transform.rotate(
                    angle: i * (math.pi / 3),
                    child: Container(
                      width: 2,
                      height: 28,
                      color: const Color(0xFF11130D),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _WordDisplayCard extends StatelessWidget {
  const _WordDisplayCard({
    required this.word,
    required this.ipa,
    required this.partOfSpeech,
    required this.meaning,
    required this.example,
    required this.phaseText,
  });

  final String word;
  final String ipa;
  final String partOfSpeech;
  final String meaning;
  final String example;
  final String phaseText;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final theme = Theme.of(context);

    return PixelBox(
      raised: true,
      color: palette.surface,
      padding: const EdgeInsets.all(PixelMetrics.space4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Phase Status Indicator
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: palette.paper,
              border: Border.all(color: palette.border, width: 1),
            ),
            child: Text(
              phaseText.toUpperCase(),
              style: TextStyle(
                fontFamily: 'Handjet',
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: palette.accent,
              ),
              textAlign: TextAlign.center,
            ),
          ),

          const SizedBox(height: PixelMetrics.space3),

          // Word & IPA
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                word,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontFamily: 'Handjet',
                  fontSize: 30,
                  fontWeight: FontWeight.bold,
                  color: palette.ink,
                ),
              ),
              if (partOfSpeech.isNotEmpty) ...[
                const SizedBox(width: 8),
                Text(
                  partOfSpeech,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: palette.accent,
                  ),
                ),
              ],
              if (ipa.isNotEmpty) ...[
                const SizedBox(width: 8),
                Text(
                  ipa,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: palette.inkFaint,
                  ),
                ),
              ],
            ],
          ),

          const SizedBox(height: PixelMetrics.space2),

          // Meaning
          Text(
            meaning,
            style: theme.textTheme.bodyLarge?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),

          if (example.isNotEmpty) ...[
            const SizedBox(height: PixelMetrics.space2),
            Text(
              '“$example”',
              style: theme.textTheme.bodyMedium?.copyWith(
                fontStyle: FontStyle.italic,
                color: palette.inkMuted,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _PlaybackSettingsSection extends StatelessWidget {
  const _PlaybackSettingsSection({required this.commuteService});

  final AudioCommuteService commuteService;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final theme = Theme.of(context);

    return PixelBox(
      raised: true,
      padding: const EdgeInsets.all(PixelMetrics.space4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('COMMUTE PACING & AUDIO MODES',
              style: theme.textTheme.titleSmall),
          const SizedBox(height: PixelMetrics.space3),

          // Recall Pause Slider
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'RECALL PAUSE: ${commuteService.recallPauseSeconds}s',
                style: theme.textTheme.labelSmall,
              ),
              Row(
                children: [1, 2, 3, 5].map((sec) {
                  final active = commuteService.recallPauseSeconds == sec;
                  return Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: GestureDetector(
                      onTap: () => commuteService.setRecallPauseSeconds(sec),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: active ? palette.accent : palette.surface,
                          border: Border.all(color: palette.border, width: 1),
                        ),
                        child: Text(
                          '${sec}s',
                          style: TextStyle(
                            fontFamily: 'Handjet',
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: active ? palette.onAccent : palette.ink,
                          ),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ],
          ),

          const SizedBox(height: PixelMetrics.space3),

          // Repeat count
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'REPEAT PER WORD: ${commuteService.repeatCountPerWord}x',
                style: theme.textTheme.labelSmall,
              ),
              Row(
                children: [1, 2, 3].map((count) {
                  final active = commuteService.repeatCountPerWord == count;
                  return Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: GestureDetector(
                      onTap: () => commuteService.setRepeatCount(count),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: active ? palette.accent : palette.surface,
                          border: Border.all(color: palette.border, width: 1),
                        ),
                        child: Text(
                          '${count}x',
                          style: TextStyle(
                            fontFamily: 'Handjet',
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: active ? palette.onAccent : palette.ink,
                          ),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ],
          ),

          const SizedBox(height: PixelMetrics.space3),

          // English Audio Voice Mode
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'VOICE (ENGLISH ONLY):',
                style: theme.textTheme.labelSmall,
              ),
              Row(
                children: [
                  _AudioModePill(
                    label: 'WORD ONLY',
                    active: commuteService.mode == CommutePlaybackMode.wordOnly,
                    onTap: () => commuteService
                        .setPlaybackMode(CommutePlaybackMode.wordOnly),
                  ),
                  const SizedBox(width: 4),
                  _AudioModePill(
                    label: 'WORD + EXAMPLE',
                    active: commuteService.mode ==
                        CommutePlaybackMode.wordAndExample,
                    onTap: () => commuteService
                        .setPlaybackMode(CommutePlaybackMode.wordAndExample),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _AudioModePill extends StatelessWidget {
  const _AudioModePill({
    required this.label,
    required this.active,
    required this.onTap,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: active ? palette.accent : palette.surface,
          border: Border.all(color: palette.border, width: 1),
        ),
        child: Text(
          label,
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
}

class _TransportControlsBar extends StatelessWidget {
  const _TransportControlsBar({required this.commuteService});

  final AudioCommuteService commuteService;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: PixelMetrics.space3,
        vertical: PixelMetrics.space2,
      ),
      decoration: BoxDecoration(
        color: palette.surface,
        border: Border(
          top: BorderSide(color: palette.border, width: PixelMetrics.border),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          // Shuffle
          PixelIconButton(
            glyph: PixelGlyph.gamepad,
            active: commuteService.isShuffle,
            semanticLabel: 'Shuffle Playlist',
            onPressed: commuteService.toggleShuffle,
          ),

          // Previous
          PixelIconButton(
            glyph: PixelGlyph.arrowLeft,
            semanticLabel: 'Previous Word',
            onPressed: commuteService.previous,
          ),

          // Play / Pause Main Action
          GestureDetector(
            onTap: () {
              if (commuteService.isPlaying) {
                commuteService.pause();
              } else {
                commuteService.resume();
              }
            },
            child: PixelBox(
              raised: true,
              color: palette.accent,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    commuteService.isPlaying ? '❚❚ PAUSE' : '▶ PLAY',
                    style: TextStyle(
                      fontFamily: 'Handjet',
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: palette.onAccent,
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Next
          PixelIconButton(
            glyph: PixelGlyph.arrowRight,
            semanticLabel: 'Next Word',
            onPressed: commuteService.next,
          ),

          // Loop
          PixelIconButton(
            glyph: PixelGlyph.bolt,
            active: commuteService.isLoop,
            semanticLabel: 'Loop Deck',
            onPressed: commuteService.toggleLoop,
          ),
        ],
      ),
    );
  }
}
