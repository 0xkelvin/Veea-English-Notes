import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'core/config/app_config.dart';
import 'core/theme/pixel_theme.dart';
import 'data/local/legacy_import.dart';
import 'data/local/sqlite_vocabulary_repository.dart';
import 'data/remote/api_client.dart';
import 'data/remote/auth_api.dart';
import 'data/remote/token_store.dart';
import 'data/remote/vocabulary_api.dart';
import 'providers/auth_provider.dart';
import 'providers/vocabulary_provider.dart';
import 'screens/home_screen.dart';
import 'services/pronunciation_service.dart';
import 'services/sync_service.dart';
import 'services/tts_service.dart';
import 'widgets/pixel/pixel_field.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final repository = await SqliteVocabularyRepository.open();
  await LegacyImport(repository).runIfNeeded();
  final pronunciation = PronunciationService(repository.database);

  final vocabulary = VocabularyProvider(repository);
  await vocabulary.init();

  const tokens = TokenStore();
  final apiClient = ApiClient(tokenStore: tokens);
  final sync = SyncService(
    repository: repository,
    api: VocabularyApi(apiClient),
  );
  final auth = AuthProvider(
    authApi: AuthApi(client: apiClient, tokens: tokens),
    tokens: tokens,
    client: apiClient,
    // Deleting an account has to wipe this device too, so the provider needs
    // the local store and the sync cursor as well as the API.
    repository: repository,
    sync: sync,
  );

  // The app is usable immediately; the session and any sync catch up behind
  // the first frame rather than blocking it.
  unawaited(
    _startBackgroundWork(
      auth: auth,
      sync: sync,
      vocabulary: vocabulary,
      pronunciation: pronunciation,
      repository: repository,
    ),
  );

  runApp(
    VeeaEnglishApp(
      vocabulary: vocabulary,
      auth: auth,
      sync: sync,
      pronunciation: pronunciation,
    ),
  );
}

/// Restores the session and performs an opening sync, if a server is
/// configured and the user is signed in.
Future<void> _startBackgroundWork({
  required AuthProvider auth,
  required SyncService sync,
  required VocabularyProvider vocabulary,
  required PronunciationService pronunciation,
  required SqliteVocabularyRepository repository,
}) async {
  // Importing 126k dictionary rows takes a second or two, so it happens behind
  // the first frame rather than delaying the journal.
  await pronunciation.importIfNeeded();
  if (await repository.backfillPronunciations(pronunciation.lookup)) {
    await vocabulary.init();
  }

  await auth.restore();
  if (!AppConfig.isCloudEnabled || !auth.isSignedIn) return;

  await sync.refreshPendingCount();
  if (await sync.synchronise()) {
    // Reload so anything pulled from another device appears straight away.
    await vocabulary.init();
  }
}

class VeeaEnglishApp extends StatelessWidget {
  const VeeaEnglishApp({
    super.key,
    required this.vocabulary,
    required this.auth,
    required this.sync,
    required this.pronunciation,
  });

  final VocabularyProvider vocabulary;
  final AuthProvider auth;
  final SyncService sync;
  final PronunciationService pronunciation;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: vocabulary),
        ChangeNotifierProvider.value(value: auth),
        ChangeNotifierProvider.value(value: sync),
        ChangeNotifierProvider(create: (_) => TtsService()),
        Provider<PronunciationService>.value(value: pronunciation),
      ],
      child: MaterialApp(
        title: 'Veea English',
        debugShowCheckedModeBanner: false,
        theme: PixelTheme.light(),
        darkTheme: PixelTheme.dark(),
        // Both palettes are built from the same tokens; the OS picks.
        themeMode: ThemeMode.system,
        scrollBehavior: const PixelScrollBehavior(),
        home: const HomeScreen(),
      ),
    );
  }
}
