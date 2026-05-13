import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../core/theme/app_colors.dart';
import '../core/theme/app_theme.dart';
import '../models/vocabulary_word.dart';
import '../providers/vocabulary_provider.dart';
import '../widgets/add_word_sheet.dart';
import '../widgets/date_selector.dart';
import '../widgets/empty_state.dart';
import '../widgets/stat_card.dart';
import '../widgets/word_card.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<VocabularyProvider>();
    final words = provider.wordsForSelectedDate;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Column(
          children: [
            // Fixed top section
            _buildHeader(context, provider),
            _buildStats(context, provider),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
              child: const DateSelector(),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
              child: _buildDailyReview(context, provider),
            ),
            _buildSectionTitle(context),

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

  Widget _buildHeader(BuildContext context, VocabularyProvider provider) {
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
                  'Hello, Learner',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  'Keep up the good work!',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppColors.mutedForeground,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          GestureDetector(
            onTap: () {
              // TODO: settings
            },
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
        ],
      ),
    );
  }

  Widget _buildStats(BuildContext context, VocabularyProvider provider) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
      child: Row(
        children: [
          Expanded(
            child: StatCard(
              icon: Icons.local_fire_department_rounded,
              label: 'Streak',
              value: '${provider.streakDays}',
              subtitle: provider.streakDays > 0 ? 'days' : 'Start today!',
              iconGradient: AppColors.primaryGradient,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: StatCard(
              icon: Icons.trending_up_rounded,
              label: 'Total Words',
              value: '${provider.totalWords}',
              subtitle: '+${provider.wordsThisWeek} this week',
              iconGradient: AppColors.accentGradient,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionTitle(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
      child: Text(
        "Today's Words",
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _buildDailyReview(BuildContext context, VocabularyProvider provider) {
    final dueWords = provider.dueWords;
    if (dueWords.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.secondary,
          borderRadius: BorderRadius.circular(AppTheme.radiusMd),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          children: [
            Icon(Icons.check_circle_outline, color: AppColors.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Daily review complete. Great consistency!',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: AppColors.mutedForeground,
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Daily Review (${dueWords.length})',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),
          ...dueWords.take(3).map((word) => _buildDueWordRow(context, provider, word)),
        ],
      ),
    );
  }

  Widget _buildDueWordRow(
    BuildContext context,
    VocabularyProvider provider,
    VocabularyWord word,
  ) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '${word.word} • ${word.masteryLevel.label}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          TextButton(
            onPressed: () => provider.markWordReviewed(word.id),
            child: const Text('Review'),
          ),
          PopupMenuButton<MasteryLevel>(
            tooltip: 'Set mastery',
            onSelected: (value) => provider.setMasteryLevel(word.id, value),
            itemBuilder: (_) => MasteryLevel.values
                .map(
                  (level) => PopupMenuItem(
                    value: level,
                    child: Text(level.label),
                  ),
                )
                .toList(),
            icon: const Icon(Icons.flag_outlined, size: 18),
          ),
        ],
      ),
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
