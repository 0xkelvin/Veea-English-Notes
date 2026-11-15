import 'package:flutter_test/flutter_test.dart';
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
    repo = await SqliteVocabularyRepository.open(
      path: inMemoryDatabasePath,
      now: () => today,
    );
    vocabProvider = VocabularyProvider(repo, now: () => today);
    await vocabProvider.init();

    cartridgeProvider = CartridgeProvider(repository: repo);
  });

  tearDown(() => repo.close());

  group('CartridgeProvider', () {
    test(
      'installs cartridge words in full mode into VocabularyProvider',
      () async {
        expect(cartridgeProvider.isInstalled('free_starter'), isFalse);

        final count = await cartridgeProvider.installCartridge(
          'free_starter',
          vocabProvider: vocabProvider,
          mode: IngestMode.full,
          baseDate: today,
        );

        expect(count, greaterThan(0));
        expect(cartridgeProvider.isInstalled('free_starter'), isTrue);
        expect(vocabProvider.words.any((w) => w.word == 'resilient'), isTrue);
      },
    );

    test(
      'installs cartridge words in dailySprint mode scheduling across dates',
      () async {
        final count = await cartridgeProvider.installCartridge(
          'free_starter',
          vocabProvider: vocabProvider,
          mode: IngestMode.dailySprint,
          baseDate: today,
        );

        expect(count, greaterThan(0));
        expect(cartridgeProvider.isInstalled('free_starter'), isTrue);

        final dates = await repo.datesWithWords();
        expect(dates.length, 1); // the five-word starter fits one sprint day
      },
    );

    test('uninstalls cartridge words cleanly', () async {
      await cartridgeProvider.installCartridge(
        'free_starter',
        vocabProvider: vocabProvider,
        mode: IngestMode.full,
        baseDate: today,
      );

      expect(vocabProvider.words.isNotEmpty, isTrue);

      final removed = await cartridgeProvider.uninstallCartridge(
        'free_starter',
        vocabProvider: vocabProvider,
      );

      expect(removed, greaterThan(0));
      expect(
        cartridgeProvider.isInstalled('free_starter'),
        isTrue, // receipt survives removal so a retry cannot resurrect deletions
      );
    });
  });
}
