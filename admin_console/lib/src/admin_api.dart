import 'models.dart';
import 'transport.dart';

/// Typed calls to the TRD 06 routes. The Go API is the authorization
/// authority: nothing here decides what an actor may do.
class AdminApi {
  AdminApi(this.transport);
  final AdminTransport transport;

  Future<Me> me() async =>
      Me.fromJson(await transport.request('GET', '/v1/me'));

  Future<UserPage> listUsers(
    SearchQuery q, {
    String? pageToken,
    int limit = 50,
  }) async {
    final body = await transport.request(
      'GET',
      '/v1/admin/users',
      query: q.params(pageToken: pageToken, limit: limit),
    );
    final items = (body['items'] as List? ?? const [])
        .whereType<Map>()
        .map((m) => AdminUserSummary.fromJson(m.cast<String, Object?>()))
        .toList();
    return UserPage(items, body['next_page_token'] as String?);
  }

  Future<AdminUser> user(String id) async =>
      AdminUser.fromJson(await transport.request('GET', '/v1/admin/users/$id'));

  Future<List<AdminSession>> sessions(String id) async {
    final body = await transport.request('GET', '/v1/admin/users/$id/sessions');
    return (body['sessions'] as List? ?? const [])
        .whereType<Map>()
        .map((m) => AdminSession.fromJson(m.cast<String, Object?>()))
        .toList();
  }

  /// One page of the account's administrative history, newest first.
  Future<AuditPage> audit(
    String id, {
    String? pageToken,
    int limit = 50,
  }) async {
    final body = await transport.request(
      'GET',
      '/v1/admin/users/$id/audit',
      query: {'limit': '$limit', 'page_token': ?pageToken},
    );
    final items = (body['items'] as List? ?? const [])
        .whereType<Map>()
        .map((m) => AuditEntry.fromJson(m.cast<String, Object?>()))
        .toList();
    return AuditPage(items, body['next_page_token'] as String?);
  }

  /// Revokes one session, or every session when [sessionId] is null.
  Future<int> revokeSessions(
    String id, {
    String? sessionId,
    required String reason,
    String? ticketRef,
  }) async {
    final body = await transport.request(
      'POST',
      '/v1/admin/users/$id/session-revocations',
      body: {
        'session_id': sessionId,
        'reason_code': reason,
        'ticket_ref': ticketRef,
      },
    );
    return (body['revoked_sessions'] as num?)?.toInt() ?? 0;
  }

  Future<AdminUser> transition(
    String id, {
    required String action,
    required String reason,
    String? ticketRef,
    required int expectedLifecycleRevision,
  }) async {
    return AdminUser.fromJson(
      await transport.request(
        'POST',
        '/v1/admin/users/$id/lifecycle-transitions',
        body: {
          'action': action,
          'reason_code': reason,
          'ticket_ref': ticketRef,
          'expected_lifecycle_revision': expectedLifecycleRevision,
        },
      ),
    );
  }

  Future<AdminUser> changeRole(
    String id, {
    required String role,
    required String reason,
    String? ticketRef,
    required int expectedRoleRevision,
  }) async {
    return AdminUser.fromJson(
      await transport.request(
        'PUT',
        '/v1/admin/users/$id/role',
        body: {
          'role': role,
          'reason_code': reason,
          'ticket_ref': ticketRef,
          'expected_role_revision': expectedRoleRevision,
        },
      ),
    );
  }
}
