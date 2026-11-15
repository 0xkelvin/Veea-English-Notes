import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:veea_admin_console/src/admin_api.dart';
import 'package:veea_admin_console/src/console_controller.dart';
import 'package:veea_admin_console/src/messages.dart';
import 'package:veea_admin_console/src/transport.dart';
import 'package:veea_admin_console/src/ui/app.dart';

import 'support/fake_backend.dart';

Finder key(String k) => find.byKey(Key(k));

Future<ConsoleController> boot(
  WidgetTester t,
  FakeBackend b,
  String email, {
  Size size = const Size(1400, 1000),
}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final c = ConsoleController(
    AdminApi(AdminTransport(baseUrl: 'http://fake.test', client: b.client)),
  );
  addTearDown(c.dispose);
  await t.pumpWidget(ConsoleApp(controller: c));
  await t.enterText(key('signin-email'), email);
  await t.enterText(key('signin-password'), 'correct horse battery staple');
  await t.tap(key('signin-submit'));
  await t.pumpAndSettle();
  return c;
}

Future<void> pick(WidgetTester t, String field, String label) async {
  await t.tap(key(field));
  await t.pumpAndSettle();
  await t.tap(find.text(label).last);
  await t.pumpAndSettle();
}

Future<void> openUser(WidgetTester t, FakeAccount a) async {
  await t.tap(key('user-row-${a.id}'));
  await t.pumpAndSettle();
}

String noticeText(WidgetTester t) => t.widget<Text>(key('notice-text')).data!;

void main() {
  late FakeBackend b;
  late FakeAccount sa, admin, user, staffPeer;
  setUp(() {
    b = FakeBackend();
    sa = b.add('root@example.test', role: 'super_admin');
    admin = b.add('ops@example.test', role: 'admin');
    user = b.add('learner@example.test');
    staffPeer = b.add('ops2@example.test', role: 'admin');
  });

  testWidgets('a non-staff account gets the no-access page', (t) async {
    await boot(t, b, user.email);
    expect(key('no-access'), findsOneWidget);
    expect(noticeText(t), Messages.noAccess);
    await t.tap(key('no-access-signout'));
    await t.pumpAndSettle();
    expect(key('signin-email'), findsOneWidget);
  });

  testWidgets('wrong password stays on sign-in with an actionable message', (
    t,
  ) async {
    t.view.physicalSize = const Size(1400, 1000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final c = ConsoleController(
      AdminApi(AdminTransport(baseUrl: 'http://fake.test', client: b.client)),
    );
    await t.pumpWidget(ConsoleApp(controller: c));
    await t.enterText(key('signin-email'), admin.email);
    await t.enterText(key('signin-password'), 'nope');
    await t.tap(key('signin-submit'));
    await t.pumpAndSettle();
    expect(noticeText(t), 'The email or password is incorrect.');
  });

  testWidgets('email code sign-in', (t) async {
    t.view.physicalSize = const Size(1400, 1000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final c = ConsoleController(
      AdminApi(AdminTransport(baseUrl: 'http://fake.test', client: b.client)),
    );
    await t.pumpWidget(ConsoleApp(controller: c));
    await t.tap(find.text('Use an email code instead'));
    await t.pumpAndSettle();
    await t.enterText(key('signin-email'), sa.email);
    await t.tap(key('signin-submit'));
    await t.pumpAndSettle();
    await t.enterText(key('signin-code'), '123456');
    await t.tap(key('signin-submit'));
    await t.pumpAndSettle();
    expect(key('signed-in-as'), findsOneWidget);
  });

  testWidgets('Admin: User accounts only, no role filter or role action', (
    t,
  ) async {
    await boot(t, b, admin.email);
    expect(key('filter-role'), findsNothing);
    expect(
      find.text('As an Admin you can see and manage User accounts only.'),
      findsOneWidget,
    );
    expect(key('user-row-${user.id}'), findsOneWidget);
    expect(key('user-row-${staffPeer.id}'), findsNothing);
    expect(key('user-row-${sa.id}'), findsNothing);
    await openUser(t, user);
    expect(key('action-suspend'), findsOneWidget);
    expect(key('action-revoke-all'), findsOneWidget);
    expect(key('action-change-role'), findsNothing);
    expect(key('action-reinstate'), findsNothing);
    expect(find.text('Signed-in devices'), findsOneWidget);
  });

  testWidgets(
    'Super Admin: every role, role change offered, self only steps down',
    (t) async {
      await boot(t, b, sa.email);
      expect(key('filter-role'), findsOneWidget);
      for (final a in [sa, admin, user, staffPeer]) {
        expect(key('user-row-${a.id}'), findsOneWidget);
      }
      await openUser(t, admin);
      expect(key('action-change-role'), findsOneWidget);
      await openUser(t, sa);
      // The last active Super Admin cannot step down: the server offers nothing.
      expect(key('action-change-role'), findsNothing);
      expect(key('no-actions'), findsOneWidget);
    },
  );

  testWidgets('loading, empty and list error states with retry', (t) async {
    final c = await boot(t, b, admin.email);
    b.gate = Completer<void>();
    unawaited(c.search(c.query));
    await t.pump();
    expect(key('list-loading'), findsOneWidget);
    b.gate!.complete();
    b.gate = null;
    await t.pumpAndSettle();
    await t.enterText(key('search-field'), 'zz');
    await t.tap(key('search-submit'));
    await t.pumpAndSettle();
    expect(
      find.text('Type at least 3 characters to search by prefix.'),
      findsOneWidget,
    );
    await t.enterText(key('search-field'), 'nobody');
    await t.tap(key('search-submit'));
    await t.pumpAndSettle();
    expect(key('list-empty'), findsOneWidget);
    b.failNext('GET /v1/admin/users', 500, 'internal_error');
    await t.enterText(key('search-field'), 'learner');
    await t.tap(key('search-submit'));
    await t.pumpAndSettle();
    expect(key('list-error'), findsOneWidget);
    expect(find.text(Messages.generic), findsOneWidget);
    await t.tap(key('list-retry'));
    await t.pumpAndSettle();
    expect(key('user-row-${user.id}'), findsOneWidget);
  });

  testWidgets('detail loading and error states', (t) async {
    final c = await boot(t, b, admin.email);
    b.gate = Completer<void>();
    unawaited(c.select(user.id));
    await t.pump();
    expect(key('detail-loading'), findsOneWidget);
    b.gate!.complete();
    b.gate = null;
    await t.pumpAndSettle();
    b.failNext('GET /v1/admin/users/${user.id}', 429, 'rate_limited');
    await c.reloadDetail();
    await t.pumpAndSettle();
    expect(key('detail-error'), findsOneWidget);
    expect(find.text(Messages.rateLimited), findsOneWidget);
  });

  testWidgets(
    'suspend needs confirmation and a fixed reason; reinstate follows',
    (t) async {
      await boot(t, b, admin.email);
      await openUser(t, user);
      await t.tap(key('action-suspend'));
      await t.pumpAndSettle();
      FilledButton confirm() => t.widget<FilledButton>(key('dialog-confirm'));
      expect(confirm().onPressed, isNull, reason: 'no reason chosen yet');
      await pick(t, 'dialog-reason', 'Abuse');
      expect(confirm().onPressed, isNotNull);
      await t.enterText(key('dialog-ticket'), 'has space');
      await t.pump();
      expect(confirm().onPressed, isNull, reason: 'invalid ticket reference');
      await t.enterText(key('dialog-ticket'), 'vat_trick');
      await t.pump();
      expect(
        confirm().onPressed,
        isNull,
        reason: 'token-shaped ticket reference',
      );
      await t.enterText(key('dialog-ticket'), 'SUP-1042');
      await t.pump();
      await t.tap(key('dialog-cancel'));
      await t.pumpAndSettle();
      expect(user.status, 'active', reason: 'cancel sends nothing');
      await t.tap(key('action-suspend'));
      await t.pumpAndSettle();
      await pick(t, 'dialog-reason', 'Abuse');
      await t.enterText(key('dialog-ticket'), 'SUP-1042');
      await t.pump();
      await t.tap(key('dialog-confirm'));
      await t.pumpAndSettle();
      expect(user.status, 'suspended');
      expect(user.suspensionReason, 'abuse');
      expect(user.ticketRef, 'SUP-1042');
      expect(noticeText(t), 'Account suspended. It was signed out everywhere.');
      expect(key('detail-suspension'), findsOneWidget);
      expect(key('action-suspend'), findsNothing);
      await t.tap(key('action-reinstate'));
      await t.pumpAndSettle();
      await pick(t, 'dialog-reason', 'Appeal upheld');
      await t.tap(key('dialog-confirm'));
      await t.pumpAndSettle();
      expect(user.status, 'active');
      expect(key('action-suspend'), findsOneWidget);
    },
  );

  testWidgets('Super Admin promotes with a role and reason', (t) async {
    await boot(t, b, sa.email);
    await openUser(t, user);
    await t.tap(key('action-change-role'));
    await t.pumpAndSettle();
    await pick(t, 'dialog-role', 'Admin');
    expect(
      find.textContaining('signs the account out on every device'),
      findsOneWidget,
    );
    await pick(t, 'dialog-reason', 'Staffing change');
    await t.tap(key('dialog-confirm'));
    await t.pumpAndSettle();
    expect(user.role, 'admin');
    expect(noticeText(t), 'Role changed to Admin.');
  });

  testWidgets('revoke one session and all sessions', (t) async {
    await boot(t, b, admin.email);
    await openUser(t, user);
    await t.tap(find.text('Revoke').first);
    await t.pumpAndSettle();
    await pick(t, 'dialog-reason', 'Security review');
    await t.tap(key('dialog-confirm'));
    await t.pumpAndSettle();
    expect(noticeText(t), 'Revoked 1 session.');
    expect(user.sessions.length, 1);
    await t.tap(key('action-revoke-all'));
    await t.pumpAndSettle();
    await pick(t, 'dialog-reason', 'Account compromise');
    await t.tap(key('dialog-confirm'));
    await t.pumpAndSettle();
    expect(user.sessions, isEmpty);
    expect(key('sessions-empty'), findsOneWidget);
  });

  testWidgets(
    'an expired access token is refreshed without bothering the operator',
    (t) async {
      await boot(t, b, admin.email);
      await openUser(t, user);
      b.expireAccess();
      await t.tap(key('action-suspend'));
      await t.pumpAndSettle();
      await pick(t, 'dialog-reason', 'Fraud');
      await t.tap(key('dialog-confirm'));
      await t.pumpAndSettle();
      expect(user.status, 'suspended');
      expect(
        b.requests.where((r) => r == 'POST /v1/auth/token/refresh'),
        hasLength(1),
      );
    },
  );

  testWidgets('a revoked session returns to sign-in with the reason', (
    t,
  ) async {
    await boot(t, b, admin.email);
    await openUser(t, user);
    b.endSessions();
    await t.tap(key('action-suspend'));
    await t.pumpAndSettle();
    await pick(t, 'dialog-reason', 'Fraud');
    await t.tap(key('dialog-confirm'));
    await t.pumpAndSettle();
    expect(key('signin-email'), findsOneWidget);
    expect(noticeText(t), Messages.sessionEnded);
    expect(user.status, 'active');
  });

  testWidgets(
    'demoted while the console is open: the server refuses and access ends',
    (t) async {
      await boot(t, b, admin.email);
      await openUser(t, user);
      expect(key('action-suspend'), findsOneWidget);
      admin.role = 'user'; // a Super Admin demoted this admin elsewhere
      await t.tap(key('action-suspend'));
      await t.pumpAndSettle();
      await pick(t, 'dialog-reason', 'Abuse');
      await t.tap(key('dialog-confirm'));
      await t.pumpAndSettle();
      expect(user.status, 'active');
      expect(key('no-access'), findsOneWidget);
      expect(noticeText(t), Messages.accessRemoved);
    },
  );

  testWidgets(
    'target became staff: target_not_permitted reloads and explains',
    (t) async {
      await boot(t, b, admin.email);
      await openUser(t, user);
      user.role = 'admin'; // promoted elsewhere
      await t.tap(key('action-suspend'));
      await t.pumpAndSettle();
      await pick(t, 'dialog-reason', 'Abuse');
      await t.tap(key('dialog-confirm'));
      await t.pumpAndSettle();
      expect(noticeText(t), Messages.targetNotPermitted);
      expect(find.text('Your role cannot view this account.'), findsOneWidget);
    },
  );

  testWidgets(
    'pending deletion: banner, no actions, and a conflict explained',
    (t) async {
      final gone = b.add('leaving@example.test', status: 'pending_deletion');
      await boot(t, b, sa.email);
      await openUser(t, gone);
      expect(key('detail-pending-deletion'), findsOneWidget);
      expect(key('action-suspend'), findsNothing);
      expect(key('action-change-role'), findsNothing);
      // The owner accepts deletion while an operator has the account open.
      await openUser(t, user);
      user.status = 'pending_deletion';
      await t.tap(key('action-suspend'));
      await t.pumpAndSettle();
      await pick(t, 'dialog-reason', 'Abuse');
      await t.tap(key('dialog-confirm'));
      await t.pumpAndSettle();
      expect(noticeText(t), Messages.pendingDeletion);
      expect(key('detail-pending-deletion'), findsOneWidget);
    },
  );

  testWidgets('last_super_admin and stale revisions reload with guidance', (
    t,
  ) async {
    final second = b.add('root2@example.test', role: 'super_admin');
    await boot(t, b, sa.email);
    await openUser(t, sa);
    expect(find.text('Step down to User'), findsOneWidget);
    second.status =
        'suspended'; // the other Super Admin was suspended meanwhile
    await t.tap(key('action-change-role'));
    await t.pumpAndSettle();
    await pick(t, 'dialog-reason', 'Access review');
    await t.tap(key('dialog-confirm'));
    await t.pumpAndSettle();
    expect(noticeText(t), Messages.lastSuperAdmin);
    expect(sa.role, 'super_admin');
    expect(
      key('action-change-role'),
      findsNothing,
      reason: 'reloaded detail no longer offers it',
    );
    await openUser(t, user);
    user.lifecycleRevision = 9; // changed by another operator
    await t.tap(key('action-suspend'));
    await t.pumpAndSettle();
    await pick(t, 'dialog-reason', 'Abuse');
    await t.tap(key('dialog-confirm'));
    await t.pumpAndSettle();
    expect(noticeText(t), Messages.changed);
  });

  testWidgets('a Super Admin who steps down loses access immediately', (
    t,
  ) async {
    b.add('root2@example.test', role: 'super_admin');
    await boot(t, b, sa.email);
    await openUser(t, sa);
    await t.tap(key('action-change-role'));
    await t.pumpAndSettle();
    expect(find.textContaining('You lose admin access'), findsOneWidget);
    await pick(t, 'dialog-reason', 'Staffing change');
    await t.tap(key('dialog-confirm'));
    await t.pumpAndSettle();
    expect(sa.role, 'user');
    expect(key('no-access'), findsOneWidget);
    expect(noticeText(t), Messages.steppedDown);
  });

  testWidgets('an account deleted while open returns to the list', (t) async {
    await boot(t, b, admin.email);
    await openUser(t, user);
    b.accounts.remove(user.id);
    await t.tap(key('action-suspend'));
    await t.pumpAndSettle();
    await pick(t, 'dialog-reason', 'Abuse');
    await t.tap(key('dialog-confirm'));
    await t.pumpAndSettle();
    expect(noticeText(t), Messages.notFound);
    expect(key('user-row-${user.id}'), findsNothing);
  });

  testWidgets('narrow layout shows list, then detail with a back button', (
    t,
  ) async {
    await boot(t, b, admin.email, size: const Size(700, 1000));
    await openUser(t, user);
    expect(key('detail'), findsOneWidget);
    expect(key('search-field'), findsNothing);
    await t.tap(find.text('Back to list'));
    await t.pumpAndSettle();
    expect(key('search-field'), findsOneWidget);
  });
}
