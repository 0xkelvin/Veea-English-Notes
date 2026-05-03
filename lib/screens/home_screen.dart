import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../core/l10n/app_strings.dart';
import '../core/theme/app_colors.dart';
import '../core/theme/app_theme.dart';
import '../providers/auth_provider.dart';
import '../providers/locale_provider.dart';
import '../providers/vocabulary_provider.dart';
import '../widgets/add_word_sheet.dart';
import '../widgets/date_selector.dart';
import '../widgets/empty_state.dart';
import '../widgets/stat_card.dart';
import '../widgets/word_card.dart';
import 'study_mode_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<VocabularyProvider>();
    final s = AppStrings(context.watch<LocaleProvider>().isVietnamese);
    final words = provider.wordsForSelectedDate;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Column(
          children: [
            // Fixed top section
            _buildHeader(context, provider, s),
            _buildStats(context, provider, s),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
              child: const DateSelector(),
            ),
            _buildSectionTitle(context, s),

            // Scrollable word list
            Expanded(
              child: words.isEmpty
                  ? const EmptyState()
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 100),
                      itemCount: words.length,
                      itemBuilder: (context, index) =>
                          WordCard(word: words[index]),
                    ),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showAddWord(context),
        elevation: 4,
        child: const Icon(Icons.add, size: 28),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, VocabularyProvider provider, AppStrings s) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              gradient: AppColors.accentGradient,
              borderRadius: BorderRadius.circular(AppTheme.radiusMd),
            ),
            child: const Icon(Icons.person, size: 24, color: Colors.white),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  s.helloLearner,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  s.keepUpWork,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppColors.mutedForeground,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          GestureDetector(
            onTap: () => _showSettings(context, s),
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.secondary,
                borderRadius: BorderRadius.circular(AppTheme.radiusMd),
              ),
              child: const Icon(
                Icons.settings_outlined,
                size: 20,
                color: AppColors.mutedForeground,
              ),
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: () async {
              await context.read<AuthProvider>().logout();
            },
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.secondary,
                borderRadius: BorderRadius.circular(AppTheme.radiusMd),
              ),
              child: const Icon(
                Icons.logout_rounded,
                size: 20,
                color: AppColors.mutedForeground,
              ),
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ChangeNotifierProvider.value(
                  value: context.read<VocabularyProvider>(),
                  child: const StudyModeScreen(),
                ),
              ),
            ),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                gradient: AppColors.primaryGradient,
                borderRadius: BorderRadius.circular(AppTheme.radiusMd),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.school_rounded, size: 18, color: Colors.white),
                  const SizedBox(width: 6),
                  Text(
                    s.vocabStudy,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStats(BuildContext context, VocabularyProvider provider, AppStrings s) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
          child: Row(
            children: [
              Expanded(
                child: StatCard(
                  icon: Icons.local_fire_department_rounded,
                  label: s.streak,
                  value: '${provider.streakDays}',
                  subtitle: provider.streakDays > 0 ? s.days : s.startToday,
                  iconGradient: AppColors.primaryGradient,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: StatCard(
                  icon: Icons.trending_up_rounded,
                  label: s.totalWords,
                  value: '${provider.totalWords}',
                  subtitle: '+${provider.wordsThisWeek} this week',
                  iconGradient: AppColors.accentGradient,
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
          child: Row(
            children: [
              Expanded(
                child: _buildDueChip(
                  context,
                  label: s.dueToday,
                  value: '${provider.wordsDueForReview.length}',
                  color: AppColors.primary,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildDueChip(
    BuildContext context, {
    required String label,
    required String value,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          Text(
            value,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  color: color,
                  fontWeight: FontWeight.bold,
                ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppColors.mutedForeground,
                    fontSize: 11,
                  ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionTitle(BuildContext context, AppStrings s) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
      child: Text(
        s.todaysWords,
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  void _showSettings(BuildContext context, AppStrings s) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return _SettingsSheet(s: s);
      },
    );
  }

  void _showAddWord(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ChangeNotifierProvider.value(
        value: context.read<VocabularyProvider>(),
        child: const AddWordSheet(),
      ),
    );
  }
}

// ── Settings Sheet ────────────────────────────────────────────────────────

class _SettingsSheet extends StatelessWidget {
  final AppStrings s;
  const _SettingsSheet({required this.s});

  @override
  Widget build(BuildContext context) {
    final locale = context.watch<LocaleProvider>();
    final isVi = locale.isVietnamese;

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 20),
          Text(
            s.settings,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
          ),
          const SizedBox(height: 20),
          Text(
            s.language,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: AppColors.mutedForeground,
                  letterSpacing: 1.2,
                ),
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: AppColors.secondary,
              borderRadius: BorderRadius.circular(AppTheme.radiusLg),
            ),
            child: Row(
              children: [
                _langTab(context, locale, label: s.languageEnglish, isVi: false, selected: !isVi),
                _langTab(context, locale, label: s.languageVietnamese, isVi: true, selected: isVi),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _langTab(
    BuildContext context,
    LocaleProvider locale, {
    required String label,
    required bool isVi,
    required bool selected,
  }) {
    return Expanded(
      child: GestureDetector(
        onTap: () => locale.setLocale(isVi),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: selected ? AppColors.card : Colors.transparent,
            borderRadius: BorderRadius.circular(AppTheme.radiusMd),
            border: selected
                ? Border.all(color: AppColors.border)
                : Border.all(color: Colors.transparent),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
              color: selected ? AppColors.foreground : AppColors.mutedForeground,
            ),
          ),
        ),
      ),
    );
  }
}
