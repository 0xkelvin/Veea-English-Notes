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
    'production defaults to Free with full rotating practice pool and one word',
    () async {
      expect(AppConfig.isFreeLaunch, isFalse);
      expect(gate.canUseMultipleWords, isFalse);
      expect(gate.practiceWordCount, 4);
      expect(gate.maximumWordsPerUnlock, 1);
      expect(gate.requiredWords, 1);
      await expectLater(
        gate.setWordsPerUnlock(2),
        throwsA(
          isA<PlatformException>().having(
            (e) => e.code,
            'code',
            'PRO_REQUIRED',
          ),
        ),
      );
      expect((await repo.getGateConfig()).wordsPerUnlock, 1);
      await gate.setPracticeWords(['w0', 'w1', 'w2']);
      expect(gate.practiceWordCount, 3);
      expect(gate.requiredWords, 1);
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
    'downgrade and cold restart enforce one without erasing paid count',
    () async {
      gate.setProAccess(true);
      await gate.setWordsPerUnlock(3);
      expect(gate.requiredWords, 3);
      gate.setProAccess(false);
      expect(gate.requiredWords, 1);
      expect(gate.config.wordsPerUnlock, 3);
      gate.dispose();
      gate = AppGateProvider(repository: repo, now: () => now);
      await gate.init();
      expect(gate.requiredWords, 1);
      expect(gate.config.wordsPerUnlock, 3);
      gate.setProAccess(true);
      expect(gate.requiredWords, 3);
      await gate.setWordsPerUnlock(999);
      expect(gate.requiredWords, 4);
      await gate.setPracticeWords(['w0', 'w1']);
      expect(gate.requiredWords, 2);
    },
  );

  test(
    'a legacy multiword config is safely effective as one on Free',
    () async {
      await repo.saveGateConfig(
        const GateConfig(wordsPerUnlock: 4, autoPronounce: false),
      );
      gate.dispose();
      gate = AppGateProvider(repository: repo, now: () => now);
      await gate.init();
      expect(gate.requiredWords, 1);
      expect(gate.config.autoPronounce, isFalse);
      expect(gate.practiceWordCount, 4);
      expect(gate.config.wordsPerUnlock, 4);
      await gate.completeGateChallenge(
        wordId: 'w0',
        targetApp: target,
        attempts: 1,
      );
      expect(grants, 1);
      gate.setProAccess(true);
      expect(gate.requiredWords, 4);
    },
  );

  test(
    'Free may lower its retained count without needing a purchase',
    () async {
      gate.setProAccess(true);
      await gate.setWordsPerUnlock(3);
      gate.setProAccess(false);
      await gate.setWordsPerUnlock(1);
      expect(gate.config.wordsPerUnlock, 1);
      expect(gate.canUseMultipleWords, isFalse);
    },
  );

  test(
    'upgrading mid-round keeps the current one-answer challenge stable',
    () async {
      gate.setProAccess(true);
      await gate.setWordsPerUnlock(3);
      gate.setProAccess(false);
      gate.beginChallengeRound(target);
      gate.setProAccess(true);
      expect(gate.requiredWords, 3);
      expect(gate.requiredWordsForApp(target), 1);
      await gate.completeGateChallenge(
        wordId: 'w0',
        targetApp: target,
        attempts: 1,
      );
      expect(grants, 1);
      gate.beginChallengeRound(target);
      expect(gate.requiredWordsForApp(target), 3);
    },
  );

  test(
    'closing a challenge releases its stale target before a changed rule or upgrade',
    () async {
      gate.setProAccess(true);
      await gate.setWordsPerUnlock(3);
      gate.beginChallengeRound(target);
      gate.endChallengeRound(target);
      await gate.setWordsPerUnlock(2);
      gate.beginChallengeRound(target);
      expect(gate.requiredWordsForApp(target), 2);
      gate.endChallengeRound(target);
      gate.setProAccess(false);
      gate.beginChallengeRound(target);
      expect(gate.requiredWordsForApp(target), 1);
      gate.endChallengeRound(target);
      gate.setProAccess(true);
      gate.beginChallengeRound(target);
      expect(gate.requiredWordsForApp(target), 2);
    },
  );

  test(
    'closing and restarting retains answers but resumes the current word rule',
    () async {
      gate.setProAccess(true);
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
      gate = AppGateProvider(repository: repo, now: () => now, hasPro: true);
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

  test('Free pool adjustment explains the effective one-word rule', () async {
    gate.setProAccess(true);
    await gate.setWordsPerUnlock(4);
    gate.setProAccess(false);
    await gate.setPracticeWords(['w0', 'w1']);
    expect(gate.requiredWords, 1);
    expect(gate.config.wordsPerUnlock, 2);
    expect(gate.poolNotice, contains('Free continues with 1 word per unlock'));
  });

  test(
    'downgrade with saved progress settles once and keeps learning records',
    () async {
      gate.setProAccess(true);
      await gate.setWordsPerUnlock(3);
      gate.beginChallengeRound(target);
      await gate.recordStepCompletion(
        wordId: 'w0',
        targetApp: target,
        attempts: 1,
      );
      await gate.recordStepCompletion(
        wordId: 'w1',
        targetApp: target,
        attempts: 1,
      );
      gate.setProAccess(false);
      expect(gate.requiredWordsForApp(target), 1);
      await gate.completeGateChallenge(
        wordId: 'w1',
        targetApp: target,
        attempts: 1,
      );
      expect(grants, 1);
      expect(gate.progressForApp(target), 0);
      expect(gate.config.wordsPerUnlock, 3);
      expect((await repo.exportAll()).length, 4);
    },
  );
}
