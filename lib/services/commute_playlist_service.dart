import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/commute_playlist.dart';
import '../models/vocabulary_word.dart';

class CommutePlaylistService extends ChangeNotifier {
  CommutePlaylistService({SharedPreferences? prefs}) : _prefs = prefs;

  SharedPreferences? _prefs;
  static const String _storageKey = 'veea_commute_playlists_v1';

  List<CommutePlaylist> _playlists = [];
  bool _initialized = false;

  List<CommutePlaylist> get playlists => List.unmodifiable(_playlists);
  bool get isInitialized => _initialized;

  Future<void> init() async {
    if (_initialized) return;
    _prefs ??= await SharedPreferences.getInstance();
    final jsonStr = _prefs?.getString(_storageKey) ?? '';
    _playlists = CommutePlaylist.decodeList(jsonStr).toList();
    _initialized = true;
    notifyListeners();
  }

  Future<void> _persist() async {
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs?.setString(_storageKey, CommutePlaylist.encodeList(_playlists));
    notifyListeners();
  }

  Future<CommutePlaylist> createPlaylist(String name, List<String> wordIds) async {
    final newPlaylist = CommutePlaylist(
      id: 'pl_${DateTime.now().millisecondsSinceEpoch}',
      name: name.trim().isEmpty ? 'Băng Cassette mới' : name.trim(),
      wordIds: wordIds,
      createdAt: DateTime.now(),
    );
    _playlists.insert(0, newPlaylist);
    await _persist();
    return newPlaylist;
  }

  Future<void> updatePlaylist(CommutePlaylist updated) async {
    final index = _playlists.indexWhere((p) => p.id == updated.id);
    if (index != -1) {
      _playlists[index] = updated;
      await _persist();
    }
  }

  Future<void> deletePlaylist(String id) async {
    _playlists.removeWhere((p) => p.id == id);
    await _persist();
  }

  /// Groups a given list of vocabulary words by their date key (`YYYY-MM-DD`).
  ///
  /// Sorted with the most recent dates first.
  static Map<String, List<VocabularyWord>> groupWordsByDate(
    List<VocabularyWord> words,
  ) {
    final map = <String, List<VocabularyWord>>{};
    for (final word in words) {
      map.putIfAbsent(word.date, () => []).add(word);
    }
    // Sort keys descending
    final sortedKeys = map.keys.toList()..sort((a, b) => b.compareTo(a));
    final sortedMap = <String, List<VocabularyWord>>{};
    for (final key in sortedKeys) {
      sortedMap[key] = map[key]!;
    }
    return sortedMap;
  }
}
