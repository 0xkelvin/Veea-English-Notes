import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../core/l10n/app_strings.dart';
import '../core/theme/app_colors.dart';
import '../core/theme/app_theme.dart';
import '../models/vocabulary_word.dart';
import '../providers/locale_provider.dart';
import '../providers/vocabulary_provider.dart';
import '../services/tts_service.dart';

class WordStudyScreen extends StatefulWidget {
  final VocabularyWord word;

  const WordStudyScreen({super.key, required this.word});

  @override
  State<WordStudyScreen> createState() => _WordStudyScreenState();
}

class _WordStudyScreenState extends State<WordStudyScreen>
    with SingleTickerProviderStateMixin {
  // 0 = Flashcard, 1 = Type It, 2 = Pronunciation
  int _step = 0;
  late AppStrings _s;

  // Flashcard state
  bool _isFlipped = false;
  late final AnimationController _flipController;
  late final Animation<double> _flipAnimation;

  // Type step state
  final _typeController = TextEditingController();
  bool _typeChecked = false;
  bool _typeCorrect = false;

  static const _stepTitlesEn = ['Flashcard', 'Type It', 'Pronunciation'];
  static const _stepTitlesVi = ['Flashcard', 'Gõ từ', 'Phát âm'];

  @override
  void initState() {
    super.initState();
    _flipController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );
    _flipAnimation = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _flipController, curve: Curves.easeInOut),
    );
    // Auto-play TTS on open
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<TtsService>().speak(widget.word.word);
    });
  }

  @override
  void dispose() {
    _flipController.dispose();
    _typeController.dispose();
    super.dispose();
  }

  void _flip() {
    if (_flipController.isAnimating) return;
    if (!_isFlipped) {
      _flipController.forward();
    } else {
      _flipController.reverse();
    }
    setState(() => _isFlipped = !_isFlipped);
  }

  /// "Got it" — show 4 difficulty levels for SM-2 rating
  void _showRatingPicker() {
    HapticFeedback.lightImpact();
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => _RatingSheet(
        onRated: (quality) async {
          await context.read<VocabularyProvider>().applyReview(widget.word, quality);
          if (mounted) Navigator.pop(context);
        },
      ),
    );
  }

  /// "Học tiếp" — go to next step (or close on last)
  void _nextStep() {
    HapticFeedback.selectionClick();
    if (_step < 2) {
      setState(() {
        _step++;
        _isFlipped = false;
        _flipController.reset();
        _typeController.clear();
        _typeChecked = false;
        _typeCorrect = false;
      });
      // Auto-speak on pronunciation step
      if (_step == 2) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) context.read<TtsService>().speak(widget.word.word);
        });
      }
    } else {
      Navigator.pop(context);
    }
  }

  void _checkType() {
    final typed = _typeController.text.trim().toLowerCase();
    final correct = widget.word.word.trim().toLowerCase();
    setState(() {
      _typeChecked = true;
      _typeCorrect = typed == correct;
    });
    HapticFeedback.lightImpact();
  }

  @override
  Widget build(BuildContext context) {
    _s = AppStrings(context.watch<LocaleProvider>().isVietnamese);
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(context),
            _buildStepBar(),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: _buildCurrentStep(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => Navigator.pop(context),
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.secondary,
                borderRadius: BorderRadius.circular(AppTheme.radiusMd),
              ),
              child: const Icon(Icons.close, size: 18, color: AppColors.foreground),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Text(
              (_s.vi ? _stepTitlesVi : _stepTitlesEn)[_step],
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
          ),
          Text(
            _s.stepTitle(_step + 1),
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: AppColors.mutedForeground,
                ),
          ),
        ],
      ),
    );
  }

  Widget _buildStepBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
      child: Row(
        children: List.generate(3, (i) {
          return Expanded(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              height: 4,
              margin: EdgeInsets.only(right: i < 2 ? 6 : 0),
              decoration: BoxDecoration(
                color: i <= _step ? AppColors.primary : AppColors.secondary,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          );
        }),
      ),
    );
  }

  Widget _buildCurrentStep() {
    switch (_step) {
      case 0:
        return _buildFlashcardStep();
      case 1:
        return _buildTypeStep();
      case 2:
        return _buildPronunciationStep();
      default:
        return const SizedBox.shrink();
    }
  }

  // ── Step 1: Flashcard ─────────────────────────────────────────────────────

  Widget _buildFlashcardStep() {
    return Column(
      children: [
        const SizedBox(height: 20),
        Expanded(
          child: GestureDetector(
            onTap: _flip,
            child: AnimatedBuilder(
              animation: _flipAnimation,
              builder: (context, child) {
                final angle = _flipAnimation.value * math.pi;
                final showBack = angle > math.pi / 2;
                return Transform(
                  alignment: Alignment.center,
                  transform: Matrix4.identity()
                    ..setEntry(3, 2, 0.001)
                    ..rotateY(angle),
                  child: showBack
                      ? Transform(
                          alignment: Alignment.center,
                          transform: Matrix4.identity()..rotateY(math.pi),
                          child: _buildCardBack(),
                        )
                      : _buildCardFront(),
                );
              },
            ),
          ),
        ),
        const SizedBox(height: 16),
        if (!_isFlipped)
          SizedBox(
            width: double.infinity,
            height: 52,
            child: OutlinedButton.icon(
              onPressed: _flip,
              icon: const Icon(Icons.flip_rounded, size: 18),
              label: Text(_s.tapToRevealMeaning),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.foreground,
                side: BorderSide(color: AppColors.border),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppTheme.radiusLg),
                ),
              ),
            ),
          )
        else
          _buildActionButtons(),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _buildCardFront() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(28),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(AppTheme.radiusXl),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // TTS button
          Builder(builder: (ctx) {
            final tts = ctx.watch<TtsService>();
            final speaking =
                tts.isSpeaking && tts.currentWord == widget.word.word;
            return GestureDetector(
              onTap: () => ctx.read<TtsService>().speak(widget.word.word),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: speaking
                      ? AppColors.primary.withValues(alpha: 0.15)
                      : AppColors.secondary,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  speaking
                      ? Icons.graphic_eq_rounded
                      : Icons.volume_up_rounded,
                  color:
                      speaking ? AppColors.primary : AppColors.mutedForeground,
                  size: 24,
                ),
              ),
            );
          }),
          const SizedBox(height: 24),
          Text(
            widget.word.word,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.5,
                ),
          ),
          if (widget.word.phonetic != null &&
              widget.word.phonetic!.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              widget.word.phonetic!,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: AppColors.mutedForeground,
                    fontStyle: FontStyle.italic,
                  ),
            ),
          ],
          const SizedBox(height: 28),
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(AppTheme.radiusSm),
            ),
            child: Text(
              _s.tapToReveal,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppColors.primary.withValues(alpha: 0.7),
                    fontSize: 12,
                  ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCardBack() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(AppTheme.radiusXl),
        border: Border.all(color: AppColors.accent.withValues(alpha: 0.4)),
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(height: 8),
            Text(
              widget.word.word,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    color: AppColors.mutedForeground,
                  ),
            ),
            const SizedBox(height: 16),
            Container(height: 1, color: AppColors.border),
            const SizedBox(height: 16),
            Text(
              widget.word.vietnameseMeaning,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: AppColors.accent,
                  ),
            ),
            if (widget.word.examples.isNotEmpty) ...[
              const SizedBox(height: 20),
              ...widget.word.examples.map(
                (ex) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.secondary,
                      borderRadius:
                          BorderRadius.circular(AppTheme.radiusMd),
                    ),
                    child: Text(
                      '"$ex"',
                      textAlign: TextAlign.center,
                      style:
                          Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: AppColors.mutedForeground,
                                fontStyle: FontStyle.italic,
                                height: 1.4,
                              ),
                    ),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  // ── Step 2: Gõ từ ────────────────────────────────────────────────────────

  Widget _buildTypeStep() {
    return SingleChildScrollView(
      child: Column(
        children: [
          const SizedBox(height: 20),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: [
                AppColors.accent.withValues(alpha: 0.15),
                AppColors.primary.withValues(alpha: 0.08),
              ]),
              borderRadius: BorderRadius.circular(AppTheme.radiusXl),
              border: Border.all(
                  color: AppColors.accent.withValues(alpha: 0.3)),
            ),
            child: Text(
              widget.word.vietnameseMeaning,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
          ),
          const SizedBox(height: 24),
          Text(
            _s.typeEnglishWord,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: AppColors.mutedForeground,
                ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _typeController,
            autofocus: true,
            enabled: !_typeChecked,
            onSubmitted: (_) {
              if (!_typeChecked) _checkType();
            },
            style: TextStyle(
              color: _typeChecked
                  ? (_typeCorrect
                      ? const Color(0xFF10B981)
                      : const Color(0xFFEF4444))
                  : AppColors.foreground,
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
            textAlign: TextAlign.center,
            decoration: InputDecoration(
              hintText: _s.typeHint,
              filled: true,
              fillColor: AppColors.secondary,
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                borderSide: BorderSide(color: AppColors.border),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                borderSide:
                    const BorderSide(color: AppColors.primary, width: 2),
              ),
              disabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                borderSide: BorderSide(
                  color: _typeChecked
                      ? (_typeCorrect
                          ? const Color(0xFF10B981)
                          : const Color(0xFFEF4444))
                      : AppColors.border,
                  width: 2,
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (_typeChecked) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _typeCorrect
                    ? const Color(0xFF10B981).withValues(alpha: 0.1)
                    : const Color(0xFFEF4444).withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                border: Border.all(
                  color: _typeCorrect
                      ? const Color(0xFF10B981).withValues(alpha: 0.35)
                      : const Color(0xFFEF4444).withValues(alpha: 0.35),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    _typeCorrect
                        ? Icons.check_circle_outline
                        : Icons.cancel_outlined,
                    color: _typeCorrect
                        ? const Color(0xFF10B981)
                        : const Color(0xFFEF4444),
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _typeCorrect
                          ? _s.correctAnswer
                          : _s.answerIs(widget.word.word),
                      style: TextStyle(
                        color: _typeCorrect
                            ? const Color(0xFF10B981)
                            : const Color(0xFFEF4444),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            _buildActionButtons(),
          ] else ...[
            SizedBox(
              width: double.infinity,
              height: 52,
              child: ElevatedButton(
                onPressed: _checkType,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  shape: RoundedRectangleBorder(
                    borderRadius:
                        BorderRadius.circular(AppTheme.radiusLg),
                  ),
                ),
                child: Text(
                  _s.check,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                  ),
                ),
              ),
            ),
          ],
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  // ── Step 3: Phát âm ───────────────────────────────────────────────────────

  Widget _buildPronunciationStep() {
    return Column(
      children: [
        const SizedBox(height: 20),
        Expanded(
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(28),
            decoration: BoxDecoration(
              color: AppColors.card,
              borderRadius: BorderRadius.circular(AppTheme.radiusXl),
              border: Border.all(color: AppColors.border),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  _s.pronunciation,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: AppColors.mutedForeground,
                        letterSpacing: 2.5,
                      ),
                ),
                const SizedBox(height: 20),
                Text(
                  widget.word.word,
                  textAlign: TextAlign.center,
                  style:
                      Theme.of(context).textTheme.headlineMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                            letterSpacing: 0.5,
                          ),
                ),
                if (widget.word.phonetic != null &&
                    widget.word.phonetic!.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    widget.word.phonetic!,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: AppColors.mutedForeground,
                          fontStyle: FontStyle.italic,
                        ),
                  ),
                ],
                const SizedBox(height: 12),
                Text(
                  widget.word.vietnameseMeaning,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: AppColors.accent,
                        fontWeight: FontWeight.w500,
                      ),
                ),
                const SizedBox(height: 36),
                // TTS play button
                Builder(builder: (ctx) {
                  final tts = ctx.watch<TtsService>();
                  final speaking =
                      tts.isSpeaking && tts.currentWord == widget.word.word;
                  return GestureDetector(
                    onTap: () =>
                        ctx.read<TtsService>().speak(widget.word.word),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      width: 84,
                      height: 84,
                      decoration: BoxDecoration(
                        gradient: AppColors.primaryGradient,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.primary
                                .withValues(alpha: speaking ? 0.5 : 0.25),
                            blurRadius: speaking ? 24 : 10,
                            spreadRadius: speaking ? 4 : 0,
                          ),
                        ],
                      ),
                      child: Icon(
                        speaking
                            ? Icons.graphic_eq_rounded
                            : Icons.volume_up_rounded,
                        color: Colors.white,
                        size: 34,
                      ),
                    ),
                  );
                }),
                const SizedBox(height: 14),
                Text(
                  _s.tapToListen,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: AppColors.mutedForeground,
                      ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        _buildActionButtons(),
        const SizedBox(height: 24),
      ],
    );
  }

  // ── Shared action buttons ─────────────────────────────────────────────────

  Widget _buildActionButtons() {
    final isLastStep = _step == 2;
    return Row(
      children: [
        Expanded(
          child: GestureDetector(
            onTap: _showRatingPicker,
            child: Container(
              height: 52,
              decoration: BoxDecoration(
                color: const Color(0xFF10B981).withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(AppTheme.radiusLg),
                border: Border.all(
                    color:
                        const Color(0xFF10B981).withValues(alpha: 0.35)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.check_circle_outline,
                      size: 18, color: Color(0xFF10B981)),
                  SizedBox(width: 6),
                  Text(
                    _s.gotIt,
                    style: TextStyle(
                      color: Color(0xFF10B981),
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: GestureDetector(
            onTap: _nextStep,
            child: Container(
              height: 52,
              decoration: BoxDecoration(
                gradient: AppColors.primaryGradient,
                borderRadius: BorderRadius.circular(AppTheme.radiusLg),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    isLastStep ? _s.finish : _s.continueStudy,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                  if (!isLastStep) ...[
                    const SizedBox(width: 6),
                    const Icon(Icons.arrow_forward_rounded,
                        size: 18, color: Colors.white),
                  ],
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ── Rating bottom sheet ────────────────────────────────────────────────────

class _RatingSheet extends StatelessWidget {
  final void Function(int quality) onRated;

  const _RatingSheet({required this.onRated});

  @override
  Widget build(BuildContext context) {
    final s = AppStrings(context.watch<LocaleProvider>().isVietnamese);
    final levels = [
      _RatingLevel(quality: 0, label: s.blackout, description: s.blackoutDesc,
          color: const Color(0xFFEF4444), icon: Icons.sentiment_very_dissatisfied_rounded),
      _RatingLevel(quality: 1, label: s.hard, description: s.hardDesc,
          color: const Color(0xFFF97316), icon: Icons.sentiment_dissatisfied_rounded),
      _RatingLevel(quality: 2, label: s.good, description: s.goodDesc,
          color: const Color(0xFFEAB308), icon: Icons.sentiment_neutral_rounded),
      _RatingLevel(quality: 3, label: s.easy, description: s.easyDesc,
          color: const Color(0xFF10B981), icon: Icons.sentiment_very_satisfied_rounded),
    ];

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: AppColors.border,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 20),
          Text(
            s.howWellRemember,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
          ),
          const SizedBox(height: 4),
          Text(
            s.ratingSubtitle,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: AppColors.mutedForeground,
                ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 20),
          ...levels.map(
            (level) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: GestureDetector(
                onTap: () {
                  Navigator.pop(context);
                  onRated(level.quality);
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 14),
                  decoration: BoxDecoration(
                    color: level.color.withValues(alpha: 0.08),
                    borderRadius:
                        BorderRadius.circular(AppTheme.radiusLg),
                    border: Border.all(
                        color: level.color.withValues(alpha: 0.3)),
                  ),
                  child: Row(
                    children: [
                      Icon(level.icon, color: level.color, size: 24),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              level.label,
                              style: TextStyle(
                                color: level.color,
                                fontWeight: FontWeight.w700,
                                fontSize: 15,
                              ),
                            ),
                            Text(
                              level.description,
                              style:
                                  Theme.of(context).textTheme.bodySmall?.copyWith(
                                        color: AppColors.mutedForeground,
                                        fontSize: 12,
                                      ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RatingLevel {
  final int quality;
  final String label;
  final String description;
  final Color color;
  final IconData icon;

  const _RatingLevel({
    required this.quality,
    required this.label,
    required this.description,
    required this.color,
    required this.icon,
  });
}
