import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../core/theme/pixel_metrics.dart';
import '../core/theme/pixel_palette.dart';
import '../models/gate_config.dart';
import '../models/vocabulary_word.dart';
import '../providers/app_gate_provider.dart';
import '../providers/vocabulary_provider.dart';
import '../services/tts_service.dart';
import '../widgets/pixel/pixel_box.dart';
import '../widgets/pixel/pixel_button.dart';
import '../widgets/pixel/pixel_icon.dart';
import 'word_editor_screen.dart';

/// Full-screen "Word Toll" App Gate challenge screen.
///
/// Intercepts launches of selected distracting apps and requires the user to
/// type 1 English word from their own saved notebook using a 3-stage
/// progressive hint & "Teach & Retype" state machine.
class AppGateScreen extends StatefulWidget {
  const AppGateScreen({
    super.key,
    this.targetApp = 'Instagram',
    this.initialWord,
    this.previewMode = false,
  });

  /// Name or package identifier of the intercepted app.
  final String targetApp;

  /// Optional injected word (used by tests or preview). When null, selects the
  /// highest-priority word from SQLite's Smart Review Queue.
  final VocabularyWord? initialWord;

  /// When true, renders quick app-switcher pills so the user can test the gate
  /// from Settings.
  final bool previewMode;

  @override
  State<AppGateScreen> createState() => _AppGateScreenState();
}

class _AppGateScreenState extends State<AppGateScreen> {
  final TextEditingController _inputController = TextEditingController();
  final FocusNode _inputFocusNode = FocusNode();

  late String _currentApp;
  VocabularyWord? _currentWord;
  bool _loading = true;
  int _attempts = 0;
  bool _unlocked = false;
  bool _flashVisible = false;

  @override
  void initState() {
    super.initState();
    _currentApp = widget.targetApp;
    _inputFocusNode.addListener(() {
      if (mounted) setState(() {});
    });
    if (widget.initialWord != null) {
      _currentWord = widget.initialWord;
      _loading = false;
    } else {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _loadNextWord(force: false),
      );
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_currentWord == null && widget.initialWord == null) {
      final vocab = _maybeReadVocabProvider(context);
      if (vocab != null && vocab.words.isNotEmpty) {
        _currentWord = vocab.words.first;
        _loading = false;
      }
    }
  }

  @override
  void dispose() {
    _inputController.dispose();
    _inputFocusNode.dispose();
    super.dispose();
  }

  Future<void> _loadNextWord({bool force = true}) async {
    if (!mounted) return;
    if (!force && _currentWord != null) return;
    setState(() => _loading = true);

    VocabularyWord? word;
    final gateProvider = _maybeReadGateProvider(context);
    if (gateProvider != null) {
      word = await gateProvider.selectGateWord();
    } else {
      final vocabProvider = _maybeReadVocabProvider(context);
      word = await vocabProvider?.selectGateWord();
    }

    if (!mounted) return;
    setState(() {
      _currentWord = word;
      _loading = false;
      _attempts = 0;
      _unlocked = false;
      _flashVisible = false;
      _inputController.clear();
    });
  }

  void _handleInputChanged(String val) {
    // Stage 2 ("Teach & Retype") crucial rule:
    // As soon as onChanged fires with text.isNotEmpty (the user's first
    // keystroke), hide the full word so they must finish typing it from
    // short-term memory.
    if (_flashVisible && val.isNotEmpty) {
      setState(() {
        _flashVisible = false;
      });
    } else {
      setState(() {});
    }
  }

  void _speak(String word) {
    try {
      context.read<TtsService>().speak(word);
    } catch (_) {
      // TTS service is optional in isolated widget tests.
    }
  }

  Future<void> _handleSubmit() async {
    final word = _currentWord;
    if (word == null) return;

    final cleaned = _inputController.text.trim().toLowerCase();
    if (cleaned.isEmpty) return;

    final target = word.word.trim().toLowerCase();
    if (cleaned == target) {
      final solvedAttempts = _attempts;
      setState(() {
        _unlocked = true;
        _flashVisible = false;
      });
      _speak(word.word);

      final gateProvider = _maybeReadGateProvider(context);
      final vocabProvider = _maybeReadVocabProvider(context);
      if (gateProvider != null) {
        final updated = await gateProvider.completeGateChallenge(
          wordId: word.id,
          targetApp: _currentApp,
          attempts: solvedAttempts,
        );
        if (updated != null && mounted) {
          setState(() => _currentWord = updated);
        }
        await vocabProvider?.init();
      } else if (vocabProvider != null) {
        final updated = await vocabProvider.recordGateCompletion(
          wordId: word.id,
          targetApp: _currentApp,
          attempts: solvedAttempts,
        );
        if (updated != null && mounted) {
          setState(() => _currentWord = updated);
        }
      }
      return;
    }

    final nextAttempts = _attempts + 1;
    _inputController.clear();
    setState(() {
      _attempts = nextAttempts;
      if (nextAttempts >= 2) {
        _flashVisible = true;
      }
    });
    _speak(word.word);
  }

  void _peekAgain() {
    _inputController.clear();
    setState(() {
      _flashVisible = true;
    });
  }

  Future<void> _openAddWordEditor() async {
    await Navigator.of(context).push(
      PageRouteBuilder<void>(
        pageBuilder: (_, _, _) => const WordEditorScreen(),
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
      ),
    );
    if (!mounted) return;
    if (_currentWord == null) {
      await _loadNextWord();
    } else {
      setState(() {});
    }
  }

  static AppGateProvider? _maybeReadGateProvider(BuildContext context) {
    try {
      return context.read<AppGateProvider>();
    } catch (_) {
      return null;
    }
  }

  static VocabularyProvider? _maybeReadVocabProvider(BuildContext context) {
    try {
      return context.read<VocabularyProvider>();
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    AppGateProvider? gateProvider;
    try {
      gateProvider = context.watch<AppGateProvider>();
    } catch (_) {
      gateProvider = null;
    }

    VocabularyProvider? vocabProvider;
    try {
      vocabProvider = context.watch<VocabularyProvider>();
    } catch (_) {
      vocabProvider = null;
    }

    final config = gateProvider?.config ?? const GateConfig();
    final needsDailyCapture =
        config.requireDailyCapture &&
        vocabProvider != null &&
        vocabProvider.todayWordCount == 0;

    return Scaffold(
      backgroundColor: palette.paper,
      body: SafeArea(
        child: Column(
          children: [
            _GateStatusBar(
              targetApp: _currentApp,
              unlocked: _unlocked,
              passBadgeLabel: config.passBadgeLabel,
              onClose: () => Navigator.of(context).maybePop(),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(PixelMetrics.space4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (widget.previewMode) ...[
                      _AppSwitcherBar(
                        selectedApp: _currentApp,
                        apps: config.gatedApps.isNotEmpty
                            ? config.gatedApps
                            : GateConfig.defaultPresetApps.take(4).toList(),
                        onSelect: (app) {
                          setState(() {
                            _currentApp = app;
                            _unlocked = false;
                          });
                        },
                      ),
                      const SizedBox(height: PixelMetrics.space4),
                    ],
                    if (_loading)
                      const _GateMessageCard(
                        title: 'LOADING GATE QUEUE…',
                        body: 'Selecting 1 word from your notebook.',
                      )
                    else if (needsDailyCapture)
                      _DailyCaptureGuardrailCard(
                        targetApp: _currentApp,
                        onAddWord: _openAddWordEditor,
                      )
                    else if (_currentWord == null)
                      _GateMessageCard(
                        title: 'NO WORDS IN NOTEBOOK',
                        body:
                            'Add at least ${GateConfig.minRequiredWords} words to your Veea notebook to activate App Gate.',
                        actionLabel: 'Add a word',
                        onAction: _openAddWordEditor,
                      )
                    else if (!_unlocked)
                      _buildChallengeBody(context, _currentWord!)
                    else
                      _buildUnlockedBody(context, _currentWord!, config),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChallengeBody(BuildContext context, VocabularyWord word) {
    final palette = context.palette;
    final theme = Theme.of(context);
    final revealExtra = _attempts >= 1 ? 1 : 0;
    final mask = GateMaskHelper.buildMask(word.word, revealExtra);
    final capturedLabel = _formatCapturedMeta(word);
    final posLabel = word.partOfSpeech?.short ?? 'word';
    final ipa = (word.pronunciation != null && word.pronunciation!.isNotEmpty)
        ? word.pronunciation!
        : '/—/';

    return PixelBox(
      raised: true,
      color: palette.surface,
      padding: const EdgeInsets.all(PixelMetrics.space4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Meta header: Captured date + source | POS tag
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Text(
                  capturedLabel.toUpperCase(),
                  style: theme.textTheme.labelSmall,
                ),
              ),
              const SizedBox(width: PixelMetrics.space2),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: PixelMetrics.space2,
                  vertical: 2,
                ),
                decoration: BoxDecoration(
                  color: palette.paper,
                  border: Border.all(
                    color: palette.border,
                    width: PixelMetrics.border,
                  ),
                ),
                child: Text(
                  posLabel,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: palette.posColor(word.partOfSpeech),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: PixelMetrics.space4),

          // Native-language meaning in large pixel type
          Text(
            word.meaning,
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.bold,
              color: palette.ink,
              height: 1.2,
            ),
          ),

          // Blanked example sentence (if present)
          if (word.examples.isNotEmpty) ...[
            const SizedBox(height: PixelMetrics.space3),
            Text(
              '"${GateMaskHelper.blankWordInSentence(word.examples.first, word.word)}"',
              style: theme.textTheme.bodyMedium?.copyWith(color: palette.ink),
            ),
          ],
          const SizedBox(height: PixelMetrics.space4),

          // Clue Box: Letter mask + Stage 1 IPA/Audio + Stage 2 Teach & Retype
          Container(
            padding: const EdgeInsets.all(PixelMetrics.space3),
            decoration: BoxDecoration(
              color: palette.paper,
              border: Border.all(
                color: palette.border,
                width: PixelMetrics.border,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(
                        mask,
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.5,
                          color: palette.ink,
                        ),
                      ),
                    ),
                    const SizedBox(width: PixelMetrics.space2),
                    Text(
                      '${word.word.length} letters',
                      style: theme.textTheme.labelSmall,
                    ),
                  ],
                ),

                // Stage 1+: Reveal IPA + "Hear it" button
                if (_attempts >= 1) ...[
                  const SizedBox(height: PixelMetrics.space3),
                  Container(height: PixelMetrics.border, color: palette.border),
                  const SizedBox(height: PixelMetrics.space3),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          'IPA: $ipa',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: palette.ink,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(width: PixelMetrics.space2),
                      PixelButton(
                        label: 'Hear it',
                        glyph: PixelGlyph.speaker,
                        onPressed: () => _speak(word.word),
                      ),
                    ],
                  ),
                ],

                // Stage 2+: "Teach & Retype" box
                if (_attempts >= 2) ...[
                  const SizedBox(height: PixelMetrics.space3),
                  Container(
                    padding: const EdgeInsets.all(PixelMetrics.space3),
                    decoration: BoxDecoration(
                      color: palette.surface,
                      border: Border.all(
                        color: palette.accent,
                        width: PixelMetrics.border,
                      ),
                    ),
                    child: _flashVisible
                        ? Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Attempt $_attempts failed · Memorise & type',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: palette.accent,
                                ),
                              ),
                              const SizedBox(height: PixelMetrics.space2),
                              Text(
                                word.word,
                                style: TextStyle(
                                  fontSize: 32,
                                  fontWeight: FontWeight.bold,
                                  color: palette.ink,
                                  letterSpacing: 1.5,
                                ),
                              ),
                              const SizedBox(height: PixelMetrics.space1),
                              Text(
                                'Start typing below — the answer hides on your first keystroke.',
                                style: theme.textTheme.bodySmall,
                              ),
                            ],
                          )
                        : Wrap(
                            crossAxisAlignment: WrapCrossAlignment.center,
                            spacing: PixelMetrics.space2,
                            runSpacing: PixelMetrics.space2,
                            children: [
                              Text(
                                'Answer hidden. Finish typing ${word.word.length} letters from memory, or',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: palette.ink,
                                ),
                              ),
                              GestureDetector(
                                onTap: _peekAgain,
                                behavior: HitTestBehavior.opaque,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: PixelMetrics.space2,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: palette.accent,
                                    border: Border.all(
                                      color: palette.border,
                                      width: 1,
                                    ),
                                  ),
                                  child: Text(
                                    'peek again',
                                    style: TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.bold,
                                      color: palette.onAccent,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: PixelMetrics.space4),

          // Input field
          Container(
            decoration: BoxDecoration(
              color: palette.paper,
              border: Border.all(
                color: _inputFocusNode.hasFocus
                    ? palette.accent
                    : palette.border,
                width: PixelMetrics.border,
              ),
            ),
            child: TextField(
              key: const Key('app_gate_input'),
              controller: _inputController,
              focusNode: _inputFocusNode,
              autocorrect: false,
              enableSuggestions: false,
              textCapitalization: TextCapitalization.none,
              textInputAction: TextInputAction.done,
              onChanged: _handleInputChanged,
              onSubmitted: (_) => _handleSubmit(),
              cursorWidth: PixelMetrics.border,
              cursorRadius: Radius.zero,
              style: theme.textTheme.bodyLarge,
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Type the ${word.word.length}-letter word...',
                hintStyle: theme.textTheme.bodyLarge?.copyWith(
                  color: palette.inkFaint,
                ),
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: PixelMetrics.space3,
                  vertical: PixelMetrics.space3,
                ),
              ),
            ),
          ),
          const SizedBox(height: PixelMetrics.space3),

          PixelButton(
            label: 'Unlock $_currentApp',
            glyph: PixelGlyph.shield,
            filled: true,
            expand: true,
            onPressed: _handleSubmit,
          ),
          const SizedBox(height: PixelMetrics.space3),

          // Stage status footer
          Text(
            _attempts == 0
                ? 'Attempt 1 of 2 · Type a wrong word to test progressive hints'
                : _attempts == 1
                ? 'Missed once · IPA + audio + 2nd letter unlocked'
                : 'Teach & retype mode · Must type from memory to pass',
            style: theme.textTheme.labelSmall,
          ),
        ],
      ),
    );
  }

  Widget _buildUnlockedBody(
    BuildContext context,
    VocabularyWord word,
    GateConfig config,
  ) {
    final palette = context.palette;
    final theme = Theme.of(context);
    final posLabel = word.partOfSpeech?.short ?? 'word';
    final ipa = (word.pronunciation != null && word.pronunciation!.isNotEmpty)
        ? word.pronunciation!
        : '/—/';

    return PixelBox(
      raised: true,
      color: palette.surface,
      padding: const EdgeInsets.all(PixelMetrics.space4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  config.passActiveLabel.toUpperCase(),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: palette.accent,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: PixelMetrics.space2,
                  vertical: 2,
                ),
                decoration: BoxDecoration(
                  color: palette.paper,
                  border: Border.all(
                    color: palette.border,
                    width: PixelMetrics.border,
                  ),
                ),
                child: Text(
                  _attempts == 0
                      ? '1st try'
                      : '${_attempts + 1} tries · Re-queued',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: palette.ink,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: PixelMetrics.space4),

          Text(
            word.word,
            style: TextStyle(
              fontSize: 34,
              fontWeight: FontWeight.bold,
              color: palette.ink,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: PixelMetrics.space2),

          Text(
            '$ipa · $posLabel — ${word.meaning}',
            style: theme.textTheme.bodyMedium?.copyWith(color: palette.ink),
          ),

          if (word.examples.isNotEmpty) ...[
            const SizedBox(height: PixelMetrics.space3),
            Text(
              '"${word.examples.first}"',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: palette.inkMuted,
              ),
            ),
          ],
          const SizedBox(height: PixelMetrics.space5),

          PixelButton(
            label: 'Continue to $_currentApp',
            glyph: PixelGlyph.check,
            filled: true,
            expand: true,
            onPressed: () async {
              final gateProvider = _maybeReadGateProvider(context);
              await gateProvider?.launchTargetApp(_currentApp);
              if (context.mounted) {
                Navigator.of(context).maybePop(true);
              }
            },
          ),
          const SizedBox(height: PixelMetrics.space2),

          PixelButton(
            label: 'Lock again · Next word',
            glyph: PixelGlyph.repeat,
            expand: true,
            onPressed: () => _loadNextWord(force: true),
          ),
          const SizedBox(height: PixelMetrics.space2),

          PixelButton(
            label: 'Hear pronunciation',
            glyph: PixelGlyph.speaker,
            expand: true,
            onPressed: () => _speak(word.word),
          ),
        ],
      ),
    );
  }

  static String _formatCapturedMeta(VocabularyWord word) {
    String dayText = word.date;
    final parsed = DateTime.tryParse(word.date);
    if (parsed != null) {
      dayText = DateFormat('d MMM').format(parsed);
    }
    if (word.source != null && word.source!.trim().isNotEmpty) {
      return 'Captured $dayText · ${word.source!.trim()}';
    }
    return 'Captured $dayText';
  }
}

class _GateStatusBar extends StatelessWidget {
  const _GateStatusBar({
    required this.targetApp,
    required this.unlocked,
    required this.passBadgeLabel,
    required this.onClose,
  });

  final String targetApp;
  final bool unlocked;
  final String passBadgeLabel;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: PixelMetrics.space4,
        vertical: PixelMetrics.space2,
      ),
      decoration: BoxDecoration(
        color: palette.surface,
        border: Border(
          bottom: BorderSide(color: palette.border, width: PixelMetrics.border),
        ),
      ),
      child: Row(
        children: [
          PixelIcon(PixelGlyph.shield, color: palette.accent, scale: 1.6),
          const SizedBox(width: PixelMetrics.space2),
          Text('VEEA GATE', style: theme.textTheme.titleMedium),
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: PixelMetrics.space2,
              vertical: 2,
            ),
            decoration: BoxDecoration(
              color: unlocked ? palette.accent : palette.paper,
              border: Border.all(
                color: palette.border,
                width: PixelMetrics.border,
              ),
            ),
            child: Text(
              unlocked
                  ? 'UNLOCKED · $passBadgeLabel'
                  : 'LOCKED · $targetApp'.toUpperCase(),
              style: theme.textTheme.labelSmall?.copyWith(
                color: unlocked ? palette.onAccent : palette.ink,
              ),
            ),
          ),
          const SizedBox(width: PixelMetrics.space2),
          PixelIconButton(
            glyph: PixelGlyph.close,
            semanticLabel: 'Close gate',
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}

class _AppSwitcherBar extends StatelessWidget {
  const _AppSwitcherBar({
    required this.selectedApp,
    required this.apps,
    required this.onSelect,
  });

  final String selectedApp;
  final List<String> apps;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('INTERCEPTED APP PREVIEW', style: theme.textTheme.labelSmall),
        const SizedBox(height: PixelMetrics.space2),
        Wrap(
          spacing: PixelMetrics.space2,
          runSpacing: PixelMetrics.space2,
          children: [
            for (final app in apps)
              GestureDetector(
                onTap: () => onSelect(app),
                behavior: HitTestBehavior.opaque,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: PixelMetrics.space3,
                    vertical: PixelMetrics.space2,
                  ),
                  decoration: BoxDecoration(
                    color: app == selectedApp
                        ? palette.accent
                        : palette.surface,
                    border: Border.all(
                      color: palette.border,
                      width: PixelMetrics.border,
                    ),
                  ),
                  child: Text(
                    app.toUpperCase(),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: app == selectedApp
                          ? palette.onAccent
                          : palette.ink,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _DailyCaptureGuardrailCard extends StatelessWidget {
  const _DailyCaptureGuardrailCard({
    required this.targetApp,
    required this.onAddWord,
  });

  final String targetApp;
  final VoidCallback onAddWord;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final theme = Theme.of(context);

    return PixelBox(
      raised: true,
      color: palette.surface,
      padding: const EdgeInsets.all(PixelMetrics.space4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'DAILY CAPTURE REQUIRED',
            style: theme.textTheme.titleMedium?.copyWith(color: palette.accent),
          ),
          const SizedBox(height: PixelMetrics.space2),
          Text(
            'You enabled "Require 1 new word captured today before unlocking". '
            'Add 1 word to today\'s journal first to unlock $targetApp.',
            style: theme.textTheme.bodyMedium?.copyWith(color: palette.ink),
          ),
          const SizedBox(height: PixelMetrics.space4),
          PixelButton(
            label: 'Capture 1 word today',
            glyph: PixelGlyph.plus,
            filled: true,
            expand: true,
            onPressed: onAddWord,
          ),
        ],
      ),
    );
  }
}

class _GateMessageCard extends StatelessWidget {
  const _GateMessageCard({
    required this.title,
    required this.body,
    this.actionLabel,
    this.onAction,
  });

  final String title;
  final String body;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final theme = Theme.of(context);

    return PixelBox(
      raised: true,
      color: palette.surface,
      padding: const EdgeInsets.all(PixelMetrics.space4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: theme.textTheme.titleMedium),
          const SizedBox(height: PixelMetrics.space2),
          Text(
            body,
            style: theme.textTheme.bodyMedium?.copyWith(color: palette.ink),
          ),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: PixelMetrics.space4),
            PixelButton(
              label: actionLabel!,
              glyph: PixelGlyph.plus,
              filled: true,
              expand: true,
              onPressed: onAction,
            ),
          ],
        ],
      ),
    );
  }
}
