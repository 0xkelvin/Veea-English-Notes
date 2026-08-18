import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/remote/api_client.dart';
import '../data/remote/vocabulary_api.dart';
import '../data/vocabulary_repository.dart';
import '../models/vocabulary_word.dart';

enum SyncState { idle, syncing, failed }

/// Drives offline-first synchronisation.
///
/// The local database is always the source of truth for what the user sees;
/// this only reconciles it with the server in the background. A failed sync is
/// therefore never fatal — the app keeps working and the next attempt picks up
/// where this one stopped.
class SyncService extends ChangeNotifier {
  SyncService({
    required VocabularyRepository repository,
    required VocabularyApi api,
    DateTime Function()? now,
  }) : _repository = repository,
       _api = api,
       _now = now ?? DateTime.now;

  /// Where the pull cursor is kept. Deliberately not in secure storage — it
  /// is not a secret, and it must survive a sign-out/sign-in on the same
  /// account without forcing a full re-download.
  static const String _cursorKey = 'sync.cursor';

  /// Stops a pathological server from keeping the client in a pull loop.
  static const int _maxPagesPerRun = 20;

  final VocabularyRepository _repository;
  final VocabularyApi _api;
  final DateTime Function() _now;

  SyncState _state = SyncState.idle;
  String? _lastError;
  DateTime? _lastSyncedAt;
  int _pendingCount = 0;

  SyncState get state => _state;
  bool get isSyncing => _state == SyncState.syncing;
  String? get lastError => _lastError;
  DateTime? get lastSyncedAt => _lastSyncedAt;

  /// Local changes still waiting to reach the server.
  int get pendingCount => _pendingCount;

  /// Refreshes [pendingCount] without contacting the server.
  Future<void> refreshPendingCount() async {
    try {
      _pendingCount = (await _repository.pendingChanges()).length;
      notifyListeners();
    } catch (error, stack) {
      debugPrint('Could not count pending changes: $error\n$stack');
    }
  }

  /// Runs a full sync: push what is pending, pull what is new, repeat while
  /// the server reports more pages.
  ///
  /// Returns true when everything reconciled. Concurrent calls are ignored
  /// rather than queued — the next scheduled run will catch up.
  Future<bool> synchronise() async {
    if (_state == SyncState.syncing) return false;

    _state = SyncState.syncing;
    _lastError = null;
    notifyListeners();

    try {
      final prefs = await SharedPreferences.getInstance();
      var cursor = _readCursor(prefs);
      var pages = 0;

      while (pages < _maxPagesPerRun) {
        pages++;

        // Only the first page carries the push; later pages are pure paging
        // and re-sending would duplicate work.
        final outgoing = pages == 1
            ? await _repository.pendingChanges()
            : const <VocabularyWord>[];

        final result = await _api.sync(changes: outgoing, since: cursor);

        // Apply the server's rows *before* moving the cursor, so a crash in
        // between replays the page instead of skipping it.
        await _repository.mergeFromServer(result.changes);

        if (outgoing.isNotEmpty) {
          await _repository.markSynced(result.acceptedIds, _now());
          _warnAboutRejections(outgoing.map((w) => w.id), result.acceptedIds);
        }

        cursor = result.serverTime;
        await prefs.setString(_cursorKey, cursor.toUtc().toIso8601String());

        if (!result.hasMore) break;
      }

      // Tombstones the server has acknowledged are no longer needed locally.
      await _repository.purgeSyncedTombstones();

      _lastSyncedAt = _now();
      _state = SyncState.idle;
      await refreshPendingCount();
      return true;
    } on ApiException catch (error) {
      _lastError = error is OfflineException
          ? 'Offline — your words are saved on this device'
          : error.message;
      _state = SyncState.failed;
      notifyListeners();
      return false;
    } catch (error, stack) {
      debugPrint('Sync failed: $error\n$stack');
      _lastError = 'Sync failed';
      _state = SyncState.failed;
      notifyListeners();
      return false;
    }
  }

  /// Forgets the pull cursor so the next sync downloads everything.
  ///
  /// Used when signing into a different account, whose history this device
  /// has never seen.
  Future<void> resetCursor() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_cursorKey);
    _lastSyncedAt = null;
    notifyListeners();
  }

  DateTime? _readCursor(SharedPreferences prefs) {
    final raw = prefs.getString(_cursorKey);
    return raw == null ? null : DateTime.tryParse(raw);
  }

  /// A pushed id the server did not accept means the row belongs to another
  /// account. Retrying cannot help, so it is logged rather than retried.
  void _warnAboutRejections(Iterable<String> pushed, List<String> accepted) {
    final acceptedSet = accepted.toSet();
    final rejected = pushed.where((id) => !acceptedSet.contains(id)).toList();
    if (rejected.isNotEmpty) {
      debugPrint('Server rejected ${rejected.length} word(s): $rejected');
    }
  }
}
