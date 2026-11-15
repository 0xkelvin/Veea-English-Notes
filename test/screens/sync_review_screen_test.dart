import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:veea_english_app/data/local/app_database.dart';
import 'package:veea_english_app/data/sync/learning_sync_api.dart';
import 'package:veea_english_app/data/sync/sync_engine.dart';
import 'package:veea_english_app/models/vocabulary_word.dart';
import 'package:veea_english_app/screens/sync_review_screen.dart';

class ReviewEngine extends SyncEngine {
  ReviewEngine(Database db)
    : super(
        db: db,
        api: LearningSyncApi(
          client: MockClient((_) async => http.Response('', 503)),
          baseUrl: 'http://localhost',
          accessToken: () async => null,
        ),
      );
  bool prompt = true;
  int declined = 0, imported = 0, confirmed = 0, plans = 0;
  List<ReviewItem> items = [];
  @override
  Future<List<ReviewItem>> reviewItems() async => items;
  @override
  Future<List<Map<String, Object?>>> heldWords() async => [];
  @override
  Future<bool> shouldPromptImport() async => prompt;
  @override
  Future<void> declineImport() async {
    declined++;
    prompt = false;
  }

  @override
  Future<bool> requiresImportConfirmation() async => false;
  @override
  Future<List<String>> pendingImportSelection() async => [];
  @override
  Future<GuestImportPlan> planImport() async {
    plans++;
    return GuestImportPlan(
      datasetId: 'dataset',
      userId: 'owner',
      candidates: [
        VocabularyWord.create(
          id: 'one',
          word: 'one',
          meaning: 'm',
          date: '2026-11-14',
          now: DateTime(2026, 11, 14),
        ),
      ],
      duplicates: [],
      sizes: {'one': 100},
      liveWords: 49999,
      contentBytes: 0,
    );
  }

  @override
  Future<ImportOutcome> importWords(
    GuestImportPlan plan,
    List<String> ids,
  ) async {
    imported++;
    return const ImportOutcome(confirmLiveWords: 49999, confirmContentBytes: 1);
  }

  @override
  Future<ImportOutcome> confirmImport(
    GuestImportPlan plan,
    List<String> ids,
  ) async {
    confirmed++;
    prompt = false;
    return const ImportOutcome(imported: 1);
  }
}

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  late Database db;
  late ReviewEngine engine;
  setUp(() async {
    db = await AppDatabase.open(path: inMemoryDatabasePath);
    engine = ReviewEngine(db);
  });
  tearDown(() => db.close());
  testWidgets(
    '§15.2.6 declining is durable policy; explicit later import refreshes and reconfirms capacity',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: SyncReviewScreen(engine: engine)),
      );
      await tester.pumpAndSettle();
      expect(find.text('Import selected'), findsOneWidget);
      await tester.tap(find.text('Keep on this device'));
      await tester.pumpAndSettle();
      expect(engine.declined, 1);
      expect(engine.imported, 0);
      await tester.tap(find.text('Import local words'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Import selected'));
      await tester.pumpAndSettle();
      expect(find.text('Capacity changed — confirm again'), findsOneWidget);
      expect(engine.plans, 3);
      expect(engine.imported, 1);
      expect(engine.confirmed, 0);
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Confirm import again'));
      await tester.pumpAndSettle();
      expect(engine.confirmed, 1);
      expect(find.textContaining('1 words imported'), findsOneWidget);
    },
  );
  testWidgets(
    '§15.2.4 tombstoned update offers recreation, delete remains delete, no bulk replay',
    (tester) async {
      engine.prompt = false;
      engine.items = [
        ReviewItem({
          'id': 1,
          'entity_id': 'lost',
          'op': 'update',
          'payload': '{"data":{"meaning":"m"}}',
          'content': '{"word":"lost","meaning":"m"}',
          'reason': 'pre_restore',
          'server_record': '{"deleted":true}',
        }),
        ReviewItem({
          'id': 2,
          'entity_id': 'live',
          'op': 'delete',
          'payload': '{}',
          'content': null,
          'reason': 'writer_retired',
          'server_record': '{"deleted":false}',
        }),
      ];
      await tester.pumpWidget(
        MaterialApp(home: SyncReviewScreen(engine: engine)),
      );
      await tester.pumpAndSettle();
      expect(find.text('Apply this edit'), findsNothing);
      expect(find.text('Add again as new word'), findsOneWidget);
      expect(find.text('Apply delete'), findsOneWidget);
      expect(find.text('Discard'), findsNWidgets(2));
      expect(find.textContaining('Apply all'), findsNothing);
    },
  );
}
