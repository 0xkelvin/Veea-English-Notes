import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'core/config/app_config.dart';
import 'data/local/legacy_import.dart';
import 'data/local/sqlite_vocabulary_repository.dart';
import 'data/remote/api_client.dart';
import 'data/remote/auth_api.dart';
import 'data/remote/token_store.dart';
import 'data/remote/vocabulary_api.dart';
import 'providers/auth_provider.dart';
import 'providers/cartridge_provider.dart';
import 'providers/pet_provider.dart';
import 'providers/theme_provider.dart';
import 'providers/vocabulary_provider.dart';
import 'providers/widget_provider.dart';
import 'screens/home_screen.dart';
import 'models/word_challenge.dart';
import 'services/commute_playlist_service.dart';
import 'services/friend_challenge_service.dart';
import 'services/pronunciation_service.dart';
import 'services/reminder_notification_service.dart';
import 'services/sync_service.dart';
import 'services/tts_service.dart';
import 'services/widget_service.dart';
import 'widgets/pixel/pixel_field.dart';
import 'widgets/word_drop_overlay.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
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

    final themeProvider = ThemeProvider();
    await themeProvider.init();

    final widgetProvider = WidgetProvider();
    await widgetProvider.init();

    runApp(
      VeeaEnglishApp(
        vocabulary: vocabulary,
        auth: auth,
        sync: sync,
        pronunciation: pronunciation,
        themeProvider: themeProvider,
        widgetProvider: widgetProvider,
      ),
    );
  } catch (error, stack) {
    debugPrint('Startup failure: $error\n$stack');
    runApp(StartupRecoveryApp(error: error.toString(), onRetry: () => main()));
  }
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
  try {
    // Importing 126k dictionary rows takes a second or two, so it happens behind
    // the first frame rather than delaying the journal.
    await pronunciation.importIfNeeded();
    if (await repository.backfillPronunciations(pronunciation.lookup)) {
      await vocabulary.init();
    }

    await ReminderNotificationService.instance.initialize();

    await auth.restore();
    if (!AppConfig.isCloudEnabled || !auth.isSignedIn) return;

    await sync.refreshPendingCount();
    if (await sync.synchronise()) {
      // Reload so anything pulled from another device appears straight away.
      await vocabulary.init();
    }
  } catch (error, stack) {
    debugPrint('Background initialization failed: $error\n$stack');
  }
}

class VeeaEnglishApp extends StatefulWidget {
  const VeeaEnglishApp({
    super.key,
    required this.vocabulary,
    required this.auth,
    required this.sync,
    required this.pronunciation,
    this.themeProvider,
    this.widgetProvider,
  });

  final VocabularyProvider vocabulary;
  final AuthProvider auth;
  final SyncService sync;
  final PronunciationService pronunciation;
  final ThemeProvider? themeProvider;
  final WidgetProvider? widgetProvider;

  @override
  State<VeeaEnglishApp> createState() => _VeeaEnglishAppState();
}

class _VeeaEnglishAppState extends State<VeeaEnglishApp> {
  late final AppLifecycleListener _lifecycleListener;
  final TtsService _ttsService = TtsService();
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  final FriendChallengeService _friendChallengeService =
      FriendChallengeService();
  StreamSubscription<WordChallenge>? _challengeSubscription;

  @override
  void initState() {
    super.initState();
    _friendChallengeService.init();
    _challengeSubscription = _friendChallengeService.incomingChallenges.listen((
      challenge,
    ) {
      if (!mounted) return;
      final navState = _navigatorKey.currentState;
      if (navState != null && navState.mounted) {
        WordDropOverlay.show(navState.context, challenge: challenge);
      }
    });

    _lifecycleListener = AppLifecycleListener(
      onResume: _handleAppResume,
      onInactive: () => widget.vocabulary.refreshWidgetData(),
      onHide: () => widget.vocabulary.refreshWidgetData(),
      onPause: () => widget.vocabulary.refreshWidgetData(),
      onRestart: () => widget.vocabulary.refreshWidgetData(),
      onDetach: () => widget.vocabulary.refreshWidgetData(),
    );

    if (widget.widgetProvider != null) {
      WidgetService.handleWidgetClick(
        widgetProvider: widget.widgetProvider!,
        ttsService: _ttsService,
      );
    }
  }

  void _handleAppResume() {
    widget.vocabulary.refreshWidgetData();
  }

  @override
  void dispose() {
    _challengeSubscription?.cancel();
    _friendChallengeService.dispose();
    _lifecycleListener.dispose();
    _ttsService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: widget.vocabulary),
        ChangeNotifierProvider.value(value: widget.auth),
        ChangeNotifierProvider.value(value: widget.sync),
        ChangeNotifierProvider.value(value: _ttsService),
        ChangeNotifierProvider.value(value: _friendChallengeService),
        ChangeNotifierProvider(
          create: (_) => widget.themeProvider ?? (ThemeProvider()..init()),
        ),
        ChangeNotifierProvider(
          create: (_) => widget.widgetProvider ?? (WidgetProvider()..init()),
        ),
        ChangeNotifierProvider(create: (_) => PetProvider()..init()),
        ChangeNotifierProvider(create: (_) => CartridgeProvider()),
        ChangeNotifierProvider(create: (_) => CommutePlaylistService()..init()),
        Provider<PronunciationService>.value(value: widget.pronunciation),
      ],
      child: Consumer<ThemeProvider>(
        builder: (context, theme, _) {
          return MaterialApp(
            navigatorKey: _navigatorKey,
            title: 'Veea English',
            debugShowCheckedModeBanner: false,
            theme: theme.activeTheme,
            darkTheme: theme.darkTheme,
            themeMode: theme.themeMode,
            scrollBehavior: const PixelScrollBehavior(),
            home: const HomeScreen(),
          );
        },
      ),
    );
  }
}

class StartupRecoveryApp extends StatelessWidget {
  const StartupRecoveryApp({
    super.key,
    required this.error,
    required this.onRetry,
  });

  final String error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: const Color(0xFF1B1E17),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'INITIALIZATION FAILED',
                  style: TextStyle(
                    color: Color(0xFFFF5252),
                    fontSize: 22,
                    fontFamily: 'Handjet',
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'The database or system services could not be opened on startup. Your saved notes are safe.',
                  style: TextStyle(color: Color(0xFFE6E4D8), fontSize: 15),
                ),
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  color: const Color(0xFF2B2E24),
                  child: Text(
                    error,
                    style: const TextStyle(
                      color: Color(0xFF9A9C8C),
                      fontSize: 12,
                      fontFamily: 'monospace',
                    ),
                    maxLines: 6,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(height: 24),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF9BBC0F),
                    foregroundColor: const Color(0xFF0F380F),
                  ),
                  onPressed: onRetry,
                  child: const Text('RETRY STARTUP'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
