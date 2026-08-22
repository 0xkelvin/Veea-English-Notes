/// Normalises text for local search.
///
/// SQLite's `LIKE` and `lower()` only fold ASCII, so `Kiên` would never match
/// a query of `kiên`. We therefore precompute a normalised haystack in Dart —
/// whose `toLowerCase` is Unicode-aware — and store it alongside each row.
///
/// The folded form additionally strips Vietnamese diacritics so that typing
/// `kien cuong` on a plain keyboard still finds `kiên cường`.
class TextNormalizer {
  TextNormalizer._();

  static const Map<String, String> _foldings = {
    'aàáạảãâầấậẩẫăằắặẳẵ': 'a',
    'eèéẹẻẽêềếệểễ': 'e',
    'iìíịỉĩ': 'i',
    'oòóọỏõôồốộổỗơờớợởỡ': 'o',
    'uùúụủũưừứựửữ': 'u',
    'yỳýỵỷỹ': 'y',
    'dđ': 'd',
  };

  static final Map<int, String> _charMap = {
    for (final entry in _foldings.entries)
      for (final rune in entry.key.runes) rune: entry.value,
  };

  /// Lowercases and strips Vietnamese diacritics.
  static String fold(String input) {
    final lower = input.toLowerCase();
    final buffer = StringBuffer();
    for (final rune in lower.runes) {
      final mapped = _charMap[rune];
      if (mapped != null) {
        buffer.write(mapped);
      } else {
        buffer.writeCharCode(rune);
      }
    }
    return buffer.toString();
  }

  /// Builds the value stored in the `search_text` column.
  ///
  /// Both the accented lowercase form and the folded form are kept so a query
  /// typed with diacritics still matches exactly, while one typed without them
  /// matches via the folded half.
  static String haystack(Iterable<String?> parts) {
    final joined = parts
        .where((p) => p != null && p.trim().isNotEmpty)
        .map((p) => p!.trim())
        .join(' ');
    final lower = joined.toLowerCase();
    final folded = fold(joined);
    return lower == folded ? lower : '$lower $folded';
  }

  /// Normalises a user's query to match against [haystack].
  static String query(String input) => fold(input).trim();
}
