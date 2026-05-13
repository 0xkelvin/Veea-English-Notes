import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../core/theme/app_colors.dart';
import '../core/theme/app_theme.dart';
import '../models/vocabulary_word.dart';
import '../providers/vocabulary_provider.dart';
import '../services/tts_service.dart';
import 'add_word_sheet.dart';

class WordCard extends StatelessWidget {
  static const Set<String> _trustedImageHosts = {
    'image.pollinations.ai',
  };

  final VocabularyWord word;

  const WordCard({super.key, required this.word});

  @override
  Widget build(BuildContext context) {
    final trustedImageUrl = _trustedImageUrl(word.imageUrl);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        border: Border.all(color: AppColors.border),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        word.word,
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                          fontSize: 18,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        word.vietnameseMeaning,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: AppColors.primary,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 8),
                      _MasteryBadge(level: word.masteryLevel),
                    ],
                  ),
                ),
                Builder(
                  builder: (context) {
                    final tts = context.watch<TtsService>();
                    final isSpeakingThis = tts.isSpeaking && tts.currentWord == word.word;
                    return _ActionButton(
                      icon: isSpeakingThis
                          ? Icons.graphic_eq_rounded
                          : Icons.volume_up_rounded,
                      onTap: () => context.read<TtsService>().speak(word.word),
                      color: isSpeakingThis
                          ? AppColors.primary.withValues(alpha: 0.2)
                          : null,
                      iconColor: isSpeakingThis ? AppColors.primary : null,
                    );
                  },
                ),
                const SizedBox(width: 8),
                _ActionButton(
                  icon: Icons.edit_outlined,
                  onTap: () => _showEdit(context),
                  color: AppColors.accent.withValues(alpha: 0.15),
                  iconColor: AppColors.accent,
                ),
                const SizedBox(width: 8),
                _ActionButton(
                  icon: Icons.delete_outline_rounded,
                  onTap: () => _confirmDelete(context),
                  color: AppColors.destructive.withValues(alpha: 0.15),
                  iconColor: AppColors.destructive,
                ),
              ],
            ),
            if (word.examples.isNotEmpty) ...[
              const SizedBox(height: 12),
              ...word.examples.map(
                (example) => Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.secondary,
                    borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                  ),
                  child: Text(
                    example,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppColors.mutedForeground,
                      fontStyle: FontStyle.italic,
                      height: 1.4,
                    ),
                  ),
                ),
              ),
            ],
            if (word.contextSentence.trim().isNotEmpty) ...[
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.secondary,
                  borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                ),
                child: Text(
                  '"${word.contextSentence}"',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppColors.foreground,
                    fontStyle: FontStyle.italic,
                    height: 1.4,
                  ),
                ),
              ),
            ],
            if (trustedImageUrl != null) ...[
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                child: Image.network(
                  trustedImageUrl,
                  height: 150,
                  width: double.infinity,
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stackTrace) => Container(
                    height: 80,
                    color: AppColors.secondary,
                    alignment: Alignment.center,
                    child: Text(
                      'Image unavailable',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: AppColors.mutedForeground,
                      ),
                    ),
                  ),
                ),
              ),
            ],
            _AiTagGroup(title: 'Synonyms', values: word.synonyms),
            _AiTagGroup(title: 'Antonyms', values: word.antonyms),
            _AiTagGroup(title: 'Idioms', values: word.idioms),
            _AiTagGroup(title: 'Phrases', values: word.phrases),
          ],
        ),
      ),
    );
  }

  String? _trustedImageUrl(String? value) {
    if (value == null || value.isEmpty) return null;
    final uri = Uri.tryParse(value);
    if (uri == null) return null;
    if (uri.scheme != 'https' || !_trustedImageHosts.contains(uri.host)) {
      return null;
    }
    return value;
  }

  void _showEdit(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ChangeNotifierProvider.value(
        value: context.read<VocabularyProvider>(),
        child: AddWordSheet(existingWord: word),
      ),
    );
  }

  void _confirmDelete(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.card,
        title: const Text('Delete Word'),
        content: Text('Remove "${word.word}" from your vocabulary?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(
              'Cancel',
              style: TextStyle(color: AppColors.mutedForeground),
            ),
          ),
          TextButton(
            onPressed: () {
              context.read<VocabularyProvider>().deleteWord(word.id);
              Navigator.of(ctx).pop();
            },
            child: const Text(
              'Delete',
              style: TextStyle(color: AppColors.destructive),
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final Color? color;
  final Color? iconColor;

  const _ActionButton({
    required this.icon,
    required this.onTap,
    this.color,
    this.iconColor,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: color ?? AppColors.secondary,
          borderRadius: BorderRadius.circular(AppTheme.radiusSm),
        ),
        child: Icon(
          icon,
          size: 18,
          color: iconColor ?? AppColors.mutedForeground,
        ),
      ),
    );
  }
}

class _AiTagGroup extends StatelessWidget {
  final String title;
  final List<String> values;

  const _AiTagGroup({
    required this.title,
    required this.values,
  });

  @override
  Widget build(BuildContext context) {
    if (values.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w600,
              color: AppColors.mutedForeground,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: values
                .map(
                  (value) => Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: AppColors.secondary,
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: AppColors.border),
                    ),
                    child: Text(
                      value,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                )
                .toList(),
          ),
        ],
      ),
    );
  }
}

class _MasteryBadge extends StatelessWidget {
  final MasteryLevel level;

  const _MasteryBadge({required this.level});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.accent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        level.label,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: AppColors.accent,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
