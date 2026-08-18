/// Grammatical category of a captured word.
///
/// Stored in SQLite as the [id] string so the enum can be reordered freely
/// without breaking existing rows.
enum PartOfSpeech {
  noun('n', 'noun'),
  verb('v', 'verb'),
  adjective('adj', 'adjective'),
  adverb('adv', 'adverb'),
  phrase('phr', 'phrase'),
  idiom('idm', 'idiom'),
  other('etc', 'other');

  const PartOfSpeech(this.id, this.label);

  /// Stable identifier persisted to the database.
  final String id;

  /// Human-readable name shown in the UI.
  final String label;

  /// Short form rendered next to a word, e.g. `resilient · adj`.
  String get short => id;

  static PartOfSpeech? fromId(String? id) {
    if (id == null || id.isEmpty) return null;
    for (final value in PartOfSpeech.values) {
      if (value.id == id) return value;
    }
    return null;
  }
}
