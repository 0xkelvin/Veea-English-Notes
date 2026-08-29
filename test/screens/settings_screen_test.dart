import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:veea_english_app/core/theme/pixel_theme.dart';
import 'package:veea_english_app/data/local/sqlite_vocabulary_repository.dart';
import 'package:veea_english_app/data/remote/api_client.dart';
import 'package:veea_english_app/data/remote/auth_api.dart';
import 'package:veea_english_app/data/remote/token_store.dart';
import 'package:veea_english_app/data/remote/vocabulary_api.dart';
import 'package:veea_english_app/models/vocabulary_word.dart';
import 'package:veea_english_app/providers/auth_provider.dart';
import 'package:veea_english_app/providers/theme_provider.dart';
import 'package:veea_english_app/providers/vocabulary_provider.dart';
import 'package:veea_english_app/providers/widget_provider.dart';
import 'package:veea_english_app/screens/settings_screen.dart';
import 'package:veea_english_app/services/sync_service.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late SqliteVocabularyRepository repo;
  late VocabularyProvider vocabProvider;
  late ThemeProvider themeProvider;
  late WidgetProvider widgetProvider;
  late AuthProvider authProvider;
  late SyncService syncService;

  final today = DateTime(2026, 8, 18, 10);

  setUp(() async {
    repo = await SqliteVocabularyRepository.open(
      path: inMemoryDatabasePath,
      now: () => today,
    );

    await repo.insert(
      VocabularyWord.create(
        id: '1',
        word: 'resilient',
        meaning: 'kiên cường',
        date: '2026-08-18',
        now: today,
      ),
    );

    vocabProvider = VocabularyProvider(repo, now: () => today);
    await vocabProvider.init();
    themeProvider = ThemeProvider();
    widgetProvider = WidgetProvider();

    const tokens = TokenStore();
    final client = ApiClient(tokenStore: tokens);
    syncService = SyncService(
      repository: repo,
      api: VocabularyApi(client),
    );
    authProvider = AuthProvider(
      authApi: AuthApi(client: client, tokens: tokens),
      tokens: tokens,
      client: client,
      repository: repo,
      sync: syncService,
    );
  });

  tearDown(() => repo.close());

  Widget buildApp(Widget child) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: vocabProvider),
        ChangeNotifierProvider.value(value: themeProvider),
        ChangeNotifierProvider.value(value: widgetProvider),
        ChangeNotifierProvider.value(value: authProvider),
        ChangeNotifierProvider.value(value: syncService),
      ],
      child: MaterialApp(theme: PixelTheme.light(), home: child),
    );
  }

  testWidgets('SettingsScreen renders offline stats, theme, widgets, and cloud tile', (tester) async {
    tester.view.physicalSize = const Size(600, 3500);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(buildApp(const SettingsScreen()));
    await tester.pump();

    expect(find.text('SETTINGS & STATS'), findsOneWidget);
    expect(find.text('ACTIVITY HEATMAP'), findsOneWidget);
    expect(find.textContaining('RETRO MILESTONES'), findsOneWidget);
    expect(find.text('RETRO PIXEL THEME'), findsOneWidget);
    expect(find.text('HOME SCREEN & LOCK SCREEN WIDGET'), findsOneWidget);
    expect(find.text('CLOUD & CROSS-DEVICE SYNC'), findsOneWidget);
  });
}
