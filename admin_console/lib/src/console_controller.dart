import 'package:flutter/foundation.dart';

import 'admin_api.dart';
import 'messages.dart';
import 'models.dart';
import 'transport.dart';

enum Phase { signedOut, noAccess, ready }

enum Load { idle, loading, loaded, failed }

class Notice {
  const Notice(this.text, {this.error = false});
  final String text;
  final bool error;
}

/// The console's state and every operator workflow (TRD 07 §5). Widgets only
/// render this and call its methods, so the same code paths run in widget
/// tests and against the real Go API.
///
/// The Go API is the authorization authority. Actions are offered only from
/// the server's `allowed_actions` and `assignable_roles`; every refusal is
/// mapped to a message and a state change (reload, no-access or sign-in).
class ConsoleController extends ChangeNotifier {
  ConsoleController(this.api);
  final AdminApi api;

  Phase phase = Phase.signedOut;
  bool signingIn = false;
  Notice? notice;
  Me? me;
  CodeChallenge? codeChallenge;

  SearchQuery query = const SearchQuery();
  Load listLoad = Load.idle;
  List<AdminUserSummary> users = const [];
  String? nextPageToken;
  bool loadingMore = false;
  String? listError;

  String? selectedId;
  Load detailLoad = Load.idle;
  AdminUser? detail;
  String? detailError;
  Load sessionsLoad = Load.idle;
  List<AdminSession> sessions = const [];
  String? sessionsError;
  bool mutating = false;

  Load auditLoad = Load.idle;
  List<AuditEntry> audit = const [];
  String? auditNextPageToken;
  String? auditError;
  bool auditLoadingMore = false;
  int auditPageSize = 50;

  bool _disposed = false;

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  void clearNotice() {
    notice = null;
    _changed();
  }

  // --- sign-in -------------------------------------------------------------------------------

  Future<void> signInWithPassword(String email, String password) =>
      _signIn(() => api.transport.passwordLogin(email.trim(), password));

  Future<void> requestCode(String email) async {
    signingIn = true;
    notice = null;
    _changed();
    try {
      codeChallenge = await api.transport.startCode(email.trim());
      notice = const Notice(
        'If this account can sign in, a code was sent to its email.',
      );
    } on Object catch (e) {
      notice = Notice(Messages.describe(e), error: true);
    } finally {
      signingIn = false;
      _changed();
    }
  }

  Future<void> verifyCode(String code) async {
    final challenge = codeChallenge;
    if (challenge == null) return;
    await _signIn(() => api.transport.verifyCode(challenge, code.trim()));
  }

  void cancelCode() {
    codeChallenge = null;
    _changed();
  }

  Future<void> _signIn(Future<void> Function() call) async {
    signingIn = true;
    notice = null;
    _changed();
    try {
      await call();
      codeChallenge = null;
      await _enter();
    } on Object catch (e) {
      api.transport.forget();
      notice = Notice(Messages.describe(e), error: true);
    } finally {
      signingIn = false;
      _changed();
    }
  }

  Future<void> _enter() async {
    me = await api.me();
    if (!me!.isStaff) {
      phase = Phase.noAccess;
      notice = const Notice(Messages.noAccess, error: true);
      return;
    }
    phase = Phase.ready;
    _changed();
    await search(const SearchQuery());
  }

  Future<void> signOut({Notice? because}) async {
    await api.transport.logout();
    _reset(because);
  }

  void _reset(Notice? because) {
    phase = Phase.signedOut;
    me = null;
    codeChallenge = null;
    query = const SearchQuery();
    users = const [];
    nextPageToken = null;
    listLoad = Load.idle;
    listError = null;
    _clearSelection();
    mutating = false;
    notice = because;
    _changed();
  }

  void _clearSelection() {
    selectedId = null;
    detail = null;
    detailLoad = Load.idle;
    detailError = null;
    sessions = const [];
    sessionsLoad = Load.idle;
    sessionsError = null;
    audit = const [];
    auditLoad = Load.idle;
    auditNextPageToken = null;
    auditError = null;
    auditLoadingMore = false;
  }

  // --- search and list -----------------------------------------------------------------------

  Future<void> search(SearchQuery q) async {
    final problem = q.problem;
    query = q;
    if (problem != null) {
      listError = problem;
      listLoad = Load.failed;
      _changed();
      return;
    }
    listLoad = Load.loading;
    listError = null;
    _changed();
    try {
      final page = await api.listUsers(q);
      users = page.items;
      nextPageToken = page.nextPageToken;
      listLoad = Load.loaded;
    } on Object catch (e) {
      if (await _global(e)) return;
      users = const [];
      nextPageToken = null;
      listError = Messages.describe(e);
      listLoad = Load.failed;
    }
    _changed();
  }

  Future<void> loadMore() async {
    final token = nextPageToken;
    if (token == null || loadingMore) return;
    loadingMore = true;
    _changed();
    try {
      final page = await api.listUsers(query, pageToken: token);
      users = [...users, ...page.items];
      nextPageToken = page.nextPageToken;
    } on Object catch (e) {
      if (await _global(e)) return;
      notice = Notice(Messages.describe(e), error: true);
    } finally {
      loadingMore = false;
      _changed();
    }
  }

  // --- detail --------------------------------------------------------------------------------

  Future<void> select(String id) async {
    _clearSelection();
    selectedId = id;
    await reloadDetail();
  }

  void closeDetail() {
    _clearSelection();
    _changed();
  }

  Future<void> reloadDetail() async {
    final id = selectedId;
    if (id == null) return;
    detailLoad = Load.loading;
    detailError = null;
    _changed();
    try {
      _showDetail(await api.user(id));
    } on Object catch (e) {
      if (await _global(e)) return;
      if (e is AdminApiException && e.code == 'not_found') {
        await _gone();
        return;
      }
      detail = null;
      detailError = e is AdminApiException && e.code == 'target_not_permitted'
          ? 'Your role cannot view this account.'
          : Messages.describe(e);
      detailLoad = Load.failed;
      _changed();
      return;
    }
    await reloadSessions();
  }

  Future<void> reloadSessions() async {
    final d = detail;
    if (d == null || !d.can('view_sessions')) {
      sessions = const [];
      sessionsLoad = Load.idle;
      _changed();
      return;
    }
    sessionsLoad = Load.loading;
    sessionsError = null;
    _changed();
    try {
      sessions = await api.sessions(d.id);
      sessionsLoad = Load.loaded;
    } on Object catch (e) {
      if (await _global(e)) return;
      sessions = const [];
      sessionsError = Messages.describe(e);
      sessionsLoad = Load.failed;
    }
    _changed();
  }

  // --- audit history (TRD 06 §9a) ----------------------------------------------------------

  /// Loads the first page of the selected account's administrative history.
  /// The server applies the same visibility rule as the detail view.
  Future<void> loadAudit() async {
    final id = selectedId;
    if (id == null) return;
    auditLoad = Load.loading;
    auditError = null;
    _changed();
    try {
      final page = await api.audit(id, limit: auditPageSize);
      if (selectedId != id) return;
      audit = page.items;
      auditNextPageToken = page.nextPageToken;
      auditLoad = Load.loaded;
    } on Object catch (e) {
      if (await _auditRefused(e)) return;
      audit = const [];
      auditNextPageToken = null;
      auditLoad = Load.failed;
    }
    _changed();
  }

  Future<void> loadMoreAudit() async {
    final id = selectedId, token = auditNextPageToken;
    if (id == null || token == null || auditLoadingMore) return;
    auditLoadingMore = true;
    _changed();
    try {
      final page = await api.audit(id, pageToken: token, limit: auditPageSize);
      if (selectedId != id) return;
      audit = [...audit, ...page.items];
      auditNextPageToken = page.nextPageToken;
    } on Object catch (e) {
      if (await _auditRefused(e)) return;
      auditLoad = Load.failed;
    } finally {
      auditLoadingMore = false;
      _changed();
    }
  }

  /// Returns true when the refusal moved the console elsewhere; otherwise sets
  /// [auditError] for the in-place error state.
  Future<bool> _auditRefused(Object e) async {
    if (await _global(e)) return true;
    if (e is AdminApiException && e.code == 'not_found') {
      await _gone();
      return true;
    }
    if (e is AdminApiException && e.code == 'target_not_permitted') {
      auditError =
          'Your role cannot view this account or its history any more.';
      await _refreshMe();
      return phase != Phase.ready;
    }
    auditError = Messages.describe(e);
    return false;
  }

  Future<void> _refreshAuditIfShown() async {
    if (auditLoad != Load.idle) await loadAudit();
  }

  void _showDetail(AdminUser u) {
    detail = u;
    detailLoad = Load.loaded;
    users = [
      for (final s in users) s.id == u.id ? s.withState(u.status, u.role) : s,
    ];
    _changed();
  }

  // --- mutations (TRD 06 §6.2) ---------------------------------------------------------------

  Future<bool> suspend(String reason, String? ticketRef) => _mutate(
    (d) => api.transition(
      d.id,
      action: 'suspend',
      reason: reason,
      ticketRef: ticketRef,
      expectedLifecycleRevision: d.lifecycleRevision,
    ),
    'Account suspended. It was signed out everywhere.',
  );

  Future<bool> reinstate(String reason, String? ticketRef) => _mutate(
    (d) => api.transition(
      d.id,
      action: 'reinstate',
      reason: reason,
      ticketRef: ticketRef,
      expectedLifecycleRevision: d.lifecycleRevision,
    ),
    'Account reinstated. Its owner must sign in again.',
  );

  Future<bool> changeRole(String role, String reason, String? ticketRef) =>
      _mutate(
        (d) => api.changeRole(
          d.id,
          role: role,
          reason: reason,
          ticketRef: ticketRef,
          expectedRoleRevision: d.roleRevision,
        ),
        'Role changed to ${roleLabels[role] ?? role}.',
      );

  /// [targetId] and [expectedEntitlementRevision] bind the user's confirmation
  /// to the detail they reviewed, even if a background reload finishes while
  /// the dialog is open. A conflict is never automatically replayed.
  Future<bool> changePlan(
    String plan,
    DateTime? endsAt,
    String reason,
    String ticketRef, {
    String? targetId,
    int? expectedEntitlementRevision,
  }) async {
    final d = detail;
    if (d == null || mutating) return false;
    if ((targetId != null && targetId != d.id) ||
        (expectedEntitlementRevision != null &&
            expectedEntitlementRevision != d.entitlementRevision)) {
      notice = const Notice(Messages.planChanged, error: true);
      await reloadDetail();
      return false;
    }
    return _mutate(
      (confirmed) => api.changePlan(
        confirmed.id,
        plan: plan,
        endsAt: endsAt,
        reason: reason,
        ticketRef: ticketRef,
        expectedEntitlementRevision:
            expectedEntitlementRevision ?? confirmed.entitlementRevision,
      ),
      plan == 'premium'
          ? 'Premium grant saved.'
          : 'Premium revoked. The account is Free.',
      refreshDetailAndAudit: true,
    );
  }

  Future<bool> revokeSessions({
    String? sessionId,
    required String reason,
    String? ticketRef,
  }) async {
    final d = detail;
    if (d == null || mutating) return false;
    mutating = true;
    notice = null;
    _changed();
    try {
      final n = await api.revokeSessions(
        d.id,
        sessionId: sessionId,
        reason: reason,
        ticketRef: ticketRef,
      );
      notice = Notice(
        n == 0
            ? 'No live session needed revoking.'
            : 'Revoked $n session${n == 1 ? '' : 's'}.',
      );
      mutating = false;
      await reloadDetail();
      await _refreshAuditIfShown();
      return true;
    } on Object catch (e) {
      mutating = false;
      if (sessionId != null &&
          e is AdminApiException &&
          e.code == 'not_found') {
        // The session (not necessarily the account) is gone; the reload decides which.
        notice = const Notice(
          'That session had already ended. The list was refreshed.',
        );
        await reloadDetail();
        return false;
      }
      await _refused(e);
      return false;
    } finally {
      mutating = false;
      _changed();
    }
  }

  Future<bool> _mutate(
    Future<AdminUser> Function(AdminUser d) call,
    String done, {
    bool refreshDetailAndAudit = false,
  }) async {
    final d = detail;
    if (d == null || mutating) return false;
    mutating = true;
    notice = null;
    _changed();
    try {
      final updated = await call(d);
      if (refreshDetailAndAudit &&
          (selectedId != d.id || phase != Phase.ready)) {
        return true;
      }
      _showDetail(updated);
      notice = Notice(done);
      if (updated.id == me?.id) {
        me = await api.me(); // a Super Admin stepping down loses access now
        if (!me!.isStaff) {
          mutating = false;
          _toNoAccess(Messages.steppedDown);
          return true;
        }
      }
      if (refreshDetailAndAudit) {
        await reloadDetail();
        if (phase == Phase.ready && detail?.id == d.id) await loadAudit();
      } else {
        mutating = false;
        await reloadSessions();
        await _refreshAuditIfShown();
      }
      return true;
    } on Object catch (e) {
      mutating = false;
      await _refused(e);
      return false;
    } finally {
      mutating = false;
      _changed();
    }
  }

  /// A refused mutation: say why and move to the state that lets the
  /// operator act on it.
  Future<void> _refused(Object e) async {
    if (await _global(e)) return;
    if (e is! AdminApiException) {
      notice = Notice(Messages.describe(e), error: true);
      return;
    }
    switch (e.code) {
      case 'not_found':
        await _gone();
        return;
      case 'target_not_permitted':
        notice = const Notice(Messages.targetNotPermitted, error: true);
        await _refreshMe();
        if (phase == Phase.ready) await reloadDetail();
      case 'entitlement_conflict':
        notice = const Notice(Messages.planChanged, error: true);
        await reloadDetail();
        if (phase == Phase.ready && detail != null) await loadAudit();
      case 'lifecycle_conflict' ||
          'role_conflict' ||
          'status_conflict' ||
          'last_super_admin':
        notice = Notice(Messages.describe(e), error: true);
        await reloadDetail();
      default:
        notice = Notice(Messages.describe(e), error: true);
    }
  }

  /// Handles outcomes that change the whole console: an ended session or lost
  /// admin access. Returns true when it did.
  Future<bool> _global(Object e) async {
    if (e is SessionEnded ||
        (e is AdminApiException && e.code == 'unauthorized')) {
      api.transport.forget();
      _reset(const Notice(Messages.sessionEnded, error: true));
      return true;
    }
    if (e is AdminApiException && e.code == 'forbidden') {
      await _refreshMe();
      if (phase == Phase.ready) {
        notice = const Notice(Messages.accessRemoved, error: true);
        _changed();
      }
      return true;
    }
    return false;
  }

  Future<void> _refreshMe() async {
    try {
      me = await api.me();
      if (!me!.isStaff) _toNoAccess(Messages.accessRemoved);
    } on SessionEnded {
      api.transport.forget();
      _reset(const Notice(Messages.sessionEnded, error: true));
    } on Object {
      // Keep the current state; the next request decides again.
    }
  }

  void _toNoAccess(String why) {
    phase = Phase.noAccess;
    users = const [];
    nextPageToken = null;
    listLoad = Load.idle;
    _clearSelection();
    notice = Notice(why, error: true);
    _changed();
  }

  Future<void> _gone() async {
    _clearSelection();
    notice = const Notice(Messages.notFound, error: true);
    _changed();
    await search(query);
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
