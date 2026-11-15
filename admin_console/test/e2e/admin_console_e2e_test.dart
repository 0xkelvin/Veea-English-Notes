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
      expect(d.allowedActions, {
        'suspend',
        'view_sessions',
        'revoke_sessions',
        'manage_plan',
      });
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
        'manage_plan',
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

      // Audit history: the three mutations above, newest first, by this Admin.
      await c.loadAudit();
      expect(c.auditLoad, Load.loaded);
      expect(c.audit.map((e) => e.action), [
        'reinstate',
        'suspend',
        'sessions_revoke',
      ]);
      expect(c.audit.map((e) => e.reasonCode), [
        'appeal_upheld',
        'abuse',
        'security_review',
      ]);
      expect(c.audit.map((e) => e.ticketRef), [null, 'SUP-1042', null]);
      expect(
        c.audit.every(
          (e) => e.actorUserId == admin.id && e.outcome == 'success',
        ),
        isTrue,
      );
      expect(c.auditNextPageToken, isNull);

      await c.select(staff.id); // a stale link to a staff account
      expect(c.detailLoad, Load.failed);
      expect(c.detailError, 'Your role cannot view this account.');
      await c.loadAudit(); // the history follows the same visibility rule
      expect(c.auditLoad, Load.failed);
      expect(
        c.auditError,
        'Your role cannot view this account or its history any more.',
      );
      expect(c.phase, Phase.ready);
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
      // Paging through the history one entry at a time.
      c.auditPageSize = 1;
      await c.loadAudit();
      expect(c.audit, hasLength(1));
      expect(c.auditNextPageToken, isNotNull);
      await c.loadMoreAudit();
      expect(c.audit.map((e) => e.action), ['role_change', 'role_change']);
      expect(c.audit.map((e) => e.reasonCode), [
        'access_review',
        'staffing_change',
      ]);
      expect(c.audit.every((e) => e.actorUserId == root.id), isTrue);
      expect(c.auditNextPageToken, isNull);
      c.auditPageSize = 50;
      // A Super Admin can view its own history (TRD 06 self-view).
      await c.select(root.id);
      await c.loadAudit();
      expect(c.auditLoad, Load.loaded);
      expect(c.audit, isEmpty);

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

  test('history: permission loss and session end while viewing', () async {
    final root = await fixture(role: 'super_admin');
    final admin = await fixture(role: 'admin');
    final target = await fixture(sessions: 1);
    final ops = await signIn(admin);
    await ops.select(target.id);
    expect(
      await ops.revokeSessions(reason: 'owner_request', ticketRef: 'SUP-77'),
      isTrue,
    );
    await ops.loadAudit();
    expect(ops.audit.single.action, 'sessions_revoke');
    expect(ops.audit.single.ticketRef, 'SUP-77');

    final sa = await signIn(root);
    await sa.select(target.id);
    await sa.loadAudit();
    expect(
      sa.audit.single.actorUserId,
      admin.id,
      reason: 'a Super Admin sees the Admin as actor',
    );
    await sa.select(admin.id);
    expect(await sa.changeRole('user', 'access_review', null), isTrue);

    await ops.loadAudit(); // refused by the server after the demotion
    expect(ops.phase, Phase.noAccess);
    expect(ops.notice!.text, Messages.accessRemoved);

    // A second Admin whose sessions are revoked while viewing the history.
    final admin2 = await fixture(role: 'admin');
    final ops2 = await signIn(admin2);
    await ops2.select(target.id);
    await ops2.loadAudit();
    expect(ops2.auditLoad, Load.loaded);
    await sa.select(admin2.id);
    expect(await sa.revokeSessions(reason: 'security_review'), isTrue);
    await ops2.loadAudit();
    expect(ops2.phase, Phase.signedOut);
    expect(ops2.notice!.text, Messages.sessionEnded);
  }, skip: skip);

  test('a non-staff account cannot use the console', () async {
    final user = await fixture();
    final c = await signIn(user);
    expect(c.phase, Phase.noAccess);
    expect(c.notice!.text, Messages.noAccess);
  }, skip: skip);
  test(
    'plans: grant and revoke refresh detail and allowlisted history without changing sessions',
    () async {
      final actor = await fixture(role: 'admin');
      final target = await fixture(sessions: 1);
      final ops = await signIn(actor);
      await ops.select(target.id);
      expect(ops.detail!.plan, 'free');
      expect(ops.detail!.can('manage_plan'), isTrue);
      final end = DateTime.now().toUtc().add(const Duration(days: 30));
      expect(
        await ops.changePlan('premium', end, 'beta_access', 'BETA-1042'),
        isTrue,
      );
      expect(ops.detail!.plan, 'premium');
      expect(ops.detail!.planExpiresAt, end);
      expect(ops.detail!.entitlementRevision, 1);
      expect(ops.audit.single.action, 'premium_grant');
      expect(ops.audit.single.reasonCode, 'beta_access');
      expect(ops.audit.single.ticketRef, 'BETA-1042');
      expect(ops.audit.single.actorUserId, actor.id);
      // Same end state is a safe no-op and does not duplicate history.
      expect(
        await ops.changePlan('premium', end, 'beta_access', 'BETA-1042'),
        isTrue,
      );
      expect(ops.detail!.entitlementRevision, 1);
      expect(ops.audit.length, 1);
      expect(
        await ops.changePlan('free', null, 'ended_early', 'SUP-1043'),
        isTrue,
      );
      expect(ops.detail!.plan, 'free');
      expect(ops.detail!.planExpiresAt, isNull);
      expect(ops.detail!.entitlementRevision, 2);
      expect(ops.audit.map((e) => e.action), [
        'premium_revoke',
        'premium_grant',
      ]);
      expect(ops.audit.map((e) => e.ticketRef), ['SUP-1043', 'BETA-1042']);
      expect((await state(target.id))['live_sessions'], 1);
    },
    skip: skip,
  );

  test(
    'plans: a second console makes a revision stale; retry requires newly confirmed detail',
    () async {
      final a = await fixture(role: 'admin'), b = await fixture(role: 'admin');
      final target = await fixture();
      final first = await signIn(a), second = await signIn(b);
      await first.select(target.id);
      await second.select(target.id);
      final oldRevision = first.detail!.entitlementRevision;
      final end = DateTime.now().toUtc().add(const Duration(days: 30));
      final otherEnd = end.add(const Duration(days: 1));
      expect(
        await second.changePlan('premium', otherEnd, 'partner', 'PARTNER-1'),
        isTrue,
      );
      expect(
        await first.changePlan('premium', end, 'promotion', 'PROMO-2'),
        isFalse,
      );
      expect(first.notice!.text, Messages.planChanged);
      expect(first.detail!.planExpiresAt, otherEnd);
      expect(first.detail!.entitlementRevision, 1);
      expect(first.audit.length, 1);
      expect(first.audit.single.actorUserId, b.id);
      expect(
        (await second.api.user(target.id)).entitlementRevision,
        1,
        reason: 'no automatic replay',
      );
      expect(
        await first.changePlan(
          'premium',
          end,
          'promotion',
          'PROMO-2',
          targetId: target.id,
          expectedEntitlementRevision: oldRevision,
        ),
        isFalse,
      );
      expect((await second.api.user(target.id)).entitlementRevision, 1);
      // The UI's new dialog supplies this newly reviewed revision.
      expect(
        await first.changePlan(
          'premium',
          end,
          'promotion',
          'PROMO-2',
          targetId: target.id,
          expectedEntitlementRevision: first.detail!.entitlementRevision,
        ),
        isTrue,
      );
      expect(first.detail!.entitlementRevision, 2);
      expect(first.detail!.planExpiresAt, end);
      expect(first.audit.length, 2);
      expect(first.audit.first.actorUserId, a.id);
    },
    skip: skip,
  );

  test(
    'plans: actor loses staff permission after viewing manage_plan',
    () async {
      final root = await fixture(role: 'super_admin'),
          actor = await fixture(role: 'admin');
      final target = await fixture();
      final ops = await signIn(actor), sa = await signIn(root);
      await ops.select(target.id);
      expect(ops.detail!.can('manage_plan'), isTrue);
      await sa.select(actor.id);
      expect(await sa.changeRole('user', 'access_review', 'SEC-1'), isTrue);
      expect(
        await ops.changePlan(
          'premium',
          DateTime.now().toUtc().add(const Duration(days: 10)),
          'support_courtesy',
          'SUP-1',
        ),
        isFalse,
      );
      expect(ops.phase, Phase.noAccess);
      expect(ops.notice!.text, Messages.accessRemoved);
      final unchanged = await sa.api.user(target.id);
      expect(unchanged.plan, 'free');
      expect(unchanged.entitlementRevision, 0);
      expect((await sa.api.audit(target.id)).items, isEmpty);
    },
    skip: skip,
  );

  test(
    'plans: target promotion removes an Admin’s permission before submit',
    () async {
      final root = await fixture(role: 'super_admin'),
          actor = await fixture(role: 'admin');
      final target = await fixture();
      final ops = await signIn(actor), sa = await signIn(root);
      await ops.select(target.id);
      expect(ops.detail!.can('manage_plan'), isTrue);
      await sa.select(target.id);
      expect(
        await sa.changeRole('admin', 'staffing_change', 'STAFF-1'),
        isTrue,
      );
      expect(
        await ops.changePlan(
          'premium',
          DateTime.now().toUtc().add(const Duration(days: 10)),
          'support_courtesy',
          'SUP-1',
        ),
        isFalse,
      );
      expect(ops.phase, Phase.ready);
      expect(ops.detailLoad, Load.failed);
      expect(ops.detailError, 'Your role cannot view this account.');
      final unchanged = await sa.api.user(target.id);
      expect(unchanged.plan, 'free');
      expect(unchanged.entitlementRevision, 0);
      expect(
        (await sa.api.audit(
          target.id,
        )).items.every((e) => e.action != 'premium_grant'),
        isTrue,
      );
    },
    skip: skip,
  );
}
