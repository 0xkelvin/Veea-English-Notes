import '../widgets/pixel/pixel_icon.dart';

/// Aggregate statistics used to power the Activity Heatmap and Milestones.
class GamificationStats {
  const GamificationStats({
    required this.totalWords,
    required this.currentStreak,
    required this.maxStreak,
    required this.totalReviews,
    required this.uniqueTagsCount,
    required this.maxWordsInDay,
    required this.dailyCounts,
  });

  static const empty = GamificationStats(
    totalWords: 0,
    currentStreak: 0,
    maxStreak: 0,
    totalReviews: 0,
    uniqueTagsCount: 0,
    maxWordsInDay: 0,
    dailyCounts: {},
  );

  final int totalWords;
  final int currentStreak;
  final int maxStreak;
  final int totalReviews;
  final int uniqueTagsCount;
  final int maxWordsInDay;

  /// Map of `YYYY-MM-DD` -> words logged on that day.
  final Map<String, int> dailyCounts;

  /// Evaluates all milestones against the current stats.
  List<GamificationBadge> get badges => [
    GamificationBadge(
      id: 'FIRST_WORD',
      title: 'FIRST STEP',
      description: 'Capture your 1st vocabulary word',
      category: 'COLLECTION',
      target: 1,
      currentValue: totalWords,
      iconGlyph: PixelGlyph.pencil,
    ),
    GamificationBadge(
      id: 'SCHOLAR_10',
      title: 'SCHOLAR I',
      description: 'Build a 10-word personal vocabulary',
      category: 'COLLECTION',
      target: 10,
      currentValue: totalWords,
      iconGlyph: PixelGlyph.cards,
    ),
    GamificationBadge(
      id: 'SCHOLAR_50',
      title: 'SCHOLAR II',
      description: 'Reach 50 vocabulary words',
      category: 'COLLECTION',
      target: 50,
      currentValue: totalWords,
      iconGlyph: PixelGlyph.trophy,
    ),
    GamificationBadge(
      id: 'LEXICON_200',
      title: 'LEXICON MASTER',
      description: 'Reach 200 vocabulary words',
      category: 'COLLECTION',
      target: 200,
      currentValue: totalWords,
      iconGlyph: PixelGlyph.star,
    ),
    GamificationBadge(
      id: 'STREAK_3',
      title: 'IGNITION',
      description: 'Maintain a 3-day capture streak',
      category: 'STREAK',
      target: 3,
      currentValue: maxStreak,
      iconGlyph: PixelGlyph.flame,
    ),
    GamificationBadge(
      id: 'STREAK_7',
      title: 'WEEK WARRIOR',
      description: 'Achieve a 7-day capture streak',
      category: 'STREAK',
      target: 7,
      currentValue: maxStreak,
      iconGlyph: PixelGlyph.flame,
    ),
    GamificationBadge(
      id: 'STREAK_30',
      title: 'INFERNO',
      description: 'Achieve a 30-day capture streak',
      category: 'STREAK',
      target: 30,
      currentValue: maxStreak,
      iconGlyph: PixelGlyph.flame,
    ),
    GamificationBadge(
      id: 'FIRST_REVIEW',
      title: 'BATTLE READY',
      description: 'Complete your 1st SM-2 spaced review',
      category: 'MASTERY',
      target: 1,
      currentValue: totalReviews,
      iconGlyph: PixelGlyph.sword,
    ),
    GamificationBadge(
      id: 'REVIEWS_50',
      title: 'SRS WARRIOR',
      description: 'Complete 50 spaced repetition reviews',
      category: 'MASTERY',
      target: 50,
      currentValue: totalReviews,
      iconGlyph: PixelGlyph.sword,
    ),
    GamificationBadge(
      id: 'TAGS_5',
      title: 'POLYGLOT EXPLORER',
      description: 'Use 5 unique tags across your vocabulary',
      category: 'EXPLORATION',
      target: 5,
      currentValue: uniqueTagsCount,
      iconGlyph: PixelGlyph.search,
    ),
    GamificationBadge(
      id: 'DAILY_SURGE',
      title: 'DAILY SURGE',
      description: 'Capture 5 or more words in a single day',
      category: 'EXPLORATION',
      target: 5,
      currentValue: maxWordsInDay,
      iconGlyph: PixelGlyph.plus,
    ),
  ];
}

/// A retro 8-bit achievement milestone.
class GamificationBadge {
  const GamificationBadge({
    required this.id,
    required this.title,
    required this.description,
    required this.category,
    required this.target,
    required this.currentValue,
    required this.iconGlyph,
  });

  final String id;
  final String title;
  final String description;
  final String category;
  final int target;
  final int currentValue;
  final PixelGlyph iconGlyph;

  bool get isUnlocked => currentValue >= target;

  double get progress => (currentValue / target).clamp(0.0, 1.0);

  int get percentage => (progress * 100).round();
}
