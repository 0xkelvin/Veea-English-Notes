import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'core/config/app_config.dart';
import 'data/local/legacy_import.dart';
import 'data/feedback_repository.dart';
import 'providers/feedback_provider.dart';
import 'data/local/sqlite_vocabulary_repository.dart';
import 'data/remote/api_client.dart';
import 'data/remote/auth_api.dart';
import 'data/remote/token_store.dart';
import 'data/remote/vocabulary_api.dart';
import 'providers/app_gate_provider.dart';
import 'providers/auth_provider.dart';
import 'providers/cartridge_provider.dart';
import 'providers/pet_provider.dart';
import 'providers/theme_provider.dart';
import 'providers/vocabulary_provider.dart';
import 'providers/widget_provider.dart';
import 'screens/app_gate_screen.dart';
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

    // Restore local ownership before showing the notebook. Network sync and
    // dictionary import stay in the background; a sign-in cannot race a late
    // startup restore and replace the account the user just opened.
    try {
      await auth.restore();
      await vocabulary.init();
    } catch (error) {
      debugPrint('Could not restore the local account: $error');
    }

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

    final appGateProvider = AppGateProvider(repository: repository);
    await appGateProvider.init();

    runApp(
      VeeaEnglishApp(
        vocabulary: vocabulary,
        auth: auth,
        sync: sync,
        pronunciation: pronunciation,
        themeProvider: themeProvider,
        widgetProvider: widgetProvider,
        appGateProvider: appGateProvider,
        feedback: FeedbackProvider(
          FeedbackRepository(repository.database, apiClient),
        ),
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
    this.appGateProvider,
    this.feedback,
  });

  final VocabularyProvider vocabulary;
  final AuthProvider auth;
  final SyncService sync;
  final PronunciationService pronunciation;
  final ThemeProvider? themeProvider;
  final WidgetProvider? widgetProvider;
  final AppGateProvider? appGateProvider;
  final FeedbackProvider? feedback;

  @override
  State<VeeaEnglishApp> createState() => _VeeaEnglishAppState();
}

class _VeeaEnglishAppState extends State<VeeaEnglishApp> {
  late final AppLifecycleListener _lifecycleListener;
  late final AppGateProvider _appGateProvider;
  final TtsService _ttsService = TtsService();
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  final FriendChallengeService _friendChallengeService =
      FriendChallengeService();
  StreamSubscription<WordChallenge>? _challengeSubscription;
  StreamSubscription<String>? _gateSubscription;
  ValueNotifier<String>? _activeGateTarget;
  int _gateRequestVersion = 0;
  String? _lastAccount;
  int _accountViewVersion = 0;
  Timer? _syncDebounce;

  void _authChanged() {
    final owner = widget.auth.accountId;
    if (owner == _lastAccount) return;
    _lastAccount = owner;
    unawaited(_refreshNotebook(owner, ++_accountViewVersion));
  }

  Future<void> _refreshNotebook(String? owner, int version) async {
    await widget.vocabulary.init();
    if (!mounted || version != _accountViewVersion) return;
    await _appGateProvider.init();
    if (!mounted || version != _accountViewVersion) return;
    await widget.feedback?.activate(owner);
    if (widget.auth.isSignedIn) await _syncNotebook();
  }

  void _wordsChanged() {
    if (!widget.auth.isSignedIn || !AppConfig.isCloudEnabled) return;
    _syncDebounce?.cancel();
    _syncDebounce = Timer(const Duration(seconds: 2), () async {
      await widget.sync.refreshPendingCount();
      if (widget.sync.pendingCount > 0) await _syncNotebook();
    });
  }

  Future<void> _syncNotebook() async {
    if (!widget.auth.isSignedIn ||
        !AppConfig.isCloudEnabled ||
        widget.auth.hasPendingDeletion) {
      return;
    }
    if (await widget.sync.synchronise() && mounted) {
      await widget.vocabulary.init();
    }
  }

  Future<void> _openGateScreen(String targetApp) async {
    final target = targetApp.trim();
    if (!mounted ||
        !target.startsWith('native:') ||
        _activeGateTarget?.value == target) {
      return;
    }
    final request = ++_gateRequestVersion;
    try {
      await _appGateProvider.prepareChallenge();
    } catch (error) {
      debugPrint('Could not refresh the gate notebook: $error');
    }
    if (!mounted || request != _gateRequestVersion) return;
    if (_activeGateTarget != null) {
      // Switch the existing gate to the latest intercepted app. The previous
      // app's completed words remain saved; duplicate events do not stack pages.
      _activeGateTarget!.value = target;
      return;
    }
    final navState = _navigatorKey.currentState;
    if (navState != null && navState.mounted) {
      final activeTarget = ValueNotifier(target);
      _activeGateTarget = activeTarget;
      navState
          .push(
            PageRouteBuilder<void>(
              pageBuilder: (_, _, _) => ValueListenableBuilder<String>(
                valueListenable: activeTarget,
                builder: (_, currentTarget, _) => AppGateScreen(
                  key: ValueKey(currentTarget),
                  targetApp: currentTarget,
                ),
              ),
              transitionDuration: Duration.zero,
              reverseTransitionDuration: Duration.zero,
            ),
          )
          .whenComplete(() {
            if (identical(_activeGateTarget, activeTarget)) {
              _activeGateTarget = null;
              activeTarget.dispose();
            }
          });
    } else {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _openGateScreen(target),
      );
    }
  }

  Future<void> _drainPendingGate() async {
    final pending = await _appGateProvider.service.consumeNativePendingGate();
    if (pending != null && pending.isNotEmpty && mounted) {
      _openGateScreen(pending);
    }
  }

  @override
  void initState() {
    super.initState();
    _appGateProvider =
        widget.appGateProvider ??
        (AppGateProvider(repository: widget.vocabulary.repository)..init());
    _lastAccount = widget.auth.accountId;
    widget.auth.addListener(_authChanged);
    widget.vocabulary.addListener(_wordsChanged);
    unawaited(widget.feedback?.activate(_lastAccount) ?? Future.value());
    _gateSubscription = _appGateProvider.service.onGateTriggered.listen((
      targetApp,
    ) {
      _openGateScreen(targetApp);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _drainPendingGate();
      unawaited(_recoverPendingDeletion());
    });

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

  Future<void> _handleAppResume() async {
    widget.vocabulary.refreshWidgetData();
    await _appGateProvider.refreshNativeScreenTime();
    try {
      await _appGateProvider.prepareChallenge();
    } catch (error) {
      debugPrint('Could not refresh challenge progress: $error');
    }
    if (!mounted) return;
    _drainPendingGate();
    unawaited(_recoverPendingDeletion());
    unawaited(_syncNotebook());
    unawaited(widget.feedback?.refresh() ?? Future.value());
  }

  Future<void> _recoverPendingDeletion() async {
    if (!widget.auth.hasPendingDeletion) return;
    try {
      final outcome = await widget.auth.checkPendingDeletion();
      if (outcome == DeletionOutcome.deleted && mounted) {
        await widget.vocabulary.init();
      }
    } catch (error) {
      debugPrint('Could not recover the pending deletion: $error');
    }
  }

  @override
  void dispose() {
    _syncDebounce?.cancel();
    widget.auth.removeListener(_authChanged);
    widget.vocabulary.removeListener(_wordsChanged);
    _gateRequestVersion++;
    _activeGateTarget?.dispose();
    _activeGateTarget = null;
    _gateSubscription?.cancel();
    if (widget.appGateProvider == null) {
      _appGateProvider.dispose();
    }
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
        if (widget.feedback != null)
          ChangeNotifierProvider.value(value: widget.feedback!),
        ChangeNotifierProvider.value(value: widget.sync),
        ChangeNotifierProvider.value(value: _ttsService),
        ChangeNotifierProvider.value(value: _friendChallengeService),
        ChangeNotifierProvider.value(value: _appGateProvider),
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
