import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:veea_english_app/data/local/app_database.dart';
import 'package:veea_english_app/data/word_suggestion_store.dart';
import 'package:veea_english_app/models/vocabulary_word.dart';
import 'package:veea_english_app/models/part_of_speech.dart';
import 'package:veea_english_app/services/word_suggestion_service.dart';

/// Delays an actual SQLite write, so clearing during an in-flight lookup is
/// verified against persisted data rather than a map that mirrors the code.
class DelayedStore extends SqliteWordSuggestionStore {
  DelayedStore(super.db, {required super.dictionaryDirectory});
  final started = Completer<void>();
  final proceed = Completer<void>();
  @override
  Future<void> saveOnline(
    WordSuggestion suggestion, {
    required String provider,
  }) async {
    started.complete();
    await proceed.future;
    await super.saveOnline(suggestion, provider: provider);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  late Directory dir;
  late Database db;
  late SqliteWordSuggestionStore store;

  Future<String> dictionaryDir() async => '${dir.path}/dictionary';
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('veea-meanings-test-');
    db = await AppDatabase.open(path: '${dir.path}/notebook.sqlite');
    store = SqliteWordSuggestionStore(db, dictionaryDirectory: dictionaryDir);
    WordSuggestionService.configureLocalStore(store);
    WordSuggestionService.allowOnlineTranslation = false;
  });
  tearDown(() async {
    WordSuggestionService.configureLocalStore(null);
    await store.close();
    await db.close();
    await dir.delete(recursive: true);
  });

  MockClient online({String meaning = 'nghĩa đã tra cứu'}) => MockClient(
    (_) async => http.Response.bytes(
      utf8.encode(
        jsonEncode([
          [
            [meaning, 'veeamemoryfixturezz', null, null, 1],
          ],
          [
            [
              'noun',
              [meaning],
            ],
          ],
        ]),
      ),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    ),
  );

  test('real bundled dictionary works cold with no HTTP or account', () async {
    var requests = 0;
    final client = MockClient((_) async {
      requests++;
      throw StateError('An offline lookup must not use HTTP');
    });
    for (final entry in {
      '  AIRPORT  ': 'Sân bay',
      'beautiful': 'Đẹp',
      'learn': 'Học',
      'recipes': 'Công thức',
      'labyrinthine': 'Cung mê',
    }.entries) {
      final result = await WordSuggestionService.suggest(
        entry.key,
        client: client,
      );
      expect(result?.meaning, contains(entry.value), reason: entry.key);
      expect(result?.sourceUrl, startsWith('https://vi.wiktionary.org/wiki/'));
    }
    expect(requests, 0);
    expect(await store.savedCount(), 0);
    expect((await Directory(await dictionaryDir()).list().toList()).length, 1);
    final metadata =
        jsonDecode(await File('assets/dictionary/manifest.json').readAsString())
            as Map;
    expect(metadata['entry_count'], 110986);
    expect(metadata['compressed_bytes'], lessThan(4 * 1024 * 1024));
  });

  test(
    'Google result survives closing both stores and reopening offline',
    () async {
      final result = await WordSuggestionService.suggest(
        ' VeeaMemoryFixtureZZ ',
        client: online(),
        allowOnline: true,
      );
      expect(result?.meaning, 'nghĩa đã tra cứu');
      expect(await store.savedCount(), 1);
      await store.close();
      await db.close();
      db = await AppDatabase.open(path: '${dir.path}/notebook.sqlite');
      store = SqliteWordSuggestionStore(db, dictionaryDirectory: dictionaryDir);
      WordSuggestionService.configureLocalStore(store);
      var requests = 0;
      final offline = MockClient((_) async {
        requests++;
        throw const SocketException('offline');
      });
      final restored = await WordSuggestionService.suggest(
        'veeamemoryfixturezz',
        client: offline,
      );
      expect(restored?.meaning, result?.meaning);
      expect(restored?.partOfSpeech, PartOfSpeech.noun);
      expect(restored?.source, 'Saved online lookup');
      expect(requests, 0);
      expect(
        (await db.query(
          SqliteWordSuggestionStore.cacheTable,
        )).single['provider'],
        'Google Translate',
      );
    },
  );

  test(
    'MyMemory fallback result is also persisted with its provider',
    () async {
      var calls = 0;
      final client = MockClient((request) async {
        calls++;
        return request.url.host == 'translate.googleapis.com'
            ? http.Response('{}', 503)
            : http.Response.bytes(
                utf8.encode(
                  jsonEncode({
                    'responseData': {'translatedText': 'nghĩa dự phòng'},
                  }),
                ),
                200,
              );
      });
      await WordSuggestionService.suggest(
        'veeamemoryfallbackzz',
        client: client,
        allowOnline: true,
      );
      WordSuggestionService.clearCache();
      final result = await WordSuggestionService.suggest(
        'veeamemoryfallbackzz',
        client: client,
      );
      expect(result?.meaning, 'nghĩa dự phòng');
      expect(calls, 2);
      expect(
        (await db.query(
          SqliteWordSuggestionStore.cacheTable,
        )).single['provider'],
        'MyMemory',
      );
    },
  );

  test('failed, identity, HTML and quota responses are not saved', () async {
    for (final text in [
      '',
      'veeamemorybadzz',
      '<html>failure</html>',
      'MYMEMORY WARNING: YOU USED ALL AVAILABLE FREE TRANSLATIONS. QUOTA EXCEEDED',
    ]) {
      var calls = 0;
      final client = MockClient((request) async {
        calls++;
        return request.url.host == 'translate.googleapis.com'
            ? http.Response('[]', 500)
            : http.Response.bytes(
                utf8.encode(
                  jsonEncode({
                    'responseData': {'translatedText': text},
                  }),
                ),
                200,
              );
      });
      final result = await WordSuggestionService.suggest(
        'veeamemorybadzz',
        client: client,
        allowOnline: true,
      );
      expect(result?.meaning, isNull, reason: text);
      expect(await store.savedCount(), 0);
      expect(calls, 2);
    }
  });

  test(
    'personal meaning wins over a warm dictionary cache and is not copied into it',
    () async {
      final bundled = await WordSuggestionService.suggest('airport');
      final word = VocabularyWord.create(
        id: 'mine',
        word: 'airport',
        meaning: 'nghĩa do tôi viết',
        date: '2026-11-26',
        now: DateTime(2026, 11, 26),
      );
      final own = await WordSuggestionService.suggest(
        'airport',
        userWords: [word],
      );
      expect(own?.meaning, word.meaning);
      expect(
        (await WordSuggestionService.suggest(
          'airport',
          userWords: [],
        ))?.meaning,
        bundled?.meaning,
      );
      expect(await store.savedCount(), 0);
    },
  );

  test(
    'a saved meaning on another date wins and deleted notes stop winning',
    () async {
      await WordSuggestionService.suggest('solution');
      final note = VocabularyWord.create(
        id: 'older-personal',
        word: 'Solution',
        meaning: 'cách giải của riêng tôi',
        date: '2026-01-01',
        now: DateTime(2026, 1, 1),
      );
      await db.insert('words', note.toDbMap());
      final own = await WordSuggestionService.suggest(
        '  SOLUTION ',
        userWords: [],
      );
      expect(own?.meaning, note.meaning);
      expect(own?.source, 'Previous note');
      await db.update(
        'words',
        {'is_deleted': 1},
        where: 'id = ?',
        whereArgs: [note.id],
      );
      expect(
        (await WordSuggestionService.suggest('solution'))?.meaning,
        contains('giải pháp'),
      );
    },
  );

  test('case and repeated whitespace reuse one persisted phrase', () async {
    await WordSuggestionService.suggest(
      'veea   phrase  zz',
      client: online(),
      allowOnline: true,
    );
    WordSuggestionService.clearCache();
    final result = await WordSuggestionService.suggest('  VEEA phrase zz ');
    expect(result?.meaning, 'nghĩa đã tra cứu');
    expect(await store.savedCount(), 1);
  });

  test(
    'clearing during an in-flight save removes it from disk and memory',
    () async {
      await store.close();
      final delayed = DelayedStore(db, dictionaryDirectory: dictionaryDir);
      store = delayed;
      WordSuggestionService.configureLocalStore(store);
      final lookup = WordSuggestionService.suggest(
        'veeamemoryracezz',
        client: online(),
        allowOnline: true,
      );
      await delayed.started.future;
      final clear = WordSuggestionService.clearSavedLookups();
      delayed.proceed.complete();
      await lookup;
      await clear;
      expect(await store.savedCount(), 0);
      expect(
        (await WordSuggestionService.suggest('veeamemoryracezz'))?.meaning,
        isNull,
      );
      expect(
        (await WordSuggestionService.suggest('airport'))?.meaning,
        contains('Sân bay'),
      );
    },
  );

  test(
    'replaceable dictionary corruption recovers without touching notebook',
    () async {
      final dictionary = Directory(await dictionaryDir());
      await dictionary.create();
      await File(
        '${dictionary.path}/veea-${SqliteWordSuggestionStore.revision}.sqlite',
      ).writeAsString('interrupted old copy');
      final word = VocabularyWord.create(
        id: 'keep',
        word: 'private',
        meaning: 'nghĩa riêng',
        date: '2026-11-26',
        now: DateTime(2026, 11, 26),
      );
      await db.insert(AppDatabase.wordsTable, word.toDbMap());
      expect(
        (await WordSuggestionService.suggest('airport'))?.meaning,
        contains('Sân bay'),
      );
      await WordSuggestionService.clearSavedLookups();
      expect((await db.query(AppDatabase.wordsTable)).single['id'], 'keep');
    },
  );

  test(
    'upgrade from v14 adds only the cache and preserves existing words',
    () async {
      final word = VocabularyWord.create(
        id: 'old',
        word: 'notebook',
        meaning: 'sổ tay',
        date: '2026-11-26',
        now: DateTime(2026, 11, 26),
      );
      await db.insert(AppDatabase.wordsTable, word.toDbMap());
      await db.execute('DROP TABLE ${SqliteWordSuggestionStore.cacheTable}');
      await db.execute('PRAGMA user_version = 14');
      await store.close();
      await db.close();
      db = await AppDatabase.open(path: '${dir.path}/notebook.sqlite');
      store = SqliteWordSuggestionStore(db, dictionaryDirectory: dictionaryDir);
      WordSuggestionService.configureLocalStore(store);
      expect(
        (await db.query(AppDatabase.wordsTable)).single['meaning'],
        'sổ tay',
      );
      expect(await store.savedCount(), 0);
    },
  );
}
