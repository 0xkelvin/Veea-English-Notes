import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:veea_english_app/data/local/sqlite_vocabulary_repository.dart';
import 'package:veea_english_app/data/remote/api_client.dart';
import 'package:veea_english_app/providers/auth_provider.dart';
import 'package:veea_english_app/providers/cartridge_provider.dart';
import 'package:veea_english_app/providers/vocabulary_provider.dart';
import 'package:veea_english_app/screens/cartridge_library_screen.dart';
import '../data/go_session_test.dart' show tokens, userA, userB;
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
  var loginUser = userA;
  setUp(() async {
    loginUser = userA;
    app = GoAccountStack(
      await SqliteVocabularyRepository.open(path: inMemoryDatabasePath),
      TestSecureStorage(),
      'http://localhost',
      network: MockClient(
        (r) async => r.url.path.endsWith('/password/login')
            ? http.Response(jsonEncode(tokens(user: loginUser)), 200)
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

  Future<void> blocked() async {
    await app.auth.signIn(
      identifier: 'fixture@example.test',
      password: 'test-only',
    );
    await packs.refreshCatalog();
    api.refusal = const ApiException(
      'restore',
      statusCode: 410,
      code: 'sync_reset_required',
    );
    await expectLater(
      packs.installServer(packs.catalog.single),
      throwsA(isA<ApiException>()),
    );
    api.refusal = null;
    api.epoch = userB;
    api.version = 2;
  }

  Future<void> settle(WidgetTester t) async {
    // SQLite FFI runs on a real isolate; drain real I/O between widget frames.
    for (var i = 0; i < 3; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await t.pumpAndSettle();
    }
  }

  testWidgets(
    'opening review and restarting send no POST; offline Discard resolves only that request',
    (t) async {
      await t.runAsync(() async {
        await blocked();
        await app.repo.database.insert('cartridge_local_state', {
          'owner_id': userA,
          'cartridge_id': 'second',
          'pending_version': 3,
          'pending_body': 'preserved second request',
          'blocked': 1,
        });
        await packs.refreshLocal();
      });
      final posts = api.posts;
      await t.pumpWidget(build());
      await settle(t);
      expect(find.byKey(const Key('blocked-synthetic')), findsOneWidget);
      expect(find.byKey(const Key('blocked-second')), findsOneWidget);
      expect(api.posts, posts);
      await t.pumpWidget(const SizedBox());
      await t.runAsync(() async {
        packs.dispose();
        packs = CartridgeProvider(repository: app.repo, api: api);
        await packs.ready;
      });
      api.catalogOffline = true;
      await t.pumpWidget(build());
      await settle(t);
      expect(find.byKey(const Key('blocked-synthetic')), findsOneWidget);
      expect(api.posts, posts);
      final discard = find.byKey(const Key('discard-synthetic'));
      await t.ensureVisible(discard);
      await t.runAsync(() => t.tap(discard));
      await settle(t);
      expect(find.byKey(const Key('blocked-synthetic')), findsNothing);
      expect(find.byKey(const Key('blocked-second')), findsOneWidget);
      expect(api.posts, posts);
      await t.pumpWidget(const SizedBox());
      await settle(t);
    },
  );

  testWidgets(
    'new installation requires explicit confirmation and sends a fresh current-version request',
    (t) async {
      await t.runAsync(blocked);
      final original = packs.blockedInstalls.single.exactBody;
      final posts = api.posts;
      await t.pumpWidget(build());
      await settle(t);
      final start = find.byKey(const Key('new-install-synthetic'));
      await t.ensureVisible(start);
      await t.runAsync(() => t.tap(start));
      await settle(t);
      expect(find.text('Start a new install?'), findsOneWidget);
      expect(api.posts, posts);
      await t.tap(find.text('Cancel'));
      await settle(t);
      expect(packs.blockedInstalls.single.exactBody, original);
      expect(api.posts, posts);
      await t.runAsync(() => t.tap(start));
      await settle(t);
      await t.runAsync(
        () => t.tap(find.byKey(const Key('confirm-new-install'))),
      );
      await settle(t);
      expect(api.posts, posts + 1);
      expect(api.postedVersions.last, 2);
      expect(api.bodies.last, isNot(original));
      expect(jsonDecode(api.bodies.last)['epoch'], userB);
      expect(find.byKey(const Key('blocked-synthetic')), findsNothing);
      await t.pumpWidget(const SizedBox());
      await settle(t);
    },
  );

  testWidgets(
    'switching accounts hides blocked requests and invalidates an open confirmation',
    (t) async {
      await t.runAsync(blocked);
      final posts = api.posts;
      await t.pumpWidget(build());
      await settle(t);
      final start = find.byKey(const Key('new-install-synthetic'));
      await t.ensureVisible(start);
      await t.runAsync(() => t.tap(start));
      await settle(t);
      expect(find.byKey(const Key('confirm-new-install')), findsOneWidget);
      await t.runAsync(() async {
        await app.auth.signOut();
        loginUser = userB;
        await app.auth.signIn(
          identifier: 'second@example.test',
          password: 'test-only',
        );
        await packs.refreshLocal();
      });
      await settle(t);
      expect(find.byKey(const Key('blocked-synthetic')), findsNothing);
      expect(find.byKey(const Key('confirm-new-install')), findsNothing);
      expect(find.text('Account changed'), findsOneWidget);
      await t.tap(find.text('Close'));
      await t.pumpAndSettle();
      expect(api.posts, posts);
      await t.runAsync(() async {
        await app.auth.signOut();
        loginUser = userA;
        await app.auth.signIn(
          identifier: 'fixture@example.test',
          password: 'test-only',
        );
        await packs.refreshLocal();
      });
      await settle(t);
      expect(find.byKey(const Key('blocked-synthetic')), findsOneWidget);
      expect(api.posts, posts);
      await t.pumpWidget(const SizedBox());
      await settle(t);
    },
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
      await settle(t);
    },
  );
}
