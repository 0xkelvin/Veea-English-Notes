import 'package:http/http.dart' as http;
import 'package:veea_english_app/data/local/sqlite_vocabulary_repository.dart';
import 'package:veea_english_app/data/remote/go/api_client.dart';
import 'package:veea_english_app/data/remote/go/auth_api.dart';
import 'package:veea_english_app/data/remote/go/session_store.dart';
import 'package:veea_english_app/data/sync/learning_sync_api.dart';
import 'package:veea_english_app/data/sync/sync_engine.dart';
import 'package:veea_english_app/providers/go_auth_provider.dart';
import 'package:veea_english_app/services/sync_service.dart';
import 'secure_storage.dart';

class GoAccountStack {
  GoAccountStack(
    this.repo,
    this.secure,
    String base, {
    http.Client? network,
    bool accountNotebooks = true,
  }) {
    store = GoTokenStore(storage: secure);
    client = GoApiClient(tokens: store, baseUrl: base, httpClient: network);
    api = GoAuthApi(client: client, tokens: store);
    engine = SyncEngine(
      db: repo.database,
      api: LearningSyncApi(
        client: GoLearningHttpClient(client),
        baseUrl: base,
        accessToken: store.readAccessToken,
      ),
    );
    sync = SyncService(
      repository: repo,
      learningEngine: engine,
      networkEnabled: accountNotebooks,
    );
    auth = GoAuthProvider(
      accountNotebooks: accountNotebooks,
      authApi: api,
      tokens: store,
      client: client,
      repository: repo,
      sync: sync,
    );
  }
  final SqliteVocabularyRepository repo;
  final TestSecureStorage secure;
  late final GoTokenStore store;
  late final GoApiClient client;
  late final GoAuthApi api;
  late final SyncEngine engine;
  late final SyncService sync;
  late final GoAuthProvider auth;
  Future<void> close() async {
    await auth.notebookSettled;
    await sync.suspend();
    auth.dispose();
    sync.dispose();
    client.dispose();
    await repo.close();
  }
}
