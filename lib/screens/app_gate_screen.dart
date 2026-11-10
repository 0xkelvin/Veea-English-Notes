import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../core/theme/pixel_metrics.dart';
import '../core/theme/pixel_palette.dart';
import '../models/gate_config.dart';
import '../models/gate_word_queue.dart';
import '../models/vocabulary_word.dart';
import '../providers/app_gate_provider.dart';
import '../providers/vocabulary_provider.dart';
import '../services/tts_service.dart';
import '../widgets/pixel/pixel_box.dart';
import '../widgets/pixel/pixel_button.dart';
import '../widgets/pixel/pixel_icon.dart';
import '../widgets/practice_word_picker.dart';
import '../widgets/native_gate_return_hint.dart';
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
    this.openedFromVeea = false,
  });

  /// Name or package identifier of the intercepted app.
  final String targetApp;

  /// Optional injected word (used by tests or preview). When null, selects the
  /// highest-priority word from SQLite's Smart Review Queue.
  final VocabularyWord? initialWord;

  /// When true, renders quick app-switcher pills so the user can test the gate
  /// from Settings.
  final bool previewMode;

  /// Internal unlocks have no system return breadcrumb to a protected app.
  final bool openedFromVeea;

  @override
  State<AppGateScreen> createState() => _AppGateScreenState();
}

class _AppGateScreenState extends State<AppGateScreen>
    with WidgetsBindingObserver {
  final TextEditingController _inputController = TextEditingController();
  final FocusNode _inputFocusNode = FocusNode();

  late String _currentApp;
  bool get _isNativeTarget => _currentApp.startsWith('native:');
  String get _displayApp =>
      _maybeReadGateProvider(context)?.displayNameForApp(_currentApp) ??
      (_isNativeTarget ? 'Protected app' : _currentApp);
  VocabularyWord? _currentWord;
  VocabularyWord? _completedNativeWord;
  bool _loading = true;
  int _attempts = 0;
  int _solvedInRound = 0;
  final Set<String> _solvedWordIds = {};
  bool _unlocked = false;
  bool _flashVisible = false;
  bool _submitting = false;
  bool _keyboardRequestScheduled = false;
  String? _challengeError;
  Timer? _accessTicker;
  AppGateProvider? _gateForDisposal;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _currentApp = widget.targetApp;
    _inputFocusNode.addListener(() {
      if (mounted) setState(() {});
    });
    if (widget.initialWord != null) {
      _currentWord = widget.initialWord;
      _loading = false;
      _scheduleAnswerKeyboard();
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final gateProvider = _maybeReadGateProvider(context);
        if (gateProvider != null && !widget.previewMode) {
          _solvedInRound = gateProvider.progressForApp(_currentApp);
          _solvedWordIds.addAll(gateProvider.solvedWordIdsForApp(_currentApp));
        }
        _loadNextWord(force: false);
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _gateForDisposal = _maybeReadGateProvider(context);
    if (_currentWord == null && widget.initialWord == null) {
      final gateProvider = _maybeReadGateProvider(context);
      if (gateProvider != null && !widget.previewMode) {
        _solvedInRound = gateProvider.progressForApp(_currentApp);
        _solvedWordIds.addAll(gateProvider.solvedWordIdsForApp(_currentApp));
      }
      final vocab = _maybeReadVocabProvider(context);
      _currentWord = gateProvider?.cachedGateWord(
        _currentApp,
        preview: widget.previewMode,
      );
      if (gateProvider == null && vocab != null) {
        _currentWord = GateWordQueue.select(
          vocab.words,
          now: vocab.today,
          excludeIds: _solvedWordIds,
        );
      }
      if (_currentWord != null) {
        _loading = false;
        _unlocked =
            !widget.previewMode &&
            gateProvider?.unlockedUntilFor(_currentApp) != null;
        _watchAccessExpiry();
        _scheduleAnswerKeyboard();
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshAccessOnResume();
    } else {
      // UIKit can resign its responder during a Shortcut handoff. Clear the
      // Flutter focus too so resuming attaches a fresh text-input connection.
      _inputFocusNode.unfocus();
    }
  }

  Future<void> _refreshAccessOnResume() async {
    final wasUnlocked = _unlocked;
    final gate = _maybeReadGateProvider(context);
    if (_isNativeTarget && !widget.previewMode) {
      await gate?.refreshNativeScreenTime();
      if (!mounted) return;
      setState(() {
        _unlocked = gate?.unlockedUntilFor(_currentApp) != null;
      });
    } else if (_unlocked &&
        !widget.previewMode &&
        gate != null &&
        gate.config.passDurationMinutes > 0) {
      setState(() {
        _unlocked = gate.unlockedUntilFor(_currentApp) != null;
      });
    }
    if (wasUnlocked && !_unlocked) {
      _solvedWordIds.clear();
      _solvedInRound = 0;
      await _loadNextWord();
      return;
    }
    _watchAccessExpiry();
    _scheduleAnswerKeyboard();
  }

  void _watchAccessExpiry() {
    _accessTicker?.cancel();
    if (!_unlocked || widget.previewMode) return;
    final gate = _maybeReadGateProvider(context);
    if (gate?.unlockedUntilFor(_currentApp) == null) return;
    // This timer updates the visible countdown only. iOS owns enforcement.
    _accessTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (gate?.unlockedUntilFor(_currentApp) == null) {
        _accessTicker?.cancel();
        _solvedWordIds.clear();
        _solvedInRound = 0;
        _loadNextWord();
      } else {
        setState(() {});
      }
    });
  }

  String _passBadgeLabel(GateConfig config) {
    if (widget.previewMode || (!_unlocked && !_isNativeTarget)) {
      return config.passBadgeLabel;
    }
    final gate = _maybeReadGateProvider(context);
    final expiry = gate?.unlockedUntilFor(_currentApp);
    if (expiry == null) return config.passBadgeLabel;
    final seconds =
        ((expiry.difference(gate!.now).inMilliseconds + 999) ~/ 1000).clamp(
          0,
          86400,
        );
    final clock = seconds >= 3600
        ? '${seconds ~/ 3600}:${((seconds ~/ 60) % 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}'
        : '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
    return '$clock PASS';
  }

  bool get _canShowAnswerKeyboard {
    if (!mounted || _loading || _currentWord == null || _unlocked) return false;
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle != null && lifecycle != AppLifecycleState.resumed) {
      return false;
    }
    if (ModalRoute.of(context)?.isCurrent != true) return false;
    final gate = _maybeReadGateProvider(context);
    if (!widget.previewMode &&
        gate != null &&
        _solvedInRound >= gate.requiredWords) {
      return false;
    }
    return true;
  }

  void _scheduleAnswerKeyboard() {
    if (_keyboardRequestScheduled || !mounted) return;
    _keyboardRequestScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _keyboardRequestScheduled = false;
      if (!_canShowAnswerKeyboard) return;
      _inputFocusNode.requestFocus();
      // Focus attaches the input client asynchronously. Request the software
      // keyboard on the next frame, after the client and active route exist.
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!_canShowAnswerKeyboard || !_inputFocusNode.hasFocus) return;
        try {
          await SystemChannels.textInput.invokeMethod<void>('TextInput.show');
        } on PlatformException catch (error) {
          debugPrint('App Gate keyboard request failed: $error');
        }
      });
      WidgetsBinding.instance.ensureVisualUpdate();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void dispose() {
    if (_currentApp.startsWith('shortcut:') && !_unlocked) {
      final provider = _gateForDisposal;
      if (provider != null) {
        unawaited(provider.service.cancelUniversalGate(_currentApp));
      }
    }
    _accessTicker?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _inputController.dispose();
    _inputFocusNode.dispose();
    super.dispose();
  }

  Future<void> _loadNextWord({bool force = true}) async {
    if (!mounted) return;
    if (!force && _currentWord != null) return;
    setState(() {
      _loading = true;
      _completedNativeWord = null;
    });

    try {
      VocabularyWord? word;
      final gateProvider = _maybeReadGateProvider(context);
      final vocabProvider = _maybeReadVocabProvider(context);
      if (gateProvider != null) {
        word = await gateProvider.selectGateWord(
          targetApp: widget.previewMode ? null : _currentApp,
          excludeIds: _solvedWordIds,
        );
        if (word == null &&
            !widget.previewMode &&
            _solvedInRound >= gateProvider.requiredWords) {
          word = gateProvider.cachedGateWord(_currentApp, preview: true);
        }
      } else {
        word = await vocabProvider?.selectGateWord();
      }

      // If multi-word round and the selected word was just solved, pick another
      // word from the user's notebook if available.
      if (word != null &&
          _solvedWordIds.contains(word.id) &&
          vocabProvider != null &&
          vocabProvider.words.length > 1) {
        final candidates = vocabProvider.words
            .where((w) => !_solvedWordIds.contains(w.id))
            .toList();
        if (candidates.isNotEmpty) {
          word = candidates.first;
        }
      }

      if (word == null &&
          gateProvider == null &&
          vocabProvider != null &&
          vocabProvider.words.isNotEmpty) {
        word = vocabProvider.words.first;
      }

      if (!mounted) return;
      setState(() {
        _currentWord = word;
        _loading = false;
        _attempts =
            !widget.previewMode &&
                word != null &&
                gateProvider?.pendingAnswerForApp(_currentApp)?.wordId ==
                    word.id
            ? gateProvider!.pendingAnswerForApp(_currentApp)!.attempts
            : 0;
        _unlocked =
            !widget.previewMode &&
            gateProvider?.unlockedUntilFor(_currentApp) != null;
        _flashVisible = false;
        _inputController.clear();
        _challengeError = null;
      });
      _scheduleAnswerKeyboard();
      _watchAccessExpiry();
    } catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _currentWord = null;
          _unlocked =
              !widget.previewMode &&
              _maybeReadGateProvider(context)?.unlockedUntilFor(_currentApp) !=
                  null;
          _challengeError =
              'Could not load your notebook. Your completed words are kept. Please try again.';
        });
        _watchAccessExpiry();
      }
    }
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

  void _autoSpeak(String word) {
    if (_maybeReadGateProvider(context)?.config.autoPronounce == true) {
      _speak(word);
    }
  }

  Future<void> _handleSubmit() async {
    if (_submitting) return;
    final word = _currentWord;
    if (word == null) return;

    final cleaned = _inputController.text.trim().toLowerCase();
    if (cleaned.isEmpty) return;

    final target = word.word.trim().toLowerCase();
    if (cleaned == target) {
      setState(() => _submitting = true);
      final solvedAttempts = widget.previewMode
          ? _attempts
          : _maybeReadGateProvider(
                  context,
                )?.pendingAnswerForApp(_currentApp)?.attempts ??
                _attempts;
      _autoSpeak(word.word);

      final gateProvider = _maybeReadGateProvider(context);
      final vocabProvider = _maybeReadVocabProvider(context);
      final requiredWords = gateProvider?.requiredWords ?? 1;
      final nextSolvedCount = _solvedInRound + 1;
      try {
        if (widget.previewMode) {
          _solvedWordIds.add(word.id);
          if (nextSolvedCount < requiredWords) {
            setState(() => _solvedInRound = nextSolvedCount);
            await _loadNextWord();
          } else {
            setState(() {
              _unlocked = true;
              _flashVisible = false;
            });
            _inputFocusNode.unfocus();
          }
          return;
        }
        if (nextSolvedCount < requiredWords && gateProvider != null) {
          await gateProvider.recordStepCompletion(
            wordId: word.id,
            targetApp: _currentApp,
            attempts: solvedAttempts,
          );
          _solvedWordIds.add(word.id);
          try {
            await vocabProvider?.init();
          } catch (error) {
            debugPrint('Could not refresh learning history: $error');
          }
          if (!mounted) return;
          setState(() {
            _solvedInRound = nextSolvedCount;
          });
          await _loadNextWord(force: true);
          return;
        }

        VocabularyWord? updated;
        if (gateProvider != null) {
          updated = await gateProvider.completeGateChallenge(
            wordId: word.id,
            targetApp: _currentApp,
            attempts: solvedAttempts,
          );
          try {
            await vocabProvider?.init();
          } catch (error) {
            debugPrint('Could not refresh learning history: $error');
          }
        } else if (vocabProvider != null) {
          updated = await vocabProvider.recordGateCompletion(
            wordId: word.id,
            targetApp: _currentApp,
            attempts: solvedAttempts,
          );
        }

        if (!mounted) return;
        setState(() {
          if (updated != null) _currentWord = updated;
          _attempts = solvedAttempts;
          _solvedInRound = 0;
          _unlocked = true;
          _flashVisible = false;
          _challengeError = null;
          _completedNativeWord = _isNativeTarget ? _currentWord : null;
        });
        _inputFocusNode.unfocus();
        _watchAccessExpiry();
        if (gateProvider?.lastError != null && mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(gateProvider!.lastError!)));
          gateProvider.consumeError();
        }

        // Automatically open the target app (e.g. Facebook, Instagram) right
        // after completing the challenge when not in Settings preview mode.
        if (!widget.previewMode && !_isNativeTarget && gateProvider != null) {
          final launched = await gateProvider.launchTargetApp(_currentApp);
          if (launched && mounted) {
            Navigator.of(context).maybePop(true);
          }
        }
      } on PlatformException catch (error) {
        if (mounted) {
          setState(
            () => _solvedInRound =
                gateProvider?.progressForApp(_currentApp) ?? _solvedInRound,
          );
          if (gateProvider?.pendingAnswerForApp(_currentApp) != null) {
            _inputFocusNode.unfocus();
          }
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                error.message ?? 'Could not unlock this app. Please try again.',
              ),
            ),
          );
          if (error.code == 'WORD_REMOVED' ||
              error.code == 'WORD_ALREADY_SOLVED' ||
              error.code == 'WORD_OUTSIDE_POOL') {
            await gateProvider?.prepareChallenge();
            _solvedInRound = gateProvider?.progressForApp(_currentApp) ?? 0;
            await _loadNextWord();
          }
        }
      } catch (error) {
        if (mounted) {
          setState(
            () => _challengeError =
                'Your answer could not be saved. Please try again.',
          );
        }
      } finally {
        if (mounted) setState(() => _submitting = false);
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
    _autoSpeak(word.word);
  }

  void _peekAgain() {
    _inputController.clear();
    setState(() {
      _flashVisible = true;
    });
  }

  Future<void> _openAddWordEditor() async {
    final vocabProvider = _maybeReadVocabProvider(context);
    await vocabProvider?.goToToday();
    if (!mounted) return;
    await Navigator.of(context).push(
      PageRouteBuilder<void>(
        pageBuilder: (_, _, _) => const WordEditorScreen(),
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
      ),
    );
    if (!mounted) return;
    await _maybeReadGateProvider(context)?.prepareChallenge();
    if (!mounted) return;
    if (_currentWord == null) {
      await _loadNextWord();
    } else {
      setState(() {});
    }
    _scheduleAnswerKeyboard();
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

    final baseConfig = gateProvider?.config ?? const GateConfig();
    final config = _isNativeTarget
        ? baseConfig.copyWith(
            passDurationMinutes: gateProvider?.nativeStatus.passMinutes ?? 15,
          )
        : baseConfig;
    final requiredWords = gateProvider?.requiredWords ?? config.wordsPerUnlock;
    final showUnlocked = _isNativeTarget && !widget.previewMode
        ? gateProvider?.unlockedUntilFor(_currentApp) != null
        : _unlocked;

    return Scaffold(
      backgroundColor: palette.paper,
      body: SafeArea(
        child: Column(
          children: [
            _GateStatusBar(
              targetApp: _displayApp,
              unlocked: showUnlocked,
              preview: widget.previewMode,
              passBadgeLabel: _passBadgeLabel(config),
              stepBadgeLabel: requiredWords > 1 && !showUnlocked
                  ? 'WORD ${(_solvedInRound + 1).clamp(1, requiredWords)}/$requiredWords'
                  : null,
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
                            _solvedInRound = 0;
                            _solvedWordIds.clear();
                          });
                          _loadNextWord();
                        },
                      ),
                      const SizedBox(height: PixelMetrics.space4),
                    ],
                    if (widget.previewMode) ...[
                      const Text(
                        'Practice only. No app access or learning history will change.',
                      ),
                      const SizedBox(height: PixelMetrics.space3),
                    ],
                    if (_challengeError != null &&
                        _currentWord != null &&
                        !showUnlocked)
                      Text(
                        _challengeError!,
                        style: TextStyle(color: palette.danger),
                      ),
                    if (_loading)
                      const _GateMessageCard(
                        title: 'LOADING GATE QUEUE…',
                        body: 'Selecting 1 word from your notebook.',
                      )
                    else if (_isNativeTarget &&
                        !widget.previewMode &&
                        gateProvider?.nativeStatus.enabled != true)
                      _GateMessageCard(
                        title: 'PROTECTION NEEDS ATTENTION',
                        body:
                            'Screen Time protection is off or access was removed. Return to Veea Settings to restore protection.',
                        actionLabel: 'Back to Veea',
                        onAction: () => Navigator.of(context).maybePop(),
                      )
                    else if (_isNativeTarget &&
                        showUnlocked &&
                        !widget.previewMode)
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          NativeGateReturnHint(
                            showSystemReturnHint: !widget.openedFromVeea,
                            remainingAccess: _passBadgeLabel(
                              config,
                            ).replaceFirst(' PASS', ''),
                            onBackToVeea: Navigator.of(context).canPop()
                                ? () => Navigator.of(context).maybePop()
                                : null,
                          ),
                          if (_completedNativeWord != null) ...[
                            const SizedBox(height: PixelMetrics.space4),
                            _buildUnlockedBody(
                              context,
                              _completedNativeWord!,
                              config,
                            ),
                          ],
                        ],
                      )
                    else if (_challengeError != null && _currentWord == null)
                      _GateMessageCard(
                        title: 'NOTEBOOK UNAVAILABLE',
                        body: _challengeError!,
                        actionLabel: 'Try again',
                        onAction: () => _loadNextWord(),
                      )
                    else if (showUnlocked && _currentWord == null)
                      _GateMessageCard(
                        title: 'ACCESS IS ACTIVE',
                        body:
                            'Your earned access is still active. Return to your app using the app switcher.',
                        actionLabel: 'Done',
                        onAction: () => Navigator.of(context).maybePop(),
                      )
                    else if (_currentWord == null &&
                        gateProvider != null &&
                        gateProvider.config.practiceWordIds != null)
                      _GateMessageCard(
                        title: 'CHOOSE YOUR PRACTICE WORDS',
                        body:
                            'Your selected practice words are no longer available. Choose words from your notebook to continue.',
                        actionLabel: 'Choose words',
                        onAction: () async {
                          final provider = gateProvider;
                          if (provider == null) return;
                          try {
                            if (await choosePracticeWords(context, provider)) {
                              if (!mounted) return;
                              _solvedInRound = provider.progressForApp(
                                _currentApp,
                              );
                              _solvedWordIds
                                ..clear()
                                ..addAll(
                                  provider.solvedWordIdsForApp(_currentApp),
                                );
                              await _loadNextWord();
                            }
                          } catch (_) {
                            if (mounted) {
                              setState(
                                () => _challengeError =
                                    'Could not update your practice words. Please try again.',
                              );
                            }
                          }
                        },
                      )
                    else if (_currentWord == null)
                      _GateMessageCard(
                        title: 'NO WORDS IN NOTEBOOK',
                        body:
                            'Add at least ${GateConfig.minRequiredWords} words to your Veea notebook to activate App Gate.',
                        actionLabel: 'Add a word',
                        onAction: _openAddWordEditor,
                      )
                    else if (!showUnlocked &&
                        !widget.previewMode &&
                        _solvedInRound >= requiredWords)
                      _GateMessageCard(
                        title: 'YOUR PROGRESS IS SAVED',
                        body:
                            'You have completed this round. Claim access without repeating the words.',
                        actionLabel: 'Claim earned access',
                        onAction: () {
                          _inputController.text = _currentWord!.word;
                          _handleSubmit();
                        },
                      )
                    else if (!showUnlocked)
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
                Text(
                  mask,
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.5,
                    color: palette.ink,
                  ),
                ),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${word.word.length} letters',
                        style: theme.textTheme.labelSmall,
                      ),
                    ),
                    if (_attempts == 0)
                      IconButton(
                        tooltip: 'Hear it',
                        onPressed: () => _speak(word.word),
                        icon: const Icon(Icons.volume_up_outlined),
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
              onTap: _scheduleAnswerKeyboard,
              onTapAlwaysCalled: true,
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
            label: _submitting ? 'Saving…' : 'Unlock $_displayApp',
            glyph: PixelGlyph.shield,
            filled: true,
            expand: true,
            onPressed: _submitting ? null : _handleSubmit,
          ),
          const SizedBox(height: PixelMetrics.space3),

          // Stage status footer
          Text(
            _attempts == 0
                ? 'Type the English word. Hints appear if you need them.'
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
                  widget.previewMode
                      ? 'PRACTICE COMPLETE'
                      : _isNativeTarget
                      ? 'WORD REVIEWED'
                      : _maybeReadGateProvider(
                              context,
                            )?.unlockedUntilFor(_currentApp) !=
                            null
                      ? 'ACCESS ACTIVE · ${_passBadgeLabel(config).replaceFirst(' PASS', '')} LEFT'
                      : config.passActiveLabel.toUpperCase(),
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
            style: _isNativeTarget && !widget.previewMode
                ? theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  )
                : TextStyle(
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

          if (widget.previewMode)
            const Text(
              'Practice finished. Your apps and learning history have not changed.',
            ),
          if (!_isNativeTarget || widget.previewMode) ...[
            PixelButton(
              label: _isNativeTarget || widget.previewMode
                  ? 'Done'
                  : 'Continue to $_displayApp',
              glyph: PixelGlyph.check,
              filled: true,
              expand: true,
              onPressed: () async {
                final gateProvider = _maybeReadGateProvider(context);
                if (!_isNativeTarget && !widget.previewMode) {
                  final launched = await gateProvider?.launchTargetApp(
                    _currentApp,
                  );
                  if (launched != true && context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          'Could not return to your app. Try again, or reopen it from Home.',
                        ),
                      ),
                    );
                    return;
                  }
                }
                if (context.mounted) {
                  Navigator.of(context).maybePop(true);
                }
              },
            ),
            const SizedBox(height: PixelMetrics.space2),
          ],

          PixelButton(
            label: widget.previewMode
                ? 'Practice again'
                : 'Lock again · Next word',
            glyph: PixelGlyph.repeat,
            expand: true,
            onPressed: () async {
              final gateProvider = _maybeReadGateProvider(context);
              try {
                if (!widget.previewMode) {
                  await gateProvider?.revokePass(_currentApp);
                }
                _solvedWordIds.clear();
                _solvedInRound = 0;
                await _loadNextWord(force: true);
              } on PlatformException catch (error) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        error.message ??
                            'Could not lock this app. Please try again.',
                      ),
                    ),
                  );
                }
              }
            },
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
    if (word.displaySource != null) {
      return 'Captured $dayText · ${word.displaySource}';
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
    this.stepBadgeLabel,
    this.preview = false,
  });

  final String targetApp;
  final bool unlocked;
  final String passBadgeLabel;
  final VoidCallback onClose;
  final String? stepBadgeLabel;
  final bool preview;

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
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Learn to unlock',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium,
                ),
                Wrap(
                  spacing: PixelMetrics.space2,
                  children: [
                    Text(
                      preview
                          ? 'Practice · $targetApp'
                          : unlocked
                          ? 'Unlocked · $passBadgeLabel'
                          : 'Locked · $targetApp',
                      style: theme.textTheme.bodySmall,
                    ),
                    if (stepBadgeLabel != null)
                      Text(
                        stepBadgeLabel!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: palette.accent,
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
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
