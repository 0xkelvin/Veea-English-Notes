import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:veea_english_app/data/local/sqlite_vocabulary_repository.dart';

/// Recreates the shipped v1 schema so the upgrade path is exercised against
/// what real users actually have on disk.
Future<void> createV1Database(String path) async {
  final db = await databaseFactory.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: 1,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE words (
            id TEXT PRIMARY KEY,
            word TEXT NOT NULL,
            vietnamese_meaning TEXT NOT NULL,
            examples TEXT NOT NULL DEFAULT '[]',
            date TEXT NOT NULL,
            created_at TEXT NOT NULL
          )
        ''');
        await db.execute('CREATE INDEX idx_words_date ON words(date)');
      },
    ),
  );
  await db.insert('words', {
    'id': 'w1',
    'word': 'resilient',
    'vietnamese_meaning': 'kiên cường',
    'examples': '["a resilient system"]',
    'date': '2026-08-10',
    'created_at': '2026-08-10T09:00:00.000Z',
  });
  await db.insert('words', {
    'id': 'w2',
    'word': 'throttle',
    'vietnamese_meaning': 'điều tiết',
    'examples': '[]',
    'date': '2026-08-11',
    'created_at': '2026-08-11T09:00:00.000Z',
  });
  await db.close();
}

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('veea_db_test');
  });

  tearDown(() async {
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  group('v1 -> v2 migration', () {
    test('preserves every existing row', () async {
      final path = '${tempDir.path}/veea.db';
      await createV1Database(path);

      final repo = await SqliteVocabularyRepository.open(path: path);
      addTearDown(repo.close);

      final stats = await repo.stats();
      expect(stats.totalWords, 2);

      final day = await repo.wordsForDate('2026-08-10');
      expect(day, hasLength(1));
      expect(day.single.word, 'resilient');
    });

    test(
      'carries vietnamese_meaning across to the renamed meaning column',
      () async {
        final path = '${tempDir.path}/veea.db';
        await createV1Database(path);

        final repo = await SqliteVocabularyRepository.open(path: path);
        addTearDown(repo.close);

        final word = await repo.findById('w1');
        expect(word!.meaning, 'kiên cường');
        expect(word.examples, ['a resilient system']);
      },
    );

    test(
      'seeds updated_at from created_at and marks rows for upload',
      () async {
        final path = '${tempDir.path}/veea.db';
        await createV1Database(path);

        final repo = await SqliteVocabularyRepository.open(path: path);
        addTearDown(repo.close);

        final word = await repo.findById('w1');
        expect(word!.updatedAt, word.createdAt);
        // Pre-existing vocabulary must reach the server on the first sync.
        expect(word.isDirty, isTrue);

        expect(await repo.pendingChanges(), hasLength(2));
      },
    );

    test('backfills search_text so migrated words are findable', () async {
      final path = '${tempDir.path}/veea.db';
      await createV1Database(path);

      final repo = await SqliteVocabularyRepository.open(path: path);
      addTearDown(repo.close);

      // Nothing wrote search_text at insert time; the Dart backfill must have
      // populated it during the upgrade.
      expect(await repo.search('resilient'), hasLength(1));
      expect(await repo.search('kiên'), hasLength(1));
      expect(await repo.search('kien'), hasLength(1));
    });

    test('adds the new columns with usable defaults', () async {
      final path = '${tempDir.path}/veea.db';
      await createV1Database(path);

      final repo = await SqliteVocabularyRepository.open(path: path);
      addTearDown(repo.close);

      final word = await repo.findById('w2');
      expect(word!.pronunciation, isNull);
      expect(word.partOfSpeech, isNull);
      expect(word.source, isNull);
      expect(word.tags, isEmpty);
      expect(word.isDeleted, isFalse);
    });

    test('is idempotent when the database is reopened', () async {
      final path = '${tempDir.path}/veea.db';
      await createV1Database(path);

      var repo = await SqliteVocabularyRepository.open(path: path);
      await repo.close();
      repo = await SqliteVocabularyRepository.open(path: path);
      addTearDown(repo.close);

      expect((await repo.stats()).totalWords, 2);
    });
  });

  test('a fresh install creates the v2 schema directly', () async {
    final repo = await SqliteVocabularyRepository.open(
      path: '${tempDir.path}/fresh.db',
    );
    addTearDown(repo.close);
    expect((await repo.stats()).totalWords, 0);
  });
}
