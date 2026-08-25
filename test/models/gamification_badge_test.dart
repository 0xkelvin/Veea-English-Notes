import 'package:flutter_test/flutter_test.dart';
import 'package:veea_english_app/models/gamification_badge.dart';

void main() {
  group('GamificationBadge and Stats Evaluation', () {
    test('badges calculate unlocked status and progress accurately', () {
      const stats = GamificationStats(
        totalWords: 15,
        currentStreak: 4,
        maxStreak: 7,
        totalReviews: 2,
        uniqueTagsCount: 5,
        maxWordsInDay: 6,
        dailyCounts: {'2026-08-18': 6},
      );

      final badges = stats.badges;
      expect(badges.length, equals(11));

      // FIRST_WORD (target 1) -> Unlocked
      final firstWord = badges.firstWhere((b) => b.id == 'FIRST_WORD');
      expect(firstWord.isUnlocked, isTrue);
      expect(firstWord.progress, equals(1.0));
      expect(firstWord.percentage, equals(100));

      // SCHOLAR_10 (target 10) -> Unlocked
      final scholar1 = badges.firstWhere((b) => b.id == 'SCHOLAR_10');
      expect(scholar1.isUnlocked, isTrue);

      // SCHOLAR_50 (target 50, current 15) -> In Progress (30%)
      final scholar2 = badges.firstWhere((b) => b.id == 'SCHOLAR_50');
      expect(scholar2.isUnlocked, isFalse);
      expect(scholar2.progress, equals(0.3));
      expect(scholar2.percentage, equals(30));

      // STREAK_7 (target 7, maxStreak 7) -> Unlocked
      final streak7 = badges.firstWhere((b) => b.id == 'STREAK_7');
      expect(streak7.isUnlocked, isTrue);

      // FIRST_REVIEW (target 1, current 2) -> Unlocked
      final firstReview = badges.firstWhere((b) => b.id == 'FIRST_REVIEW');
      expect(firstReview.isUnlocked, isTrue);

      // TAGS_5 (target 5, current 5) -> Unlocked
      final tags5 = badges.firstWhere((b) => b.id == 'TAGS_5');
      expect(tags5.isUnlocked, isTrue);

      // DAILY_SURGE (target 5, current 6) -> Unlocked
      final surge = badges.firstWhere((b) => b.id == 'DAILY_SURGE');
      expect(surge.isUnlocked, isTrue);
    });

    test('empty stats produces all locked badges with 0% progress', () {
      final badges = GamificationStats.empty.badges;
      for (final badge in badges) {
        expect(badge.isUnlocked, isFalse);
        expect(badge.progress, equals(0.0));
        expect(badge.percentage, equals(0));
      }
    });
  });
}
