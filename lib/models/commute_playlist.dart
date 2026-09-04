import 'dart:convert';

/// A user-created custom cassette playlist for hands-free Commute audio playback.
class CommutePlaylist {
  const CommutePlaylist({
    required this.id,
    required this.name,
    required this.wordIds,
    required this.createdAt,
  });

  final String id;
  final String name;
  final List<String> wordIds;
  final DateTime createdAt;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'wordIds': wordIds,
    'createdAt': createdAt.toIso8601String(),
  };

  factory CommutePlaylist.fromJson(Map<String, dynamic> json) => CommutePlaylist(
    id: json['id'] as String,
    name: json['name'] as String,
    wordIds: (json['wordIds'] as List<dynamic>?)
            ?.map((e) => e.toString())
            .toList() ??
        const [],
    createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
        DateTime.now(),
  );

  CommutePlaylist copyWith({
    String? id,
    String? name,
    List<String>? wordIds,
    DateTime? createdAt,
  }) {
    return CommutePlaylist(
      id: id ?? this.id,
      name: name ?? this.name,
      wordIds: wordIds ?? this.wordIds,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  static String encodeList(List<CommutePlaylist> list) =>
      jsonEncode(list.map((p) => p.toJson()).toList());

  static List<CommutePlaylist> decodeList(String jsonString) {
    if (jsonString.isEmpty) return const [];
    try {
      final decoded = jsonDecode(jsonString) as List<dynamic>;
      return decoded
          .map((e) => CommutePlaylist.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return const [];
    }
  }
}
