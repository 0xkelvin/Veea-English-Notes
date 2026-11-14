import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// A conclusive problem answer (RFC 9457) from the Go sync routes.
class SyncProblem implements Exception {
  const SyncProblem(
    this.status,
    this.code, {
    this.reason,
    this.epoch,
    this.liveWords,
    this.contentBytes,
    this.lastSeq,
  });

  final int status;
  final String code;

  /// `sync_reset_required` only: epoch_changed, writer_unknown, cursor_compacted, cursor_ahead.
  final String? reason;
  final String? epoch;

  /// `capacity_changed` only.
  final int? liveWords;
  final int? contentBytes;
  final int? lastSeq;

  bool get isReset => status == 410 && code == 'sync_reset_required';

  @override
  String toString() =>
      'SyncProblem($status $code${reason == null ? '' : ' $reason'})';
}

/// No conclusive answer arrived: a transport failure, a timeout or a 5xx. For
/// a push or import this is an **unknown outcome**: the request may have been
/// processed (TRD 05 §5.3).
class SyncUnknownOutcome implements Exception {
  const SyncUnknownOutcome(this.cause);
  final Object cause;
  @override
  String toString() => 'SyncUnknownOutcome($cause)';
}

class WriterState {
  const WriterState(this.writerId, this.lastSeq, this.active);
  final String writerId;
  final int lastSeq;
  final bool active;
}

class SyncState {
  const SyncState({
    required this.epoch,
    required this.headRevision,
    required this.tombstoneHorizon,
    required this.liveWords,
    required this.wordLimit,
    required this.contentBytes,
    required this.contentByteLimit,
    this.writer,
  });

  final String epoch;
  final int headRevision;
  final int tombstoneHorizon;
  final int liveWords;
  final int wordLimit;
  final int contentBytes;
  final int contentByteLimit;
  final WriterState? writer;

  factory SyncState.fromJson(Map<String, Object?> j) {
    final w = j['writer'] as Map<String, Object?>?;
    return SyncState(
      epoch: j['epoch']! as String,
      headRevision: j['head_revision']! as int,
      tombstoneHorizon: j['tombstone_horizon']! as int,
      liveWords: j['live_words']! as int,
      wordLimit: j['word_limit']! as int,
      contentBytes: j['content_bytes']! as int,
      contentByteLimit: j['content_byte_limit']! as int,
      writer: w == null
          ? null
          : WriterState(
              w['writer_id']! as String,
              w['last_seq']! as int,
              w['active']! as bool,
            ),
    );
  }
}

/// One mutation result. A duplicate carries its [originalOutcome].
class MutationResult {
  const MutationResult(this.json);
  final Map<String, Object?> json;

  int get seq => json['seq']! as int;
  String get entityId => json['entity_id']! as String;
  String get outcome => json['outcome']! as String;
  String? get originalOutcome => json['original_outcome'] as String?;
  String? get code => json['code'] as String?;
  String? get detail => json['detail'] as String?;
  String? get limit => json['limit'] as String?;
  List<String> get conflictedFields =>
      (json['conflicted_fields'] as List? ?? const []).cast<String>();
  Map<String, Object?>? get record => json['record'] as Map<String, Object?>?;

  /// The outcome that settled the mutation, looking through a duplicate.
  String get effectiveOutcome =>
      outcome == 'duplicate' ? (originalOutcome ?? 'rejected') : outcome;
}

class PushResponse {
  const PushResponse(
    this.results,
    this.headRevision,
    this.liveWords,
    this.contentBytes,
    this.lastSeq,
  );
  final List<MutationResult> results;
  final int headRevision;
  final int liveWords;
  final int contentBytes;
  final int lastSeq;
}

class Page {
  const Page(
    this.epoch,
    this.records, {
    this.cursor,
    this.hasMore = false,
    this.nextPageToken,
    this.catchUpCursor,
    this.snapshotRevision,
  });
  final String epoch;
  final List<Map<String, Object?>> records;
  final String? cursor;
  final bool hasMore;
  final String? nextPageToken;
  final String? catchUpCursor;
  final int? snapshotRevision;
}

/// The TRD 05 sync routes of the Go backend (`backend/api/openapi.yaml`).
class LearningSyncApi {
  LearningSyncApi({
    required http.Client client,
    required String baseUrl,
    required Future<String?> Function() accessToken,
    Duration timeout = const Duration(seconds: 20),
  }) : _http = client,
       _base = baseUrl,
       _token = accessToken,
       _timeout = timeout;

  final http.Client _http;
  final String _base;
  final Future<String?> Function() _token;
  final Duration _timeout;

  Future<Map<String, String>> _headers({bool body = false}) async {
    final t = await _token();
    return {
      'accept': 'application/json',
      if (body) 'content-type': 'application/json',
      'authorization': 'Bearer ${t ?? ''}',
    };
  }

  Future<Map<String, Object?>> _get(
    String path,
    Map<String, String> query,
  ) async {
    final uri = Uri.parse(
      '$_base$path',
    ).replace(queryParameters: query.isEmpty ? null : query);
    late http.Response r;
    try {
      r = await _http.get(uri, headers: await _headers()).timeout(_timeout);
    } on Exception catch (e) {
      throw SyncUnknownOutcome(e);
    }
    return _decode(r);
  }

  Future<Map<String, Object?>> _post(String path, List<int> body) async {
    late http.Response r;
    try {
      r = await _http
          .post(
            Uri.parse('$_base$path'),
            headers: await _headers(body: true),
            body: body,
          )
          .timeout(_timeout);
    } on Exception catch (e) {
      throw SyncUnknownOutcome(e);
    }
    return _decode(r);
  }

  Map<String, Object?> _decode(http.Response r) {
    if (r.statusCode >= 500 && r.statusCode != 503) {
      throw SyncUnknownOutcome('HTTP ${r.statusCode}');
    }
    final Object? body;
    try {
      body = r.bodyBytes.isEmpty ? null : jsonDecode(utf8.decode(r.bodyBytes));
    } on FormatException {
      throw const SyncUnknownOutcome('malformed response');
    }
    if (r.statusCode >= 200 && r.statusCode < 300 && body is! Map) {
      throw const SyncUnknownOutcome('incomplete response');
    }
    if (r.statusCode >= 200 && r.statusCode < 300) {
      return (body as Map).cast<String, Object?>();
    }
    if (body is! Map) {
      throw SyncUnknownOutcome('HTTP ${r.statusCode} without a problem body');
    }
    final p = body.cast<String, Object?>();
    throw SyncProblem(
      r.statusCode,
      p['code'] as String? ?? 'unknown',
      reason: p['reason'] as String?,
      epoch: p['epoch'] as String?,
      liveWords: p['live_words'] as int?,
      contentBytes: p['content_bytes'] as int?,
      lastSeq: p['last_seq'] as int?,
    );
  }

  Future<SyncState> state({String? writerId}) async => SyncState.fromJson(
    await _get('/v1/learning/sync/state', {'writer_id': ?writerId}),
  );

  Future<(String writerId, String epoch)> registerWriter() async {
    final j = await _post('/v1/learning/sync/writers', utf8.encode('{}'));
    return (j['writer_id']! as String, j['epoch']! as String);
  }

  /// Sends [mutations] — the exact stored bytes of each mutation object — so a
  /// retry is byte-identical to the original attempt.
  Future<PushResponse> push({
    required String epoch,
    required String writerId,
    required List<Uint8List> mutations,
  }) => _write('/v1/learning/sync/push', epoch, writerId, null, mutations);

  Future<PushResponse> importWords({
    required String epoch,
    required String writerId,
    required int basisLiveWords,
    required int basisContentBytes,
    required List<Uint8List> mutations,
  }) => _write(
    '/v1/learning/sync/import',
    epoch,
    writerId,
    '{"live_words":$basisLiveWords,"content_bytes":$basisContentBytes}',
    mutations,
  );

  Future<PushResponse> _write(
    String path,
    String epoch,
    String writerId,
    String? basis,
    List<Uint8List> mutations,
  ) async {
    final b = BytesBuilder(copy: false)
      ..add(
        utf8.encode(
          '{"epoch":${jsonEncode(epoch)},"writer_id":${jsonEncode(writerId)},',
        ),
      )
      ..add(basis == null ? const [] : utf8.encode('"capacity_basis":$basis,'))
      ..add(utf8.encode('"mutations":['));
    for (var i = 0; i < mutations.length; i++) {
      if (i > 0) b.addByte(0x2c);
      b.add(mutations[i]);
    }
    b.add(utf8.encode(']}'));
    final j = await _post(path, b.takeBytes());
    return PushResponse(
      (j['results']! as List)
          .cast<Map<String, Object?>>()
          .map(MutationResult.new)
          .toList(),
      j['head_revision']! as int,
      j['live_words']! as int,
      j['content_bytes']! as int,
      j['last_seq']! as int,
    );
  }

  Future<Page> changes(String cursor, {int limit = 500}) async {
    final j = await _get('/v1/learning/sync/changes', {
      'cursor': cursor,
      'limit': '$limit',
    });
    return Page(
      j['epoch']! as String,
      (j['changes']! as List).cast<Map<String, Object?>>(),
      cursor: j['cursor']! as String,
      hasMore: j['has_more']! as bool,
    );
  }

  Future<Page> snapshot({String? pageToken, int limit = 500}) async {
    final j = await _get('/v1/learning/sync/snapshot', {
      'limit': '$limit',
      'page_token': ?pageToken,
    });
    return Page(
      j['epoch']! as String,
      (j['items']! as List).cast<Map<String, Object?>>(),
      nextPageToken: j['next_page_token'] as String?,
      catchUpCursor: j['catch_up_cursor']! as String,
      snapshotRevision: j['snapshot_revision']! as int,
    );
  }
}
