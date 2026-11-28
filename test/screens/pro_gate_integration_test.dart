import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:veea_english_app/core/config/app_config.dart';
import 'package:veea_english_app/data/local/sqlite_vocabulary_repository.dart';
import 'package:veea_english_app/data/pro_repository.dart';
import 'package:veea_english_app/main.dart';
import 'package:veea_english_app/models/gate_config.dart';
import 'package:veea_english_app/models/vocabulary_word.dart';
import 'package:veea_english_app/providers/app_gate_provider.dart';
import 'package:veea_english_app/providers/pro_provider.dart';
import 'package:veea_english_app/providers/vocabulary_provider.dart';
import 'package:veea_english_app/services/app_gate_service.dart';
import 'package:veea_english_app/services/pronunciation_service.dart';
import 'package:veea_english_app/services/sync_service.dart';
import '../providers/pro_provider_test.dart' show TestAuth, TestPro;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final now = DateTime(2026, 11, 26);
  late SqliteVocabularyRepository repo;
  late AppGateProvider gate;
  late VocabularyProvider vocabulary;
  late TestAuth auth;
  late TestPro store;
  late ProProvider pro;
  late SyncService sync;
  final protectionWrites = <String>[];

  setUp(() async {
    AppConfig.overrideFreeLaunch(null);
    AppConfig.overrideBaseUrl('http://localhost');
    AppConfig.overrideAppleProduct('app.test.pro');
    SharedPreferences.setMockInitialValues({});
    protectionWrites.clear();
    messenger.setMockMethodCallHandler(
      const MethodChannel('flutter_tts'),
      (_) async => 1,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel(AppGateService.channelName),
      (call) async {
        if (call.method == 'getScreenTimeStatus') {
          return {
            'supported': true,
            'available': true,
            'authorized': true,
            'enabled': true,
            'configured': true,
            'passMinutes': 15,
            'applications': [
              {'id': 'native:first', 'label': 'First app', 'lockEnabled': true},
              {
                'id': 'native:second',
                'label': 'Second app',
                'lockEnabled': true,
                'customPassMinutes': 7,
              },
            ],
          };
        }
        if (call.method.startsWith('setScreenTime') ||
            call.method.startsWith('removeScreenTime')) {
          protectionWrites.add(call.method);
        }
        return null;
      },
    );
    repo = await SqliteVocabularyRepository.open(
      path: inMemoryDatabasePath,
      now: () => now,
    );
    for (var i = 0; i < 3; i++) {
      await repo.insert(
        VocabularyWord.create(
          id: 'w$i',
          word: 'fixture $i',
          meaning: 'meaning $i',
          date: '2026-11-26',
          now: now,
        ),
      );
    }
    await repo.saveGateConfig(const GateConfig(wordsPerUnlock: 3));
    gate = AppGateProvider(repository: repo, now: () => now);
    await gate.init();
    vocabulary = VocabularyProvider(repo, now: () => now);
    await vocabulary.init();
    auth = TestAuth()..select('synthetic-owner');
    store = TestPro();
    pro = ProProvider(auth: auth, repository: store);
    sync = SyncService(repository: repo);
  });
  tearDown(() async {
    gate.dispose();
    vocabulary.dispose();
    auth.dispose();
    sync.dispose();
    await repo.close();
    AppConfig.overrideFreeLaunch(null);
    AppConfig.overrideBaseUrl(null);
    AppConfig.overrideAppleProduct(null);
    messenger.setMockMethodCallHandler(
      const MethodChannel('flutter_tts'),
      null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel(AppGateService.channelName),
      null,
    );
  });

  testWidgets(
    'verified guest Pro survives sign-out; refund restores Free without losing rules or words',
    (tester) async {
      await tester.pumpWidget(
        VeeaEnglishApp(
          vocabulary: vocabulary,
          auth: auth,
          sync: sync,
          pro: pro,
          appGateProvider: gate,
          pronunciation: PronunciationService(repo.database),
        ),
      );
      await tester.pumpAndSettle();
      expect(gate.requiredWords, 1);
      expect(gate.config.wordsPerUnlock, 3);
      expect(gate.nativeStatus.enabledApplicationCount, 2);
      expect(gate.nativeStatus.durationFor('native:second'), 7);

      store.state = const ProStoreState(
        hasPro: true,
        hasLifetime: true,
        localApple: true,
      );
      await pro.refresh();
      await tester.pumpAndSettle();
      expect(pro.hasPro, isTrue);
      expect(gate.requiredWords, 3);

      auth.select(null);
      for (var i = 0; i < 12; i++) {
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
      await tester.pumpAndSettle();
      expect(pro.hasLocalApple, isTrue);
      expect(gate.requiredWords, 3);
      store.state = const ProStoreState();
      await pro.refresh();
      expect(pro.hasPro, isFalse);
      expect(gate.requiredWords, 1);
      expect(gate.config.wordsPerUnlock, 3);
      expect(gate.nativeStatus.enabledApplicationCount, 2);
      expect(gate.nativeStatus.durationFor('native:second'), 7);
      expect(protectionWrites, isEmpty);
      expect(await tester.runAsync(() => repo.exportAll()), hasLength(3));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final action in ['purchase', 'restore']) {
    testWidgets(
      'guest $action immediately enables multiple selected unlock words without account claims',
      (tester) async {
        auth.select(null);
        await tester.pumpWidget(
          VeeaEnglishApp(
            vocabulary: vocabulary,
            auth: auth,
            sync: sync,
            pro: pro,
            appGateProvider: gate,
            pronunciation: PronunciationService(repo.database),
          ),
        );
        await tester.pumpAndSettle();
        expect(gate.requiredWords, 1);
        const owned = ProStoreState(
          hasPro: true,
          hasLifetime: true,
          localSandbox: true,
        );
        store.state = owned;
        store.purchaseResult = owned;
        if (action == 'purchase') {
          await pro.purchase();
        } else {
          await pro.restore();
        }
        await tester.pumpAndSettle();
        expect(pro.hasLocalSandbox, isTrue);
        expect(gate.canUseMultipleWords, isTrue);
        await tester.runAsync(() => gate.setPracticeWords(['w0', 'w1', 'w2']));
        expect(gate.requiredWords, 3);
        expect(store.claims, 0);
        expect(store.entitlementReads, 0);
        expect(await tester.runAsync(() => repo.exportAll()), hasLength(3));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'signed-in Sandbox acknowledgement keeps multiword device Pro without a Production grant',
    (tester) async {
      store.state = const ProStoreState(
        hasPro: true,
        hasLifetime: true,
        localSandbox: true,
        transactions: ['synthetic-sandbox-proof'],
      );
      store.claimResult = {
        'plan': 'free',
        'plan_expires_at': null,
        'apple_purchase_available': true,
        'purchase_environment': 'Sandbox',
        'purchase_recorded': false,
        'purchase_revoked': false,
      };
      await tester.pumpWidget(
        VeeaEnglishApp(
          vocabulary: vocabulary,
          auth: auth,
          sync: sync,
          pro: pro,
          appGateProvider: gate,
          pronunciation: PronunciationService(repo.database),
        ),
      );
      await tester.pumpAndSettle();
      expect(pro.hasLocalSandbox, isTrue);
      expect(pro.hasServerApple, isFalse);
      expect(store.lastServerUntil, isNull);
      expect(store.lastClearServer, isTrue);
      expect(gate.requiredWords, 3);
      expect(gate.config.wordsPerUnlock, 3);
      expect(store.claimedIds, contains('synthetic-sandbox-proof'));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
