import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:veea_english_app/core/config/app_config.dart';
import 'package:veea_english_app/data/local/sqlite_vocabulary_repository.dart';
import 'package:veea_english_app/models/gate_config.dart';
import 'package:veea_english_app/models/vocabulary_word.dart';
import 'package:veea_english_app/providers/app_gate_provider.dart';
import 'package:veea_english_app/services/app_gate_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  final now = DateTime(2026, 11, 26);
  const target = 'native:00000000-0000-0000-0000-000000000001';
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late SqliteVocabularyRepository repo;
  late AppGateProvider gate;
  var grants = 0;

  setUp(() async {
    AppConfig.overrideFreeLaunch(null);
    grants = 0;
    messenger.setMockMethodCallHandler(
      const MethodChannel(AppGateService.channelName),
      (call) async {
        if (call.method == 'grantPass') grants++;
        if (call.method == 'getScreenTimeStatus' ||
            call.method == 'grantPass') {
          return {
            'supported': true,
            'available': true,
            'authorized': true,
            'enabled': true,
            'passMinutes': 47,
            'applications': [
              {'id': target, 'label': 'Synthetic app'},
            ],
          };
        }
        return null;
      },
    );
    repo = await SqliteVocabularyRepository.open(
      path: inMemoryDatabasePath,
      now: () => now,
    );
    for (var i = 0; i < 4; i++) {
      await repo.insert(
        VocabularyWord.create(
          id: 'w$i',
          word: 'fixture $i',
          meaning: 'nghĩa $i',
          date: '2026-11-26',
          now: now,
        ),
      );
    }
    gate = AppGateProvider(repository: repo, now: () => now);
    await gate.init();
  });
  tearDown(() async {
    gate.dispose();
    await repo.close();
    messenger.setMockMethodCallHandler(
      const MethodChannel(AppGateService.channelName),
      null,
    );
    AppConfig.overrideFreeLaunch(null);
  });

  test(
    'Free applies the complete practice pool and configurable count',
    () async {
      expect(gate.practiceWordCount, 4);
      expect(gate.maximumWordsPerUnlock, 4);
      await gate.setWordsPerUnlock(3);
      expect(gate.requiredWords, 3);
      expect((await repo.getGateConfig()).wordsPerUnlock, 3);
    },
  );

  test(
    'one answer earns a free pass and later sessions rotate words',
    () async {
      final ids = <String>{};
      for (var i = 0; i < 4; i++) {
        final word = (await gate.selectGateWord(targetApp: target))!;
        expect(ids.add(word.id), isTrue);
        await gate.completeGateChallenge(
          wordId: word.id,
          targetApp: target,
          attempts: 1,
        );
        expect(gate.progressForApp(target), 0);
      }
      expect(grants, 4);
      expect((await repo.exportAll()).length, 4);
    },
  );

  test(
    'previous multiword protection survives restart and remains editable',
    () async {
      await repo.saveGateConfig(
        const GateConfig(wordsPerUnlock: 4, autoPronounce: false),
      );
      gate.dispose();
      gate = AppGateProvider(repository: repo, now: () => now);
      await gate.init();
      expect(gate.requiredWords, 4);
      expect(gate.config.autoPronounce, isFalse);
      await gate.setWordsPerUnlock(999);
      expect(gate.requiredWords, 4);
      await gate.setPracticeWords(['w0', 'w1']);
      expect(gate.requiredWords, 2);
    },
  );

  test('a settings change applies to the next challenge', () async {
    gate.beginChallengeRound(target);
    await gate.setWordsPerUnlock(3);
    expect(gate.requiredWordsForApp(target), 1);
    gate.endChallengeRound(target);
    gate.beginChallengeRound(target);
    expect(gate.requiredWordsForApp(target), 3);
  });

  test(
    'closing and restarting retains answers but resumes the current word rule',
    () async {
      await gate.setWordsPerUnlock(3);
      gate.beginChallengeRound(target);
      await gate.recordStepCompletion(
        wordId: 'w0',
        targetApp: target,
        attempts: 1,
      );
      gate.endChallengeRound(target);
      await gate.setWordsPerUnlock(2);
      gate.dispose();
      gate = AppGateProvider(repository: repo, now: () => now);
      await gate.init();
      gate.beginChallengeRound(target);
      expect(gate.requiredWordsForApp(target), 2);
      expect(gate.progressForApp(target), 1);
      await gate.completeGateChallenge(
        wordId: 'w1',
        targetApp: target,
        attempts: 1,
      );
      expect(grants, 1);
    },
  );

  test('pool reduction adjusts the free multiword rule', () async {
    await gate.setWordsPerUnlock(4);
    await gate.setPracticeWords(['w0', 'w1']);
    expect(gate.requiredWords, 2);
    expect(gate.config.wordsPerUnlock, 2);
    expect(gate.poolNotice, contains('adjusted to 2'));
  });

  test(
    'legacy selected pool retains its count and progress until save',
    () async {
      await repo.saveGateConfig(
        const GateConfig(
          practiceWordIds: ['w0', 'w1', 'w2', 'w3'],
          wordsPerUnlock: 2,
        ),
      );
      await repo.recordGateCompletion(
        wordId: 'w0',
        targetApp: target,
        attempts: 0,
        now: now,
        completesRound: false,
      );
      gate.dispose();
      gate = AppGateProvider(repository: repo, now: () => now);
      await gate.init();

      expect(gate.practiceWordCount, 4);
      expect(gate.requiredWords, 2);
      expect(gate.usesExactUnlockWords, isFalse);
      expect(gate.progressForApp(target), 1);

      await gate.setPracticeWords(['w0', 'w1', 'w2', 'w3']);
      expect(gate.requiredWords, 4);
      expect(gate.usesExactUnlockWords, isTrue);
      expect(gate.progressForApp(target), 1);
    },
  );
}
