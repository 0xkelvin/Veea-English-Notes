import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:veea_english_app/data/local/sqlite_vocabulary_repository.dart';
import 'package:veea_english_app/models/gate_config.dart';
import 'package:veea_english_app/models/part_of_speech.dart';
import 'package:veea_english_app/models/vocabulary_word.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  final baseNow = DateTime.utc(2026, 8, 21, 12, 0, 0);
  late SqliteVocabularyRepository repo;

  setUp(() async {
    repo = await SqliteVocabularyRepository.open(
      path: inMemoryDatabasePath,
      now: () => baseNow,
    );
  });

  tearDown(() => repo.close());

  group('GateConfig & GateLogs persistence', () {
    test('seeds default singleton gate_config row on creation', () async {
      final config = await repo.getGateConfig();
      expect(config.enabled, isFalse);
      expect(config.passDurationMinutes, 15);
      expect(config.dailyWordGoal, isFalse);
      expect(config.gatedApps, isEmpty);
    });

    test('saves and reloads updated GateConfig', () async {
      const updated = GateConfig(
        enabled: true,
        passDurationMinutes: 30,
        dailyWordGoal: true,
        gatedApps: ['Instagram', 'X'],
      );
      await repo.saveGateConfig(updated);

      final loaded = await repo.getGateConfig();
      expect(loaded.enabled, isTrue);
      expect(loaded.passDurationMinutes, 30);
      expect(loaded.dailyWordGoal, isTrue);
      expect(loaded.gatedApps, ['Instagram', 'X']);
    });
  });

  group('Smart Review Queue (4-tier priority order)', () {
    test('returns null when notebook is empty', () async {
      final selected = await repo.selectGateWord(now: baseNow);
      expect(selected, isNull);
    });

    test('prioritises Tier 1 (last_gate_failed = 1) over all others', () async {
      // Tier 2: recent capture (1 hour ago)
      await repo.insert(
        VocabularyWord(
          id: 'recent_word',
          word: 'recent',
          meaning: 'gần đây',
          date: '2026-08-21',
          createdAt: baseNow.subtract(const Duration(hours: 1)),
          updatedAt: baseNow,
          srsStage: 0,
        ),
      );

      // Tier 1: older word that failed a previous gate
      await repo.insert(
        VocabularyWord(
          id: 'failed_word',
          word: 'preliminary',
          meaning: 'sơ bộ',
          date: '2026-08-10',
          createdAt: baseNow.subtract(const Duration(days: 11)),
          updatedAt: baseNow,
          srsStage: 0,
          lastGateFailed: true,
        ),
      );

      final selected = await repo.selectGateWord(now: baseNow);
      expect(selected?.id, 'failed_word');
    });

    test(
      'prioritises Tier 2 (recent captures within 72h with srs_stage < 3) over Tier 3',
      () async {
        // Tier 3: old word due for SRS review
        await repo.insert(
          VocabularyWord(
            id: 'due_word',
            word: 'fixture',
            meaning: 'đồ cố định',
            date: '2026-08-10',
            createdAt: baseNow.subtract(const Duration(days: 10)),
            updatedAt: baseNow,
            srsStage: 1,
            nextReviewAt: baseNow
                .subtract(const Duration(hours: 2))
                .millisecondsSinceEpoch,
          ),
        );

        // Tier 2: captured 2 days ago with srs_stage = 2
        await repo.insert(
          VocabularyWord(
            id: 'recent_capture',
            word: 'atmosphere',
            meaning: 'bầu không khí',
            date: '2026-08-19',
            createdAt: baseNow.subtract(const Duration(hours: 48)),
            updatedAt: baseNow,
            srsStage: 2,
          ),
        );

        final selected = await repo.selectGateWord(now: baseNow);
        expect(selected?.id, 'recent_capture');
      },
    );

    test(
      'prioritises Tier 3 (next_review_at <= now) ordered by srs_stage ASC, next_review_at ASC',
      () async {
        // Older than 72 hours, due now, srs_stage = 2
        await repo.insert(
          VocabularyWord(
            id: 'due_stage_2',
            word: 'curtain',
            meaning: 'rèm cửa',
            date: '2026-08-01',
            createdAt: baseNow.subtract(const Duration(days: 20)),
            updatedAt: baseNow,
            srsStage: 2,
            nextReviewAt: baseNow
                .subtract(const Duration(hours: 5))
                .millisecondsSinceEpoch,
          ),
        );

        // Older than 72 hours, due now, srs_stage = 1
        await repo.insert(
          VocabularyWord(
            id: 'due_stage_1',
            word: 'resilient',
            meaning: 'kiên cường',
            date: '2026-08-01',
            createdAt: baseNow.subtract(const Duration(days: 20)),
            updatedAt: baseNow,
            srsStage: 1,
            nextReviewAt: baseNow
                .subtract(const Duration(hours: 1))
                .millisecondsSinceEpoch,
          ),
        );

        final selected = await repo.selectGateWord(now: baseNow);
        expect(selected?.id, 'due_stage_1');
      },
    );

    test(
      'falls back to Tier 4 (least-recently reviewed active word)',
      () async {
        final futureReview = baseNow
            .add(const Duration(days: 5))
            .millisecondsSinceEpoch;

        await repo.insert(
          VocabularyWord(
            id: 'reviewed_recently',
            word: 'throttle',
            meaning: 'điều tiết',
            date: '2026-08-01',
            createdAt: baseNow.subtract(const Duration(days: 20)),
            updatedAt: baseNow,
            srsStage: 3,
            nextReviewAt: futureReview,
            lastReviewedAt: baseNow
                .subtract(const Duration(days: 1))
                .millisecondsSinceEpoch,
          ),
        );

        await repo.insert(
          VocabularyWord(
            id: 'reviewed_long_ago',
            word: 'bottleneck',
            meaning: 'nút cổ chai',
            date: '2026-08-01',
            createdAt: baseNow.subtract(const Duration(days: 20)),
            updatedAt: baseNow,
            srsStage: 3,
            nextReviewAt: futureReview,
            lastReviewedAt: baseNow
                .subtract(const Duration(days: 10))
                .millisecondsSinceEpoch,
          ),
        );

        final selected = await repo.selectGateWord(now: baseNow);
        expect(selected?.id, 'reviewed_long_ago');
      },
    );
  });

  group('recordGateCompletion (Stage 0, 1, 2 SRS transitions)', () {
    setUp(() async {
      await repo.insert(
        VocabularyWord(
          id: 'w1',
          word: 'preliminary',
          meaning: 'sơ bộ',
          partOfSpeech: PartOfSpeech.adjective,
          date: '2026-08-21',
          createdAt: baseNow,
          updatedAt: baseNow,
          srsStage: 2,
          lastGateFailed: true,
        ),
      );
    });

    test(
      'Stage 0 (0 wrong attempts): increments srs_stage and clears last_gate_failed',
      () async {
        final updated = await repo.recordGateCompletion(
          wordId: 'w1',
          targetApp: 'Instagram',
          attempts: 0,
          now: baseNow,
        );

        expect(updated?.srsStage, 3);
        expect(updated?.lastGateFailed, isFalse);
        expect(updated?.nextReviewAt, isNotNull);
        expect(updated!.nextReviewAt! > baseNow.millisecondsSinceEpoch, isTrue);

        final logs = await repo.recentGateLogs();
        expect(logs, hasLength(1));
        expect(logs.first.wordId, 'w1');
        expect(logs.first.targetApp, 'Instagram');
        expect(logs.first.attempts, 0);
      },
    );

    test(
      'Stage 1 (1 wrong attempt): keeps srs_stage unchanged and clears last_gate_failed',
      () async {
        final updated = await repo.recordGateCompletion(
          wordId: 'w1',
          targetApp: 'YouTube',
          attempts: 1,
          now: baseNow,
        );

        expect(updated?.srsStage, 2);
        expect(updated?.lastGateFailed, isFalse);
      },
    );

    test(
      'Stage 2 (2+ wrong attempts): resets srs_stage = 0 and sets last_gate_failed = 1',
      () async {
        final updated = await repo.recordGateCompletion(
          wordId: 'w1',
          targetApp: 'TikTok',
          attempts: 2,
          now: baseNow,
        );

        expect(updated?.srsStage, 0);
        expect(updated?.lastGateFailed, isTrue);
        // Scheduled for later the same day (4 hours later)
        expect(
          updated?.nextReviewAt,
          baseNow.add(const Duration(hours: 4)).millisecondsSinceEpoch,
        );
      },
    );
  });
}
