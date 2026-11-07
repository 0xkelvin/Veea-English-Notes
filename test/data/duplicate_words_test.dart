import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:veea_english_app/data/local/sqlite_vocabulary_repository.dart';
import 'package:veea_english_app/models/vocabulary_word.dart';
import 'package:veea_english_app/models/word_identity.dart';
import 'package:veea_english_app/providers/vocabulary_provider.dart';
import 'package:veea_english_app/services/backup_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  late SqliteVocabularyRepository repo;
  final now = DateTime(2026, 11, 7, 12);
  VocabularyWord word(
    String id,
    String spelling, {
    String meaning = 'ngân hàng',
    String date = '2026-11-07',
  }) => VocabularyWord.create(
    id: id,
    word: spelling,
    meaning: meaning,
    date: date,
    now: now,
  );
  setUp(() async {
    repo = await SqliteVocabularyRepository.open(path: inMemoryDatabasePath);
  });
  tearDown(() => repo.close());
  test(
    'identity ignores case and whitespace without stemming or removing accents',
    () {
      expect(WordIdentity.key('  TAKE  \t OFF  '), 'take off');
      expect(WordIdentity.key('Don’t'), WordIdentity.key("don't"));
      expect(WordIdentity.key('recipe'), isNot(WordIdentity.key('recipes')));
      expect(WordIdentity.key('resume'), isNot(WordIdentity.key('résumé')));
      expect(WordIdentity.key('co-op'), isNot(WordIdentity.key('coop')));
    },
  );
  test(
    'finds complete spelling across dates, ignores notes and deleted words',
    () async {
      await repo.insert(word('saved', 'BANK', date: '2026-10-01'));
      await repo.insert(word('partial', 'banking', meaning: 'bank'));
      await repo.insert(word('note', 'river', meaning: 'bank'));
      await repo.insert(word('deleted', 'bank'));
      await repo.softDelete('deleted', now);
      expect((await repo.matchingWords('  bank  ')).map((w) => w.id), [
        'saved',
      ]);
      expect(await repo.matchingWords('bank', excludeId: 'saved'), isEmpty);
    },
  );
  test('handles phrase whitespace and typographic apostrophes', () async {
    await repo.insert(word('phrase', 'take   off'));
    await repo.insert(word('quote', 'don’t'));
    expect((await repo.matchingWords('take off')).single.id, 'phrase');
    expect((await repo.matchingWords("DON'T")).single.id, 'quote');
  });
  test(
    'a duplicate cannot overwrite a saved entry or its learning records',
    () async {
      await repo.insert(word('saved', 'bank', date: '2026-10-01'));
      await repo.database.insert('srs_reviews', {
        'word_id': 'saved',
        'next_review_date': '2026-11-10',
        'repetitions': 4,
      });
      final before = await repo.database.query('words');
      final reviews = await repo.database.query('srs_reviews');
      await expectLater(
        repo.insertChecked(word('new', ' BANK ')),
        throwsA(isA<DuplicateWordException>()),
      );
      expect(await repo.database.query('words'), before);
      expect(await repo.database.query('srs_reviews'), reviews);
    },
  );
  test(
    'a second meaning requires explicit opt-in and identical meanings remain blocked',
    () async {
      await repo.insert(word('saved', 'bank'));
      await expectLater(
        repo.insertChecked(word('new', 'bank', meaning: 'bờ sông')),
        throwsA(isA<DuplicateWordException>()),
      );
      await repo.insertChecked(
        word('new', 'bank', meaning: 'bờ sông'),
        allowDifferentMeaning: true,
      );
      await expectLater(
        repo.insertChecked(
          word('again', 'BANK', meaning: '  BỜ SÔNG '),
          allowDifferentMeaning: true,
        ),
        throwsA(isA<DuplicateWordException>()),
      );
      expect(await repo.exportAll(), hasLength(2));
    },
  );
  test('simultaneous adds create one entry', () async {
    Future<bool> add(String id) async {
      try {
        await repo.insertChecked(word(id, 'bank'));
        return true;
      } on DuplicateWordException {
        return false;
      }
    }

    final results = await Future.wait([add('a'), add('b')]);
    expect(results.where((r) => r), hasLength(1));
    expect(await repo.exportAll(), hasLength(1));
  });
  test(
    'renaming into an existing spelling is guarded; editing itself is allowed',
    () async {
      final original = word('saved', 'river');
      await repo.insert(original);
      await repo.insert(word('other', 'bank'));
      await expectLater(
        repo.updateChecked(original.copyWith(word: 'bank')),
        throwsA(isA<DuplicateWordException>()),
      );
      expect((await repo.findById('saved'))!.word, 'river');
      await repo.updateChecked(original.copyWith(meaning: 'dòng sông'));
      expect((await repo.findById('saved'))!.meaning, 'dòng sông');
    },
  );
  test(
    'lookup has no 200-result limit and searches only the active account',
    () async {
      await repo.activateNotebook('A');
      await repo.insert(word('private', 'bank'));
      await repo.activateNotebook('B');
      expect(await repo.matchingWords('bank'), isEmpty);
      final batch = repo.database.batch();
      for (var i = 0; i < 240; i++) {
        batch.insert('words', word('partial$i', 'banking$i').toDbMap());
      }
      await batch.commit(noResult: true);
      await repo.insert(word('old', 'bank', date: '2020-01-01'));
      expect((await repo.matchingWords('bank')).single.id, 'old');
    },
  );
  test('provider exposes a duplicate as a normal recoverable choice', () async {
    await repo.insert(word('saved', 'bank', date: '2026-10-01'));
    final provider = VocabularyProvider(repo, now: () => now);
    addTearDown(provider.dispose);
    await provider.init();
    await provider.addWord(word: 'BANK', meaning: 'ngân hàng');
    expect(provider.duplicateWords.single.id, 'saved');
    expect(provider.lastError, contains('already'));
    expect(provider.stats.totalWords, 1);
    provider.consumeError();
    expect(provider.duplicateWords, isEmpty);
    await provider.addWord(
      word: 'bank',
      meaning: 'bờ sông',
      allowDifferentMeaning: true,
    );
    expect(provider.lastError, isNull);
    expect(provider.stats.totalWords, 2);
  });
  test(
    'backup preview and round-trip preserve separate meanings and merge repeated imports',
    () async {
      await repo.insertChecked(word('first', 'bank'));
      await repo.insertChecked(
        word('second', 'bank', meaning: 'bờ sông'),
        allowDifferentMeaning: true,
      );
      final backup = BackupService.exportToJson(await repo.exportAll());
      final directory = await Directory.systemTemp.createTemp(
        'veea-restore-senses-',
      );
      final restored = await SqliteVocabularyRepository.open(
        path: '${directory.path}/restore.db',
      );
      try {
        final preview = await BackupService.previewBackup(
          rawContent: backup,
          repository: restored,
        );
        expect(preview.wouldInsert, 2);
        expect(preview.wouldMerge, 0);
        final result = await BackupService.importBackupText(
          rawContent: backup,
          repository: restored,
          now: () => now,
        );
        expect(result.inserted, 2);
        expect(
          (await restored.exportAll()).map((w) => w.meaning),
          containsAll(['ngân hàng', 'bờ sông']),
        );
        final again = await BackupService.previewBackup(
          rawContent: backup,
          repository: restored,
        );
        expect(again.wouldInsert, 0);
        expect(again.wouldMerge, 2);
        await BackupService.importBackupText(
          rawContent: backup,
          repository: restored,
          now: () => now,
        );
        expect(await restored.exportAll(), hasLength(2));
      } finally {
        await restored.close();
        await directory.delete(recursive: true);
      }
    },
  );
  test('starter pack skips words saved on previous dates', () async {
    final provider = VocabularyProvider(repo, now: () => now);
    addTearDown(provider.dispose);
    await provider.init();
    final added = await provider.loadStarterPack();
    expect(added, 5);
    await provider.goToPreviousDay();
    expect(await provider.loadStarterPack(), 0);
    expect(await repo.exportAll(), hasLength(5));
  });
}
