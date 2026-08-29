import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/pet_companion.dart';

/// Presentation state for the 8-bit Virtual Pet Companion ("Veea-chi").
class PetProvider extends ChangeNotifier {
  static const _storageKey = 'veea_pet_companion_data';

  PetCompanion _pet = const PetCompanion();
  String _currentSpeech = 'Feed me vocabulary! ✨';
  bool _isDisposed = false;

  PetCompanion get pet => _pet;
  String get currentSpeech => _currentSpeech;

  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonStr = prefs.getString(_storageKey);
      if (jsonStr != null && jsonStr.isNotEmpty) {
        final Map<String, dynamic> data = jsonDecode(jsonStr);
        _pet = PetCompanion.fromJson(data);

        // Reset words fed today if date changed
        final todayKey = _todayKey();
        if (_pet.lastFedDateKey != todayKey) {
          _pet = _pet.copyWith(
            wordsFedToday: 0,
            lastFedDateKey: todayKey,
          );
        }
      }
    } catch (e) {
      debugPrint('Could not load pet data: $e');
    }
    _notify();
  }

  Future<void> feedWord(String word) async {
    final todayKey = _todayKey();
    final newXp = _pet.xp + 15;
    final newFedCount = _pet.wordsFedToday + 1;
    final prevLevel = _pet.level;

    _pet = _pet.copyWith(
      xp: newXp,
      wordsFedToday: newFedCount,
      lastFedDateKey: todayKey,
    );

    if (_pet.level > prevLevel) {
      _currentSpeech = '🎉 LEVEL UP! Now Lv. ${_pet.level} (${_pet.stage.displayName})!';
    } else {
      _currentSpeech = 'Yum! "$word" +15 XP! ✨';
    }

    await _save();
    _notify();
  }

  Future<void> petTouch() async {
    _pet = _pet.copyWith(xp: _pet.xp + 2);
    _currentSpeech = '❤️ *Happy 8-bit purr* (+2 XP)';
    await _save();
    _notify();
  }

  Future<void> rename(String newName) async {
    if (newName.trim().isEmpty) return;
    _pet = _pet.copyWith(name: newName.trim().toUpperCase());
    _currentSpeech = 'My name is ${_pet.name}! 👾';
    await _save();
    _notify();
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_storageKey, jsonEncode(_pet.toJson()));
    } catch (e) {
      debugPrint('Could not save pet data: $e');
    }
  }

  static String _todayKey() {
    final now = DateTime.now();
    return '${now.year}-${now.month}-${now.day}';
  }

  void _notify() {
    if (!_isDisposed) notifyListeners();
  }

  @override
  void dispose() {
    _isDisposed = true;
    super.dispose();
  }
}
