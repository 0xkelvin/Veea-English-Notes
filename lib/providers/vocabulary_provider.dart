import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import '../models/vocabulary_word.dart';
import '../providers/auth_provider.dart';
import '../services/vocabulary_api_service.dart';

class VocabularyProvider extends ChangeNotifier {
  final VocabularyApiService _api;
  final AuthProvider _auth;

  List<VocabularyWord> _words = [];
  DateTime _selectedDate = DateTime.now();
  bool _isLoaded = false;
  String? _error;

  VocabularyProvider(this._api, this._auth);

  bool get isLoaded => _isLoaded;
  String? get error => _error;
  List<VocabularyWord> get allWords => List.unmodifiable(_words);
  DateTime get selectedDate => _selectedDate;
  String get selectedDateKey => DateFormat('yyyy-MM-dd').format(_selectedDate);

  List<VocabularyWord> get wordsForSelectedDate =>
      _words.where((w) => w.date == selectedDateKey).toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

  int get totalWords => _words.length;

  int get streakDays {
    if (_words.isEmpty) return 0;
    final dates = _words.map((w) => w.date).toSet().toList()..sort();
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

  /// Words due for review today (never reviewed OR nextReviewDate <= today).
  List<VocabularyWord> get wordsDueForReview {
    final today = DateFormat('yyyy-MM-dd').format(DateTime.now());
    return _words
        .where((w) =>
            w.nextReviewDate == null ||
            w.nextReviewDate!.compareTo(today) <= 0)
        .toList();
  }

  String? get _token => _auth.accessToken;

  Future<void> init() async {
    if (_token == null) return;
    try {
      _words = await _api.fetchAll(_token!);
      _isLoaded = true;
      _error = null;
    } catch (e) {
      _error = e.toString();
      _isLoaded = true;
    }
    notifyListeners();
  }

  void selectDate(DateTime date) {
    _selectedDate = date;
    notifyListeners();
  }

  Future<void> addWord({
    required String word,
    required String vietnameseMeaning,
    String? phonetic,
    List<String> examples = const [],
  }) async {
    if (_token == null) return;
    final created = await _api.create(
      accessToken: _token!,
      word: word.trim(),
      vietnameseMeaning: vietnameseMeaning.trim(),
      phonetic: phonetic?.trim(),
      examples: examples
          .where((e) => e.trim().isNotEmpty)
          .map((e) => e.trim())
          .toList(),
      date: selectedDateKey,
    );
    _words.add(created);
    notifyListeners();
  }

  Future<void> deleteWord(String id) async {
    if (_token == null) return;
    await _api.delete(accessToken: _token!, id: id);
    _words.removeWhere((w) => w.id == id);
    notifyListeners();
  }

  Future<void> updateWord(VocabularyWord updated) async {
    if (_token == null) return;
    final result = await _api.update(
      accessToken: _token!,
      id: updated.id,
      word: updated.word,
      vietnameseMeaning: updated.vietnameseMeaning,
      phonetic: updated.phonetic,
      examples: updated.examples,
      date: updated.date,
    );
    final index = _words.indexWhere((w) => w.id == result.id);
    if (index != -1) {
      _words[index] = result;
      notifyListeners();
    }
  }

  /// Apply SM-2 review via cloud API.
  Future<void> applyReview(VocabularyWord word, int quality) async {
    if (_token == null) return;
    final updated = await _api.applyReview(
      accessToken: _token!,
      id: word.id,
      quality: quality.clamp(0, 3),
    );
    final index = _words.indexWhere((w) => w.id == updated.id);
    if (index != -1) {
      _words[index] = updated;
      notifyListeners();
    }
  }
}

