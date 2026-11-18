import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:veea_admin_console/src/messages.dart';

import 'console_widget_test.dart' show boot, openUser, pick, key, noticeText;
import 'support/fake_backend.dart';

void main() {
  late FakeBackend b;
  late FakeAccount admin, user, root;
  final expiry = DateTime.now().toUtc().add(const Duration(days: 30));
  int writes() => b.requests.where((r) => r.endsWith('/entitlement')).length;
  Future<void> openPlan(WidgetTester t, {bool grant = true}) async {
    await t.ensureVisible(
      key(grant ? 'action-grant-premium' : 'action-revoke-premium'),
    );
    await t.tap(key(grant ? 'action-grant-premium' : 'action-revoke-premium'));
    await t.pumpAndSettle();
  }

  Future<void> complete(
    WidgetTester t, {
    bool grant = true,
    String? end,
  }) async {
    await pick(
      t,
      'dialog-reason',
      grant ? 'Support courtesy' : 'Owner request',
    );
    await t.enterText(key('dialog-ticket'), 'SUP-1050');
    if (grant) {
      await t.enterText(key('dialog-expiry'), end ?? expiry.toIso8601String());
    }
    await t.pump();
    await t.tap(key('dialog-confirm'));
    await t.pumpAndSettle();
  }

  setUp(() {
    b = FakeBackend();
    root = b.add('root@example.test', role: 'super_admin');
    admin = b.add('ops@example.test', role: 'admin');
    user = b.add('learner@example.test');
  });
  testWidgets(
    'effective plan/expiry use server detail; actions require manage_plan',
    (t) async {
      user
        ..plan = 'premium'
        ..planExpiresAt = expiry;
      user.withheldActions.add('manage_plan');
      final c = await boot(t, b, admin.email);
      await openUser(t, user);
      expect(find.text('Effective plan'), findsOneWidget);
      expect(find.text('Premium'), findsOneWidget);
      expect(find.text(expiry.toIso8601String()), findsOneWidget);
      expect(key('action-grant-premium'), findsNothing);
      expect(key('action-revoke-premium'), findsNothing);
      user.withheldActions.clear();
      await c.reloadDetail();
      await t.pumpAndSettle();
      expect(key('action-grant-premium'), findsOneWidget);
      expect(key('action-revoke-premium'), findsOneWidget);
      await c.select(root.id);
      await t.pumpAndSettle();
      expect(key('action-grant-premium'), findsNothing);
    },
  );
  testWidgets('self and pending deletion never offer plan management', (
    t,
  ) async {
    await boot(t, b, root.email);
    await openUser(t, root);
    expect(key('action-grant-premium'), findsNothing);
    user.status = 'pending_deletion';
    await openUser(t, user);
    expect(key('action-grant-premium'), findsNothing);
    expect(key('action-revoke-premium'), findsNothing);
  });
  testWidgets(
    'grant requires reason, valid mandatory ticket and explicit valid expiry; cancel sends nothing',
    (t) async {
      await boot(t, b, admin.email);
      await openUser(t, user);
      await openPlan(t);
      FilledButton confirm() => t.widget<FilledButton>(key('dialog-confirm'));
      expect(confirm().onPressed, isNull);
      await pick(t, 'dialog-reason', 'Support courtesy');
      await t.enterText(key('dialog-expiry'), expiry.toIso8601String());
      await t.pump();
      expect(confirm().onPressed, isNull);
      for (final invalid in ['', 'bad ticket', 'SUP-vat_secret']) {
        await t.enterText(key('dialog-ticket'), invalid);
        await t.pump();
        expect(confirm().onPressed, isNull);
      }
      await t.enterText(key('dialog-ticket'), 'SUP-1050');
      for (final invalid in [
        '',
        '2027-02-30T10:00:00Z',
        '2027-05-10T10:00:00',
      ]) {
        await t.enterText(key('dialog-expiry'), invalid);
        await t.pump();
        expect(confirm().onPressed, isNull);
      }
      await t.enterText(key('dialog-expiry'), expiry.toIso8601String());
      await t.pump();
      expect(confirm().onPressed, isNotNull);
      await t.tap(key('dialog-cancel'));
      await t.pumpAndSettle();
      expect(writes(), 0);
    },
  );
  testWidgets(
    'grant sends normalized UTC with revision and refreshes detail plus initially unloaded audit',
    (t) async {
      user.entitlementRevision = 7;
      final c = await boot(t, b, admin.email);
      await openUser(t, user);
      await openPlan(t);
      expect(
        find.textContaining('current limits stay the same'),
        findsOneWidget,
      );
      const end = '2027-01-15T10:30:00+07:00';
      await complete(t, end: end);
      expect(b.planRequests.single, {
        'plan': 'premium',
        'ends_at': '2027-01-15T03:30:00.000Z',
        'reason_code': 'support_courtesy',
        'ticket_ref': 'SUP-1050',
        'expected_entitlement_revision': 7,
      });
      expect(c.detail!.plan, 'premium');
      expect(c.detail!.entitlementRevision, 8);
      expect(c.audit.single.action, 'premium_grant');
      expect(c.audit.single.ticketRef, 'SUP-1050');
      final put = b.requests.indexWhere((r) => r.endsWith('/entitlement'));
      expect(
        b.requests.skip(put + 1),
        contains('GET /v1/admin/users/${user.id}'),
      );
      expect(
        b.requests.skip(put + 1),
        contains('GET /v1/admin/users/${user.id}/audit'),
      );
      await t.tap(key('tab-audit'));
      await t.pumpAndSettle();
      expect(find.text('Premium granted'), findsOneWidget);
    },
  );
  testWidgets(
    'revoke requires a ticket, sends null expiry and displays Free with refreshed audit',
    (t) async {
      user
        ..plan = 'premium'
        ..planExpiresAt = expiry
        ..entitlementRevision = 3;
      final c = await boot(t, b, admin.email);
      await openUser(t, user);
      await openPlan(t, grant: false);
      expect(key('dialog-expiry'), findsNothing);
      await pick(t, 'dialog-reason', 'Owner request');
      expect(t.widget<FilledButton>(key('dialog-confirm')).onPressed, isNull);
      await t.enterText(key('dialog-ticket'), 'SUP-1050');
      await t.pump();
      await t.tap(key('dialog-confirm'));
      await t.pumpAndSettle();
      expect(b.planRequests.single, {
        'plan': 'free',
        'ends_at': null,
        'reason_code': 'owner_request',
        'ticket_ref': 'SUP-1050',
        'expected_entitlement_revision': 3,
      });
      expect(c.detail!.plan, 'free');
      expect(c.detail!.planExpiresAt, isNull);
      expect(key('action-revoke-premium'), findsNothing);
      expect(c.audit.single.action, 'premium_revoke');
      expect(find.text('No active Premium grant'), findsOneWidget);
    },
  );
  testWidgets(
    '409 reloads latest plan and requires a fresh confirmation without automatic replay',
    (t) async {
      final c = await boot(t, b, admin.email);
      await openUser(t, user);
      await openPlan(t);
      user
        ..plan = 'premium'
        ..planExpiresAt = expiry.add(const Duration(days: 1))
        ..entitlementRevision = 1;
      await complete(t);
      expect(noticeText(t), Messages.planChanged);
      expect(writes(), 1);
      expect(c.detail!.entitlementRevision, 1);
      expect(c.detail!.planExpiresAt, user.planExpiresAt);
      await t.pumpAndSettle();
      expect(writes(), 1);
      expect(key('dialog-confirm'), findsNothing);
      await openPlan(t);
      expect(t.widget<FilledButton>(key('dialog-confirm')).onPressed, isNull);
      await complete(t);
      expect(writes(), 2);
      expect(b.planRequests.last['expected_entitlement_revision'], 1);
      expect(c.detail!.entitlementRevision, 2);
      expect(c.audit.single.action, 'premium_grant');
    },
  );
  testWidgets(
    'reload during confirmation cannot silently replace the confirmed revision',
    (t) async {
      final c = await boot(t, b, admin.email);
      await openUser(t, user);
      await openPlan(t);
      user.entitlementRevision = 1;
      await c.reloadDetail();
      await t.pumpAndSettle();
      await complete(t);
      expect(writes(), 0);
      expect(noticeText(t), Messages.planChanged);
    },
  );
  testWidgets(
    'changing the selected account while confirming never changes another target',
    (t) async {
      final other = b.add('other@example.test');
      final c = await boot(t, b, admin.email);
      await openUser(t, user);
      await openPlan(t);
      await c.select(other.id);
      await t.pumpAndSettle();
      await complete(t);
      expect(writes(), 0);
      expect(c.detail!.id, other.id);
    },
  );
  testWidgets(
    'permission loss while the dialog is open is enforced by the backend',
    (t) async {
      final c = await boot(t, b, admin.email);
      await openUser(t, user);
      await openPlan(t);
      admin.role = 'user';
      await complete(t);
      expect(c.phase.name, 'noAccess');
      expect(noticeText(t), Messages.accessRemoved);
      expect(user.plan, 'free');
      expect(user.audit, isEmpty);
      expect(key('action-grant-premium'), findsNothing);
    },
  );
  testWidgets(
    'target permission loss reloads capability controls and never changes the plan',
    (t) async {
      final c = await boot(t, b, admin.email);
      await openUser(t, user);
      await openPlan(t);
      user.withheldActions.add('manage_plan');
      await complete(t);
      expect(noticeText(t), Messages.targetNotPermitted);
      expect(c.detail!.can('manage_plan'), isFalse);
      expect(key('action-grant-premium'), findsNothing);
      expect(user.audit, isEmpty);
    },
  );
  testWidgets(
    'backend expiry range refusal is actionable and never resubmitted automatically',
    (t) async {
      await boot(t, b, admin.email);
      await openUser(t, user);
      await openPlan(t);
      b.failNext(
        'PUT /v1/admin/users/${user.id}/entitlement',
        400,
        'invalid_expiry',
      );
      await complete(t, end: '2020-01-01T00:00:00Z');
      expect(noticeText(t), Messages.invalidExpiry);
      expect(writes(), 1);
      expect(user.audit, isEmpty);
    },
  );
  testWidgets('Apple lifetime expiry and manual-only revocation are explicit', (
    t,
  ) async {
    user
      ..plan = 'premium'
      ..planExpiresAt = null;
    await boot(t, b, admin.email);
    await openUser(t, user);
    expect(find.text('No expiry · Apple lifetime purchase'), findsOneWidget);
    expect(find.text('Clear manual grant'), findsOneWidget);
    await openPlan(t, grant: false);
    expect(
      find.textContaining('Apple lifetime purchase remains active'),
      findsOneWidget,
    );
  });
}
