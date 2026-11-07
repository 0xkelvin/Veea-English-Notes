import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/theme/pixel_metrics.dart';
import '../core/theme/pixel_palette.dart';
import '../models/vocabulary_word.dart';
import '../providers/vocabulary_provider.dart';
import '../services/audio_commute_service.dart';
import '../services/pronunciation_service.dart';
import '../services/tts_service.dart';
import '../widgets/commute_tape_selector_sheet.dart';
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
  List<VocabularyWord> _allWords = [];

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

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final vocab = context.read<VocabularyProvider>();
      try {
        final allWords = await vocab.allWords();
        if (!mounted) return;
        _allWords = allWords;
        final todayKey = VocabularyProvider.dateKey(vocab.today);
        final todayWords = allWords
            .where((word) => word.date == todayKey)
            .toList();
        final playlist = todayWords.isNotEmpty ? todayWords : allWords;
        if (playlist.isNotEmpty) {
          _commuteService.startPlayback(
            playlist,
            playlistTitle: todayWords.isNotEmpty
                ? 'Today · ${playlist.length} words'
                : 'All saved words · ${playlist.length}',
            autoplay: false,
          );
        }
        setState(() {});
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Could not load your words. Please reopen Listen to try again.',
              ),
            ),
          );
        }
      }
    });
  }

  void _openTapeSelector() {
    CommuteTapeSelectorSheet.show(
      context,
      allWords: _allWords,
      commuteService: _commuteService,
    );
  }

  void _openPlaybackSettings() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: context.palette.surface,
      builder: (sheetContext) => ConstrainedBox(
        key: const Key('listen_settings_sheet'),
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.85,
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Semantics(
                        header: true,
                        child: Text(
                          'Listening settings',
                          style: Theme.of(sheetContext).textTheme.titleMedium,
                        ),
                      ),
                    ),
                    const SizedBox(width: PixelMetrics.space2),
                    TextButton(
                      onPressed: () => Navigator.of(sheetContext).pop(),
                      child: const Text('Done'),
                    ),
                  ],
                ),
                const SizedBox(height: PixelMetrics.space2),
                Flexible(
                  child: SingleChildScrollView(
                    key: const Key('listen_settings_scroll'),
                    child: AnimatedBuilder(
                      animation: _commuteService,
                      builder: (_, _) => _PlaybackSettingsSection(
                        commuteService: _commuteService,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
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
                  Expanded(
                    child: Text(
                      'Listen',
                      style: theme.textTheme.titleMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: PixelMetrics.space2),
                  PixelIconButton(
                    key: const Key('listen_settings_button'),
                    glyph: PixelGlyph.gear,
                    semanticLabel: 'Listening settings',
                    onPressed: _openPlaybackSettings,
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
                    playlistTitle: _commuteService.playlistTitle,
                    trackInfo: _commuteService.totalWords > 0
                        ? '${_commuteService.currentIndex + 1} / ${_commuteService.totalWords}'
                        : 'NO WORDS',
                  ),

                  const SizedBox(height: PixelMetrics.space3),

                  // Tape Selector Strip
                  _TapeSelectorStrip(
                    playlistTitle: _commuteService.playlistTitle,
                    wordCount: _commuteService.totalWords,
                    onOpenSelector: _openTapeSelector,
                  ),

                  const SizedBox(height: PixelMetrics.space4),

                  // Current Word Card
                  if (currentWord != null) ...[
                    _WordDisplayCard(
                      word: currentWord.word,
                      ipa: currentWord.pronunciation != null
                          ? PronunciationService.format(
                              currentWord.pronunciation!,
                            )
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
                          'No words to play yet.\nSave a word in your notebook, then come back to listen.',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 16),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),

            // Bottom Transport Control Bar
            _TransportControlsBar(
              commuteService: _commuteService,
              onOpenSelector: _openTapeSelector,
            ),
          ],
        ),
      ),
    );
  }
}

class _TapeSelectorStrip extends StatelessWidget {
  const _TapeSelectorStrip({
    required this.playlistTitle,
    required this.wordCount,
    required this.onOpenSelector,
  });

  final String playlistTitle;
  final int wordCount;
  final VoidCallback onOpenSelector;

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
        border: Border.all(color: palette.border, width: PixelMetrics.border),
        boxShadow: [
          BoxShadow(
            color: palette.border.withValues(alpha: 0.3),
            offset: const Offset(2, 2),
            blurRadius: 0,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              PixelIcon(
                PixelGlyph.headphones,
                color: palette.accent,
                scale: 1.8,
              ),
              const SizedBox(width: PixelMetrics.space2),
              Expanded(
                child: Text(
                  playlistTitle,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: palette.ink,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: PixelMetrics.space2),
          PixelButton(label: 'Choose words', onPressed: onOpenSelector),
        ],
      ),
    );
  }
}

class _RetroCassetteWidget extends StatelessWidget {
  const _RetroCassetteWidget({
    required this.tapeAnimation,
    required this.isPlaying,
    required this.trackInfo,
    this.playlistTitle = 'TODAY',
  });

  final Animation<double> tapeAnimation;
  final bool isPlaying;
  final String trackInfo;
  final String playlistTitle;

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
              Expanded(
                child: Text(
                  'SIDE A • ${playlistTitle.toUpperCase()}',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: palette.accent,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  'TRACK: $trackInfo',
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFFE0DFD5),
                  ),
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
          // Show status only once there is something to report.
          if (phaseText.isNotEmpty) ...[
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
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: palette.accent,
                ),
                textAlign: TextAlign.center,
              ),
            ),

            const SizedBox(height: PixelMetrics.space3),
          ],

          // Word & IPA
          Wrap(
            spacing: PixelMetrics.space2,
            runSpacing: PixelMetrics.space1,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                word,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontSize: 30,
                  fontWeight: FontWeight.bold,
                  color: palette.ink,
                ),
              ),
              if (partOfSpeech.isNotEmpty) ...[
                Text(
                  partOfSpeech,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: palette.accent,
                  ),
                ),
              ],
              if (ipa.isNotEmpty) ...[
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _ListeningSettingMenu<int>(
          key: const Key('listen_pause_menu'),
          label: 'Pause between words',
          value: commuteService.recallPauseSeconds,
          options: const {1: '1 sec', 2: '2 sec', 3: '3 sec', 5: '5 sec'},
          onSelected: commuteService.setRecallPauseSeconds,
        ),
        const Divider(height: 1),
        _ListeningSettingMenu<int>(
          key: const Key('listen_repeats_menu'),
          label: 'Repeat each word',
          value: commuteService.repeatCountPerWord,
          options: const {1: '1 time', 2: '2 times', 3: '3 times'},
          onSelected: commuteService.setRepeatCount,
        ),
        const Divider(height: 1),
        _ListeningSettingMenu<CommutePlaybackMode>(
          key: const Key('listen_content_menu'),
          label: 'Read aloud',
          value: commuteService.mode,
          options: const {
            CommutePlaybackMode.wordOnly: 'Word only',
            CommutePlaybackMode.wordAndExample: 'Word and example',
          },
          onSelected: commuteService.setPlaybackMode,
        ),
      ],
    );
  }
}

class _ListeningSettingMenu<T> extends StatelessWidget {
  const _ListeningSettingMenu({
    super.key,
    required this.label,
    required this.value,
    required this.options,
    required this.onSelected,
  });

  final String label;
  final T value;
  final Map<T, String> options;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = context.palette;
    return PopupMenuButton<T>(
      tooltip: 'Change ${label.toLowerCase()}',
      initialValue: value,
      position: PopupMenuPosition.under,
      onSelected: onSelected,
      itemBuilder: (_) => [
        for (final option in options.entries)
          CheckedPopupMenuItem<T>(
            value: option.key,
            checked: option.key == value,
            child: Text(option.value),
          ),
      ],
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: PixelMetrics.space3),
          child: Row(
            children: [
              Expanded(
                flex: 3,
                child: Text(label, style: theme.textTheme.bodyMedium),
              ),
              const SizedBox(width: PixelMetrics.space3),
              Flexible(
                flex: 2,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Flexible(
                      child: Text(
                        options[value] ?? '',
                        textAlign: TextAlign.end,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: palette.accent,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: PixelMetrics.space1),
                    Icon(
                      Icons.keyboard_arrow_down,
                      size: 20,
                      color: palette.inkMuted,
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

class _TransportControlsBar extends StatelessWidget {
  const _TransportControlsBar({
    required this.commuteService,
    required this.onOpenSelector,
  });

  final AudioCommuteService commuteService;
  final VoidCallback onOpenSelector;

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
          // Eject / Select Playlist
          PixelIconButton(
            glyph: PixelGlyph.headphones,
            semanticLabel: 'Select Tape / Playlist',
            onPressed: onOpenSelector,
          ),

          // Shuffle
          PixelIconButton(
            glyph: PixelGlyph.shuffle,
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
          IconButton.filled(
            tooltip: commuteService.isPlaying ? 'Pause' : 'Play',
            onPressed: commuteService.totalWords == 0
                ? null
                : () {
                    if (commuteService.isPlaying) {
                      commuteService.pause();
                    } else {
                      commuteService.resume();
                    }
                  },
            icon: Icon(
              commuteService.isPlaying
                  ? Icons.pause_rounded
                  : Icons.play_arrow_rounded,
            ),
          ),

          // Next
          PixelIconButton(
            glyph: PixelGlyph.arrowRight,
            semanticLabel: 'Next Word',
            onPressed: commuteService.next,
          ),

          // Repeat / Loop
          PixelIconButton(
            glyph: PixelGlyph.repeat,
            active: commuteService.isLoop,
            semanticLabel: 'Repeat Playlist',
            onPressed: commuteService.toggleLoop,
          ),
        ],
      ),
    );
  }
}
