import '../../models/vocabulary_word.dart';
import 'api_client.dart';

/// Result of one `POST /vocabulary/sync` round trip.
class SyncResult {
  const SyncResult({
    required this.acceptedIds,
    required this.changes,
    required this.serverTime,
    required this.hasMore,
  });

  /// Ids the server stored. Anything pushed but missing here belongs to
  /// another account and must not be retried.
  final List<String> acceptedIds;

  /// Rows changed since the cursor, tombstones included.
  final List<VocabularyWord> changes;

  /// Cursor for the next pull. Persist only after [changes] is applied.
  final DateTime serverTime;

  /// Whether the server capped the page and another pull is due immediately.
  final bool hasMore;
}

/// Vocabulary endpoints.
class VocabularyApi {
  const VocabularyApi(this._client);

  final ApiClient _client;

  /// Pushes [changes] and pulls everything changed after [since].
  ///
  /// Both halves share one request so no write can land in the gap between
  /// them.
  Future<SyncResult> sync({
    required List<VocabularyWord> changes,
    DateTime? since,
  }) async {
    final data = await _client.post(
      '/vocabulary/sync',
      body: {
        'changes': changes.map((w) => w.toApiJson()).toList(),
        if (since != null) 'since': since.toUtc().toIso8601String(),
      },
    );

    final accepted = (data['accepted'] as List<Object?>? ?? const [])
        .map((id) => id.toString())
        .toList(growable: false);

    final remote = (data['changes'] as List<Object?>? ?? const [])
        .whereType<Map<String, Object?>>()
        .map(VocabularyWord.fromApiJson)
        .toList(growable: false);

    final serverTime = DateTime.tryParse(data['serverTime'] as String? ?? '');
    if (serverTime == null) {
      throw const ApiException('Sync response is missing serverTime');
    }

    return SyncResult(
      acceptedIds: accepted,
      changes: remote,
      serverTime: serverTime,
      hasMore: data['hasMore'] as bool? ?? false,
    );
  }
}
