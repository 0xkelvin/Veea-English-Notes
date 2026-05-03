import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../core/l10n/app_strings.dart';
import '../core/theme/app_colors.dart';
import '../core/theme/app_theme.dart';
import '../models/vocabulary_word.dart';
import '../providers/locale_provider.dart';
import '../providers/vocabulary_provider.dart';
import 'flashcard_screen.dart';
import 'quiz_screen.dart';

class StudyModeScreen extends StatefulWidget {
  const StudyModeScreen({super.key});

  @override
  State<StudyModeScreen> createState() => _StudyModeScreenState();
}

class _StudyModeScreenState extends State<StudyModeScreen> {
  bool _dueOnly = true;
  late AppStrings _s;

  List<VocabularyWord> _getWords(VocabularyProvider provider) {
    return _dueOnly ? provider.wordsDueForReview : provider.allWords;
  }

  @override
  Widget build(BuildContext context) {
    _s = AppStrings(context.watch<LocaleProvider>().isVietnamese);
    final provider = context.watch<VocabularyProvider>();
    final dueCount = provider.wordsDueForReview.length;
    final totalCount = provider.allWords.length;
    final words = _getWords(provider);

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildHeader(context),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildSummaryRow(context, dueCount, totalCount),
                    const SizedBox(height: 24),
                    _buildFilter(context),
                    const SizedBox(height: 28),
                    Text(
                      _s.chooseModeTitle,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                    const SizedBox(height: 16),
                    _buildModeCard(
                      context,
                      icon: Icons.style_rounded,
                      gradient: AppColors.primaryGradient,
                      title: _s.flashcard,
                      subtitle: _s.flashcardSubtitle,
                      wordCount: words.length,
                      onTap: words.isEmpty
                          ? null
                          : () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => FlashcardScreen(words: words),
                                ),
                              ),
                    ),
                    const SizedBox(height: 14),
                    _buildModeCard(
                      context,
                      icon: Icons.quiz_rounded,
                      gradient: AppColors.accentGradient,
                      title: _s.multipleChoice,
                      subtitle: _s.multipleChoiceSubtitle,
                      wordCount: words.length,
                      minWords: 4,
                      onTap: words.length < 4
                          ? null
                          : () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => QuizScreen(words: words),
                                ),
                              ),
                    ),
                    if (words.length < 4)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(
                          _s.needMoreWords,
                          style:
                              Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: AppColors.mutedForeground,
                                  ),
                        ),
                      ),
                  ],
                ),
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
              child: const Icon(
                Icons.arrow_back_ios_new_rounded,
                size: 18,
                color: AppColors.foreground,
              ),
            ),
          ),
          const SizedBox(width: 16),
          Text(
            _s.vocabStudy,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryRow(
      BuildContext context, int dueCount, int totalCount) {
    return Row(
      children: [
        Expanded(
          child: _buildStatChip(
            context,
            label: _s.dueToday,
            value: '$dueCount',
            color: AppColors.primary,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _buildStatChip(
            context,
            label: _s.totalWords,
            value: '$totalCount',
            color: AppColors.accent,
          ),
        ),
      ],
    );
  }

  Widget _buildStatChip(BuildContext context,
      {required String label,
      required String value,
      required Color color}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  color: color,
                  fontWeight: FontWeight.bold,
                ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: AppColors.mutedForeground,
                ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilter(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: AppColors.secondary,
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
      ),
      child: Row(
        children: [
          _buildFilterTab(_s.dueTodayFilter, _dueOnly, () {
            setState(() => _dueOnly = true);
          }),
          _buildFilterTab(_s.allWords, !_dueOnly, () {
            setState(() => _dueOnly = false);
          }),
        ],
      ),
    );
  }

  Widget _buildFilterTab(String label, bool active, VoidCallback onTap) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: active ? AppColors.card : Colors.transparent,
            borderRadius: BorderRadius.circular(AppTheme.radiusMd),
            border: active
                ? Border.all(color: AppColors.border)
                : Border.all(color: Colors.transparent),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              fontWeight: active ? FontWeight.w600 : FontWeight.normal,
              color: active ? AppColors.foreground : AppColors.mutedForeground,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildModeCard(
    BuildContext context, {
    required IconData icon,
    required LinearGradient gradient,
    required String title,
    required String subtitle,
    required int wordCount,
    int minWords = 1,
    required VoidCallback? onTap,
  }) {
    final disabled = onTap == null;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedOpacity(
        opacity: disabled ? 0.45 : 1.0,
        duration: const Duration(milliseconds: 200),
        child: Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(AppTheme.radiusXl),
            border: Border.all(color: AppColors.border),
          ),
          child: Row(
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  gradient: gradient,
                  borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                ),
                child: Icon(icon, color: Colors.white, size: 26),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: AppColors.mutedForeground,
                          ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '$wordCount',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                  Text(
                    _s.words,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: AppColors.mutedForeground,
                        ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
