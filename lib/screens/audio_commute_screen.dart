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

/// Hands-Free Listening Audio Player Screen.
class AudioCommuteScreen extends StatefulWidget {
  const AudioCommuteScreen({super.key});

  @override
  State<AudioCommuteScreen> createState() => _AudioCommuteScreenState();
}

class _AudioCommuteScreenState extends State<AudioCommuteScreen> {
  late final AudioCommuteService _commuteService;
  List<VocabularyWord> _allWords = [];

  @override
  void initState() {
    super.initState();
    final tts = context.read<TtsService>();
    _commuteService = AudioCommuteService(ttsService: tts);

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
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(PixelMetrics.radiusLg),
        ),
      ),
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
    setState(() {});
  }

  @override
  void dispose() {
    _commuteService.removeListener(_onServiceUpdate);
    _commuteService.stop();
    _commuteService.dispose();
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
                horizontal: PixelMetrics.space3,
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
                  Expanded(
                    child: Text('Listen', style: theme.textTheme.titleMedium),
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

            // Main Player Header & Word Display
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(PixelMetrics.space4),
                children: [
                  _PlaylistHeaderCard(
                    playlistTitle: _commuteService.playlistTitle,
                    currentIndex: _commuteService.currentIndex,
                    totalWords: _commuteService.totalWords,
                    isPlaying: _commuteService.isPlaying,
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
                      isPlaying: _commuteService.isPlaying,
                    ),
                  ] else ...[
                    PixelBox(
                      raised: true,
                      padding: const EdgeInsets.all(PixelMetrics.space6),
                      child: Column(
                        children: [
                          Container(
                            width: 48,
                            height: 48,
                            decoration: BoxDecoration(
                              color: palette.paper,
                              borderRadius: BorderRadius.circular(
                                PixelMetrics.radius,
                              ),
                              border: Border.all(
                                color: palette.border,
                                width: PixelMetrics.border,
                              ),
                            ),
                            alignment: Alignment.center,
                            child: PixelIcon(
                              PixelGlyph.headphones,
                              color: palette.inkMuted,
                              scale: 2.4,
                            ),
                          ),
                          const SizedBox(height: PixelMetrics.space3),
                          Text(
                            'No words to play yet',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.titleMedium,
                          ),
                          const SizedBox(height: PixelMetrics.space2),
                          Text(
                            'Save a word in your notebook, then come back to listen.',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: palette.inkMuted,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
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

class _PlaylistHeaderCard extends StatelessWidget {
  const _PlaylistHeaderCard({
    required this.playlistTitle,
    required this.currentIndex,
    required this.totalWords,
    required this.isPlaying,
    required this.onOpenSelector,
  });

  final String playlistTitle;
  final int currentIndex;
  final int totalWords;
  final bool isPlaying;
  final VoidCallback onOpenSelector;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final theme = Theme.of(context);
    final textScale = MediaQuery.textScalerOf(context).scale(1);
    final trackLabel = totalWords > 0
        ? 'Word ${currentIndex + 1} of $totalWords'
        : 'No words saved';

    return PixelBox(
      padding: const EdgeInsets.all(PixelMetrics.space3),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compactStack = constraints.maxWidth < 310 || textScale > 1.25;

          final artwork = AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: isPlaying
                  ? palette.accent.withValues(alpha: 0.14)
                  : palette.paper,
              borderRadius: BorderRadius.circular(PixelMetrics.radiusSm),
              border: Border.all(
                color: isPlaying
                    ? palette.accent.withValues(alpha: 0.35)
                    : palette.border,
                width: PixelMetrics.border,
              ),
            ),
            alignment: Alignment.center,
            child: Icon(
              isPlaying ? Icons.graphic_eq_rounded : Icons.headphones_rounded,
              size: 20,
              color: palette.accent,
            ),
          );

          final chooseButton = TextButton(
            onPressed: onOpenSelector,
            style: TextButton.styleFrom(
              foregroundColor: palette.accent,
              backgroundColor: palette.accent.withValues(alpha: 0.08),
              padding: const EdgeInsets.symmetric(
                horizontal: PixelMetrics.space3,
                vertical: PixelMetrics.space2,
              ),
              minimumSize: const Size(0, PixelMetrics.tapTarget),
              tapTargetSize: MaterialTapTargetSize.padded,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(PixelMetrics.radiusSm),
              ),
            ),
            child: const Text('Choose words'),
          );

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  if (!compactStack) ...[
                    artwork,
                    const SizedBox(width: PixelMetrics.space3),
                  ],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          playlistTitle,
                          style: theme.textTheme.titleSmall?.copyWith(
                            color: palette.ink,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          trackLabel,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: palette.inkMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (!compactStack) ...[
                    const SizedBox(width: PixelMetrics.space2),
                    chooseButton,
                  ],
                ],
              ),
              if (compactStack) ...[
                const SizedBox(height: PixelMetrics.space2),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: chooseButton,
                ),
              ],
              if (totalWords > 0) ...[
                const SizedBox(height: PixelMetrics.space3),
                ClipRRect(
                  borderRadius: BorderRadius.circular(PixelMetrics.radiusPill),
                  child: LinearProgressIndicator(
                    value: (currentIndex + 1) / totalWords,
                    minHeight: 3,
                    backgroundColor: palette.border.withValues(alpha: 0.7),
                    color: palette.accent,
                    semanticsLabel: 'Playlist progress',
                  ),
                ),
              ],
            ],
          );
        },
      ),
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
    required this.isPlaying,
  });

  final String word;
  final String ipa;
  final String partOfSpeech;
  final String meaning;
  final String example;
  final String phaseText;
  final bool isPlaying;

  String _formatPhaseText(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return '';
    if (trimmed == 'PAUSED') return 'Paused';
    if (trimmed.startsWith('PLAYING:')) return 'Reading word';
    if (trimmed.startsWith('EXAMPLE:')) return 'Reading example';
    if (trimmed == 'NEXT WORD…') return 'Next word…';
    if (trimmed.startsWith('PAUSE ')) {
      return 'Pause ${trimmed.substring(6)}';
    }
    if (trimmed.startsWith('REPEAT ')) {
      return 'Repeat ${trimmed.substring(7)}';
    }
    return trimmed[0].toUpperCase() + trimmed.substring(1).toLowerCase();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final theme = Theme.of(context);
    final formattedPhase = _formatPhaseText(phaseText);

    return PixelBox(
      raised: true,
      color: palette.surface,
      padding: const EdgeInsets.all(PixelMetrics.space5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Show status only once there is something to report.
          if (formattedPhase.isNotEmpty) ...[
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: PixelMetrics.space3,
                vertical: PixelMetrics.space1,
              ),
              decoration: BoxDecoration(
                color: isPlaying
                    ? palette.accent.withValues(alpha: 0.10)
                    : palette.paper,
                borderRadius: BorderRadius.circular(PixelMetrics.radiusPill),
                border: Border.all(
                  color: isPlaying
                      ? palette.accent.withValues(alpha: 0.24)
                      : palette.border,
                  width: PixelMetrics.border,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: isPlaying ? palette.accent : palette.inkMuted,
                    ),
                  ),
                  const SizedBox(width: PixelMetrics.space2),
                  Flexible(
                    child: Text(
                      formattedPhase,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: isPlaying ? palette.accent : palette.inkMuted,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: PixelMetrics.space4),
          ],

          // Primary Headword
          Text(
            word,
            style: theme.textTheme.displaySmall?.copyWith(
              // Use the headline size on narrow phones; user text scaling
              // still applies fully, with no fitted/shrunk text.
              fontSize: MediaQuery.sizeOf(context).width < 360 ? 26 : 32,
              fontWeight: FontWeight.w700,
              color: palette.ink,
              height: 1.2,
              letterSpacing: -0.4,
            ),
          ),

          if (partOfSpeech.isNotEmpty || ipa.isNotEmpty) ...[
            const SizedBox(height: PixelMetrics.space2),
            Wrap(
              spacing: PixelMetrics.space2,
              runSpacing: PixelMetrics.space1,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (partOfSpeech.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: PixelMetrics.space2,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: palette.accent.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(
                        PixelMetrics.radiusPill,
                      ),
                    ),
                    child: Text(
                      partOfSpeech,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: palette.accent,
                      ),
                    ),
                  ),
                if (ipa.isNotEmpty)
                  Text(
                    ipa,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: palette.inkMuted,
                    ),
                  ),
              ],
            ),
          ],

          const SizedBox(height: PixelMetrics.space4),
          Divider(height: 1, color: palette.border),
          const SizedBox(height: PixelMetrics.space4),

          // Primary Meaning
          Text(
            meaning,
            style: theme.textTheme.titleMedium?.copyWith(
              color: palette.ink,
              fontWeight: FontWeight.w600,
              height: 1.4,
            ),
          ),

          if (example.isNotEmpty) ...[
            const SizedBox(height: PixelMetrics.space4),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(PixelMetrics.space3),
              decoration: BoxDecoration(
                color: palette.paper,
                borderRadius: BorderRadius.circular(PixelMetrics.radiusSm),
                border: Border.all(
                  color: palette.border,
                  width: PixelMetrics.border,
                ),
              ),
              child: Text(
                '“$example”',
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontStyle: FontStyle.italic,
                  color: palette.inkMuted,
                  height: 1.45,
                ),
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
                child: Text(
                  label,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: palette.ink,
                    fontWeight: FontWeight.w500,
                  ),
                ),
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
  const _TransportControlsBar({required this.commuteService});

  final AudioCommuteService commuteService;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: PixelMetrics.space3,
        vertical: PixelMetrics.space3,
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
            iconSize: 28,
            style: IconButton.styleFrom(
              backgroundColor: palette.accent,
              foregroundColor: palette.onAccent,
              disabledBackgroundColor: palette.border,
              disabledForegroundColor: palette.inkFaint,
              minimumSize: const Size(52, 52),
            ),
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
