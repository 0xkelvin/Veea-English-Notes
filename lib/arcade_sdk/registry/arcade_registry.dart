import '../contracts/arcade_game_manifest.dart';

/// Central registry managing and discovering all Arcade Mini-Games.
class ArcadeRegistry {
  static final List<ArcadeGameManifest> _games = [];
  static bool _initialized = false;

  /// Returns an unmodifiable list of all registered games.
  static List<ArcadeGameManifest> get allGames => List.unmodifiable(_games);

  /// Returns official core games authored by the core Veea team.
  static List<ArcadeGameManifest> get officialGames =>
      _games.where((g) => g.author == '@veea_team').toList();

  /// Returns community-contributed games.
  static List<ArcadeGameManifest> get communityGames =>
      _games.where((g) => g.author != '@veea_team').toList();

  /// Registers a new game into the Arcade Center.
  static void register(ArcadeGameManifest manifest) {
    final existingIndex = _games.indexWhere((g) => g.id == manifest.id);
    if (existingIndex >= 0) {
      _games[existingIndex] = manifest;
    } else {
      _games.add(manifest);
    }
  }

  /// Registers a batch of games.
  static void registerAll(List<ArcadeGameManifest> manifests) {
    for (final manifest in manifests) {
      register(manifest);
    }
  }

  /// Clears the registry (useful for unit testing).
  static void reset() {
    _games.clear();
    _initialized = false;
  }

  /// Finds a game by its unique ID.
  static ArcadeGameManifest? findById(String id) {
    try {
      return _games.firstWhere((g) => g.id == id);
    } catch (_) {
      return null;
    }
  }

  /// Marks registry as initialized.
  static void markInitialized() {
    _initialized = true;
  }

  /// Whether the registry has been initialized.
  static bool get isInitialized => _initialized;
}
