import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/cartridges_data.dart';
import '../models/cartridge.dart';
import 'vocabulary_provider.dart';

enum IngestMode {
  full, // Imports all words immediately for today
  dailySprint, // Spreads 5 words per day into future dates
}

/// Manages career DLC cartridges and their installation into the user's notebook.
class CartridgeProvider extends ChangeNotifier {
  CartridgeProvider() {
    _loadState();
  }

  static const _kInstalledKey = 'veea_installed_cartridges';
  final Set<String> _installedIds = {};
  bool _initialized = false;

  bool get isInitialized => _initialized;

  bool isInstalled(String cartridgeId) => _installedIds.contains(cartridgeId);

  List<Cartridge> get availableCartridges => CartridgesData.allCartridges;

  Future<void> _loadState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = prefs.getStringList(_kInstalledKey) ?? [];
      _installedIds.addAll(list);
    } catch (_) {
      // Graceful fallback for test or mock environments
    }
    _initialized = true;
    notifyListeners();
  }

  /// Installs all words in a cartridge into the user's SQLite vocabulary notebook.
  Future<int> installCartridge(
    String cartridgeId, {
    required VocabularyProvider vocabProvider,
    IngestMode mode = IngestMode.full,
    DateTime? baseDate,
  }) async {
    final cartridge = CartridgesData.allCartridges.firstWhere(
      (c) => c.id == cartridgeId,
      orElse: () => CartridgesData.siliconValleyTech,
    );

    final now = baseDate ?? DateTime.now();
    final todayStr = DateFormat('yyyy-MM-dd').format(now);

    int installedCount = 0;

    for (var i = 0; i < cartridge.words.length; i++) {
      final cw = cartridge.words[i];

      String targetDateStr = todayStr;
      DateTime targetDateTime = now;

      if (mode == IngestMode.dailySprint) {
        final dayOffset = i ~/ 5; // 5 words per day
        targetDateTime = now.add(Duration(days: dayOffset));
        targetDateStr = DateFormat('yyyy-MM-dd').format(targetDateTime);
      }

      final vocabWord = cw.toVocabularyWord(
        date: targetDateStr,
        now: targetDateTime,
        cartridgeTitle: cartridge.title,
      );

      // Check if word is already present before inserting
      final exists = vocabProvider.words.any(
        (w) => w.word.toLowerCase() == cw.word.toLowerCase(),
      );

      if (!exists) {
        await vocabProvider.insertWord(vocabWord);
        installedCount++;
      }
    }

    _installedIds.add(cartridgeId);
    await _saveState();
    notifyListeners();

    return installedCount;
  }

  /// Uninstalls cartridge words from the user's notebook.
  Future<int> uninstallCartridge(
    String cartridgeId, {
    required VocabularyProvider vocabProvider,
  }) async {
    final cartridge = CartridgesData.allCartridges.firstWhere(
      (c) => c.id == cartridgeId,
      orElse: () => CartridgesData.siliconValleyTech,
    );

    int removedCount = 0;
    final cartridgeWordKeys =
        cartridge.words.map((w) => w.word.toLowerCase()).toSet();

    for (final w in vocabProvider.words.toList()) {
      if (cartridgeWordKeys.contains(w.word.toLowerCase()) &&
          w.tags.contains('tech-career')) {
        await vocabProvider.deleteWord(w.id);
        removedCount++;
      }
    }

    _installedIds.remove(cartridgeId);
    await _saveState();
    notifyListeners();

    return removedCount;
  }

  Future<void> _saveState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_kInstalledKey, _installedIds.toList());
    } catch (_) {}
  }
}
