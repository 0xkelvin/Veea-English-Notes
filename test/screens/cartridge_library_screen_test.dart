import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:veea_english_app/data/local/sqlite_vocabulary_repository.dart';
import 'package:veea_english_app/providers/auth_provider.dart';
import 'package:veea_english_app/providers/cartridge_provider.dart';
import 'package:veea_english_app/providers/vocabulary_provider.dart';
import 'package:veea_english_app/screens/cartridge_library_screen.dart';
import '../data/go_session_test.dart' show tokens;
import '../support/go_account_stack.dart';
import '../support/secure_storage.dart';
import '../providers/cartridge_server_test.dart' show FakeCartridgeApi;

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  late GoAccountStack app;
  late VocabularyProvider vocab;
  late CartridgeProvider packs;
  late FakeCartridgeApi api;
  setUp(() async {
    app = GoAccountStack(
      await SqliteVocabularyRepository.open(path: inMemoryDatabasePath),
      TestSecureStorage(),
      'http://localhost',
      network: MockClient(
        (r) async => r.url.path.endsWith('/password/login')
            ? http.Response(jsonEncode(tokens()), 200)
            : http.Response('{"code":"sync_unavailable"}', 503),
      ),
    );
    await app.auth.restore();
    vocab = VocabularyProvider(app.repo);
    await vocab.init();
    api = FakeCartridgeApi();
    packs = CartridgeProvider(repository: app.repo, api: api);
    await packs.ready;
  });
  tearDown(() async {
    packs.dispose();
    vocab.dispose();
    await app.close();
  });
  Widget build() => MultiProvider(
    providers: [
      ChangeNotifierProvider<AuthProvider>.value(value: app.auth),
      ChangeNotifierProvider<VocabularyProvider>.value(value: vocab),
      ChangeNotifierProvider<CartridgeProvider>.value(value: packs),
    ],
    child: const MaterialApp(home: CartridgeLibraryScreen()),
  );
  testWidgets('guest can see the bundled starter without a server catalog', (
    t,
  ) async {
    await t.pumpWidget(build());
    await t.runAsync(() async {
      await packs.refreshCatalog();
    });
    await t.pumpAndSettle();
    expect(find.text('FREE STARTER'), findsOneWidget);
    expect(find.text('Free · available offline'), findsOneWidget);
    expect(find.byKey(const Key('install-synthetic')), findsNothing);
    expect(api.posts, 0);
    await t.pumpWidget(const SizedBox());
  });
  testWidgets(
    'Premium metadata is visible; cancel sends nothing and plan refusal is explained',
    (t) async {
      await t.runAsync(() async {
        await app.auth.signIn(
          identifier: 'fixture@example.test',
          password: 'test-only',
        );
        await packs.refreshCatalog();
      });
      api.premium = false;
      await t.pumpWidget(build());
      await t.pumpAndSettle();
      final install = find.byKey(const Key('install-synthetic'));
      await t.ensureVisible(install);
      await t.tap(install);
      await t.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      await t.pumpAndSettle();
      expect(find.text('Install Synthetic fixture?'), findsOneWidget);
      await t.tap(find.text('Cancel'));
      await t.pumpAndSettle();
      expect(api.posts, 0);
      expect(api.downloads, 0);
      await t.tap(install);
      await t.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      await t.pumpAndSettle();
      await t.tap(find.text('Confirm'));
      await t.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await t.pumpAndSettle();
      expect(find.textContaining('Premium is required'), findsOneWidget);
      expect(api.posts, 0);
      await t.pumpWidget(const SizedBox());
    },
  );
}
