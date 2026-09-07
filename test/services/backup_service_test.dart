import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:veea_english_app/data/local/sqlite_vocabulary_repository.dart';
import 'package:veea_english_app/models/part_of_speech.dart';
import 'package:veea_english_app/models/vocabulary_word.dart';
import 'package:veea_english_app/services/backup_service.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late SqliteVocabularyRepository repo;
  final now = DateTime(2026, 8, 18, 10);

  setUp(() async {
    repo = await SqliteVocabularyRepository.open(
      path: inMemoryDatabasePath,
      now: () => now,
    );
  });

  tearDown(() => repo.close());

  test('BackupService exports to JSON and imports back cleanly', () async {
    final word1 = VocabularyWord.create(
      id: 'w1',
      word: 'resilient',
      meaning: 'kiên cường',
      date: '2026-08-18',
      now: now,
      pronunciation: '/rɪˈzɪl.jənt/',
      partOfSpeech: PartOfSpeech.adjective,
      examples: ['Stay resilient.'],
      tags: ['starter', 'mindset'],
    );
    await repo.insert(word1);

    final jsonString = BackupService.exportToJson([word1]);
    expect(jsonString, contains('"word": "resilient"'));
    expect(jsonString, contains('"wordCount": 1'));

    // Wipe repo
    await repo.deleteAll();
    expect((await repo.recentWords()).length, 0);

    // Import back
    final result = await BackupService.importBackupText(
      rawContent: jsonString,
      repository: repo,
      now: () => now,
    );

    expect(result.isSuccess, isTrue);
    expect(result.inserted, 1);
    expect(result.merged, 0);

    final words = await repo.recentWords();
    expect(words.length, 1);
    expect(words.first.word, 'resilient');
    expect(words.first.meaning, 'kiên cường');
    expect(words.first.pronunciation, '/rɪˈzɪl.jənt/');
    expect(words.first.partOfSpeech, PartOfSpeech.adjective);
    expect(words.first.examples, ['Stay resilient.']);
    expect(words.first.tags, ['starter', 'mindset']);
  });

  test('BackupService exports to CSV and handles commas and quotes', () async {
    final word = VocabularyWord.create(
      id: 'w2',
      word: 'trade-off',
      meaning: 'sự đánh đổi, thỏa hiệp "đôi bên"',
      date: '2026-08-18',
      now: now,
      partOfSpeech: PartOfSpeech.noun,
      examples: ['Cost vs quality, a classic trade-off.'],
      tags: ['strategy', 'decision'],
    );
    await repo.insert(word);

    final csvString = BackupService.exportToCsv([word]);
    expect(csvString, contains('trade-off'));
    // Quotes inside meaning should be escaped as ""
    expect(csvString, contains('""đôi bên""'));

    await repo.deleteAll();

    final result = await BackupService.importBackupText(
      rawContent: csvString,
      repository: repo,
      now: () => now,
    );

    expect(result.isSuccess, isTrue);
    expect(result.inserted, 1);

    final imported = await repo.recentWords();
    expect(imported.first.word, 'trade-off');
    expect(imported.first.meaning, 'sự đánh đổi, thỏa hiệp "đôi bên"');
  });

  test('BackupService merges duplicate words cleanly', () async {
    final existing = VocabularyWord.create(
      id: 'w3',
      word: 'bottleneck',
      meaning: 'điểm nghẽn',
      date: '2026-08-18',
      now: now,
      examples: ['First example.'],
      tags: ['tech'],
    );
    await repo.insert(existing);

    // Import a CSV with same word but new pronunciation, extra example, and extra tag
    const csvData = '''
Word,Meaning,Part of Speech,Pronunciation,Date,Examples,Tags,Source
bottleneck,,noun,/ˈbɑː.t̬əl.nek/,2026-08-18,Second example.,system; devops,Manual
''';

    final result = await BackupService.importBackupText(
      rawContent: csvData,
      repository: repo,
      now: () => now,
    );

    expect(result.isSuccess, isTrue);
    expect(result.inserted, 0);
    expect(result.merged, 1);

    final updated = await repo.recentWords();
    expect(updated.length, 1);
    expect(updated.first.word, 'bottleneck');
    expect(updated.first.meaning, 'điểm nghẽn'); // Preserved
    expect(updated.first.pronunciation, '/ˈbɑː.t̬əl.nek/'); // Enriched
    expect(updated.first.partOfSpeech, PartOfSpeech.noun); // Enriched
    expect(updated.first.examples, contains('First example.'));
    expect(updated.first.examples, contains('Second example.'));
    expect(updated.first.tags, contains('tech'));
    expect(updated.first.tags, contains('system'));
  });

  test(
    'BackupService previewBackup returns correct stats and samples without modifying database',
    () async {
      final existing = VocabularyWord.create(
        id: 'existing-id',
        word: 'persist',
        meaning: 'kiên trì',
        date: '2026-08-18',
        now: now,
      );
      await repo.insert(existing);

      final backupJson = BackupService.exportToJson([
        existing,
        VocabularyWord.create(
          id: 'new-id',
          word: 'transient',
          meaning: 'ngắn ngủi',
          date: '2026-08-18',
          now: now,
        ),
      ]);

      final preview = await BackupService.previewBackup(
        rawContent: backupJson,
        repository: repo,
      );

      expect(preview.isSuccess, isTrue);
      expect(preview.totalParsed, 2);
      expect(preview.wouldInsert, 1);
      expect(preview.wouldMerge, 1);
      expect(preview.summary, contains('1 new'));

      // DB state is untouched
      final count = (await repo.recentWords()).length;
      expect(count, 1);
    },
  );

  test(
    'BackupService regenerates ID on collision with different word to prevent overwriting unrelated data',
    () async {
      final existing = VocabularyWord.create(
        id: 'collision-id-123',
        word: 'cat',
        meaning: 'con mèo',
        date: '2026-08-18',
        now: now,
      );
      await repo.insert(existing);

      // Backup entry with SAME ID but DIFFERENT word 'dog'
      final importedDog = VocabularyWord.create(
        id: 'collision-id-123',
        word: 'dog',
        meaning: 'con chó',
        date: '2026-08-18',
        now: now,
      );

      final jsonContent = BackupService.exportToJson([importedDog]);

      final result = await BackupService.importBackupText(
        rawContent: jsonContent,
        repository: repo,
        now: () => now,
      );

      expect(result.isSuccess, isTrue);
      expect(result.inserted, 1);
      expect(result.merged, 0);

      // BOTH words must exist in repository!
      final words = await repo.recentWords();
      expect(words.length, 2);
      final cat = words.firstWhere((w) => w.word == 'cat');
      final dog = words.firstWhere((w) => w.word == 'dog');
      expect(cat.id, 'collision-id-123');
      expect(dog.id, isNot('collision-id-123')); // Newly generated UUID
      expect(dog.meaning, 'con chó');
    },
  );
}
