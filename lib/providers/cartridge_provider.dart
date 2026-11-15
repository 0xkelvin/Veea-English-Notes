import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:sqflite/sqflite.dart';
import '../data/cartridges/cartridge_api.dart';
import '../data/cartridges_data.dart';
import '../data/local/app_database.dart';
import '../data/local/sqlite_vocabulary_repository.dart';
import '../data/remote/api_client.dart';
import '../models/cartridge.dart';
import '../services/sync_service.dart';
import 'vocabulary_provider.dart';

enum IngestMode { full, dailySprint }

/// An immutable identity for the exact pre-restore request being reviewed.
class BlockedCartridgeInstall {
  BlockedCartridgeInstall._(this.owner, this.id, this.version, this.exactBody);
  final String owner, id, exactBody;
  final int version;
}

/// Read-only preflight shown before explicit confirmation. Rechecked before replacement.
class CartridgeInstallReview {
  CartridgeInstallReview._(
    this.request,
    this.pack,
    Map<String, Object?> capacity,
  ) : capacity = Map.unmodifiable(capacity);
  final BlockedCartridgeInstall request;
  final CartridgeMetadata pack;
  final Map<String, Object?> capacity;
}

/// Bundled starter plus account-scoped, durable server installation attempts (TRD 10).
class CartridgeProvider extends ChangeNotifier {
  CartridgeProvider({this.repository, this.api, this.sync}) {
    ready = refreshLocal();
  }
  late final Future<void> ready;
  final SqliteVocabularyRepository? repository;
  final CartridgeApi? api;
  final SyncService? sync;
  String? _owner;
  final Set<String> _installed = {};
  List<BlockedCartridgeInstall> _blocked = [];
  List<BlockedCartridgeInstall> get blockedInstalls =>
      List.unmodifiable(_blocked);
  List<CartridgeMetadata> catalog = [];
  bool isInitialized = false, busy = false;
  String? message;
  bool _disposed = false;
  List<Cartridge> get availableCartridges => CartridgesData.allCartridges;
  String? get loadedOwner => _owner;
  bool isInstalled(String id) => _installed.contains(id);
  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Future<String> _current() async =>
      await repository?.notebookOwner() ?? AppDatabase.guestWorkspace;
  Future<void> refreshLocal() async {
    final owner = await _current();
    if (_owner != owner) {
      catalog = [];
      _installed.clear();
      _blocked = [];
      message = null;
      _owner = owner;
    }
    if (repository != null) {
      final rows = await repository!.database.query(
        'cartridge_local_state',
        where: 'owner_id = ?',
        whereArgs: [owner],
      );
      if (await _current() != owner) return;
      _installed
        ..clear()
        ..addAll(
          rows
              .where((r) => (r['installed_version']! as int) > 0)
              .map((r) => r['cartridge_id']! as String),
        );
      _blocked = rows
          .where((r) => r['blocked'] == 1)
          .map(
            (r) => BlockedCartridgeInstall._(
              owner,
              r['cartridge_id']! as String,
              r['pending_version']! as int,
              r['pending_body']! as String,
            ),
          )
          .toList();
    }
    isInitialized = true;
    _changed();
  }

  Future<void> refreshCatalog() async {
    await ready;
    await refreshLocal();
    if (api == null || _owner == AppDatabase.guestWorkspace) return;
    final owner = _owner;
    try {
      final rows = await api!.catalog();
      if (await _current() != owner) return;
      catalog = rows;
    } on Object catch (_) {
      if (await _current() != owner) return;
      message =
          'Catalog unavailable. Installed words and the Free starter work offline.';
    }
    _changed();
  }

  Future<void> _same(String owner) async {
    if (await _current() != owner) {
      throw const ApiException('The notebook changed. Open the library again.');
    }
  }

  Future<Map<String, Object?>?> pending(String id) async {
    if (repository == null) return null;
    final rows = await repository!.database.query(
      'cartridge_local_state',
      where: 'owner_id = ? AND cartridge_id = ?',
      whereArgs: [await _current(), id],
    );
    return rows.isEmpty ? null : rows.single;
  }

  Future<void> _save(
    String owner,
    String id,
    Map<String, Object?> values, {
    BlockedCartridgeInstall? resolving,
  }) async {
    await repository!.database.transaction((tx) async {
      final rows = await tx.query(
        'app_metadata',
        where: 'key = ?',
        whereArgs: ['notebook_owner'],
      );
      final current = rows.isEmpty
          ? AppDatabase.guestWorkspace
          : rows.single['value'];
      if (current != owner) {
        throw const ApiException(
          'The notebook changed. Open the library again.',
        );
      }
      if (resolving != null) {
        final changed = await tx.update(
          'cartridge_local_state',
          values,
          where:
              'owner_id = ? AND cartridge_id = ? AND blocked = 1 AND pending_version = ? AND pending_body = ?',
          whereArgs: [owner, id, resolving.version, resolving.exactBody],
        );
        if (changed != 1) {
          throw const ApiException(
            'This review changed. Open the library again.',
          );
        }
        return;
      }
      await tx.insert('cartridge_local_state', {
        'owner_id': owner,
        'cartridge_id': id,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
      await tx.update(
        'cartridge_local_state',
        values,
        where: 'owner_id = ? AND cartridge_id = ?',
        whereArgs: [owner, id],
      );
    });
  }

  Future<void> _reviewCurrent(BlockedCartridgeInstall request) async {
    await _same(request.owner);
    final row = await pending(request.id);
    await _same(request.owner);
    if (row?['blocked'] != 1 ||
        row?['pending_version'] != request.version ||
        row?['pending_body'] != request.exactBody) {
      throw const ApiException('This review changed. Open the library again.');
    }
  }

  /// Local resolution only: preserve the installed watermark and all owned vocabulary.
  Future<void> discardBlocked(BlockedCartridgeInstall request) async {
    if (busy) return;
    await _reviewCurrent(request);
    await _save(request.owner, request.id, {
      'blocked': 0,
      'pending_body': null,
      'pending_version': null,
      'pending_unknown': 0,
      'needs_confirmation': 0,
    }, resolving: request);
    await refreshLocal();
  }

  Future<CartridgeInstallReview> prepareNewInstall(
    BlockedCartridgeInstall request,
  ) async {
    await ready;
    await _reviewCurrent(request);
    final packs = await api!.catalog();
    await _same(request.owner);
    final matches = packs.where((p) => p.id == request.id);
    if (matches.isEmpty) {
      throw const ApiException(
        'This pack is no longer available. You can discard the saved request.',
      );
    }
    final pack = matches.single;
    await api!.download(
      pack.id,
      pack.version,
    ); // Current server entitlement, never client time.
    await _same(request.owner);
    if (sync != null && !await sync!.synchronise()) {
      throw const ApiException(
        'Sync is not ready. Settle pending vocabulary changes before installing.',
      );
    }
    await _same(request.owner);
    final capacity = await api!.capacity();
    await _reviewCurrent(request);
    return CartridgeInstallReview._(request, pack, capacity);
  }

  /// The caller must show this preflight and obtain explicit confirmation first.
  Future<int> startNewInstall(CartridgeInstallReview confirmed) =>
      _installServer(confirmed.pack, review: confirmed);

  Future<Map<String, Object?>> refreshCapacity() async {
    final owner = await _current();
    final result = await api!.capacity();
    await _same(owner);
    return result;
  }

  /// Explicit confirmation only. Unknown attempts retain their original epoch/version/body
  /// across restart; they are resolved by the server watermark, never by a new writer identity.
  Future<int> installServer(
    CartridgeMetadata pack, {
    Map<String, Object?>? confirmedCapacity,
  }) => _installServer(pack, confirmedCapacity: confirmedCapacity);

  Future<int> _installServer(
    CartridgeMetadata pack, {
    Map<String, Object?>? confirmedCapacity,
    CartridgeInstallReview? review,
  }) async {
    final confirmCapacity = confirmedCapacity != null;
    await ready;
    if (repository == null || api == null) return 0;
    final owner = await _current();
    if (busy) return 0;
    if (owner == AppDatabase.guestWorkspace) {
      throw const ApiException('Sign in to install server packs.');
    }
    busy = true;
    message = null;
    _changed();
    try {
      if (review != null) {
        final fresh = await prepareNewInstall(review.request);
        await _same(owner);
        if (fresh.pack.version != review.pack.version ||
            fresh.capacity['epoch'] != review.capacity['epoch'] ||
            fresh.capacity['live_words'] != review.capacity['live_words'] ||
            fresh.capacity['content_bytes'] !=
                review.capacity['content_bytes']) {
          throw const ApiException(
            'The version or capacity changed. Review and confirm a new installation again.',
          );
        }
        await _save(owner, pack.id, {
          'blocked': 0,
          'pending_body': jsonEncode({
            'epoch': fresh.capacity['epoch'],
            'capacity_basis': {
              'live_words': fresh.capacity['live_words'],
              'content_bytes': fresh.capacity['content_bytes'],
            },
          }),
          'pending_version': fresh.pack.version,
          'pending_unknown': 0,
          'needs_confirmation': 0,
        }, resolving: review.request);
        await refreshLocal();
      }
      var saved = await pending(pack.id);
      await _same(owner);
      if (saved?['blocked'] == 1) {
        throw const ApiException(
          'This pre-restore installation needs review. It will not be replayed automatically.',
        );
      }
      var body = saved?['pending_body'] as String?;
      var version = saved?['pending_version'] as int? ?? pack.version;
      if (body != null &&
          saved?['needs_confirmation'] == 1 &&
          !confirmCapacity) {
        throw const ApiException(
          'Capacity changed. Review capacity and confirm again.',
        );
      }
      if (body == null) {
        // New installs download with current authorization. Accepted unknown retries must be
        // resolvable after downgrade too, so they go straight to their durable receipt check.
        await api!.download(pack.id, version);
        await _same(owner);
        if (sync != null && !await sync!.synchronise()) {
          throw const ApiException(
            'Sync is not ready. Settle pending vocabulary changes before installing.',
          );
        }
        final st = await api!.capacity();
        await _same(owner);
        body = jsonEncode({
          'epoch': st['epoch'],
          'capacity_basis': {
            'live_words': st['live_words'],
            'content_bytes': st['content_bytes'],
          },
        });
        await _save(owner, pack.id, {
          'pending_body': body,
          'pending_version': version,
          'pending_unknown': 0,
          'needs_confirmation': 0,
        });
      } else if (confirmCapacity) {
        final st = confirmedCapacity;
        await _same(owner);
        final old = (jsonDecode(body) as Map).cast<String, Object?>();
        // The epoch of an uncertain attempt is immutable, including after restore.
        old['capacity_basis'] = {
          'live_words': st['live_words'],
          'content_bytes': st['content_bytes'],
        };
        body = jsonEncode(old);
        await _save(owner, pack.id, {
          'pending_body': body,
          'needs_confirmation': 0,
        });
      }
      final earlierUnknown = saved?['pending_unknown'] == 1;
      // Conservative crash marker, written before any bytes leave this device.
      await _save(owner, pack.id, {'pending_unknown': 1});
      Map<String, Object?> result;
      try {
        result = await api!.install(pack.id, version, body, owner: owner);
      } on ApiException catch (e) {
        await _same(owner);
        final unknown =
            earlierUnknown ||
            e is OfflineException ||
            e.statusCode == null ||
            (e.statusCode ?? 0) >= 500;
        if (e.code == 'capacity_changed') {
          await _save(owner, pack.id, {
            'needs_confirmation': 1,
            'pending_unknown': unknown ? 1 : 0,
          });
          final st = await api!.capacity();
          await _same(owner);
          message =
              'Capacity changed: ${st['live_words']} words and ${st['content_bytes']} bytes used. Review and confirm again.';
        } else if (e.code == 'sync_reset_required') {
          await _save(owner, pack.id, {'blocked': 1});
          await refreshLocal();
          message =
              'A database restore requires review. This installation will not be replayed.';
        } else if (!unknown) {
          await _save(owner, pack.id, {
            'pending_body': null,
            'pending_version': null,
            'pending_unknown': 0,
          });
        }
        rethrow;
      }
      await _same(owner);
      await _save(owner, pack.id, {
        'installed_version': result['installed_version'],
        'pending_body': null,
        'pending_version': null,
        'pending_unknown': 0,
        'needs_confirmation': 0,
      });
      _installed.add(pack.id);
      final caughtUp = sync == null || await sync!.synchronise();
      await _same(owner);
      message = caughtUp
          ? 'Pack installed. Your words remain available after downgrade.'
          : 'Installation saved. Connect and sync to finish loading the words.';
      await refreshCatalog();
      return result['added']! as int;
    } on ApiException catch (e) {
      message ??= e.code == 'plan_required'
          ? 'Premium is required for this download or update. Installed words stay available.'
          : e is OfflineException
          ? 'Outcome not confirmed. Retry the saved installation when online.'
          : e.message;
      rethrow;
    } finally {
      busy = false;
      _changed();
    }
  }

  Future<int> installCartridge(
    String id, {
    required VocabularyProvider vocabProvider,
    IngestMode mode = IngestMode.full,
    DateTime? baseDate,
  }) async {
    await ready;
    final repo =
        repository ??
        (vocabProvider.repository is SqliteVocabularyRepository
            ? vocabProvider.repository as SqliteVocabularyRepository
            : null);
    if (repo == null) throw StateError('a persistent notebook is required');
    final owner = await repo.notebookOwner() ?? AppDatabase.guestWorkspace;
    final pack = availableCartridges.firstWhere((c) => c.id == id);
    if (busy) return 0;
    busy = true;
    _changed();
    try {
      // One SQLite transaction: words and the receipt survive or roll back together.
      final count = await repo.database.transaction((tx) async {
        final receipts = await tx.query(
          'cartridge_local_state',
          where: 'owner_id = ? AND cartridge_id = ? AND installed_version > 0',
          whereArgs: [owner, id],
        );
        if (receipts.isNotEmpty) return 0;
        final rows = await tx.query(
          'app_metadata',
          where: 'key = ?',
          whereArgs: ['notebook_owner'],
        );
        if ((rows.isEmpty
                ? AppDatabase.guestWorkspace
                : rows.single['value']) !=
            owner) {
          throw StateError('notebook changed');
        }
        var n = 0;
        final now = baseDate ?? DateTime.now();
        for (var i = 0; i < pack.words.length; i++) {
          final date = mode == IngestMode.dailySprint
              ? now.add(Duration(days: i ~/ 5))
              : now;
          final word = pack.words[i].toVocabularyWord(
            date: DateFormat('yyyy-MM-dd').format(date),
            now: date,
            cartridgeTitle: pack.title,
          );
          // Stable IDs include tombstones; an explicit update must not recreate a deletion.
          if ((await tx.query(
            'words',
            columns: ['id'],
            where: 'id = ?',
            whereArgs: [word.id],
          )).isNotEmpty) {
            continue;
          }
          final duplicate = await tx.query(
            'words',
            columns: ['id'],
            where: 'lower(word) = lower(?) AND is_deleted = 0',
            whereArgs: [word.word],
          );
          if (duplicate.isNotEmpty) continue;
          await tx.insert('words', word.toDbMap());
          n++;
        }
        await tx.insert('cartridge_local_state', {
          'owner_id': owner,
          'cartridge_id': id,
          'installed_version': 1,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        return n;
      });
      _owner = owner;
      _installed.add(id);
      await vocabProvider.init();
      return count;
    } finally {
      busy = false;
      _changed();
    }
  }

  /// Legacy removal keeps the receipt: deleting owned words never enables a replay.
  Future<int> uninstallCartridge(
    String id, {
    required VocabularyProvider vocabProvider,
  }) async {
    final pack = availableCartridges.firstWhere((c) => c.id == id);
    var n = 0;
    for (final w in pack.words) {
      final key = w
          .toVocabularyWord(date: '2026-01-01', now: DateTime(2026))
          .id;
      for (final owned
          in vocabProvider.words.where((v) => v.id == key).toList()) {
        await vocabProvider.deleteWord(owned.id);
        n++;
      }
    }
    return n;
  }
}
