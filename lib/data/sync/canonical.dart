import 'dart:convert';
import 'dart:typed_data';

/// TRD 05 limits (§10.1). Field limits count Unicode code points.
abstract final class SyncLimits {
  static const maxLiveWords = 50000;
  static const maxItemBytes = 8192;
  static const maxContentBytes = 64 * 1024 * 1024;
  static const maxWord = 200;
  static const maxMeaning = 2000;
  static const maxPronunciation = 200;
  static const maxSource = 500;
  static const maxExamples = 20;
  static const maxExample = 500;
  static const maxTags = 30;
  static const maxTag = 50;
  static const maxMutations = 200;
  static const maxRequestBytes = 2 * 1024 * 1024;
}

/// The Flutter `PartOfSpeech` ids the server accepts.
const syncPartsOfSpeech = {'n', 'v', 'adj', 'adv', 'phr', 'idm', 'etc'};

/// The synced part of a word. Its canonical encoding is byte-identical to the
/// Go `learning.AppendCanonical`, so the client computes the same 8 KiB and
/// 64 MiB quantities the server enforces (TRD 05 §11.1).
class SyncContent {
  const SyncContent({
    required this.word,
    required this.meaning,
    this.pronunciation,
    this.partOfSpeech,
    this.source,
    this.examples = const [],
    this.tags = const [],
  });

  final String word;
  final String meaning;
  final String? pronunciation;
  final String? partOfSpeech;
  final String? source;
  final List<String> examples;
  final List<String> tags;

  factory SyncContent.fromJson(Map<String, Object?> json) => SyncContent(
    word: json['word']! as String,
    meaning: json['meaning']! as String,
    pronunciation: json['pronunciation'] as String?,
    partOfSpeech: json['part_of_speech'] as String?,
    source: json['source'] as String?,
    examples: (json['examples'] as List? ?? const []).cast<String>(),
    tags: (json['tags'] as List? ?? const []).cast<String>(),
  );

  Map<String, Object?> toJson() => {
    'word': word,
    'meaning': meaning,
    'pronunciation': pronunciation,
    'part_of_speech': partOfSpeech,
    'source': source,
    'examples': examples,
    'tags': tags,
  };

  @override
  bool operator ==(Object other) =>
      other is SyncContent &&
      other.word == word &&
      other.meaning == meaning &&
      other.pronunciation == pronunciation &&
      other.partOfSpeech == partOfSpeech &&
      other.source == source &&
      _listEq(other.examples, examples) &&
      _listEq(other.tags, tags);

  @override
  int get hashCode => Object.hash(
    word,
    meaning,
    pronunciation,
    partOfSpeech,
    source,
    Object.hashAll(examples),
    Object.hashAll(tags),
  );
}

bool _listEq(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Encodes [c] canonically: fixed key order, no whitespace, `null` for an
/// absent optional field, strings escaping only `"`, `\`, LF and TAB, every
/// other character as raw UTF-8.
Uint8List canonicalEncode(SyncContent c) {
  final b = BytesBuilder(copy: false);
  void raw(String s) => b.add(ascii.encode(s));
  raw('{"word":');
  _string(b, c.word);
  raw(',"meaning":');
  _string(b, c.meaning);
  raw(',"pronunciation":');
  _nullable(b, c.pronunciation);
  raw(',"part_of_speech":');
  _nullable(b, c.partOfSpeech);
  raw(',"source":');
  _nullable(b, c.source);
  raw(',"examples":');
  _list(b, c.examples);
  raw(',"tags":');
  _list(b, c.tags);
  raw('}');
  return b.takeBytes();
}

/// `canonicalEncode(c).length`.
int canonicalSize(SyncContent c) => canonicalEncode(c).length;

void _string(BytesBuilder b, String s) {
  b.addByte(0x22);
  for (final byte in utf8.encode(s)) {
    switch (byte) {
      case 0x22:
        b
          ..addByte(0x5c)
          ..addByte(0x22);
      case 0x5c:
        b
          ..addByte(0x5c)
          ..addByte(0x5c);
      case 0x0a:
        b
          ..addByte(0x5c)
          ..addByte(0x6e);
      case 0x09:
        b
          ..addByte(0x5c)
          ..addByte(0x74);
      default:
        b.addByte(byte);
    }
  }
  b.addByte(0x22);
}

void _nullable(BytesBuilder b, String? s) =>
    s == null ? b.add(ascii.encode('null')) : _string(b, s);

void _list(BytesBuilder b, List<String> l) {
  b.addByte(0x5b);
  for (var i = 0; i < l.length; i++) {
    if (i > 0) b.addByte(0x2c);
    _string(b, l[i]);
  }
  b.addByte(0x5d);
}

/// A per-item validation failure, matching the server's `invalid_item`
/// `detail` and `field`.
class SyncInvalid {
  const SyncInvalid(this.detail, [this.field]);
  final String detail;
  final String? field;

  @override
  String toString() => field == null ? detail : '$detail($field)';
}

/// Validates a word in the server's order (TRD 05 §10.1): UTF-8, control
/// characters, part of speech and dates, field limits, then the serialized
/// 8 KiB size. A Dart string cannot hold invalid UTF-8, but it can hold a lone
/// surrogate, which would not survive encoding; that is `invalid_utf8`.
SyncInvalid? validateSyncItem(
  SyncContent c, {
  required String captureDay,
  required String clientCreatedAt,
}) {
  final fields = <(String, String, int)>[
    ('word', c.word, SyncLimits.maxWord),
    ('meaning', c.meaning, SyncLimits.maxMeaning),
    if (c.pronunciation != null)
      ('pronunciation', c.pronunciation!, SyncLimits.maxPronunciation),
    if (c.partOfSpeech != null) ('part_of_speech', c.partOfSpeech!, 0),
    if (c.source != null) ('source', c.source!, SyncLimits.maxSource),
    for (final e in c.examples) ('examples', e, SyncLimits.maxExample),
    for (final t in c.tags) ('tags', t, SyncLimits.maxTag),
  ];
  for (final (_, value, _) in fields) {
    for (final r in value.runes) {
      if (r >= 0xD800 && r <= 0xDFFF) return const SyncInvalid('invalid_utf8');
    }
  }
  for (final (_, value, _) in fields) {
    for (final r in value.runes) {
      if (r < 0x20 && r != 0x09 && r != 0x0a) {
        return const SyncInvalid('control_character');
      }
    }
  }
  if (c.partOfSpeech != null && !syncPartsOfSpeech.contains(c.partOfSpeech)) {
    return const SyncInvalid('invalid_part_of_speech');
  }
  if (!_validDay(captureDay) || !_validInstant(clientCreatedAt)) {
    return const SyncInvalid('invalid_date');
  }
  if (c.word.runes.isEmpty) return const SyncInvalid('field_empty', 'word');
  if (c.examples.length > SyncLimits.maxExamples) {
    return const SyncInvalid('too_many_entries', 'examples');
  }
  if (c.tags.length > SyncLimits.maxTags) {
    return const SyncInvalid('too_many_entries', 'tags');
  }
  for (final (name, value, max) in fields) {
    if (max > 0 && value.runes.length > max) {
      return SyncInvalid('field_too_long', name);
    }
  }
  if (canonicalSize(c) > SyncLimits.maxItemBytes) {
    return const SyncInvalid('item_too_large');
  }
  return null;
}

final _day = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$');

bool _validDay(String s) {
  final m = _day.firstMatch(s);
  if (m == null) return false;
  final y = int.parse(m[1]!), mo = int.parse(m[2]!), d = int.parse(m[3]!);
  if (y < 1 || mo < 1 || mo > 12 || d < 1) return false;
  final t = DateTime.utc(y, mo, d);
  return t.year == y && t.month == mo && t.day == d;
}

bool _validInstant(String s) {
  // RFC 3339 with a mandatory offset, as Go's time.RFC3339Nano requires.
  if (!RegExp(
    r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$',
  ).hasMatch(s)) {
    return false;
  }
  // DateTime.parse normalizes invalid calendar dates and 24:00. Go refuses
  // those, so validate the local components before applying the offset.
  if (!_validDay(s.substring(0, 10)) ||
      int.parse(s.substring(11, 13)) > 23 ||
      int.parse(s.substring(14, 16)) > 59 ||
      int.parse(s.substring(17, 19)) > 59) {
    return false;
  }
  final t = DateTime.tryParse(s);
  if (t == null) return false;
  final y = t.toUtc().year;
  return y >= 1 && y <= 9999;
}
