import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';
import '../models/vocabulary_word.dart';
import '../services/storage_service.dart';

class VocabularyProvider extends ChangeNotifier {
  final StorageService _storage;
  final _uuid = const Uuid();

  List<VocabularyWord> _words = [];
  DateTime _selectedDate = DateTime.now();
  bool _isLoaded = false;

  VocabularyProvider(this._storage);

  bool get isLoaded => _isLoaded;
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
    List<String> examples = const [],
  }) async {
    final newWord = VocabularyWord(
      id: _uuid.v4(),
      word: word.trim(),
      vietnameseMeaning: vietnameseMeaning.trim(),
      examples: examples
          .where((e) => e.trim().isNotEmpty)
          .map((e) => e.trim())
          .toList(),
      date: selectedDateKey,
    );
    _words.add(newWord);
    notifyListeners();
    await _storage.insertWord(newWord);
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
}
