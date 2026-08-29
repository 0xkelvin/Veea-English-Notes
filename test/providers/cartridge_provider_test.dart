import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:veea_english_app/data/local/sqlite_vocabulary_repository.dart';
import 'package:veea_english_app/providers/cartridge_provider.dart';
import 'package:veea_english_app/providers/vocabulary_provider.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late SqliteVocabularyRepository repo;
  late VocabularyProvider vocabProvider;
  late CartridgeProvider cartridgeProvider;

  final today = DateTime(2026, 8, 29, 10);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    repo = await SqliteVocabularyRepository.open(
      path: inMemoryDatabasePath,
      now: () => today,
    );
    vocabProvider = VocabularyProvider(repo, now: () => today);
    await vocabProvider.init();

    cartridgeProvider = CartridgeProvider();
  });

  tearDown(() => repo.close());

  group('CartridgeProvider', () {
    test('installs cartridge words in full mode into VocabularyProvider', () async {
      expect(cartridgeProvider.isInstalled('silicon_valley_tech_vol1'), isFalse);

      final count = await cartridgeProvider.installCartridge(
        'silicon_valley_tech_vol1',
        vocabProvider: vocabProvider,
        mode: IngestMode.full,
        baseDate: today,
      );

      expect(count, greaterThan(0));
      expect(cartridgeProvider.isInstalled('silicon_valley_tech_vol1'), isTrue);
      expect(vocabProvider.words.any((w) => w.word == 'idempotent'), isTrue);
    });

    test('installs cartridge words in dailySprint mode scheduling across dates', () async {
      final count = await cartridgeProvider.installCartridge(
        'silicon_valley_tech_vol1',
        vocabProvider: vocabProvider,
        mode: IngestMode.dailySprint,
        baseDate: today,
      );

      expect(count, greaterThan(0));
      expect(cartridgeProvider.isInstalled('silicon_valley_tech_vol1'), isTrue);

      final dates = await repo.datesWithWords();
      expect(dates.length, greaterThan(1));
    });

    test('uninstalls cartridge words cleanly', () async {
      await cartridgeProvider.installCartridge(
        'silicon_valley_tech_vol1',
        vocabProvider: vocabProvider,
        mode: IngestMode.full,
        baseDate: today,
      );

      expect(vocabProvider.words.isNotEmpty, isTrue);

      final removed = await cartridgeProvider.uninstallCartridge(
        'silicon_valley_tech_vol1',
        vocabProvider: vocabProvider,
      );

      expect(removed, greaterThan(0));
      expect(cartridgeProvider.isInstalled('silicon_valley_tech_vol1'), isFalse);
    });
  });
}
