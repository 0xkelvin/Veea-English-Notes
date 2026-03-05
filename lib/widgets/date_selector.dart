import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../core/theme/app_colors.dart';
import '../core/theme/app_theme.dart';
import '../providers/vocabulary_provider.dart';

class DateSelector extends StatelessWidget {
  const DateSelector({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<VocabularyProvider>();
    final selectedDate = provider.selectedDate;
    final now = DateTime.now();

    String dateLabel;
    if (_isSameDay(selectedDate, now)) {
      dateLabel = 'Today, ${DateFormat('MMM d').format(selectedDate)}';
    } else if (_isSameDay(selectedDate, now.subtract(const Duration(days: 1)))) {
      dateLabel = 'Yesterday, ${DateFormat('MMM d').format(selectedDate)}';
    } else if (_isSameDay(selectedDate, now.add(const Duration(days: 1)))) {
      dateLabel = 'Tomorrow, ${DateFormat('MMM d').format(selectedDate)}';
    } else {
      dateLabel = DateFormat('EEE, MMM d').format(selectedDate);
    }

    return Row(
      children: [
        _NavButton(
          icon: Icons.chevron_left,
          onTap: () => provider.selectDate(
            selectedDate.subtract(const Duration(days: 1)),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: GestureDetector(
            onTap: () => _showDatePicker(context, provider),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
              decoration: BoxDecoration(
                color: AppColors.secondary,
                borderRadius: BorderRadius.circular(AppTheme.radiusMd),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(
                    Icons.calendar_today,
                    size: 16,
                    color: AppColors.mutedForeground,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    dateLabel,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        _NavButton(
          icon: Icons.chevron_right,
          onTap: () => provider.selectDate(
            selectedDate.add(const Duration(days: 1)),
          ),
        ),
      ],
    );
  }

  Future<void> _showDatePicker(
    BuildContext context,
    VocabularyProvider provider,
  ) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: provider.selectedDate,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 365)),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.dark(
              primary: AppColors.primary,
              onPrimary: Colors.white,
              surface: AppColors.card,
              onSurface: Colors.white,
            ),
            dialogTheme: DialogThemeData(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppTheme.radiusXl),
              ),
            ),
          ),
          child: child!,
        );
      },
    );
    if (picked != null) {
      provider.selectDate(picked);
    }
  }

  bool _isSameDay(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }
}

class _NavButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;

  const _NavButton({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: AppColors.secondary,
          borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        ),
        child: Icon(icon, size: 20, color: AppColors.mutedForeground),
      ),
    );
  }
}
