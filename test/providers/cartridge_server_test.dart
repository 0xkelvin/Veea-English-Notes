import 'dart:io';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';
import 'package:veea_english_app/data/cartridges/cartridge_api.dart';
import 'package:veea_english_app/data/cartridges_data.dart';
import 'package:veea_english_app/data/local/sqlite_vocabulary_repository.dart';
import 'package:veea_english_app/data/remote/api_client.dart';
import 'package:veea_english_app/providers/cartridge_provider.dart';
import 'package:veea_english_app/providers/vocabulary_provider.dart';

class FakeCartridgeApi implements CartridgeApi {
  bool premium = true, lost = false, capacityChanged = false;
  int version = 1, installed = 0, posts = 0, downloads = 0;
  final bodies = <String>[];
  ApiException? refusal;
  Map<String, Object?> result() => {
    'installed_version': installed,
    'added': 1,
    'head_revision': installed,
  };
  @override
  Future<List<CartridgeMetadata>> catalog() async => [
    CartridgeMetadata({
      'id': 'synthetic',
      'title': 'Synthetic fixture',
      'required_plan': 'premium',
      'version': version,
      'installed_version': installed,
      'word_count': version,
    }),
  ];
  @override
  Future<void> download(String id, int version) async {
    downloads++;
    if (!premium) {
      throw const ApiException(
        'Premium required',
        statusCode: 403,
        code: 'plan_required',
      );
    }
  }

  @override
  Future<Map<String, Object?>> capacity() async => {
    'epoch': '00000000-0000-4000-8000-000000000001',
    'live_words': capacityChanged ? 50000 : 0,
    'content_bytes': 0,
  };
  @override
  Future<Map<String, Object?>> install(
    String id,
    int version,
    String body,
  ) async {
    posts++;
    bodies.add(body);
    if (refusal != null) throw refusal!;
    if (installed >= version) {
      return {
        'installed_version': installed,
        'added': 0,
        'head_revision': installed,
      };
    }
    if (capacityChanged) {
      throw const ApiException(
        'capacity',
        statusCode: 409,
        code: 'capacity_changed',
      );
    }
    installed = version;
    if (lost) throw const OfflineException();
    return result();
  }
}

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  late SqliteVocabularyRepository repo;
  late FakeCartridgeApi api;
  late CartridgeProvider provider;
  final a = const Uuid().v4(), b = const Uuid().v4();
  setUp(() async {
    repo = await SqliteVocabularyRepository.open(path: inMemoryDatabasePath);
    await repo.activateNotebook(a);
    api = FakeCartridgeApi();
    provider = CartridgeProvider(repository: repo, api: api);
    await provider.refreshCatalog();
  });
  tearDown(() async {
    provider.dispose();
    await repo.close();
  });

  test(
    'unknown accepted install survives provider restart and downgrade; retries same bytes without redownload',
    () async {
      final pack = provider.catalog.single;
      api.lost = true;
      await expectLater(
        provider.installServer(pack),
        throwsA(isA<OfflineException>()),
      );
      final stored = await provider.pending(pack.id);
      expect(stored!['pending_unknown'], 1);
      final original = stored['pending_body'];
      provider.dispose();
      provider = CartridgeProvider(repository: repo, api: api);
      api.premium = false;
      await provider.refreshCatalog();
      expect(await provider.installServer(pack), 0);
      expect(api.posts, 2);
      expect(api.downloads, 1);
      expect(api.bodies, [original, original]);
      expect((await provider.pending(pack.id))!['installed_version'], 1);
    },
  );
  test(
    'plan_required is a fixed refusal and does not queue installation',
    () async {
      api.premium = false;
      await expectLater(
        provider.installServer(provider.catalog.single),
        throwsA(
          isA<ApiException>().having((e) => e.code, 'code', 'plan_required'),
        ),
      );
      expect(api.posts, 0);
      expect(await provider.pending('synthetic'), isNull);
      expect(provider.message, contains('Installed words stay available'));
    },
  );
  test(
    'capacity refusal is atomic; no resubmission until explicit refreshed confirmation',
    () async {
      api.capacityChanged = true;
      final pack = provider.catalog.single;
      await expectLater(
        provider.installServer(pack),
        throwsA(isA<ApiException>()),
      );
      expect(api.installed, 0);
      expect((await provider.pending(pack.id))!['needs_confirmation'], 1);
      await expectLater(
        provider.installServer(pack),
        throwsA(isA<ApiException>()),
      );
      expect(api.posts, 1);
      api.capacityChanged = false;
      expect(
        await provider.installServer(
          pack,
          confirmedCapacity: await api.capacity(),
        ),
        1,
      );
      expect(api.posts, 2);
    },
  );
  test(
    'account switch isolates pending attempts and confirmed deletion clears only that owner',
    () async {
      api.lost = true;
      await expectLater(
        provider.installServer(provider.catalog.single),
        throwsA(isA<OfflineException>()),
      );
      await repo.activateNotebook(b);
      await provider.refreshLocal();
      expect(await provider.pending('synthetic'), isNull);
      await repo.database.insert('cartridge_local_state', {
        'owner_id': b,
        'cartridge_id': 'synthetic',
        'installed_version': 3,
      });
      await repo.deleteAll(accountId: a);
      expect(
        (await repo.database.query('cartridge_local_state')).single['owner_id'],
        b,
      );
    },
  );
  test(
    'new server version requires an explicit install, and then advances local watermark',
    () async {
      await provider.installServer(provider.catalog.single);
      api.version = 2;
      await provider.refreshCatalog();
      expect(api.posts, 1);
      expect(provider.catalog.single.version, 2);
      await provider.installServer(provider.catalog.single);
      expect(api.posts, 2);
      expect((await provider.pending('synthetic'))!['installed_version'], 2);
    },
  );
  test(
    'starter is offline, transactional, retry-safe and does not restore edited/deleted words',
    () async {
      await repo.activateNotebook(null);
      final vocab = VocabularyProvider(repo);
      await vocab.init();
      expect(
        await provider.installCartridge(
          CartridgesData.starter.id,
          vocabProvider: vocab,
        ),
        5,
      );
      final ids = vocab.words.map((w) => w.id).toList();
      expect(ids.every((id) => Uuid.isValidUUID(fromString: id)), isTrue);
      final edited = vocab.words.first;
      await repo.update(edited.copyWith(meaning: 'mine'));
      await vocab.deleteWord(ids.last);
      expect(
        await provider.installCartridge(
          CartridgesData.starter.id,
          vocabProvider: vocab,
        ),
        0,
      );
      expect((await repo.findById(edited.id))!.meaning, 'mine');
      expect((await repo.findById(ids.last))!.isDeleted, isTrue);
      vocab.dispose();
    },
  );
  test(
    'unknown attempt preserves exact request after a later plan refusal',
    () async {
      final pack = provider.catalog.single;
      api.refusal = const OfflineException();
      await expectLater(
        provider.installServer(pack),
        throwsA(isA<OfflineException>()),
      );
      final original = (await provider.pending(pack.id))!['pending_body'];
      api.refusal = const ApiException(
        'plan',
        statusCode: 403,
        code: 'plan_required',
      );
      await expectLater(
        provider.installServer(pack),
        throwsA(isA<ApiException>()),
      );
      final pending = await provider.pending(pack.id);
      expect(pending!['pending_unknown'], 1);
      expect(pending['pending_body'], original);
      expect(api.bodies, [original, original]);
      api.refusal = null;
      expect(await provider.installServer(pack), 1);
    },
  );
  test(
    'restore refusal blocks an unknown install without adopting the new epoch',
    () async {
      final pack = provider.catalog.single;
      api.refusal = const OfflineException();
      await expectLater(
        provider.installServer(pack),
        throwsA(isA<OfflineException>()),
      );
      final original =
          (await provider.pending(pack.id))!['pending_body'] as String;
      api.refusal = const ApiException(
        'restore',
        statusCode: 410,
        code: 'sync_reset_required',
      );
      await expectLater(
        provider.installServer(pack),
        throwsA(isA<ApiException>()),
      );
      expect((await provider.pending(pack.id))!['blocked'], 1);
      api.refusal = null;
      await expectLater(
        provider.installServer(pack),
        throwsA(isA<ApiException>()),
      );
      expect(api.posts, 2);
      expect((await provider.pending(pack.id))!['pending_body'], original);
      expect(
        jsonDecode(original)['epoch'],
        '00000000-0000-4000-8000-000000000001',
      );
    },
  );
  test(
    'SQLite v13 upgrade preserves notebook and creates durable install state',
    () async {
      final dir = await Directory.systemTemp.createTemp('veea-cartridge-');
      addTearDown(() => dir.delete(recursive: true));
      final path = '${dir.path}/notebook.db';
      var old = await databaseFactory.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 13,
          onCreate: (db, _) async {
            await db.execute('CREATE TABLE preserved (value TEXT)');
            await db.insert('preserved', {'value': 'saved'});
          },
        ),
      );
      await old.close();
      final upgraded = await SqliteVocabularyRepository.open(path: path);
      addTearDown(upgraded.close);
      expect(
        (await upgraded.database.query('preserved')).single['value'],
        'saved',
      );
      await upgraded.database.insert('cartridge_local_state', {
        'owner_id': a,
        'cartridge_id': 'fixture',
        'pending_body': 'exact',
      });
      expect(
        (await upgraded.database.query(
          'cartridge_local_state',
        )).single['pending_body'],
        'exact',
      );
    },
  );
}
