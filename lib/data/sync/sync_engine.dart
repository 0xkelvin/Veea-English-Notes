import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../../models/vocabulary_word.dart';
import '../../models/word_identity.dart';
import '../local/app_database.dart';
import 'canonical.dart';
import 'learning_sync_api.dart';

/// Outcome of one [SyncEngine.sync] run.
enum SyncRun {
  /// Pushed, pulled and caught up.
  done,

  /// Nothing to do: the guest notebook is open, or sync is closed.
  skipped,

  /// A request's outcome is unknown or was refused for now; retried later.
  pending,

  /// An import is waiting for the user to confirm the refreshed capacity.
  needsImportConfirmation,

  /// The session is over (401); the auth layer must sign in again.
  unauthorized,
}

/// One unresolved item for the user (TRD 05 §8.4). Actions are per item and
/// operation-specific; there is no bulk replay.
class ReviewItem {
  ReviewItem(this.row);
  final Map<String, Object?> row;

  int get id => row['id']! as int;
  String get entityId => row['entity_id']! as String;

  /// The original operation, including delete intent.
  String get op => row['op']! as String;
  String get reason => row['reason']! as String;
  Map<String, Object?> get payload =>
      (jsonDecode(row['payload']! as String) as Map).cast<String, Object?>();
  Map<String, Object?>? get content => row['content'] == null
      ? null
      : (jsonDecode(row['content']! as String) as Map).cast<String, Object?>();
  Map<String, Object?>? get serverRecord => row['server_record'] == null
      ? null
      : (jsonDecode(row['server_record']! as String) as Map)
            .cast<String, Object?>();
}

/// A review action that the item's operation and the current server state do
/// not allow; for example Apply on an update of a word the server no longer has.
class ReviewActionUnavailable implements Exception {
  const ReviewActionUnavailable(this.message);
  final String message;
  @override
  String toString() => 'ReviewActionUnavailable($message)';
}

/// The import selection does not fit the account's remaining capacity.
class ImportOverCapacity implements Exception {
  const ImportOverCapacity(this.words, this.bytes);
  final int words;
  final int bytes;
}

class GuestImportPlan {
  GuestImportPlan({
    required this.datasetId,
    required this.userId,
    required this.candidates,
    required this.duplicates,
    required this.sizes,
    required this.liveWords,
    required this.contentBytes,
  });

  final String datasetId;
  final String userId;

  /// Eligible guest words (positive `guest_created` provenance), not duplicates.
  final List<VocabularyWord> candidates;

  /// Eligible words matching an account word's spelling and sense; excluded by default.
  final List<VocabularyWord> duplicates;

  /// Canonical size of each candidate, the quantity the server's byte budget counts.
  final Map<String, int> sizes;
  final int liveWords;
  final int contentBytes;

  int get remainingWords => SyncLimits.maxLiveWords - liveWords;
  int get remainingBytes => SyncLimits.maxContentBytes - contentBytes;

  bool fits(Iterable<String> ids) {
    var n = 0, b = 0;
    for (final id in ids.toSet()) {
      if (!sizes.containsKey(id)) return false;
      n++;
      b += sizes[id]!;
    }
    return n <= remainingWords && b <= remainingBytes;
  }
}

class ImportOutcome {
  const ImportOutcome({
    this.imported = 0,
    this.leftInGuest = 0,
    this.confirmLiveWords,
    this.confirmContentBytes,
    this.pending = false,
  });

  final int imported;

  /// Words the server rejected; they stay in the guest notebook.
  final int leftInGuest;

  /// Set after `capacity_changed`: the refreshed capacity the user must confirm.
  final int? confirmLiveWords;
  final int? confirmContentBytes;

  /// The import request's outcome is unknown; it is retried unchanged.
  final bool pending;

  bool get needsConfirmation => confirmLiveWords != null;
}

/// The TRD 05 vocabulary sync client.
///
/// The open notebook's words live in the `words` table; other partitions are
/// archived by the repository. Never-sent edits are derived from dirty rows by
/// diffing against `server_copy`, so they can be rebased freely. Once a request
/// is about to be transmitted its mutations get contiguous `seq` values and
/// their exact bytes are stored in `sync_queue` first; from then on they are
/// only ever retried unchanged (§5.3).
class SyncEngine {
  SyncEngine({
    required Database db,
    required LearningSyncApi api,
    DateTime Function()? now,
    Uuid uuid = const Uuid(),
  }) : _db = db,
       _api = api,
       _now = now ?? DateTime.now,
       _uuid = uuid;

  final Database _db;
  final LearningSyncApi _api;
  final DateTime Function() _now;
  final Uuid _uuid;
  Future<void> _serial = Future.value();

  // All public operations that may send share one writer lane. The caller
  // awaits idle before switching notebooks; transaction fences also prevent
  // a late response from touching a different open account.
  Future<T> _exclusive<T>(Future<T> Function() action) {
    final done = Completer<void>();
    final previous = _serial;
    _serial = done.future;
    return previous.then((_) => action()).whenComplete(done.complete);
  }

  Future<void> get idle => _serial;

  Future<void> _assertOwner(DatabaseExecutor db, String p) async {
    if (partitionOf(await _owner(db) ?? '') != p) {
      throw const _NotebookClosed();
    }
  }

  static const _fields = [
    'word',
    'meaning',
    'pronunciation',
    'part_of_speech',
    'source',
    'examples',
    'tags',
  ];

  // --- partitions ------------------------------------------------------------------------------

  Future<String?> _owner([DatabaseExecutor? db]) async {
    final rows = await (db ?? _db).query(
      'app_metadata',
      where: 'key = ?',
      whereArgs: ['notebook_owner'],
    );
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  static String partitionOf(String userId) => 'account:$userId';

  Future<Map<String, Object?>> _partition(
    DatabaseExecutor db,
    String partition,
  ) async {
    final rows = await db.query(
      'sync_partitions',
      where: 'partition = ?',
      whereArgs: [partition],
    );
    if (rows.isNotEmpty) return rows.single;
    await db.insert('sync_partitions', {
      'partition': partition,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    return (await db.query(
      'sync_partitions',
      where: 'partition = ?',
      whereArgs: [partition],
    )).single;
  }

  Future<void> _setPartition(
    DatabaseExecutor db,
    String partition,
    Map<String, Object?> values,
  ) => db.update(
    'sync_partitions',
    values,
    where: 'partition = ?',
    whereArgs: [partition],
  );

  // --- the sync run ----------------------------------------------------------------------------

  /// Runs one sync of the open account notebook: resolve sent requests, push
  /// never-sent edits, then pull (or snapshot and catch up).
  Future<SyncRun> sync() => _exclusive(_sync);

  Future<SyncRun> _sync() async {
    final owner = await _owner();
    if (owner == null) return SyncRun.skipped; // the guest notebook never syncs
    final p = partitionOf(owner);
    try {
      await _ensureWriter(p);
      for (var round = 0; round < 50; round++) {
        final r = await _pushOnce(p);
        if (r == null) break; // nothing left to send
        if (r != SyncRun.done) return r;
      }
      await _pull(p);
      return SyncRun.done;
    } on _NotebookClosed {
      return SyncRun.skipped;
    } on _ResetHandled {
      return SyncRun.done;
    } on SyncProblem catch (e) {
      if (e.status == 401) return SyncRun.unauthorized;
      if (e.status == 503 || e.status == 429) return SyncRun.pending;
      rethrow;
    } on SyncUnknownOutcome {
      return SyncRun.pending;
    }
  }

  Future<void> _ensureWriter(String p) async {
    final part = await _partition(_db, p);
    if (part['writer_id'] != null) return;
    final (writer, epoch) = await _api.registerWriter();
    await _db.transaction((txn) async {
      await _assertOwner(txn, p);
      await _setPartition(txn, p, {
        'writer_id': writer,
        'epoch': epoch,
        'next_seq': 0,
      });
    });
  }

  /// Sends one request: the oldest group of already-sequenced mutations if
  /// any (an unchanged retry), else a new group built from dirty rows.
  /// Returns null when there is nothing to send.
  Future<SyncRun?> _pushOnce(String p) async {
    await _assertOwner(_db, p);
    if ((await _partition(_db, p))['import_confirmation'] == 1) {
      return SyncRun.needsImportConfirmation;
    }
    var group = await _queuedGroup(p);
    if (group.isEmpty) {
      group = await _sequenceNewGroup(p);
      if (group.isEmpty) return null;
    }
    final part = await _partition(_db, p);
    final writer = part['writer_id']! as String,
        epoch = part['epoch']! as String;
    final kind = group.first['kind']! as String;
    final hadUnknown = group.any((e) => e['unknown'] == 1);
    if (hadUnknown) {
      // The authoritative high-water mark: a retired writer can process nothing
      // more, so its queue goes to review; otherwise retry unchanged either way
      // (last_seq >= seq proves processing, not application).
      final st = await _api.state(writerId: writer);
      if (st.epoch != epoch) {
        await _resetFor(p, 'epoch_changed', writerState: st.writer);
        throw const _ResetHandled();
      }
      if (st.writer == null || !st.writer!.active) {
        await _resetFor(p, 'writer_unknown', writerState: st.writer);
        throw const _ResetHandled();
      }
    }
    final bytes = [for (final e in group) e['payload']! as Uint8List];
    // Commit uncertainty BEFORE transmission. A process death after POST
    // must be indistinguishable from a lost response on the next launch.
    await _assertOwner(_db, p);
    await _markUnknown(p, writer, group);
    try {
      final PushResponse resp;
      if (kind == 'import') {
        final basis = (jsonDecode(group.first['basis']! as String) as Map)
            .cast<String, Object?>();
        resp = await _api.importWords(
          epoch: epoch,
          writerId: writer,
          basisLiveWords: basis['live_words']! as int,
          basisContentBytes: basis['content_bytes']! as int,
          mutations: bytes,
        );
      } else {
        resp = await _api.push(
          epoch: epoch,
          writerId: writer,
          mutations: bytes,
        );
      }
      await _applyResults(p, group, resp);
      return SyncRun.done;
    } on SyncUnknownOutcome {
      await _markUnknown(p, writer, group);
      return SyncRun.pending;
    } on SyncProblem catch (e) {
      if (e.isReset) {
        await _resetFor(p, e.reason!);
        throw const _ResetHandled();
      }
      if (e.code == 'capacity_changed') {
        if (!hadUnknown) await _release(p, writer, group);
        await _setPartition(_db, p, {'import_confirmation': 1});
        return SyncRun.needsImportConfirmation;
      }
      // Any other refusal settles only this attempt. With no earlier unknown
      // attempt nothing was processed, so the seq values are released; after
      // an unknown attempt they stay, unchanged, for a later retry.
      if (!hadUnknown &&
          e.status != 503 &&
          e.status != 429 &&
          e.status != 401) {
        await _release(p, writer, group);
      }
      if (e.status == 401) return SyncRun.unauthorized;
      return SyncRun.pending;
    }
  }

  Future<List<Map<String, Object?>>> _queuedGroup(String p) async {
    final rows = await _db.query(
      'sync_queue',
      where: 'partition = ?',
      whereArgs: [p],
      orderBy: 'seq',
    );
    if (rows.isEmpty) return rows;
    final kind = rows.first['kind'];
    final out = <Map<String, Object?>>[];
    for (final r in rows) {
      if (r['kind'] != kind ||
          r['request_id'] != rows.first['request_id'] ||
          out.length == SyncLimits.maxMutations) {
        break;
      }
      out.add(r);
    }
    return out;
  }

  Future<void> _markUnknown(
    String p,
    String writer,
    List<Map<String, Object?>> group,
  ) async {
    await _db.update(
      'sync_queue',
      {'unknown': 1},
      where: 'partition = ? AND writer_id = ? AND seq BETWEEN ? AND ?',
      whereArgs: [p, writer, group.first['seq'], group.last['seq']],
    );
  }

  /// Returns a group whose only attempt was conclusively refused to never sent.
  Future<void> _release(
    String p,
    String writer,
    List<Map<String, Object?>> group,
  ) async {
    await _db.transaction((txn) async {
      await txn.delete(
        'sync_queue',
        where: 'partition = ? AND writer_id = ? AND seq >= ?',
        whereArgs: [p, writer, group.first['seq']],
      );
      await _setPartition(txn, p, {
        'next_seq': (group.first['seq']! as int) - 1,
      });
    });
  }

  // --- never-sent edits ------------------------------------------------------------------------

  Map<String, Object?>? _serverCopy(Map<String, Object?> row) =>
      row['server_copy'] == null
      ? null
      : (jsonDecode(row['server_copy']! as String) as Map)
            .cast<String, Object?>();

  static List<String> _list(Object? json) => json == null
      ? const []
      : (jsonDecode(json as String) as List).cast<String>();

  static Map<String, Object?> rowData(Map<String, Object?> row) => {
    'word': row['word'],
    'meaning': row['meaning'],
    'pronunciation': row['pronunciation'],
    'part_of_speech': row['part_of_speech'],
    'source': row['source'],
    'examples': _list(row['examples']),
    'tags': _list(row['tags']),
    'capture_day': row['date'],
    'client_created_at': DateTime.parse(
      row['created_at']! as String,
    ).toUtc().toIso8601String(),
  };

  static Object? _serverField(Map<String, Object?> rec, String f) =>
      f == 'capture_day' ? rec['capture_day'] : (rec['content'] as Map?)?[f];

  static bool _same(Object? a, Object? b) => a is List && b is List
      ? (a.length == b.length &&
            List.generate(a.length, (i) => a[i] == b[i]).every((x) => x))
      : a == b;

  /// Plans the never-sent mutation for a dirty row against its server copy.
  /// Returns null when nothing has to be sent (and settles the row).
  Future<Map<String, Object?>?> _plan(
    DatabaseExecutor txn,
    String p,
    Map<String, Object?> row,
  ) async {
    final id = row['id']! as String;
    final rec = _serverCopy(row);
    final base = row['server_revision'] as int?;
    final deleted = row['is_deleted'] == 1;
    final data = rowData(row);
    if (deleted) {
      if (base == null || (rec != null && rec['deleted'] == true)) {
        await txn.delete(
          'words',
          where: 'id = ?',
          whereArgs: [id],
        ); // never on the server, or already deleted there
        return null;
      }
      return {'op': 'delete', 'entity_id': id, 'base_revision': base};
    }
    if (base == null) return {'op': 'create', 'entity_id': id, 'data': data};
    if (rec != null && rec['deleted'] == true) {
      if (row['sync_intent'] == 'restore') {
        return {
          'op': 'restore',
          'entity_id': id,
          'base_revision': base,
          'data': data,
        };
      }
      // An edit to a word deleted elsewhere: deletes beat stale edits. The edit
      // goes to review; the cache follows the server.
      await _review(
        txn,
        p,
        id,
        'update',
        {'op': 'update', 'entity_id': id, 'base_revision': base, 'data': data},
        data,
        'deleted_on_server',
        rec,
      );
      await txn.delete('words', where: 'id = ?', whereArgs: [id]);
      return null;
    }
    final changed = <String>[];
    for (final f in [..._fields, 'capture_day']) {
      if (rec == null || !_same(data[f], _serverField(rec, f))) changed.add(f);
    }
    if (changed.isEmpty) {
      await txn.update(
        'words',
        {'is_dirty': 0, 'sync_intent': null},
        where: 'id = ?',
        whereArgs: [id],
      );
      return null;
    }
    return {
      'op': 'update',
      'entity_id': id,
      'base_revision': base,
      'changed_fields': changed,
      'data': {for (final f in changed) f: data[f]},
    };
  }

  static Uint8List _encodeMutation(int seq, Map<String, Object?> m) =>
      utf8.encode(jsonEncode({'seq': seq, ...m}));

  /// Builds the next group from dirty rows and stores it, sequenced, before
  /// anything is transmitted.
  Future<List<Map<String, Object?>>> _sequenceNewGroup(String p) async {
    return _db.transaction((txn) async {
      await _assertOwner(txn, p);
      final part = await _partition(txn, p);
      final writer = part['writer_id']! as String;
      var seq = part['next_seq']! as int;
      final rows = await txn.query(
        'words',
        where: "is_dirty = 1 AND sync_hold IS NULL AND provenance = 'account'",
        orderBy: 'updated_at, id',
        limit: 400,
      );
      var bytes = 0;
      final group = <Map<String, Object?>>[];
      final requestId = _uuid.v4();
      for (final row in rows) {
        if (group.length == SyncLimits.maxMutations) break;
        final m = await _plan(txn, p, row);
        if (m == null) continue;
        final data = m['data'] as Map<String, Object?>?;
        if (data != null && m['op'] != 'update') {
          final inv = validateSyncItem(
            SyncContent.fromJson(data),
            captureDay: data['capture_day']! as String,
            clientCreatedAt: data['client_created_at']! as String,
          );
          if (inv != null) {
            await txn.update(
              'words',
              {'sync_hold': 'invalid:${inv.detail}'},
              where: 'id = ?',
              whereArgs: [row['id']],
            );
            continue;
          }
        }
        final payload = _encodeMutation(seq + 1, m);
        if (bytes + payload.length + 256 > SyncLimits.maxRequestBytes &&
            group.isNotEmpty) {
          break;
        }
        seq++;
        bytes += payload.length + 1;
        final entry = {
          'partition': p,
          'writer_id': writer,
          'seq': seq,
          'kind': 'push',
          'request_id': requestId,
          'entity_id': row['id'],
          'op': m['op'],
          'payload': payload,
          'local_updated_at': row['updated_at'],
          'unknown': 0,
        };
        await txn.insert('sync_queue', entry);
        group.add(entry);
      }
      await _setPartition(txn, p, {'next_seq': seq});
      return group;
    });
  }

  // --- results ---------------------------------------------------------------------------------

  Future<void> _applyResults(
    String p,
    List<Map<String, Object?>> group,
    PushResponse resp,
  ) async {
    final byseq = {for (final r in resp.results) r.seq: r};
    if (byseq.length != group.length ||
        group.any((e) => byseq[e['seq']]?.entityId != e['entity_id']) ||
        resp.lastSeq < (group.last['seq']! as int)) {
      throw const SyncUnknownOutcome('incomplete mutation results');
    }
    await _db.transaction((txn) async {
      await _assertOwner(txn, p);
      for (final e in group) {
        final r = byseq[e['seq']];
        if (r == null) continue;
        if (e['kind'] == 'import') {
          await _settleImported(txn, p, e, r);
        } else {
          await _settle(txn, p, e, r);
        }
        await txn.delete(
          'sync_queue',
          where: 'partition = ? AND writer_id = ? AND seq = ?',
          whereArgs: [p, e['writer_id'], e['seq']],
        );
      }
    });
  }

  Future<Map<String, Object?>?> _row(DatabaseExecutor txn, String id) async {
    final rows = await txn.query('words', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : rows.single;
  }

  Future<void> _settle(
    DatabaseExecutor txn,
    String p,
    Map<String, Object?> e,
    MutationResult r,
  ) async {
    final id = e['entity_id']! as String;
    final row = await _row(txn, id);
    final unchanged = row != null && row['updated_at'] == e['local_updated_at'];
    final payload = (jsonDecode(utf8.decode(e['payload']! as Uint8List)) as Map)
        .cast<String, Object?>();
    final outcome = r.effectiveOutcome;
    if (outcome == 'applied' || outcome == 'merged' || outcome == 'no_op') {
      await _adoptSentResult(txn, p, id, payload, row, r.record, unchanged);
      return;
    }
    switch (r.code) {
      case 'mutation_expired':
        // Processed, record gone. Never renumbered: reconcile or review.
        if (_reflects(payload, r.record)) {
          await _adoptSentResult(txn, p, id, payload, row, r.record, unchanged);
        } else {
          await _review(
            txn,
            p,
            id,
            e['op']! as String,
            payload,
            row == null
                ? payload['data'] as Map<String, Object?>?
                : rowData(row),
            'mutation_expired',
            r.record,
            origin: e,
          );
          await _adopt(txn, id, r.record, overwrite: true);
        }
      case 'quota_exceeded':
        // Stays local, marked not backed up, until the user asks (§10.2).
        await txn.update(
          'words',
          {'sync_hold': 'quota'},
          where: 'id = ?',
          whereArgs: [id],
        );
      case 'invalid_item':
        await txn.update(
          'words',
          {'sync_hold': 'invalid:${r.detail}'},
          where: 'id = ?',
          whereArgs: [id],
        );
      default: // deleted_on_server, stale_base, unknown_item, id_in_use, mutation_reused
        await _review(
          txn,
          p,
          id,
          e['op']! as String,
          payload,
          row == null ? payload['data'] as Map<String, Object?>? : rowData(row),
          r.code ?? 'rejected',
          r.record,
          origin: e,
        );
        await _adopt(txn, id, r.record, overwrite: true);
    }
  }

  Future<void> _adoptSentResult(
    DatabaseExecutor txn,
    String p,
    String id,
    Map<String, Object?> payload,
    Map<String, Object?>? row,
    Map<String, Object?>? record,
    bool unchanged,
  ) async {
    if (unchanged || row == null) {
      await _adopt(txn, id, record, overwrite: unchanged);
    } else {
      final current = rowData(row);
      final before = _serverCopy(row);
      final sent =
          (payload['data'] as Map?)?.cast<String, Object?>() ??
          <String, Object?>{};
      final later = <String, Object?>{};
      for (final f in [..._fields, 'capture_day']) {
        final expected = sent.containsKey(f)
            ? sent[f]
            : before == null
            ? null
            : _serverField(before, f);
        if (!_same(current[f], expected)) later[f] = current[f];
      }
      if (record == null || record['deleted'] == true) {
        // A server delete wins. A later local edit is a separate review item.
        await _review(
          txn,
          p,
          id,
          row['is_deleted'] == 1
              ? 'delete'
              : row['sync_intent'] == 'restore'
              ? 'restore'
              : 'update',
          {
            'op': row['sync_intent'] == 'restore' ? 'restore' : 'update',
            'entity_id': id,
            'data': later,
          },
          current,
          'edited_during_send',
          record,
        );
        await _adopt(txn, id, record, overwrite: true);
      } else {
        await _adopt(txn, id, record, overwrite: true);
        await txn.update(
          'words',
          {
            ..._localFields(later),
            'is_deleted': row['is_deleted'],
            'is_dirty': 1,
            'updated_at': row['updated_at'],
            'sync_intent': row['sync_intent'],
          },
          where: 'id = ?',
          whereArgs: [id],
        );
      }
    }
  }

  /// Whether the server record already holds what the mutation intended.
  bool _reflects(Map<String, Object?> payload, Map<String, Object?>? rec) {
    switch (payload['op']) {
      case 'delete':
        return rec == null || rec['deleted'] == true;
      case 'update':
        if (rec == null || rec['deleted'] == true) return false;
        final data = (payload['data']! as Map).cast<String, Object?>();
        return data.entries.every(
          (d) => _same(d.value, _serverField(rec, d.key)),
        );
      default: // create, restore
        if (rec == null || rec['deleted'] == true) return false;
        final data = (payload['data']! as Map).cast<String, Object?>();
        return [
          ..._fields,
          'capture_day',
        ].every((f) => _same(data[f], _serverField(rec, f)));
    }
  }

  /// Takes [rec] as the server copy. With [overwrite] (the row was not edited
  /// since the mutation was sent) the cache follows the server exactly.
  Future<void> _adopt(
    DatabaseExecutor txn,
    String id,
    Map<String, Object?>? rec, {
    required bool overwrite,
  }) async {
    final row = await _row(txn, id);
    if (rec == null) {
      if (row != null && overwrite) {
        await txn.delete('words', where: 'id = ?', whereArgs: [id]);
      }
      return;
    }
    if (row == null) {
      if (rec['deleted'] != true) {
        await txn.insert('words', _rowFromRecord(rec, null));
      }
      return;
    }
    if (overwrite) {
      if (rec['deleted'] == true) {
        await txn.delete('words', where: 'id = ?', whereArgs: [id]);
      } else {
        await txn.update(
          'words',
          _rowFromRecord(rec, row),
          where: 'id = ?',
          whereArgs: [id],
        );
      }
    } else {
      await txn.update(
        'words',
        {'server_copy': jsonEncode(rec), 'server_revision': rec['revision']},
        where: 'id = ?',
        whereArgs: [id],
      );
    }
  }

  /// A clean local row mirroring a live server record, keeping local-only
  /// review progress of [existing].
  Map<String, Object?> _rowFromRecord(
    Map<String, Object?> rec,
    Map<String, Object?>? existing,
  ) {
    final c = (rec['content']! as Map).cast<String, Object?>();
    final w = VocabularyWord(
      id: rec['entity_id']! as String,
      word: c['word']! as String,
      meaning: c['meaning']! as String,
      pronunciation: c['pronunciation'] as String?,
      source: c['source'] as String?,
      examples: (c['examples']! as List).cast<String>(),
      tags: (c['tags']! as List).cast<String>(),
      date: rec['capture_day']! as String,
      createdAt: DateTime.parse(rec['client_created_at']! as String).toLocal(),
      updatedAt: DateTime.parse(rec['updated_at']! as String).toLocal(),
      isDirty: false,
    );
    final m = w.toDbMap()
      ..['part_of_speech'] = c['part_of_speech']
      ..['server_copy'] = jsonEncode(rec)
      ..['server_revision'] = rec['revision']
      ..['sync_intent'] = null
      ..['sync_hold'] = null;
    if (existing != null) {
      for (final k in [
        'srs_stage',
        'next_review_at',
        'last_reviewed_at',
        'last_gate_failed',
        'provenance',
      ]) {
        m[k] = existing[k];
      }
    } else {
      m['provenance'] = 'account';
    }
    return m;
  }

  // --- pull, snapshot and catch-up ---------------------------------------------------------------

  Future<void> _pull(String p) async {
    final part = await _partition(_db, p);
    var cursor = part['cursor'] as String?;
    if (cursor == null) {
      await _fullResync(p, _Mode.normal);
      return;
    }
    for (var i = 0; i < 1000; i++) {
      final Page page;
      try {
        page = await _api.changes(cursor!);
      } on SyncProblem catch (e) {
        if (!e.isReset) rethrow;
        await _resetFor(p, e.reason!);
        return;
      }
      await _db.transaction((txn) async {
        await _assertOwner(txn, p);
        for (final rec in page.records) {
          await _applyRemote(txn, rec);
        }
        await _setPartition(txn, p, {
          'cursor': page.cursor,
          'epoch': page.epoch,
        });
      });
      cursor = page.cursor;
      if (!page.hasMore) return;
    }
    throw const SyncUnknownOutcome('feed remains paginated');
  }

  /// A record from the feed: a clean row follows the server; a dirty row keeps
  /// its local edit and only learns the new server copy (its next push diffs
  /// against it).
  Future<void> _applyRemote(
    DatabaseExecutor txn,
    Map<String, Object?> rec,
  ) async {
    final id = rec['entity_id']! as String;
    await txn.update(
      'sync_review',
      {'server_record': jsonEncode(rec)},
      where: 'partition = ? AND entity_id = ?',
      whereArgs: [partitionOf((await _owner(txn))!), id],
    );
    final row = await _row(txn, id);
    if (row == null) {
      if (rec['deleted'] != true) {
        await txn.insert('words', _rowFromRecord(rec, null));
      }
      return;
    }
    await _rebase(txn, row, rec);
  }

  Future<void> _rebase(
    DatabaseExecutor txn,
    Map<String, Object?> row,
    Map<String, Object?>? rec,
  ) async {
    final id = row['id']! as String;
    if (row['is_dirty'] != 1) {
      await _adopt(txn, id, rec, overwrite: true);
      return;
    }
    final queued = await txn.query(
      'sync_queue',
      where: 'entity_id = ?',
      whereArgs: [id],
    );
    if (queued.isNotEmpty || row['server_revision'] == null) {
      // Uncertain requests retain the old base as well as their stored bytes.
      // A never-sent create remains local until sent or reviewed.
      return;
    }
    final intent = await _planForReview(row);
    if (intent == null) return;
    if (row['is_deleted'] == 1 && (rec == null || rec['deleted'] == true)) {
      await txn.delete('words', where: 'id = ?', whereArgs: [id]);
    } else if (rec == null || rec['deleted'] == true) {
      if (row['sync_intent'] == 'restore' && rec != null) {
        await _adopt(txn, id, rec, overwrite: false);
      } else {
        await _review(
          txn,
          partitionOf((await _owner(txn))!),
          id,
          intent['op']! as String,
          intent,
          rowData(row),
          'reset_missing',
          rec,
        );
        await _adopt(txn, id, rec, overwrite: true);
      }
    } else if (row['is_deleted'] == 1) {
      await _adopt(txn, id, rec, overwrite: false);
    } else {
      await txn.update(
        'words',
        {
          ..._rowFromRecord(rec, row),
          ..._localFields((intent['data']! as Map).cast<String, Object?>()),
          'is_dirty': 1,
          'updated_at': row['updated_at'],
          'sync_hold': row['sync_hold'],
        },
        where: 'id = ?',
        whereArgs: [id],
      );
    }
  }

  Future<void> _resetFor(
    String p,
    String reason, {
    WriterState? writerState,
  }) async {
    switch (reason) {
      case 'cursor_compacted':
        await _fullResync(p, _Mode.normal);
      case 'writer_unknown':
        await _fullResync(p, _Mode.retired, writerState: writerState);
      default: // epoch_changed (a restore) and cursor_ahead (a rewound head)
        await _fullResync(p, _Mode.restore);
    }
  }

  /// Stages a snapshot, catches up from its boundary until `has_more` is false
  /// (also when empty), and only then replaces the cache. `cursor_compacted`
  /// during either discards the staged copy and starts again (§8.5).
  Future<void> _fullResync(
    String p,
    _Mode mode, {
    WriterState? writerState,
  }) async {
    final oldEpoch = (await _partition(_db, p))['epoch'];
    for (var attempt = 0; attempt < 5; attempt++) {
      await _db.delete('sync_staging', where: 'partition = ?', whereArgs: [p]);
      try {
        String? token;
        late String cursor, epoch;
        do {
          final page = await _api.snapshot(pageToken: token);
          if (oldEpoch != null && page.epoch != oldEpoch) mode = _Mode.restore;
          if (token != null && page.epoch != epoch) {
            throw const SyncProblem(
              410,
              'sync_reset_required',
              reason: 'epoch_changed',
            );
          }
          await _db.transaction((txn) async {
            for (final rec in page.records) {
              await txn.insert('sync_staging', {
                'partition': p,
                'entity_id': rec['entity_id'],
                'record': jsonEncode(rec),
              }, conflictAlgorithm: ConflictAlgorithm.replace);
            }
          });
          token = page.nextPageToken;
          cursor = page.catchUpCursor!;
          epoch = page.epoch;
        } while (token != null);
        while (true) {
          final page = await _api.changes(cursor);
          if (page.epoch != epoch) {
            throw const SyncProblem(
              410,
              'sync_reset_required',
              reason: 'epoch_changed',
            );
          }
          await _db.transaction((txn) async {
            for (final rec in page.records) {
              await txn.insert('sync_staging', {
                'partition': p,
                'entity_id': rec['entity_id'],
                'record': jsonEncode(rec),
              }, conflictAlgorithm: ConflictAlgorithm.replace);
            }
          });
          cursor = page.cursor!;
          if (!page.hasMore) break;
        }
        await _replaceCache(p, mode, cursor, epoch, writerState);
        if (mode != _Mode.normal) await _ensureWriter(p);
        return;
      } on SyncProblem catch (e) {
        if (e.isReset &&
            (e.reason == 'cursor_compacted' || e.reason == 'epoch_changed')) {
          if (e.reason == 'epoch_changed') mode = _Mode.restore;
          continue;
        }
        rethrow;
      }
    }
    throw StateError('snapshot did not settle');
  }

  Future<void> _replaceCache(
    String p,
    _Mode mode,
    String cursor,
    String epoch,
    WriterState? ws,
  ) async {
    await _db.transaction((txn) async {
      await _assertOwner(txn, p);
      final staged = <String, Map<String, Object?>>{
        for (final r in await txn.query(
          'sync_staging',
          where: 'partition = ?',
          whereArgs: [p],
        ))
          r['entity_id']! as String: (jsonDecode(r['record']! as String) as Map)
              .cast<String, Object?>(),
      };
      final local = await txn.query('words');
      if (mode == _Mode.normal) {
        for (final row in local) {
          final id = row['id']! as String;
          final rec = staged.remove(id);
          if (row['is_dirty'] == 1) {
            await _rebase(txn, row, rec);
          } else if (rec == null || rec['deleted'] == true) {
            await txn.delete('words', where: 'id = ?', whereArgs: [id]);
          } else {
            await txn.update(
              'words',
              _rowFromRecord(rec, row),
              where: 'id = ?',
              whereArgs: [id],
            );
          }
        }
      } else {
        // Restore or retired writer: the old queue and every unsynced local
        // change go to review with their original operation; nothing is sent
        // or moved onto the new writer or epoch. The cache becomes the snapshot.
        final reason = mode == _Mode.restore ? 'pre_restore' : 'writer_retired';
        final queued = await txn.query(
          'sync_queue',
          where: 'partition = ?',
          whereArgs: [p],
          orderBy: 'seq',
        );
        final covered = <String>{};
        for (final e in queued) {
          final payload =
              (jsonDecode(utf8.decode(e['payload']! as Uint8List)) as Map)
                  .cast<String, Object?>();
          final id = e['entity_id']! as String;
          final row = local.where((r) => r['id'] == id).firstOrNull;
          var why = reason;
          if (ws != null) {
            why = (e['seq']! as int) <= ws.lastSeq
                ? '${reason}_processed'
                : '${reason}_unprocessed';
          }
          // Imports also enter per-item review. The original guest remains
          // local; an unknown import must never be automatically resubmitted.
          if (e['kind'] == 'import') {
            final archives = await txn.query(
              'account_workspaces',
              where: 'account_id = ?',
              whereArgs: [AppDatabase.guestWorkspace],
            );
            if (archives.isNotEmpty) {
              final archive =
                  (jsonDecode(archives.single['payload']! as String) as Map)
                      .cast<String, Object?>();
              archive['words'] = [
                for (final word in (archive['words'] as List? ?? const []))
                  (word as Map)['id'] == id
                      ? {...word, 'sync_hold': 'review'}
                      : word,
              ];
              await txn.update(
                'account_workspaces',
                {'payload': jsonEncode(archive)},
                where: 'account_id = ?',
                whereArgs: [AppDatabase.guestWorkspace],
              );
            }
          }

          await _review(
            txn,
            p,
            id,
            e['op']! as String,
            payload,
            row == null
                ? payload['data'] as Map<String, Object?>?
                : rowData(row),
            why,
            staged[id],
            origin: e,
          );
          covered.add(id);
        }
        for (final row in local) {
          final id = row['id']! as String;
          if (covered.contains(id)) continue;
          if (row['is_dirty'] == 1) {
            final m = await _planForReview(row);
            if (m != null) {
              await _review(
                txn,
                p,
                id,
                m['op']! as String,
                m,
                rowData(row),
                reason,
                staged[id],
              );
            }
          } else if (mode == _Mode.restore) {
            final rec = staged[id];
            final data = rowData(row);
            if (row['is_deleted'] == 1) continue;
            if (rec == null) {
              await _review(
                txn,
                p,
                id,
                'create',
                {'op': 'create', 'entity_id': id, 'data': data},
                data,
                'restore_lost',
                null,
              );
            } else if (!_reflects({'op': 'create', 'data': data}, rec)) {
              await _review(
                txn,
                p,
                id,
                'update',
                {
                  'op': 'update',
                  'entity_id': id,
                  'base_revision': rec['revision'],
                  'data': data,
                },
                data,
                'restore_lost',
                rec,
              );
            }
          }
        }
        await txn.delete('sync_queue', where: 'partition = ?', whereArgs: [p]);
        for (final row in local) {
          final id = row['id']! as String;
          final rec = staged.remove(id);
          if (rec == null || rec['deleted'] == true) {
            await txn.delete('words', where: 'id = ?', whereArgs: [id]);
          } else {
            await txn.update(
              'words',
              _rowFromRecord(rec, row),
              where: 'id = ?',
              whereArgs: [id],
            );
          }
        }
        await _setPartition(txn, p, {'writer_id': null, 'next_seq': 0});
      }
      for (final rec in staged.values) {
        if (rec['deleted'] == true) continue;
        await txn.insert(
          'words',
          _rowFromRecord(rec, null),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await txn.delete('sync_staging', where: 'partition = ?', whereArgs: [p]);
      await _setPartition(txn, p, {'cursor': cursor, 'epoch': epoch});
    });
  }

  /// The operation a dirty row intends, without side effects.
  Future<Map<String, Object?>?> _planForReview(Map<String, Object?> row) async {
    final id = row['id']! as String;
    final base = row['server_revision'] as int?;
    final data = rowData(row);
    if (row['is_deleted'] == 1) {
      return base == null
          ? null
          : {'op': 'delete', 'entity_id': id, 'base_revision': base};
    }
    if (base == null) return {'op': 'create', 'entity_id': id, 'data': data};
    final rec = _serverCopy(row);
    if (rec != null && rec['deleted'] == true) {
      return row['sync_intent'] == 'restore'
          ? {
              'op': 'restore',
              'entity_id': id,
              'base_revision': base,
              'data': data,
            }
          : null;
    }
    return {
      'op': 'update',
      'entity_id': id,
      'base_revision': base,
      'changed_fields': [
        for (final f in [..._fields, 'capture_day'])
          if (rec == null || !_same(data[f], _serverField(rec, f))) f,
      ],
      'data': {
        for (final f in [..._fields, 'capture_day'])
          if (rec == null || !_same(data[f], _serverField(rec, f))) f: data[f],
      },
    };
  }

  // --- review ------------------------------------------------------------------------------------

  /// Adds a review item unless it is already resolved against [rec]: a delete
  /// of a word that is absent or tombstoned, or a create of a word that exists.
  Future<void> _review(
    DatabaseExecutor txn,
    String p,
    String id,
    String op,
    Map<String, Object?> payload,
    Map<String, Object?>? content,
    String reason,
    Map<String, Object?>? rec, {
    Map<String, Object?>? origin,
  }) async {
    final live = rec != null && rec['deleted'] != true;
    if (op == 'delete' && !live) return;
    if (op == 'create' && live && reason != 'restore_lost') return;
    await txn.insert('sync_review', {
      'partition': p,
      'entity_id': id,
      'op': op,
      'payload': jsonEncode(payload),
      'content': content == null ? null : jsonEncode(content),
      'reason': reason,
      'server_record': rec == null ? null : jsonEncode(rec),
      'writer_id': origin?['writer_id'],
      'seq': origin?['seq'],
      'original_payload': origin?['payload'],
      'created_at': _now().toUtc().toIso8601String(),
    });
  }

  Future<String> _openPartition() async {
    final owner = await _owner();
    if (owner == null) throw StateError('no account notebook is open');
    return partitionOf(owner);
  }

  Future<List<ReviewItem>> reviewItems() async {
    final p = await _openPartition();
    return [
      for (final r in await _db.query(
        'sync_review',
        where: 'partition = ?',
        whereArgs: [p],
        orderBy: 'id',
      ))
        ReviewItem(r),
    ];
  }

  /// Apply, specific to the item's operation (§8.4). Re-creating a word the
  /// server lacks is not Apply: it is [addAgainAsNewWord].
  Future<void> applyReview(int id) => _exclusive(() => _applyReview(id));

  Future<void> _applyReview(int id) async {
    final p = await _openPartition();
    await _db.transaction((txn) async {
      final item = await _item(txn, p, id);
      final row = await _row(txn, item.entityId);
      final live = row != null && row['is_deleted'] != 1;
      final now = _now().toUtc().toIso8601String();
      switch (item.op) {
        case 'delete':
          if (live) {
            await txn.update(
              'words',
              {'is_deleted': 1, 'is_dirty': 1, 'updated_at': now},
              where: 'id = ?',
              whereArgs: [item.entityId],
            );
          } // otherwise already resolved
        case 'update':
          if (!live) {
            throw const ReviewActionUnavailable(
              'the word no longer exists; add it again as a new word',
            );
          }
          final data = (item.payload['data']! as Map).cast<String, Object?>();
          await txn.update(
            'words',
            {..._localFields(data), 'is_dirty': 1, 'updated_at': now},
            where: 'id = ?',
            whereArgs: [item.entityId],
          );
        case 'restore':
          final rec = item.serverRecord;
          if (live) break; // already restored
          if (rec == null || rec['deleted'] != true) {
            throw const ReviewActionUnavailable(
              'there is no deleted word to restore; add it again as a new word',
            );
          }
          final data =
              item.content ??
              (item.payload['data']! as Map).cast<String, Object?>();
          await txn.insert('words', {
            ..._newRow(item.entityId, data, now),
            'server_copy': jsonEncode(rec),
            'server_revision': rec['revision'],
            'sync_intent': 'restore',
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        default:
          throw const ReviewActionUnavailable('add it again as a new word');
      }
      await txn.delete('sync_review', where: 'id = ?', whereArgs: [id]);
    });
  }

  /// The distinct action for a word the server lacks: a new word with a new id.
  Future<String> addAgainAsNewWord(int id) =>
      _exclusive(() => _addAgainAsNewWord(id));

  Future<String> _addAgainAsNewWord(int id) async {
    final p = await _openPartition();
    final newId = _uuid.v4();
    await _db.transaction((txn) async {
      final item = await _item(txn, p, id);
      final data =
          item.content ??
          (item.payload['data'] as Map?)?.cast<String, Object?>();
      if (data == null || data['word'] == null) {
        throw const ReviewActionUnavailable('nothing to add');
      }
      await txn.insert(
        'words',
        _newRow(newId, data, _now().toUtc().toIso8601String()),
      );
      await txn.delete('sync_review', where: 'id = ?', whereArgs: [id]);
    });
    return newId;
  }

  Future<void> discardReview(int id) => _exclusive(() => _discardReview(id));

  Future<void> _discardReview(int id) async {
    final p = await _openPartition();
    await _db.delete(
      'sync_review',
      where: 'id = ? AND partition = ?',
      whereArgs: [id, p],
    );
  }

  Future<ReviewItem> _item(DatabaseExecutor txn, String p, int id) async {
    final rows = await txn.query(
      'sync_review',
      where: 'id = ? AND partition = ?',
      whereArgs: [id, p],
    );
    if (rows.isEmpty) {
      throw const ReviewActionUnavailable('no such review item');
    }
    return ReviewItem(rows.single);
  }

  static Map<String, Object?> _localFields(Map<String, Object?> data) => {
    for (final e in data.entries)
      switch (e.key) {
        'capture_day' => 'date',
        'client_created_at' => 'created_at',
        final k => k,
      }: e.value is List
          ? jsonEncode(e.value)
          : e.value,
  };

  Map<String, Object?> _newRow(
    String id,
    Map<String, Object?> data,
    String now,
  ) {
    final w = VocabularyWord(
      id: id,
      word: data['word']! as String,
      meaning: (data['meaning'] ?? '') as String,
      pronunciation: data['pronunciation'] as String?,
      source: data['source'] as String?,
      examples: ((data['examples'] ?? const []) as List).cast<String>(),
      tags: ((data['tags'] ?? const []) as List).cast<String>(),
      date: (data['capture_day'] ?? now.substring(0, 10)) as String,
      createdAt: DateTime.parse(
        (data['client_created_at'] ?? now) as String,
      ).toLocal(),
      updatedAt: DateTime.parse(now).toLocal(),
      isDirty: true,
    );
    return w.toDbMap()..['part_of_speech'] = data['part_of_speech'];
  }

  /// "Back up now" for a word held locally after `quota_exceeded`: an explicit
  /// action that lets the next sync send it as a new create.
  Future<List<Map<String, Object?>>> heldWords() =>
      _db.query('words', where: "sync_hold = 'quota' AND is_deleted = 0");

  Future<void> backUpNow(String entityId) => _db.update(
    'words',
    {'sync_hold': null},
    where: "id = ? AND sync_hold = 'quota'",
    whereArgs: [entityId],
  );

  // --- guest import ------------------------------------------------------------------------------

  Future<List<Map<String, Object?>>> _guestRows(DatabaseExecutor db) async {
    final saved = await db.query(
      'account_workspaces',
      where: 'account_id = ?',
      whereArgs: [AppDatabase.guestWorkspace],
    );
    if (saved.isEmpty) return const [];
    final payload = (jsonDecode(saved.single['payload']! as String) as Map)
        .cast<String, Object?>();
    return ((payload['words'] as List?) ?? const [])
        .cast<Map>()
        .map((m) => m.cast<String, Object?>())
        .toList();
  }

  /// Guest words with positive guest provenance (§9.6). Legacy words never qualify.
  Future<List<Map<String, Object?>>> _eligibleGuestRows(
    DatabaseExecutor db,
  ) async => (await _guestRows(db))
      .where(
        (r) =>
            r['provenance'] == 'guest_created' &&
            r['is_deleted'] != 1 &&
            r['sync_hold'] == null,
      )
      .toList();

  Future<String?> _guestDataset(
    DatabaseExecutor db, {
    bool create = false,
  }) async {
    final g = await _partition(db, 'guest');
    if (g['guest_dataset_id'] != null || !create) {
      return g['guest_dataset_id'] as String?;
    }
    final id = _uuid.v4();
    await _setPartition(db, 'guest', {'guest_dataset_id': id});
    return id;
  }

  /// Whether to show the one-time import prompt for the open account: the
  /// guest notebook holds eligible words and no decision was recorded for this
  /// (account, guest dataset) on this device (§9.2).
  Future<bool> shouldPromptImport() async {
    final owner = await _owner();
    if (owner == null || (await _eligibleGuestRows(_db)).isEmpty) return false;
    final dataset = await _guestDataset(_db, create: true);
    final d = await _db.query(
      'sync_import_decisions',
      where: 'user_id = ? AND guest_dataset_id = ?',
      whereArgs: [owner, dataset],
    );
    return d.isEmpty;
  }

  Future<void> _decide(String decision) async {
    final owner = await _owner();
    final dataset = await _guestDataset(_db, create: true);
    await _db.insert('sync_import_decisions', {
      'user_id': owner,
      'guest_dataset_id': dataset,
      'decision': decision,
      'decided_at': _now().toUtc().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Records "keep on this device"; the prompt is not shown again for this
  /// account and guest dataset. Later imports stay possible, explicitly.
  Future<void> declineImport() => _decide('declined');

  /// Plans an explicit import: eligible guest words, duplicates of the
  /// account's words, and the server's current capacity.
  Future<List<String>> pendingImportSelection() async {
    final p = await _openPartition();
    return (await _db.query(
      'sync_queue',
      where: "partition = ? AND kind = 'import'",
      whereArgs: [p],
      orderBy: 'seq',
    )).map((r) => r['entity_id']! as String).toList();
  }

  Future<bool> requiresImportConfirmation() async =>
      (await _partition(_db, await _openPartition()))['import_confirmation'] ==
      1;

  Future<List<Map<String, Object?>>> _importCandidates(
    DatabaseExecutor db,
  ) async => [
    ...await _eligibleGuestRows(db),
    ...await db.query(
      'words',
      where:
          "sync_hold = 'backup' AND is_deleted = 0 AND provenance = 'account'",
    ),
  ];

  Future<GuestImportPlan> planImport() async {
    final owner = await _owner();
    if (owner == null) throw StateError('sign in to import guest words');
    final st = await _api.state();
    await _assertOwner(_db, partitionOf(owner));
    final eligible = await _importCandidates(_db);
    final account = (await _db.query(
      'words',
      where: "is_deleted = 0 AND (sync_hold IS NULL OR sync_hold != 'backup')",
    )).map(VocabularyWord.fromDbMap).toList();
    final candidates = <VocabularyWord>[], duplicates = <VocabularyWord>[];
    final sizes = <String, int>{};
    for (final r in eligible) {
      final w = VocabularyWord.fromDbMap(r);
      if (account.any((a) => WordIdentity.sameSense(a, w))) {
        duplicates.add(w);
      } else {
        candidates.add(w);
        sizes[w.id] = canonicalSize(SyncContent.fromJson(rowData(r)));
      }
    }
    return GuestImportPlan(
      datasetId: (await _guestDataset(_db, create: true))!,
      userId: owner,
      candidates: candidates,
      duplicates: duplicates,
      sizes: sizes,
      liveWords: st.liveWords,
      contentBytes: st.contentBytes,
    );
  }

  /// Imports the words the user chose. The selection must fit [plan]'s
  /// capacity; when it does not, the user chooses fewer (§9.3). Words not
  /// chosen stay in the guest notebook.
  Future<ImportOutcome> importWords(GuestImportPlan plan, List<String> ids) =>
      _exclusive(() => _importWords(plan, ids));

  Future<ImportOutcome> _importWords(
    GuestImportPlan plan,
    List<String> ids,
  ) async {
    if (!plan.fits(ids)) {
      throw ImportOverCapacity(plan.remainingWords, plan.remainingBytes);
    }
    final owner = await _owner();
    if (owner == null) throw StateError('sign in to import guest words');
    if (plan.userId != owner || plan.datasetId != await _guestDataset(_db)) {
      throw const ReviewActionUnavailable(
        'Review the import for this account again',
      );
    }
    final p = partitionOf(owner);
    await _ensureWriter(p);
    if ((await _db.query(
      'sync_queue',
      where: 'partition = ?',
      whereArgs: [p],
    )).isNotEmpty) {
      final r = await _sync(); // already holds the writer lane
      if (r != SyncRun.done) return const ImportOutcome(pending: true);
    }
    final guest = {
      for (final r in await _importCandidates(_db)) r['id']! as String: r,
    };
    await _db.transaction((txn) async {
      await _assertOwner(txn, p);
      final part = await _partition(txn, p);
      var seq = part['next_seq']! as int;
      final basis = jsonEncode({
        'live_words': plan.liveWords,
        'content_bytes': plan.contentBytes,
      });
      var requestId = _uuid.v4();
      var requestCount = 0;
      for (final id in ids.toSet()) {
        final r = guest[id];
        if (r == null) continue;
        if (requestCount++ == 200) {
          requestId = _uuid.v4();
          requestCount = 1;
        }
        seq++;
        await txn.insert('sync_queue', {
          'partition': p,
          'writer_id': part['writer_id'],
          'seq': seq,
          'kind': 'import',
          'request_id': requestId,
          'entity_id': id,
          'op': 'create',
          'payload': _encodeMutation(seq, {
            'op': 'create',
            'entity_id': id,
            'data': rowData(r),
          }),
          'unknown': 0,
          'basis': basis,
        });
      }
      await _setPartition(txn, p, {'next_seq': seq});
    });
    return _sendImports(p);
  }

  /// After `capacity_changed`: the user saw the refreshed capacity and
  /// confirmed. Requests that were never sent are re-planned against it; a
  /// request with an unknown earlier attempt keeps its bytes and gets the new
  /// basis only (§9.4).
  Future<ImportOutcome> confirmImport(GuestImportPlan plan, List<String> ids) =>
      _exclusive(() => _confirmImport(plan, ids));

  Future<ImportOutcome> _confirmImport(
    GuestImportPlan refreshed,
    List<String> ids,
  ) async {
    final owner = await _owner();
    if (owner == null ||
        refreshed.userId != owner ||
        refreshed.datasetId != await _guestDataset(_db)) {
      throw const ReviewActionUnavailable(
        'Review the import for this account again',
      );
    }
    final p = partitionOf(owner);
    final queued = await _db.query(
      'sync_queue',
      where: "partition = ? AND kind = 'import'",
      whereArgs: [p],
    );
    if (queued.isEmpty && !refreshed.fits(ids)) {
      throw ImportOverCapacity(
        refreshed.remainingWords,
        refreshed.remainingBytes,
      );
    }
    if (queued.isEmpty) {
      await _setPartition(_db, p, {'import_confirmation': 0});
      return _importWords(refreshed, ids);
    }
    // An uncertain request cannot be edited by changing the selection.
    final queuedIds = queued.map((r) => r['entity_id']).toSet();
    if (ids.toSet().length != queuedIds.length || !queuedIds.containsAll(ids)) {
      throw const ReviewActionUnavailable(
        'Resolve the original import selection first',
      );
    }
    await _db.transaction((txn) async {
      await _assertOwner(txn, p);
      await txn.update(
        'sync_queue',
        {
          'basis': jsonEncode({
            'live_words': refreshed.liveWords,
            'content_bytes': refreshed.contentBytes,
          }),
        },
        where: "partition = ? AND kind = 'import'",
        whereArgs: [p],
      );
      await _setPartition(txn, p, {'import_confirmation': 0});
    });
    return _sendImports(p);
  }

  Future<ImportOutcome> _sendImports(String p) async {
    final before = (await _importCandidates(_db)).length;
    final queued = (await _db.query(
      'sync_queue',
      where: "partition = ? AND kind = 'import'",
      whereArgs: [p],
    )).length;
    SyncRun? r;
    for (var batch = 0; batch < 50; batch++) {
      r = await _pushOnce(p);
      if (r != SyncRun.done) break;
      final remaining = await _db.query(
        'sync_queue',
        where: "partition = ? AND kind = 'import'",
        whereArgs: [p],
      );
      if (remaining.isEmpty) break;
    }
    final after = (await _importCandidates(_db)).length;
    if (r == SyncRun.needsImportConfirmation) {
      final st = await _api.state();
      return ImportOutcome(
        confirmLiveWords: st.liveWords,
        confirmContentBytes: st.contentBytes,
      );
    }
    if (r != SyncRun.done) return const ImportOutcome(pending: true);
    await _decide('imported');
    final imported = before - after;
    return ImportOutcome(imported: imported, leftInGuest: queued - imported);
  }

  /// A result of an import create: an accepted word moves from the guest
  /// notebook into the account cache; a rejected one stays a guest word.
  Future<void> _settleImported(
    DatabaseExecutor txn,
    String p,
    Map<String, Object?> queued,
    MutationResult r,
  ) async {
    final mutation =
        (jsonDecode(utf8.decode(queued['payload']! as Uint8List)) as Map)
            .cast<String, Object?>();
    final saved = await txn.query(
      'account_workspaces',
      where: 'account_id = ?',
      whereArgs: [AppDatabase.guestWorkspace],
    );
    final archive = saved.isEmpty
        ? <String, Object?>{'words': <Map>[]}
        : (jsonDecode(saved.single['payload']! as String) as Map)
              .cast<String, Object?>();
    final words = ((archive['words'] as List?) ?? const []).cast<Map>();
    final guestRow = words
        .where((w) => w['id'] == r.entityId)
        .firstOrNull
        ?.cast<String, Object?>();
    final local = guestRow ?? await _row(txn, r.entityId);
    final ok =
        (['applied', 'merged', 'no_op'].contains(r.effectiveOutcome) ||
            (r.code == 'mutation_expired' && _reflects(mutation, r.record))) &&
        r.record != null &&
        r.record!['deleted'] != true;
    if (!ok) {
      if (r.code == 'mutation_expired' || r.code == 'mutation_reused') {
        await _review(
          txn,
          p,
          r.entityId,
          'create',
          mutation,
          local == null
              ? (mutation['data'] as Map).cast<String, Object?>()
              : rowData(local),
          r.code!,
          r.record,
          origin: queued,
        );
        // The old import is now review-only, including its guest source.
        // It cannot be sequenced again by a later generic import action.
        if (guestRow != null) {
          archive['words'] = [
            for (final w in words)
              w['id'] == r.entityId ? {...w, 'sync_hold': 'review'} : w,
          ];
          await txn.update(
            'account_workspaces',
            {'payload': jsonEncode(archive)},
            where: 'account_id = ?',
            whereArgs: [AppDatabase.guestWorkspace],
          );
        } else if (local != null) {
          await txn.update(
            'words',
            {'sync_hold': 'review'},
            where: 'id = ?',
            whereArgs: [r.entityId],
          );
        }
      }
      return;
    }
    if (guestRow != null) {
      archive['words'] = words.where((w) => w['id'] != r.entityId).toList();
      // Remove references to the moved word from the guest archive. Review
      // scheduling remains device-only and is never part of the wire payload.
      for (final table in [
        'srs_reviews',
        'gate_logs',
        'gate_round_progress',
        'gate_pending_answers',
        'gate_word_rotation',
      ]) {
        archive[table] = ((archive[table] as List?) ?? const [])
            .where((row) => (row as Map)['word_id'] != r.entityId)
            .toList();
      }
      final pool = archive['practice_pool'] as Map?;
      if (pool != null && pool['practice_word_ids_json'] != null) {
        pool['practice_word_ids_json'] = jsonEncode(
          (jsonDecode(pool['practice_word_ids_json'] as String) as List)
              .where((id) => id != r.entityId)
              .toList(),
        );
      }
      await txn.update(
        'account_workspaces',
        {'payload': jsonEncode(archive)},
        where: 'account_id = ?',
        whereArgs: [AppDatabase.guestWorkspace],
      );
    }
    await txn.insert('words', {
      ..._rowFromRecord(r.record!, local),
      'provenance': 'account',
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }
}

enum _Mode { normal, restore, retired }

class _ResetHandled implements Exception {
  const _ResetHandled();
}

class _NotebookClosed implements Exception {
  const _NotebookClosed();
}
