import 'package:shared_preferences/shared_preferences.dart';
import '../models/vocabulary_word.dart';

class StorageService {
  static const String _wordsKey = 'vocabulary_words';

  final SharedPreferences _prefs;

  StorageService(this._prefs);

  List<VocabularyWord> loadWords() {
    final encoded = _prefs.getString(_wordsKey);
    if (encoded == null || encoded.isEmpty) return [];
    try {
      return VocabularyWord.decode(encoded);
    } catch (_) {
      return [];
    }
  }

  Future<void> saveWords(List<VocabularyWord> words) async {
    await _prefs.setString(_wordsKey, VocabularyWord.encode(words));
  }
}
