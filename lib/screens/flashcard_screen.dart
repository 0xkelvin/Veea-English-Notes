import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../core/l10n/app_strings.dart';
import '../core/theme/app_colors.dart';
import '../core/theme/app_theme.dart';
import '../models/vocabulary_word.dart';
import '../providers/locale_provider.dart';
import '../providers/vocabulary_provider.dart';
import '../services/tts_service.dart';

class FlashcardScreen extends StatefulWidget {
  final List<VocabularyWord> words;

  const FlashcardScreen({super.key, required this.words});

  @override
  State<FlashcardScreen> createState() => _FlashcardScreenState();
}

class _FlashcardScreenState extends State<FlashcardScreen>
    with SingleTickerProviderStateMixin {
  late final List<VocabularyWord> _deck;
  int _index = 0;
  bool _isFlipped = false;
  int _reviewedCount = 0;
  late AppStrings _s;

  late final AnimationController _flipController;
  late final Animation<double> _flipAnimation;

  @override
  void initState() {
    super.initState();
    _deck = List.of(widget.words)..shuffle(math.Random());

    _flipController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );
    _flipAnimation = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _flipController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _flipController.dispose();
    super.dispose();
  }

  void _flip() {
    if (_flipController.isAnimating) return;
    if (!_isFlipped) {
      _flipController.forward();
      // Auto-play TTS when revealing the answer
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) context.read<TtsService>().speak(_deck[_index].word);
      });
    } else {
      _flipController.reverse();
    }
    setState(() => _isFlipped = !_isFlipped);
  }

  Future<void> _rate(int quality) async {
    final provider = context.read<VocabularyProvider>();
    await provider.applyReview(_deck[_index], quality);
    setState(() {
      _reviewedCount++;
      if (_index < _deck.length - 1) {
        _index++;
        _isFlipped = false;
        _flipController.reset();
      }
    });
  }

  bool get _isDone => _reviewedCount >= _deck.length;

  @override
  Widget build(BuildContext context) {
    _s = AppStrings(context.watch<LocaleProvider>().isVietnamese);
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(context),
            if (!_isDone) ...[
              _buildProgress(),
              const SizedBox(height: 20),
              Expanded(child: _buildCard()),
              _buildRatingButtons(),
              const SizedBox(height: 24),
            ] else
              Expanded(child: _buildSummary(context)),
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
              child: const Icon(Icons.arrow_back_ios_new_rounded,
                  size: 18, color: AppColors.foreground),
            ),
          ),
          const SizedBox(width: 16),
          Text(
            'Flashcard',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
          ),
          const Spacer(),
          if (!_isDone)
            Text(
              '${_index + 1} / ${_deck.length}',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: AppColors.mutedForeground,
                  ),
            ),
        ],
      ),
    );
  }

  Widget _buildProgress() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: LinearProgressIndicator(
          value: (_index) / _deck.length,
          minHeight: 5,
          backgroundColor: AppColors.secondary,
          valueColor: const AlwaysStoppedAnimation(AppColors.primary),
        ),
      ),
    );
  }

  Widget _buildCard() {
    return GestureDetector(
      onTap: _flip,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
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
                      child: _buildCardBack(_deck[_index]),
                    )
                  : _buildCardFront(_deck[_index]),
            );
          },
        ),
      ),
    );
  }

  Widget _buildCardFront(VocabularyWord word) {
    return _cardContainer(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(AppTheme.radiusSm),
            ),
            child: Text(
              'Tap to flip',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppColors.primary,
                    fontSize: 11,
                  ),
            ),
          ),
          const SizedBox(height: 24),
          Text(
            word.word,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.5,
                ),
          ),
          if (word.reviewCount > 0) ...[
            const SizedBox(height: 12),
            _buildSRBadge(word),
          ],
        ],
      ),
    );
  }

  Widget _buildCardBack(VocabularyWord word) {
    return _cardContainer(
      gradient: AppColors.accentGradient.colors.first.withValues(alpha: 0.05),
      child: SingleChildScrollView(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              word.word,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    color: AppColors.mutedForeground,
                  ),
            ),
            const SizedBox(height: 16),
            Container(
              height: 1,
              color: AppColors.border,
              margin: const EdgeInsets.symmetric(horizontal: 20),
            ),
            const SizedBox(height: 16),
            Text(
              word.vietnameseMeaning,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: AppColors.accent,
                  ),
            ),
            if (word.examples.isNotEmpty) ...[
              const SizedBox(height: 20),
              ...word.examples.map(
                (ex) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.secondary,
                      borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                    ),
                    child: Text(
                      '"$ex"',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: AppColors.mutedForeground,
                            fontStyle: FontStyle.italic,
                          ),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _cardContainer({required Widget child, Color? gradient}) {
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(minHeight: 300),
      padding: const EdgeInsets.all(28),
      decoration: BoxDecoration(
        color: gradient != null
            ? AppColors.card.withValues(alpha: 0.95)
            : AppColors.card,
        borderRadius: BorderRadius.circular(AppTheme.radiusXl),
        border: Border.all(color: AppColors.border),
      ),
      child: Center(child: child),
    );
  }

  Widget _buildSRBadge(VocabularyWord word) {
    return Text(
      _s.reviewStats(word.reviewCount, word.intervalDays),
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: AppColors.mutedForeground,
            fontSize: 11,
          ),
    );
  }

  Widget _buildRatingButtons() {
    if (!_isFlipped) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
        child: SizedBox(
          width: double.infinity,
          height: 48,
          child: OutlinedButton.icon(
            onPressed: _flip,
            icon: const Icon(Icons.flip_rounded, size: 18),
            label: Text(_s.showAnswer),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.foreground,
              side: BorderSide(color: AppColors.border),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppTheme.radiusLg),
              ),
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      child: Column(
        children: [
          Text(
            _s.howWellRemember,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: AppColors.mutedForeground,
                ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _ratingButton(_s.blackout, 0,
                  const Color(0xFFEF4444), const Color(0xFFDC2626)),
              const SizedBox(width: 8),
              _ratingButton(_s.hard, 1,
                  const Color(0xFFF59E0B), const Color(0xFFD97706)),
              const SizedBox(width: 8),
              _ratingButton(_s.good, 2,
                  const Color(0xFF10B981), const Color(0xFF059669)),
              const SizedBox(width: 8),
              _ratingButton(_s.easy, 3,
                  const Color(0xFF3B82F6), const Color(0xFF2563EB)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _ratingButton(
      String label, int quality, Color start, Color end) {
    return Expanded(
      child: GestureDetector(
        onTap: () => _rate(quality),
        child: Container(
          height: 52,
          decoration: BoxDecoration(
            gradient: LinearGradient(colors: [start, end]),
            borderRadius: BorderRadius.circular(AppTheme.radiusLg),
          ),
          child: Center(
            child: Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSummary(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                gradient: AppColors.primaryGradient,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.check_rounded,
                  color: Colors.white, size: 40),
            ),
            const SizedBox(height: 24),
            Text(
              _s.done,
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              _s.reviewedWords(_deck.length),
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: AppColors.mutedForeground,
                  ),
            ),
            const SizedBox(height: 40),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                onPressed: () => Navigator.pop(context),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppTheme.radiusLg),
                  ),
                ),
                child: Text(_s.backToStudy,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
