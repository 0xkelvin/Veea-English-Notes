/// Projections of the TRD 06 contract (`backend/api/openapi.yaml` 1.5.0-trd06).
library;

DateTime? _time(Object? v) =>
    v is String ? DateTime.tryParse(v)?.toUtc() : null;
String _str(Map<String, Object?> j, String k) {
  final v = j[k];
  if (v is! String) throw FormatException('missing $k');
  return v;
}

const staffRoles = {'admin', 'super_admin'};

/// The signed-in account from `GET /v1/me`. Its role only decides what the
/// console offers to load; the API decides every request again.
class Me {
  const Me({
    required this.id,
    required this.email,
    required this.role,
    required this.status,
  });
  factory Me.fromJson(Map<String, Object?> j) => Me(
    id: _str(j, 'id'),
    email: _str(j, 'email'),
    role: _str(j, 'role'),
    status: _str(j, 'status'),
  );
  final String id, email, role, status;
  bool get isStaff => staffRoles.contains(role);
  bool get isSuperAdmin => role == 'super_admin';
}

class AdminUserSummary {
  const AdminUserSummary({
    required this.id,
    required this.email,
    required this.status,
    required this.role,
    required this.createdAt,
    this.stateChangedAt,
  });
  factory AdminUserSummary.fromJson(Map<String, Object?> j) => AdminUserSummary(
    id: _str(j, 'id'),
    email: _str(j, 'email'),
    status: _str(j, 'status'),
    role: _str(j, 'role'),
    createdAt: _time(j['created_at'])!,
    stateChangedAt: _time(j['state_changed_at']),
  );
  final String id, email, status, role;
  final DateTime createdAt;
  final DateTime? stateChangedAt;
  AdminUserSummary withState(String status, String role) => AdminUserSummary(
    id: id,
    email: email,
    status: status,
    role: role,
    createdAt: createdAt,
    stateChangedAt: stateChangedAt,
  );
}

class UserPage {
  const UserPage(this.items, this.nextPageToken);
  final List<AdminUserSummary> items;
  final String? nextPageToken;
}

class Suspension {
  const Suspension({
    required this.reasonCode,
    this.ticketRef,
    this.suspendedAt,
    this.suspendedBy,
    required this.resumeStatus,
  });
  final String reasonCode, resumeStatus;
  final String? ticketRef, suspendedBy;
  final DateTime? suspendedAt;
}

/// `AdminUser`: the administrative detail, including the server-computed
/// [allowedActions] and [assignableRoles] for this actor and target state.
class AdminUser {
  AdminUser._(this.json);
  factory AdminUser.fromJson(Map<String, Object?> j) {
    for (final k in ['id', 'email', 'status', 'role']) {
      _str(j, k);
    }
    if (j['allowed_actions'] is! List ||
        j['assignable_roles'] is! List ||
        j['sessions'] is! Map) {
      throw const FormatException('incomplete admin user');
    }
    return AdminUser._(j);
  }
  final Map<String, Object?> json;
  String get id => json['id']! as String;
  String get email => json['email']! as String;
  String get status => json['status']! as String;
  String get role => json['role']! as String;
  String? get displayName => json['display_name'] as String?;
  bool get hasPassword => json['has_password'] == true;
  DateTime? get emailVerifiedAt => _time(json['email_verified_at']);
  DateTime? get createdAt => _time(json['created_at']);
  DateTime? get stateChangedAt => _time(json['state_changed_at']);
  DateTime? get roleChangedAt => _time(json['role_changed_at']);
  int get lifecycleRevision =>
      (json['lifecycle_revision'] as num?)?.toInt() ?? 0;
  int get roleRevision => (json['role_revision'] as num?)?.toInt() ?? 0;
  int get liveSessions =>
      ((json['sessions'] as Map)['live_count'] as num?)?.toInt() ?? 0;
  DateTime? get lastSeenAt => _time((json['sessions'] as Map)['last_seen_at']);
  Set<String> get allowedActions =>
      (json['allowed_actions'] as List).whereType<String>().toSet();
  List<String> get assignableRoles =>
      (json['assignable_roles'] as List).whereType<String>().toList();
  bool can(String action) => allowedActions.contains(action);
  bool get pendingDeletion => status == 'pending_deletion';
  DateTime? get deletionAcceptedAt {
    final p = json['pending_deletion'];
    return p is Map ? _time(p['accepted_at']) : null;
  }

  Suspension? get suspension {
    final s = json['suspension'];
    if (s is! Map) return null;
    return Suspension(
      reasonCode: s['reason_code'] as String? ?? 'other',
      ticketRef: s['ticket_ref'] as String?,
      suspendedAt: _time(s['suspended_at']),
      suspendedBy: s['suspended_by_user_id'] as String?,
      resumeStatus: s['resume_status'] as String? ?? 'active',
    );
  }
}

/// One administrative change on an account: exactly the API's allowlisted fields
/// (`GET /v1/admin/users/{id}/audit`, TRD 06 §9a).
class AuditEntry {
  const AuditEntry({
    required this.occurredAt,
    required this.action,
    required this.outcome,
    this.actorUserId,
    this.reasonCode,
    this.ticketRef,
  });
  factory AuditEntry.fromJson(Map<String, Object?> j) => AuditEntry(
    occurredAt: _time(j['occurred_at'])!,
    action: _str(j, 'action'),
    outcome: _str(j, 'outcome'),
    actorUserId: j['actor_user_id'] as String?,
    reasonCode: j['reason_code'] as String?,
    ticketRef: j['ticket_ref'] as String?,
  );
  final DateTime occurredAt;
  final String action, outcome;
  final String? actorUserId, reasonCode, ticketRef;
}

class AuditPage {
  const AuditPage(this.items, this.nextPageToken);
  final List<AuditEntry> items;
  final String? nextPageToken;
}

const auditActionLabels = {
  'suspend': 'Suspended',
  'reinstate': 'Reinstated',
  'role_change': 'Role changed',
  'role_bootstrap': 'Made Super Admin (CLI bootstrap)',
  'sessions_revoke': 'Sessions revoked',
  'premium_grant': 'Premium granted',
  'premium_revoke': 'Premium revoked',
};

class AdminSession {
  const AdminSession({
    required this.id,
    required this.deviceName,
    required this.platform,
    this.createdAt,
    this.lastSeenAt,
  });
  factory AdminSession.fromJson(Map<String, Object?> j) => AdminSession(
    id: _str(j, 'id'),
    deviceName: _str(j, 'device_name'),
    platform: _str(j, 'platform'),
    createdAt: _time(j['created_at']),
    lastSeenAt: _time(j['last_seen_at']),
  );
  final String id, deviceName, platform;
  final DateTime? createdAt, lastSeenAt;
}

/// The fixed reason codes per mutation (TRD 06 §6.5). The server rejects any
/// other value with 400.
const reasonCodes = <String, List<String>>{
  'suspend': [
    'abuse',
    'fraud',
    'account_compromise',
    'policy_violation',
    'legal_request',
    'owner_request',
    'other',
  ],
  'reinstate': [
    'appeal_upheld',
    'issue_resolved',
    'suspended_in_error',
    'other',
  ],
  'role': ['staffing_change', 'access_review', 'account_compromise', 'other'],
  'sessions': [
    'account_compromise',
    'owner_request',
    'security_review',
    'other',
  ],
};

const reasonLabels = <String, String>{
  'abuse': 'Abuse',
  'fraud': 'Fraud',
  'account_compromise': 'Account compromise',
  'policy_violation': 'Policy violation',
  'legal_request': 'Legal request',
  'owner_request': 'Owner request',
  'appeal_upheld': 'Appeal upheld',
  'issue_resolved': 'Issue resolved',
  'suspended_in_error': 'Suspended in error',
  'staffing_change': 'Staffing change',
  'access_review': 'Access review',
  'security_review': 'Security review',
  'other': 'Other',
};

const roleLabels = {
  'user': 'User',
  'admin': 'Admin',
  'super_admin': 'Super Admin',
};
const statusLabels = {
  'active': 'Active',
  'deactivated': 'Deactivated',
  'suspended': 'Suspended',
  'pending_deletion': 'Pending deletion',
};
int roleRank(String role) =>
    const {'user': 1, 'admin': 2, 'super_admin': 3}[role] ?? 0;

final _ticket = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,39}$');

/// Mirrors the server's ticket reference rule: short identifier, no spaces or
/// `@`, and nothing token-shaped.
bool validTicketRef(String s) {
  if (!_ticket.hasMatch(s)) return false;
  final lower = s.toLowerCase();
  return !['vct_', 'vat_', 'vrt_', 'vop_'].any(lower.contains);
}

enum MatchMode { prefix, exact }

/// A list request. Empty text lists every visible account.
class SearchQuery {
  const SearchQuery({
    this.text = '',
    this.mode = MatchMode.prefix,
    this.role,
    this.status,
  });
  final String text;
  final MatchMode mode;
  final String? role, status;

  /// A message when the query cannot be sent, otherwise null.
  String? get problem {
    final t = text.trim();
    if (t.isEmpty) return null;
    if (mode == MatchMode.exact && !t.contains('@')) {
      return 'Enter a full email address for an exact match.';
    }
    if (mode == MatchMode.prefix && t.runes.length < 3) {
      return 'Type at least 3 characters to search by prefix.';
    }
    return null;
  }

  Map<String, String> params({String? pageToken, int limit = 50}) => {
    if (text.trim().isNotEmpty)
      (mode == MatchMode.exact ? 'email' : 'email_prefix'): text.trim(),
    'role': ?role,
    'status': ?status,
    'limit': '$limit',
    'page_token': ?pageToken,
  };
}
