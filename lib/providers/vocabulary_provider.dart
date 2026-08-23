import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../data/vocabulary_repository.dart';
import '../models/part_of_speech.dart';
import '../models/vocabulary_stats.dart';
import '../models/vocabulary_word.dart';
import '../services/widget_service.dart';

enum LoadStatus { loading, ready, failed }

/// Presentation state for the vocabulary journal.
///
/// Every mutation writes to the repository first and then re-reads the
/// affected view, so what is on screen always reflects what is on disk. The
/// previous implementation mutated its in-memory list before awaiting the
/// write, which left memory and disk out of step whenever a write failed.
class VocabularyProvider extends ChangeNotifier {
  VocabularyProvider(this._repository, {DateTime Function()? now, Uuid? uuid})
    : _now = now ?? DateTime.now,
      _uuid = uuid ?? const Uuid() {
    _selectedDate = _dayOnly(_now());
  }

  final VocabularyRepository _repository;
  final DateTime Function() _now;
  final Uuid _uuid;

  LoadStatus _status = LoadStatus.loading;
  List<VocabularyWord> _words = const [];
  VocabularyStats _stats = VocabularyStats.empty;
  Set<String> _markedDates = const {};
  late DateTime _selectedDate;
  String? _lastError;
  String? _undoableDeletionId;
  bool _isDisposed = false;

  @override
  void dispose() {
    _isDisposed = true;
    super.dispose();
  }

  @override
  void notifyListeners() {
    if (_isDisposed) return;
    super.notifyListeners();
  }

  LoadStatus get status => _status;
  bool get isLoading => _status == LoadStatus.loading;

  /// Words for [selectedDate], newest first.
  List<VocabularyWord> get words => _words;

  VocabularyStats get stats => _stats;

  DateTime get selectedDate => _selectedDate;

  String get selectedDateKey => dateKey(_selectedDate);

  /// Days holding at least one word, so the date bar can mark them.
  Set<String> get markedDates => _markedDates;

  bool get isToday => dateKey(_selectedDate) == dateKey(_now());

  /// Message for the last failed operation, cleared once shown.
  String? get lastError => _lastError;

  /// Id of the word just deleted, while the undo affordance is live.
  String? get undoableDeletionId => _undoableDeletionId;

  Future<void> init() async {
    _status = LoadStatus.loading;
    notifyListeners();
    await _refresh(initialLoad: true);
  }

  /// Switches the visible day and reloads it.
  ///
  /// Returns the reload future so tests (and any caller that needs to wait)
  /// can await it; the UI calls this without awaiting.
  Future<void> selectDate(DateTime date) {
    final day = _dayOnly(date);
    if (dateKey(day) == dateKey(_selectedDate)) return Future.value();
    _selectedDate = day;
    _undoableDeletionId = null;
    notifyListeners();
    return _refresh();
  }

  Future<void> goToPreviousDay() =>
      selectDate(_selectedDate.subtract(const Duration(days: 1)));

  Future<void> goToNextDay() =>
      selectDate(_selectedDate.add(const Duration(days: 1)));

  Future<void> goToToday() => selectDate(_now());

  Future<void> addWord({
    required String word,
    required String meaning,
    String? pronunciation,
    PartOfSpeech? partOfSpeech,
    String? source,
    List<String> examples = const [],
    List<String> tags = const [],
  }) {
    return _mutate('Could not save the word', () async {
      await _repository.insert(
        VocabularyWord.create(
          id: _uuid.v4(),
          word: word,
          meaning: meaning,
          date: selectedDateKey,
          now: _now(),
          pronunciation: pronunciation,
          partOfSpeech: partOfSpeech,
          source: source,
          examples: examples,
          tags: tags,
        ),
      );
    });
  }

  Future<void> updateWord(
    VocabularyWord original, {
    required String word,
    required String meaning,
    String? pronunciation,
    PartOfSpeech? partOfSpeech,
    String? source,
    List<String> examples = const [],
    List<String> tags = const [],
  }) {
    return _mutate('Could not update the word', () async {
      await _repository.update(
        original.edited(
          word: word,
          meaning: meaning,
          now: _now(),
          pronunciation: pronunciation,
          partOfSpeech: partOfSpeech,
          source: source,
          examples: examples,
          tags: tags,
        ),
      );
    });
  }

  Future<void> deleteWord(String id) {
    return _mutate('Could not delete the word', () async {
      await _repository.softDelete(id, _now());
      _undoableDeletionId = id;
    });
  }

  Future<void> undoDelete() {
    final id = _undoableDeletionId;
    if (id == null) return Future.value();
    return _mutate('Could not restore the word', () async {
      await _repository.restore(id, _now());
      _undoableDeletionId = null;
    });
  }

  void dismissUndo() {
    if (_undoableDeletionId == null) return;
    _undoableDeletionId = null;
    notifyListeners();
  }

  Future<List<VocabularyWord>> search(String query) async {
    try {
      return await _repository.search(query);
    } catch (error, stack) {
      debugPrint('Search failed: $error\n$stack');
      return const [];
    }
  }

  void consumeError() {
    if (_lastError == null) return;
    _lastError = null;
    notifyListeners();
  }

  /// Runs a write, then reloads. On failure the screen is left untouched and
  /// [lastError] is set for the UI to surface.
  Future<void> _mutate(
    String failureMessage,
    Future<void> Function() action,
  ) async {
    try {
      await action();
      _lastError = null;
      await _refresh();
    } catch (error, stack) {
      debugPrint('$failureMessage: $error\n$stack');
      _lastError = failureMessage;
      notifyListeners();
    }
  }

  Future<void> _refresh({bool initialLoad = false}) async {
    try {
      final results = await Future.wait([
        _repository.wordsForDate(selectedDateKey),
        _repository.stats(),
        _repository.datesWithWords(),
      ]);
      _words = results[0] as List<VocabularyWord>;
      _stats = results[1] as VocabularyStats;
      _markedDates = results[2] as Set<String>;
      _status = LoadStatus.ready;

      if (_words.isNotEmpty) {
        WidgetService.updateWidgetWords(
          words: _words,
          streakDays: _stats.streakDays,
        );
      }
    } catch (error, stack) {
      debugPrint('Failed to load vocabulary: $error\n$stack');
      if (initialLoad) _status = LoadStatus.failed;
      _lastError = 'Could not load your words';
    }
    notifyListeners();
  }

  static DateTime _dayOnly(DateTime value) =>
      DateTime(value.year, value.month, value.day);

  /// Formats a date as the `YYYY-MM-DD` key used throughout storage.
  static String dateKey(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';
}
