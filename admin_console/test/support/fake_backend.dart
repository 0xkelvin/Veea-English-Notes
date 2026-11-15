import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:veea_admin_console/src/models.dart';

/// An in-memory stand-in for the TRD 06 routes, for widget tests only. It
/// mirrors the approved matrix and the server-computed `allowed_actions`, so
/// the console is exercised against the same decisions. The real Go API is
/// covered by test/e2e/admin_console_e2e_test.dart.
class FakeAccount {
  FakeAccount(
    this.id,
    this.email, {
    this.role = 'user',
    this.status = 'active',
    this.password = 'correct horse battery staple',
  });
  final String id, email, password;
  String role, status;
  String plan = 'free';
  DateTime? planExpiresAt;
  int entitlementRevision = 0;
  final withheldActions = <String>{};
  int lifecycleRevision = 0, roleRevision = 0;
  String? resumeStatus, suspensionReason, ticketRef;
  final sessions = <String>['s-$_n-a', 's-${_n++}-b'];
  final audit =
      <Map<String, Object?>>[]; // newest first, the API's allowlisted fields
  void record(
    String action,
    String actor,
    Map<String, Object?> body,
  ) => audit.insert(0, {
    'occurred_at':
        '2026-11-15T10:${(audit.length % 60).toString().padLeft(2, '0')}:00Z',
    'action': action,
    'outcome': 'success',
    'actor_user_id': actor,
    'reason_code': body['reason_code'],
    'ticket_ref': body['ticket_ref'],
  });
  static int _n = 0;
}

class _Failure {
  _Failure(this.status, this.code, this.accountStatus);
  final int status;
  final String code;
  final String? accountStatus;
}

class FakeBackend {
  final accounts = <String, FakeAccount>{};
  final _access = <String, String>{}, _refresh = <String, String>{};
  final _failures = <String, _Failure>{};
  final requests = <String>[];
  final planRequests = <Map<String, Object?>>[];
  Completer<void>?
  gate; // when set, admin requests wait for it (loading states)
  int _tokens = 0;

  FakeAccount add(
    String email, {
    String role = 'user',
    String status = 'active',
  }) {
    final a = FakeAccount(
      '00000000-0000-7000-8000-${(accounts.length + 1).toString().padLeft(12, '0')}',
      email,
      role: role,
      status: status,
    );
    if (status == 'suspended') {
      a.resumeStatus = 'active';
      a.suspensionReason = 'abuse';
    }
    accounts[a.id] = a;
    return a;
  }

  /// Fails the next request whose "METHOD path" starts with [prefix].
  void failNext(
    String prefix,
    int status,
    String code, {
    String? accountStatus,
  }) => _failures[prefix] = _Failure(status, code, accountStatus);

  /// Access tokens stop working; refresh still works.
  void expireAccess() => _access.clear();

  /// Every token stops working (session revoked server-side).
  void endSessions() {
    _access.clear();
    _refresh.clear();
  }

  http.Client get client => MockClient(_handle);

  String _token(String prefix) =>
      '${prefix}_${(++_tokens).toString().padLeft(43, 'x')}';

  Map<String, Object?> _issue(FakeAccount a) {
    final access = _token('vat'), refresh = _token('vrt');
    _access[access] = a.id;
    _refresh[refresh] = a.id;
    return {
      'session_id': '00000000-0000-7000-8000-999999999999',
      'access_token': access,
      'access_expires_at': '2030-01-01T00:00:00Z',
      'refresh_token': refresh,
      'refresh_expires_at': '2030-01-01T00:00:00Z',
      'user': {'id': a.id, 'email': a.email},
    };
  }

  http.Response _json(int status, Object body) => http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json'},
  );
  http.Response _problem(int status, String code, {String? accountStatus}) =>
      _json(status, {
        'type': 'about:blank',
        'title': 'x',
        'status': status,
        'code': code,
        'request_id': 'req-fake-0001',
        'account_status': ?accountStatus,
      });

  static bool _staff(String role) => role == 'admin' || role == 'super_admin';
  static bool _permits(FakeAccount actor, FakeAccount t, String act) {
    final self = actor.id == t.id;
    if (actor.role == 'super_admin') {
      return self ? (act == 'view' || act == 'role') : true;
    }
    if (actor.role == 'admin') {
      return !self && t.role == 'user' && act != 'role';
    }
    return false;
  }

  int get _activeSuperAdmins => accounts.values
      .where((a) => a.role == 'super_admin' && a.status == 'active')
      .length;

  List<String> _assignable(FakeAccount actor, FakeAccount t) {
    if (actor.role != 'super_admin' || t.status == 'pending_deletion') {
      return [];
    }
    final rank = {'user': 1, 'admin': 2, 'super_admin': 3};
    final out = <String>[];
    final roles = actor.id == t.id
        ? (t.role == 'super_admin' ? ['user'] : <String>[])
        : ['user', 'admin', 'super_admin'].where((r) => r != t.role);
    for (final r in roles) {
      if (rank[r]! > rank[t.role]! && t.status != 'active') continue;
      if (t.role == 'super_admin' &&
          t.status == 'active' &&
          _activeSuperAdmins == 1) {
        continue;
      }
      out.add(r);
    }
    return out;
  }

  Map<String, Object?> _detail(FakeAccount actor, FakeAccount t) {
    final allowed = <String>[];
    final assignable = _assignable(actor, t);
    if (_permits(actor, t, 'suspend') &&
        (t.status == 'active' || t.status == 'deactivated')) {
      allowed.add('suspend');
    }
    if (_permits(actor, t, 'reinstate') && t.status == 'suspended') {
      allowed.add('reinstate');
    }
    if (assignable.isNotEmpty) allowed.add('change_role');
    if (_permits(actor, t, 'sessions')) {
      allowed.addAll(['view_sessions', 'revoke_sessions']);
    }
    if (_permits(actor, t, 'plan') && t.status != 'pending_deletion') {
      allowed.add('manage_plan');
    }
    return {
      'id': t.id,
      'email': t.email,
      'email_verified_at': '2026-11-01T00:00:00Z',
      'has_password': true,
      'password_changed_at': null,
      'display_name': null,
      'preferred_language': 'en',
      'time_zone': 'UTC',
      'created_at': '2026-11-01T00:00:00Z',
      'status': t.status,
      'lifecycle_revision': t.lifecycleRevision,
      'state_changed_at': null,
      'suspension': t.status == 'suspended'
          ? {
              'reason_code': t.suspensionReason,
              'ticket_ref': t.ticketRef,
              'suspended_at': '2026-11-02T00:00:00Z',
              'suspended_by_user_id': null,
              'resume_status': t.resumeStatus,
            }
          : null,
      'pending_deletion': t.status == 'pending_deletion'
          ? {'accepted_at': '2026-11-03T00:00:00Z'}
          : null,
      'role': t.role,
      'role_revision': t.roleRevision,
      'plan': t.plan,
      'plan_expires_at': t.planExpiresAt?.toUtc().toIso8601String(),
      'entitlement_revision': t.entitlementRevision,
      'role_changed_at': null,
      'sessions': {
        'live_count': t.status == 'active' ? t.sessions.length : 0,
        'last_seen_at': null,
      },
      'allowed_actions': allowed
          .where((a) => !t.withheldActions.contains(a))
          .toList(),
      'assignable_roles': assignable,
    };
  }

  Future<http.Response> _handle(http.Request r) async {
    final key = '${r.method} ${r.url.path}';
    requests.add(key);
    for (final prefix in _failures.keys.toList()) {
      if (key.startsWith(prefix)) {
        final f = _failures.remove(prefix)!;
        return _problem(f.status, f.code, accountStatus: f.accountStatus);
      }
    }
    final body = r.body.isEmpty
        ? const <String, Object?>{}
        : (jsonDecode(r.body) as Map).cast<String, Object?>();
    switch (key) {
      case 'POST /v1/auth/password/login':
        final a = accounts.values
            .where((a) => a.email == body['email'])
            .firstOrNull;
        if (a == null || a.password != body['password']) {
          return _problem(401, 'invalid_credentials');
        }
        return _json(200, _issue(a));
      case 'POST /v1/auth/otp/start':
        return _json(202, {
          'challenge_token': 'vct_${'c' * 43}',
          'expires_at': '2030-01-01T00:00:00Z',
          'resend_after': '2030-01-01T00:00:00Z',
        });
      case 'POST /v1/auth/otp/verify':
        if (body['code'] != '123456') return _problem(400, 'invalid_code');
        return _json(200, _issue(accounts.values.first));
      case 'POST /v1/auth/token/refresh':
        final id = _refresh.remove(body['refresh_token']);
        if (id == null) return _problem(401, 'unauthorized');
        return _json(200, _issue(accounts[id]!));
      case 'POST /v1/auth/logout':
        return http.Response('', 204);
    }
    final bearer = (r.headers['authorization'] ?? '').replaceFirst(
      'Bearer ',
      '',
    );
    final actor = accounts[_access[bearer]];
    if (actor == null || actor.status != 'active') {
      return _problem(401, 'unauthorized');
    }
    if (key == 'GET /v1/me') {
      return _json(200, {
        'id': actor.id,
        'email': actor.email,
        'role': actor.role,
        'status': actor.status,
      });
    }
    if (gate != null) await gate!.future;
    if (!_staff(actor.role)) return _problem(403, 'forbidden');
    final segments = r.url.pathSegments; // v1 admin users [id] [sub]
    if (segments.length < 3 || segments[1] != 'admin') {
      return _problem(404, 'not_found');
    }
    if (segments.length == 3) {
      final q = r.url.queryParameters;
      if (actor.role == 'admin' && q['role'] != null && q['role'] != 'user') {
        return _problem(403, 'target_not_permitted');
      }
      final items = accounts.values
          .where((a) {
            if (actor.role == 'admin' && a.role != 'user') return false;
            if (q['email_prefix'] != null &&
                !a.email.startsWith(q['email_prefix']!)) {
              return false;
            }
            if (q['email'] != null && a.email != q['email']) return false;
            if (q['status'] != null && a.status != q['status']) return false;
            if (q['role'] != null && a.role != q['role']) return false;
            return true;
          })
          .map(
            (a) => {
              'id': a.id,
              'email': a.email,
              'status': a.status,
              'role': a.role,
              'created_at': '2026-11-01T00:00:00Z',
              'state_changed_at': null,
            },
          );
      return _json(200, {'items': items.toList(), 'next_page_token': null});
    }
    final t = accounts[segments[3]];
    if (t == null) return _problem(404, 'not_found');
    final sub = segments.length > 4 ? segments[4] : '';
    switch ('${r.method} $sub') {
      case 'GET ':
        if (!_permits(actor, t, 'view')) {
          return _problem(403, 'target_not_permitted');
        }
        return _json(200, _detail(actor, t));
      case 'GET audit':
        if (!_permits(actor, t, 'view')) {
          return _problem(403, 'target_not_permitted');
        }
        final limit = int.parse(r.url.queryParameters['limit'] ?? '50');
        final from = int.parse(
          (r.url.queryParameters['page_token'] ?? 'h1.0').substring(3),
        );
        final page = t.audit.skip(from).take(limit).toList();
        final next = from + limit < t.audit.length
            ? 'h1.${from + limit}'
            : null;
        return _json(200, {'items': page, 'next_page_token': next});
      case 'GET sessions':
        if (!_permits(actor, t, 'sessions')) {
          return _problem(403, 'target_not_permitted');
        }
        return _json(200, {
          'sessions': [
            for (final s in t.status == 'active' ? t.sessions : <String>[])
              {
                'id':
                    '00000000-0000-7000-8000-${s.hashCode.toRadixString(16).padLeft(12, '0').substring(0, 12)}',
                'device_name': 'Phone $s',
                'platform': 'ios',
                'created_at': '2026-11-01T00:00:00Z',
                'last_seen_at': '2026-11-01T00:00:00Z',
                'refresh_expires_at': '2030-01-01T00:00:00Z',
                'absolute_expires_at': '2030-01-01T00:00:00Z',
              },
          ],
        });
      case 'POST session-revocations':
        if (!_permits(actor, t, 'sessions')) {
          return _problem(403, 'target_not_permitted');
        }
        final n = body['session_id'] == null ? t.sessions.length : 1;
        t.record('sessions_revoke', actor.id, body);
        if (body['session_id'] == null) {
          t.sessions.clear();
        } else if (t.sessions.isNotEmpty) {
          t.sessions.removeAt(0);
        }
        return _json(200, {'revoked_sessions': n});
      case 'POST lifecycle-transitions':
        final act = body['action'] as String;
        if (!_permits(actor, t, act)) {
          return _problem(403, 'target_not_permitted');
        }
        if (act == 'suspend') {
          if (t.status == 'pending_deletion') {
            return _problem(409, 'status_conflict', accountStatus: t.status);
          }
          if (t.lifecycleRevision != body['expected_lifecycle_revision']) {
            return _problem(409, 'lifecycle_conflict');
          }
          t
            ..resumeStatus = t.status
            ..status = 'suspended'
            ..suspensionReason = body['reason_code'] as String
            ..ticketRef = body['ticket_ref'] as String?
            ..lifecycleRevision += 1
            ..sessions.clear()
            ..record('suspend', actor.id, body);
        } else {
          if (t.status == 'pending_deletion') {
            return _problem(409, 'status_conflict', accountStatus: t.status);
          }
          t
            ..status = t.resumeStatus ?? 'active'
            ..resumeStatus = null
            ..lifecycleRevision += 1
            ..record('reinstate', actor.id, body);
        }
        return _json(200, _detail(actor, t));
      case 'PUT entitlement':
        planRequests.add(Map.of(body));
        if (!_permits(actor, t, 'plan') ||
            t.withheldActions.contains('manage_plan')) {
          return _problem(403, 'target_not_permitted');
        }
        final plan = body['plan'] as String;
        final expiry = body['ends_at'] == null
            ? null
            : DateTime.parse(body['ends_at']! as String);
        final reasons =
            reasonCodes[plan == 'premium'
                ? 'premium_grant'
                : 'premium_revoke']!;
        if (!reasons.contains(body['reason_code']) ||
            body['ticket_ref'] is! String ||
            !validTicketRef(body['ticket_ref']! as String)) {
          return _problem(400, 'invalid_request');
        }
        if (t.plan == plan && t.planExpiresAt == expiry) {
          return _json(200, _detail(actor, t));
        }
        if (t.status == 'pending_deletion') {
          return _problem(409, 'status_conflict', accountStatus: t.status);
        }
        if (t.entitlementRevision != body['expected_entitlement_revision']) {
          return _problem(409, 'entitlement_conflict');
        }
        t
          ..plan = plan
          ..planExpiresAt = expiry
          ..entitlementRevision += 1
          ..record(
            plan == 'premium' ? 'premium_grant' : 'premium_revoke',
            actor.id,
            body,
          );
        return _json(200, _detail(actor, t));
      case 'PUT role':
        if (!_permits(actor, t, 'role')) {
          return _problem(403, 'target_not_permitted');
        }
        if (t.status == 'pending_deletion') {
          return _problem(409, 'status_conflict', accountStatus: t.status);
        }
        if (t.role == 'super_admin' && _activeSuperAdmins == 1) {
          return _problem(409, 'last_super_admin');
        }
        if (t.roleRevision != body['expected_role_revision']) {
          return _problem(409, 'role_conflict');
        }
        t
          ..role = body['role'] as String
          ..roleRevision += 1
          ..record('role_change', actor.id, body);
        return _json(200, _detail(actor, t));
    }
    return _problem(404, 'not_found');
  }
}
