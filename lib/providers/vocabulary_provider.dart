import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';
import '../models/vocabulary_word.dart';
import '../services/ai_enrichment_service.dart';
import '../services/storage_service.dart';

class VocabularyProvider extends ChangeNotifier {
  final StorageService _storage;
  final AiEnrichmentService _aiEnrichmentService;
  final _uuid = const Uuid();

  List<VocabularyWord> _words = [];
  DateTime _selectedDate = DateTime.now();
  bool _isLoaded = false;

  VocabularyProvider(
    this._storage, {
    AiEnrichmentService? aiEnrichmentService,
  }) : _aiEnrichmentService = aiEnrichmentService ?? AiEnrichmentService();

  bool get isLoaded => _isLoaded;
  List<VocabularyWord> get allWords => List.unmodifiable(_words);
  DateTime get selectedDate => _selectedDate;
  String get selectedDateKey => DateFormat('yyyy-MM-dd').format(_selectedDate);

  List<VocabularyWord> get wordsForSelectedDate =>
      _words.where((w) => w.date == selectedDateKey).toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

  int get totalWords => _words.length;

  List<VocabularyWord> get dueWords {
    final now = DateTime.now();
    return _words.where((w) => !w.nextReviewAt.isAfter(now)).toList()
      ..sort((a, b) => a.nextReviewAt.compareTo(b.nextReviewAt));
  }

  int get streakDays {
    if (_words.isEmpty) return 0;

    final dates = _words.map((w) => w.date).toSet().toList()..sort();
    if (dates.isEmpty) return 0;

    final today = DateFormat('yyyy-MM-dd').format(DateTime.now());
    final yesterday = DateFormat('yyyy-MM-dd').format(
      DateTime.now().subtract(const Duration(days: 1)),
    );

    if (!dates.contains(today) && !dates.contains(yesterday)) return 0;

    int streak = 0;
    var checkDate = dates.contains(today)
        ? DateTime.now()
        : DateTime.now().subtract(const Duration(days: 1));

    while (true) {
      final key = DateFormat('yyyy-MM-dd').format(checkDate);
      if (dates.contains(key)) {
        streak++;
        checkDate = checkDate.subtract(const Duration(days: 1));
      } else {
        break;
      }
    }
    return streak;
  }

  int get wordsThisWeek {
    final now = DateTime.now();
    final weekStart = now.subtract(Duration(days: now.weekday - 1));
    final weekStartKey = DateFormat('yyyy-MM-dd').format(weekStart);
    return _words.where((w) => w.date.compareTo(weekStartKey) >= 0).length;
  }

  Future<void> init() async {
    await _storage.migrateFromSharedPreferences();
    _words = await _storage.loadWords();
    _isLoaded = true;
    notifyListeners();
  }

  void selectDate(DateTime date) {
    _selectedDate = date;
    notifyListeners();
  }

  Future<void> addWord({
    required String word,
    required String vietnameseMeaning,
    required String contextSentence,
    List<String> examples = const [],
  }) async {
    final newWord = VocabularyWord(
      id: _uuid.v4(),
      word: word.trim(),
      vietnameseMeaning: vietnameseMeaning.trim(),
      contextSentence: contextSentence.trim(),
      examples: examples
          .where((e) => e.trim().isNotEmpty)
          .map((e) => e.trim())
          .toList(),
      date: selectedDateKey,
    );
    _words.add(newWord);
    notifyListeners();
    await _storage.insertWord(newWord);

    try {
      final enrichment = await _aiEnrichmentService.enrichWord(
        word: newWord.word,
        contextSentence: newWord.contextSentence,
      );
      final enriched = newWord.copyWith(
        synonyms: enrichment.synonyms,
        antonyms: enrichment.antonyms,
        idioms: enrichment.idioms,
        phrases: enrichment.phrases,
        imageUrl: enrichment.imageUrl,
      );
      final index = _words.indexWhere((w) => w.id == newWord.id);
      if (index != -1) {
        _words[index] = enriched;
        notifyListeners();
        await _storage.updateWord(enriched);
      }
    } catch (_) {
      // Keep save flow resilient even when enrichment fails.
    }
  }

  Future<void> deleteWord(String id) async {
    _words.removeWhere((w) => w.id == id);
    notifyListeners();
    await _storage.deleteWord(id);
  }

  Future<void> updateWord(VocabularyWord updated) async {
    final index = _words.indexWhere((w) => w.id == updated.id);
    if (index != -1) {
      _words[index] = updated;
      notifyListeners();
      await _storage.updateWord(updated);
    }
  }

  Future<void> setMasteryLevel(String wordId, MasteryLevel masteryLevel) async {
    final index = _words.indexWhere((w) => w.id == wordId);
    if (index == -1) return;

    final current = _words[index];
    final updated = current.copyWith(
      masteryLevel: masteryLevel,
      nextReviewAt: _nextReviewDate(masteryLevel),
    );
    _words[index] = updated;
    notifyListeners();
    await _storage.updateWord(updated);
  }

  Future<void> markWordReviewed(String wordId) async {
    final index = _words.indexWhere((w) => w.id == wordId);
    if (index == -1) return;

    final now = DateTime.now();
    final current = _words[index];
    final nextMastery = current.masteryLevel.next;
    final updated = current.copyWith(
      masteryLevel: nextMastery,
      reviewCount: current.reviewCount + 1,
      lastReviewedAt: now,
      nextReviewAt: _nextReviewDate(nextMastery, reference: now),
    );
    _words[index] = updated;
    notifyListeners();
    await _storage.updateWord(updated);
  }

  DateTime _nextReviewDate(
    MasteryLevel masteryLevel, {
    DateTime? reference,
  }) {
    final from = reference ?? DateTime.now();
    final days = switch (masteryLevel) {
      MasteryLevel.newWord => 0,
      MasteryLevel.learning => 1,
      MasteryLevel.familiar => 3,
      MasteryLevel.mastered => 7,
    };
    return from.add(Duration(days: days));
  }
}
