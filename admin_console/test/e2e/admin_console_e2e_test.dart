import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:veea_admin_console/src/admin_api.dart';
import 'package:veea_admin_console/src/console_controller.dart';
import 'package:veea_admin_console/src/messages.dart';
import 'package:veea_admin_console/src/models.dart';
import 'package:veea_admin_console/src/transport.dart';

/// The console against the real Go router, OpenAPI checker and local
/// PostgreSQL (`backend/scripts/test-flutter-admin.sh`). The control surface
/// only creates synthetic accounts and reads their state; every admin action
/// below goes through the real /v1/admin routes, and the server decides.
final api = Platform.environment['VEEA_ADMIN_E2E_API'];
final control = Platform.environment['VEEA_ADMIN_E2E_CONTROL'];

class Account {
  Account(Map<String, Object?> j)
    : id = j['id']! as String,
      email = j['email']! as String,
      password = j['password']! as String;
  final String id, email, password;
}

Future<Account> fixture({
  String role = 'user',
  String status = 'active',
  int sessions = 0,
}) async {
  final r = await http.post(
    Uri.parse('$control/fixture-account'),
    body: jsonEncode({'role': role, 'status': status, 'sessions': sessions}),
  );
  expect(r.statusCode, 200);
  return Account((jsonDecode(r.body) as Map).cast<String, Object?>());
}

Future<Map<String, Object?>> state(String id) async =>
    (jsonDecode(
              (await http.get(Uri.parse('$control/account-state?id=$id'))).body,
            )
            as Map)
        .cast<String, Object?>();

Future<ConsoleController> signIn(Account a) async {
  final c = ConsoleController(AdminApi(AdminTransport(baseUrl: api!)));
  await c.signInWithPassword(a.email, a.password);
  return c;
}

void main() {
  HttpOverrides.global = null; // real loopback sockets
  final skip = api == null || control == null
      ? 'run through backend/scripts/test-flutter-admin.sh'
      : null;

  test(
    'Admin: search, view, revoke a session, suspend and reinstate a User',
    () async {
      final admin = await fixture(role: 'admin');
      final target = await fixture(sessions: 2);
      final staff = await fixture(role: 'admin');
      final c = await signIn(admin);
      expect(c.phase, Phase.ready);
      expect(c.me!.role, 'admin');
      expect(c.listLoad, Load.loaded);
      expect(
        c.users.every((u) => u.role == 'user'),
        isTrue,
        reason: 'Admins list User accounts only',
      );

      await c.search(SearchQuery(text: target.email, mode: MatchMode.exact));
      expect(c.users.map((u) => u.id), [target.id]);
      await c.search(SearchQuery(text: staff.email, mode: MatchMode.exact));
      expect(c.listLoad, Load.loaded);
      expect(
        c.users,
        isEmpty,
        reason: 'staff accounts are invisible to Admins',
      );

      await c.select(target.id);
      final d = c.detail!;
      expect(d.allowedActions, {'suspend', 'view_sessions', 'revoke_sessions'});
      expect(d.assignableRoles, isEmpty);
      expect(c.sessions, hasLength(2));

      expect(
        await c.revokeSessions(
          sessionId: c.sessions.first.id,
          reason: 'security_review',
        ),
        isTrue,
      );
      expect(c.notice!.text, 'Revoked 1 session.');
      expect(c.sessions, hasLength(1));
      expect((await state(target.id))['live_sessions'], 1);

      expect(await c.suspend('abuse', 'SUP-1042'), isTrue);
      expect(c.detail!.status, 'suspended');
      expect(c.detail!.suspension!.ticketRef, 'SUP-1042');
      expect(c.detail!.allowedActions, {
        'reinstate',
        'view_sessions',
        'revoke_sessions',
      });
      expect(await state(target.id), containsPair('live_sessions', 0));
      expect(
        c.users,
        isEmpty,
        reason: 'list row patched too (still filtered to the staff email)',
      );

      expect(await c.reinstate('appeal_upheld', null), isTrue);
      expect(c.detail!.status, 'active');
      expect((await state(target.id))['status'], 'active');

      await c.select(staff.id); // a stale link to a staff account
      expect(c.detailLoad, Load.failed);
      expect(c.detailError, 'Your role cannot view this account.');
      await c.signOut();
      expect(c.phase, Phase.signedOut);
    },
    skip: skip,
  );

  test(
    'Super Admin: every role, promotion, pending deletion and last Super Admin',
    () async {
      final root = await fixture(role: 'super_admin');
      final other = await fixture(role: 'super_admin');
      final target = await fixture(sessions: 1);
      final leaving = await fixture(status: 'pending_deletion');
      final c = await signIn(root);
      expect(c.me!.isSuperAdmin, isTrue);
      await c.search(const SearchQuery(role: 'super_admin'));
      expect(c.users.map((u) => u.id), containsAll([root.id, other.id]));

      await c.select(target.id);
      expect(c.detail!.assignableRoles, ['admin', 'super_admin']);
      expect(await c.changeRole('admin', 'staffing_change', null), isTrue);
      expect(c.detail!.role, 'admin');
      expect(
        await state(target.id),
        allOf(containsPair('role', 'admin'), containsPair('live_sessions', 0)),
        reason: 'promotion revokes every target session',
      );
      expect(await c.changeRole('user', 'access_review', null), isTrue);
      expect((await state(target.id))['role'], 'user');

      await c.select(leaving.id);
      expect(c.detail!.pendingDeletion, isTrue);
      expect(c.detail!.allowedActions, {'view_sessions', 'revoke_sessions'});
      // A stale screen that still offers Suspend: the server refuses and the console explains.
      expect(await c.suspend('abuse', null), isFalse);
      expect(c.notice!.text, Messages.pendingDeletion);
      expect(c.detail!.pendingDeletion, isTrue, reason: 'detail reloaded');

      await c.select(other.id);
      expect(await c.suspend('account_compromise', null), isTrue);
      await c.select(root.id);
      expect(
        c.detail!.assignableRoles,
        isEmpty,
        reason: 'the last active Super Admin cannot step down',
      );
      expect(await c.changeRole('user', 'access_review', null), isFalse);
      expect(c.notice!.text, Messages.lastSuperAdmin);
      expect((await state(root.id))['role'], 'super_admin');
      expect(c.phase, Phase.ready);

      await c.select(other.id);
      expect(await c.reinstate('issue_resolved', null), isTrue);
      await c.select(root.id);
      expect(c.detail!.assignableRoles, ['user']);
      expect(await c.changeRole('user', 'staffing_change', null), isTrue);
      expect(
        c.phase,
        Phase.noAccess,
        reason: 'stepping down ends admin access at once',
      );
      expect(c.notice!.text, Messages.steppedDown);
    },
    skip: skip,
  );

  test(
    'an Admin demoted while the console is open is refused by the server',
    () async {
      final root = await fixture(role: 'super_admin');
      final admin = await fixture(role: 'admin');
      final target = await fixture(sessions: 1);
      final ops = await signIn(admin);
      await ops.select(target.id);
      expect(
        ops.detail!.can('suspend'),
        isTrue,
        reason: 'the screen still offers Suspend',
      );

      final sa = await signIn(root);
      await sa.select(admin.id);
      expect(await sa.changeRole('user', 'access_review', null), isTrue);

      expect(await ops.suspend('abuse', null), isFalse);
      expect(ops.phase, Phase.noAccess);
      expect(ops.notice!.text, Messages.accessRemoved);
      expect(
        await state(target.id),
        allOf(
          containsPair('status', 'active'),
          containsPair('live_sessions', 1),
        ),
        reason: 'nothing changed',
      );
      expect(
        (await state(admin.id))['live_sessions'],
        greaterThan(0),
        reason: 'demotion keeps sessions',
      );
    },
    skip: skip,
  );

  test(
    'session expiry: access tokens refresh silently; a revoked session returns to sign-in',
    () async {
      final root = await fixture(role: 'super_admin');
      final admin = await fixture(role: 'admin');
      final ops = await signIn(admin);
      final r = await http.post(
        Uri.parse('$control/expire-access'),
        body: jsonEncode({'session_id': ops.api.transport.sessionId}),
      );
      expect(r.statusCode, 200);
      await ops.search(const SearchQuery());
      expect(
        ops.listLoad,
        Load.loaded,
        reason: 'an expired access token is refreshed once',
      );
      expect(ops.phase, Phase.ready);

      final sa = await signIn(root);
      await sa.select(admin.id);
      expect(await sa.revokeSessions(reason: 'security_review'), isTrue);

      await ops.search(const SearchQuery());
      expect(ops.phase, Phase.signedOut);
      expect(ops.notice!.text, Messages.sessionEnded);
      expect(ops.api.transport.signedIn, isFalse);
    },
    skip: skip,
  );

  test('a non-staff account cannot use the console', () async {
    final user = await fixture();
    final c = await signIn(user);
    expect(c.phase, Phase.noAccess);
    expect(c.notice!.text, Messages.noAccess);
  }, skip: skip);
}
