import 'package:flutter/material.dart';

import '../console_controller.dart';
import '../models.dart';
import 'action_dialog.dart';
import 'app.dart';

String fmt(DateTime? t) {
  if (t == null) return '—';
  final l = t.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${l.year}-${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
}

class ConsolePage extends StatelessWidget {
  const ConsolePage({super.key, required this.controller});
  final ConsoleController controller;

  @override
  Widget build(BuildContext context) {
    final me = controller.me!;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Veea Admin Console'),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Center(
              child: Text(
                '${me.email} · ${roleLabels[me.role] ?? me.role}',
                key: const Key('signed-in-as'),
              ),
            ),
          ),
          TextButton(
            key: const Key('signout'),
            onPressed: () => controller.signOut(),
            child: const Text('Sign out'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          NoticeBanner(controller: controller),
          Expanded(
            child: LayoutBuilder(
              builder: (context, box) {
                final list = UserListPane(controller: controller);
                final detail = UserDetailPane(controller: controller);
                if (box.maxWidth >= 960) {
                  return Row(
                    children: [
                      SizedBox(width: 440, child: list),
                      const VerticalDivider(width: 1),
                      Expanded(child: detail),
                    ],
                  );
                }
                return controller.selectedId == null ? list : detail;
              },
            ),
          ),
        ],
      ),
    );
  }
}

// --- list ----------------------------------------------------------------------------------

class UserListPane extends StatefulWidget {
  const UserListPane({super.key, required this.controller});
  final ConsoleController controller;
  @override
  State<UserListPane> createState() => _UserListPaneState();
}

class _UserListPaneState extends State<UserListPane> {
  late final _text = TextEditingController(text: widget.controller.query.text);
  late MatchMode _mode = widget.controller.query.mode;
  late String? _status = widget.controller.query.status,
      _role = widget.controller.query.role;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _search() => widget.controller.search(
    SearchQuery(text: _text.text, mode: _mode, role: _role, status: _status),
  );

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final superAdmin = c.me?.isSuperAdmin ?? false;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const Key('search-field'),
            controller: _text,
            onSubmitted: (_) => _search(),
            decoration: InputDecoration(
              labelText: _mode == MatchMode.exact
                  ? 'Exact email'
                  : 'Email starts with',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                key: const Key('search-submit'),
                tooltip: 'Search',
                icon: const Icon(Icons.search),
                onPressed: _search,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SegmentedButton<MatchMode>(
                segments: const [
                  ButtonSegment(
                    value: MatchMode.prefix,
                    label: Text('Starts with'),
                  ),
                  ButtonSegment(value: MatchMode.exact, label: Text('Exact')),
                ],
                selected: {_mode},
                onSelectionChanged: (s) => setState(() => _mode = s.first),
              ),
              DropdownButton<String?>(
                key: const Key('filter-status'),
                value: _status,
                hint: const Text('Any status'),
                items: [
                  const DropdownMenuItem<String?>(
                    value: null,
                    child: Text('Any status'),
                  ),
                  for (final s in statusLabels.entries)
                    DropdownMenuItem<String?>(
                      value: s.key,
                      child: Text(s.value),
                    ),
                ],
                onChanged: (v) => setState(() => _status = v),
              ),
              // Admins only ever see User accounts (TRD 06 D1), so they get no role filter.
              if (superAdmin)
                DropdownButton<String?>(
                  key: const Key('filter-role'),
                  value: _role,
                  hint: const Text('Any role'),
                  items: [
                    const DropdownMenuItem<String?>(
                      value: null,
                      child: Text('Any role'),
                    ),
                    for (final r in roleLabels.entries)
                      DropdownMenuItem<String?>(
                        value: r.key,
                        child: Text(r.value),
                      ),
                  ],
                  onChanged: (v) => setState(() => _role = v),
                ),
            ],
          ),
          if (!superAdmin)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'As an Admin you can see and manage User accounts only.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          const SizedBox(height: 12),
          Expanded(child: _results(context, c)),
        ],
      ),
    );
  }

  Widget _results(BuildContext context, ConsoleController c) {
    switch (c.listLoad) {
      case Load.idle:
      case Load.loading:
        return const Center(
          child: CircularProgressIndicator(key: Key('list-loading')),
        );
      case Load.failed:
        return _StateMessage(
          key: const Key('list-error'),
          icon: Icons.error_outline,
          text: c.listError ?? 'The accounts could not be loaded.',
          action: c.query.problem == null
              ? TextButton(
                  key: const Key('list-retry'),
                  onPressed: () => c.search(c.query),
                  child: const Text('Retry'),
                )
              : null,
        );
      case Load.loaded:
        if (c.users.isEmpty) {
          return _StateMessage(
            key: const Key('list-empty'),
            icon: Icons.search_off,
            text:
                c.query.text.trim().isEmpty &&
                    c.query.status == null &&
                    c.query.role == null
                ? 'There are no accounts you can see yet.'
                : 'No accounts match this search. Change the filters or clear the search.',
          );
        }
        return ListView.separated(
          itemCount: c.users.length + (c.nextPageToken != null ? 1 : 0),
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, i) {
            if (i == c.users.length) {
              return Padding(
                padding: const EdgeInsets.all(8),
                child: c.loadingMore
                    ? const Center(child: CircularProgressIndicator())
                    : OutlinedButton(
                        key: const Key('load-more'),
                        onPressed: c.loadMore,
                        child: const Text('Load more'),
                      ),
              );
            }
            final u = c.users[i];
            return ListTile(
              key: Key('user-row-${u.id}'),
              selected: u.id == c.selectedId,
              title: Text(u.email, overflow: TextOverflow.ellipsis),
              subtitle: Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    RoleChip(u.role),
                    StatusChip(u.status),
                    Text('Created ${fmt(u.createdAt)}'),
                  ],
                ),
              ),
              onTap: () => c.select(u.id),
            );
          },
        );
    }
  }
}

class _StateMessage extends StatelessWidget {
  const _StateMessage({
    super.key,
    required this.icon,
    required this.text,
    this.action,
  });
  final IconData icon;
  final String text;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 36),
          const SizedBox(height: 8),
          Text(text, textAlign: TextAlign.center),
          ?action,
        ],
      ),
    ),
  );
}

class RoleChip extends StatelessWidget {
  const RoleChip(this.role, {super.key});
  final String role;
  @override
  Widget build(BuildContext context) => Chip(
    visualDensity: VisualDensity.compact,
    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    label: Text(roleLabels[role] ?? role),
    avatar: role == 'user' ? null : const Icon(Icons.shield_outlined, size: 16),
  );
}

class StatusChip extends StatelessWidget {
  const StatusChip(this.status, {super.key});
  final String status;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final warn = status != 'active';
    return Chip(
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      backgroundColor: warn ? scheme.errorContainer : null,
      label: Text(
        statusLabels[status] ?? status,
        style: warn ? TextStyle(color: scheme.onErrorContainer) : null,
      ),
    );
  }
}

// --- detail --------------------------------------------------------------------------------

class UserDetailPane extends StatelessWidget {
  const UserDetailPane({super.key, required this.controller});
  final ConsoleController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    if (c.selectedId == null) {
      return const _StateMessage(
        icon: Icons.person_search,
        text: 'Select an account to see its details and actions.',
      );
    }
    final back = Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        onPressed: c.closeDetail,
        icon: const Icon(Icons.arrow_back),
        label: const Text('Back to list'),
      ),
    );
    if (c.detailLoad == Load.loading && c.detail == null) {
      return Column(
        children: [
          back,
          const Expanded(
            child: Center(
              child: CircularProgressIndicator(key: Key('detail-loading')),
            ),
          ),
        ],
      );
    }
    if (c.detailLoad == Load.failed || c.detail == null) {
      return Column(
        children: [
          back,
          Expanded(
            child: _StateMessage(
              key: const Key('detail-error'),
              icon: Icons.error_outline,
              text: c.detailError ?? 'The account could not be loaded.',
              action: TextButton(
                onPressed: c.reloadDetail,
                child: const Text('Retry'),
              ),
            ),
          ),
        ],
      );
    }
    final d = c.detail!;
    final self = d.id == c.me?.id;
    final t = Theme.of(context).textTheme;
    final header = Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          back,
          Row(
            children: [
              Expanded(
                child: Text(
                  d.email,
                  style: t.headlineSmall,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (c.detailLoad == Load.loading)
                const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              RoleChip(d.role),
              StatusChip(d.status),
              if (self) const Chip(label: Text('You')),
            ],
          ),
        ],
      ),
    );
    final overview = ListView(
      key: const Key('detail'),
      padding: const EdgeInsets.all(16),
      children: [
        if (d.pendingDeletion)
          _Callout(
            key: const Key('detail-pending-deletion'),
            icon: Icons.delete_forever_outlined,
            text:
                'Pending deletion since ${fmt(d.deletionAcceptedAt)}. The owner asked for this account to be erased. It '
                'cannot be suspended, reinstated or given a new role, and its data is being removed.',
          ),
        if (d.suspension case final s?)
          _Callout(
            key: const Key('detail-suspension'),
            icon: Icons.block,
            text:
                'Suspended ${fmt(s.suspendedAt)} for "${reasonLabels[s.reasonCode] ?? s.reasonCode}"'
                '${s.ticketRef != null ? ' (ticket ${s.ticketRef})' : ''}. Reinstating returns it to '
                '${statusLabels[s.resumeStatus] ?? s.resumeStatus}.',
          ),
        const SizedBox(height: 16),
        _Facts({
          'Account ID': d.id,
          'Display name': d.displayName ?? '—',
          'Email verified': fmt(d.emailVerifiedAt),
          'Password set': d.hasPassword
              ? 'Yes'
              : 'No (signs in with email codes)',
          'Created': fmt(d.createdAt),
          'Status changed': fmt(d.stateChangedAt),
          'Role changed': fmt(d.roleChangedAt),
          'Effective plan': planLabels[d.plan] ?? d.plan,
          'Plan expiry (UTC)':
              d.planExpiresAt?.toIso8601String() ?? 'No active Premium grant',
          'Live sessions': '${d.liveSessions}',
          'Last seen': fmt(d.lastSeenAt),
        }),
        const SizedBox(height: 16),
        _Actions(controller: c, user: d, self: self),
        if (d.can('view_sessions')) ...[
          const SizedBox(height: 24),
          _Sessions(controller: c, user: d),
        ],
      ],
    );
    return DefaultTabController(
      key: ValueKey('tabs-${d.id}'), // a new account opens on Overview
      length: 2,
      child: Column(
        children: [
          header,
          const TabBar(
            tabs: [
              Tab(key: Key('tab-overview'), text: 'Overview'),
              Tab(key: Key('tab-audit'), text: 'Audit history'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                overview,
                AuditHistoryTab(controller: c),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The account's administrative history (TRD 07 §5a). Loaded when the tab is
/// first shown; the server applies the same visibility rule as the detail.
class AuditHistoryTab extends StatefulWidget {
  const AuditHistoryTab({super.key, required this.controller});
  final ConsoleController controller;
  @override
  State<AuditHistoryTab> createState() => _AuditHistoryTabState();
}

class _AuditHistoryTabState extends State<AuditHistoryTab> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.controller.auditLoad == Load.idle) {
        widget.controller.loadAudit();
      }
    });
  }

  String _actor(String? id) {
    if (id == null) return 'the operator CLI';
    if (id == widget.controller.me?.id) return 'you';
    return 'staff account ${id.substring(0, 8)}…';
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final t = Theme.of(context).textTheme;
    const scope =
        'Suspensions, reinstatements, role changes and session revocations made by staff. '
        'Entries are kept for 180 days.';
    switch (c.auditLoad) {
      case Load.idle:
      case Load.loading:
        return const Center(
          child: CircularProgressIndicator(key: Key('audit-loading')),
        );
      case Load.failed:
        return _StateMessage(
          key: const Key('audit-error'),
          icon: Icons.error_outline,
          text: c.auditError ?? 'The history could not be loaded.',
          action: TextButton(
            key: const Key('audit-retry'),
            onPressed: c.loadAudit,
            child: const Text('Retry'),
          ),
        );
      case Load.loaded:
        if (c.audit.isEmpty) {
          return const _StateMessage(
            key: Key('audit-empty'),
            icon: Icons.history,
            text: 'No administrative changes in the last 180 days.\n$scope',
          );
        }
        return ListView(
          key: const Key('audit-list'),
          padding: const EdgeInsets.all(16),
          children: [
            Text(scope, style: t.bodySmall),
            const SizedBox(height: 8),
            for (final (i, e) in c.audit.indexed)
              ListTile(
                key: Key('audit-entry-$i'),
                contentPadding: EdgeInsets.zero,
                leading: Icon(_icon(e.action)),
                title: Text(auditActionLabels[e.action] ?? e.action),
                subtitle: Text(
                  [
                    '${fmt(e.occurredAt)} by ${_actor(e.actorUserId)}',
                    if (e.reasonCode != null)
                      'Reason: ${reasonLabels[e.reasonCode] ?? e.reasonCode}',
                    if (e.ticketRef != null) 'Ticket ${e.ticketRef}',
                  ].join(' · '),
                ),
                trailing: e.outcome == 'success'
                    ? null
                    : const Chip(label: Text('Failed')),
              ),
            if (c.auditNextPageToken != null)
              Padding(
                padding: const EdgeInsets.all(8),
                child: c.auditLoadingMore
                    ? const Center(child: CircularProgressIndicator())
                    : OutlinedButton(
                        key: const Key('audit-load-more'),
                        onPressed: c.loadMoreAudit,
                        child: const Text('Load older entries'),
                      ),
              ),
          ],
        );
    }
  }

  IconData _icon(String action) => switch (action) {
    'suspend' => Icons.block,
    'reinstate' => Icons.settings_backup_restore,
    'sessions_revoke' => Icons.logout,
    _ => Icons.admin_panel_settings_outlined,
  };
}

class _Callout extends StatelessWidget {
  const _Callout({super.key, required this.icon, required this.text});
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: scheme.onTertiaryContainer),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: scheme.onTertiaryContainer),
            ),
          ),
        ],
      ),
    );
  }
}

class _Facts extends StatelessWidget {
  const _Facts(this.facts);
  final Map<String, String> facts;
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Column(
      children: [
        for (final e in facts.entries)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 150, child: Text(e.key, style: t.bodySmall)),
                Expanded(child: SelectableText(e.value)),
              ],
            ),
          ),
      ],
    );
  }
}

/// Only the actions the server listed for this actor and target state.
class _Actions extends StatelessWidget {
  const _Actions({
    required this.controller,
    required this.user,
    required this.self,
  });
  final ConsoleController controller;
  final AdminUser user;
  final bool self;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final u = user;
    final buttons = <Widget>[
      if (u.can('suspend'))
        FilledButton.tonalIcon(
          key: const Key('action-suspend'),
          icon: const Icon(Icons.block),
          label: const Text('Suspend'),
          onPressed: c.mutating ? null : () => _suspend(context),
        ),
      if (u.can('reinstate'))
        FilledButton.tonalIcon(
          key: const Key('action-reinstate'),
          icon: const Icon(Icons.settings_backup_restore),
          label: const Text('Reinstate'),
          onPressed: c.mutating ? null : () => _reinstate(context),
        ),
      if (u.can('change_role') && u.assignableRoles.isNotEmpty)
        FilledButton.tonalIcon(
          key: const Key('action-change-role'),
          icon: const Icon(Icons.admin_panel_settings_outlined),
          label: Text(self ? 'Step down to User' : 'Change role'),
          onPressed: c.mutating ? null : () => _role(context),
        ),
      if (u.can('manage_plan')) ...[
        FilledButton.tonalIcon(
          key: const Key('action-grant-premium'),
          icon: const Icon(Icons.workspace_premium_outlined),
          label: const Text('Grant Premium'),
          onPressed: c.mutating || c.detailLoad != Load.loaded
              ? null
              : () => _plan(context, true),
        ),
        if (u.plan == 'premium')
          OutlinedButton.icon(
            key: const Key('action-revoke-premium'),
            icon: const Icon(Icons.remove_circle_outline),
            label: const Text('Revoke Premium'),
            onPressed: c.mutating || c.detailLoad != Load.loaded
                ? null
                : () => _plan(context, false),
          ),
      ],
      if (u.can('revoke_sessions') && u.liveSessions > 0)
        OutlinedButton.icon(
          key: const Key('action-revoke-all'),
          icon: const Icon(Icons.logout),
          label: const Text('Sign out everywhere'),
          onPressed: c.mutating ? null : () => _revoke(context, null),
        ),
    ];
    if (buttons.isEmpty) {
      return Text(
        u.pendingDeletion
            ? 'No changes are possible while the account is pending deletion.'
            : self
            ? 'There is nothing you can change on your own account here. You can step down only while another active Super Admin remains.'
            : 'Your role has no actions available for this account.',
        key: const Key('no-actions'),
        style: Theme.of(context).textTheme.bodySmall,
      );
    }
    return Wrap(spacing: 8, runSpacing: 8, children: buttons);
  }

  Future<ActionRequest?> _ask(BuildContext context, ActionDialog dialog) =>
      showDialog<ActionRequest>(context: context, builder: (_) => dialog);

  Future<void> _plan(BuildContext context, bool grant) async {
    final confirmed = user;
    final request = await _ask(
      context,
      ActionDialog(
        title: grant ? 'Grant Premium?' : 'Revoke Premium?',
        target: confirmed.email,
        reasonKind: grant ? 'premium_grant' : 'premium_revoke',
        confirmLabel: grant ? 'Grant Premium' : 'Revoke Premium',
        requireTicket: true,
        requireExpiry: grant,
        destructive: !grant,
        effect: grant
            ? 'Premium starts when saved and ends at the expiry you choose. An existing grant is replaced. Roles, sessions, data and current limits stay the same.'
            : 'The account returns to Free immediately. Roles, sessions, data and current limits stay the same.',
      ),
    );
    if (request != null) {
      await controller.changePlan(
        grant ? 'premium' : 'free',
        request.endsAt,
        request.reason,
        request.ticketRef!,
        targetId: confirmed.id,
        expectedEntitlementRevision: confirmed.entitlementRevision,
      );
    }
  }

  Future<void> _suspend(BuildContext context) async {
    final r = await _ask(
      context,
      ActionDialog(
        title: 'Suspend account?',
        target: user.email,
        reasonKind: 'suspend',
        confirmLabel: 'Suspend account',
        destructive: true,
        effect:
            'The account is signed out on every device and cannot sign in until it is reinstated. Its data is kept, '
            'and its owner can still export or delete it.',
      ),
    );
    if (r != null) await controller.suspend(r.reason, r.ticketRef);
  }

  Future<void> _reinstate(BuildContext context) async {
    final resume = user.suspension?.resumeStatus ?? 'active';
    final r = await _ask(
      context,
      ActionDialog(
        title: 'Reinstate account?',
        target: user.email,
        reasonKind: 'reinstate',
        confirmLabel: 'Reinstate account',
        effect:
            'The account returns to ${statusLabels[resume] ?? resume}. Old sessions and codes stay invalid; the owner '
            'must sign in again${resume == 'deactivated' ? ' after reactivating by email' : ''}.',
      ),
    );
    if (r != null) await controller.reinstate(r.reason, r.ticketRef);
  }

  Future<void> _role(BuildContext context) async {
    final r = await _ask(
      context,
      ActionDialog(
        title: self ? 'Step down to User?' : 'Change role?',
        target: user.email,
        reasonKind: 'role',
        confirmLabel: self ? 'Step down' : 'Change role',
        roles: user.assignableRoles,
        destructive: self,
        effectForRole: (role) {
          if (self) {
            return 'You lose admin access as soon as this is saved. You stay signed in as a User.';
          }
          if (roleRank(role) > roleRank(user.role)) {
            return 'Promoting to ${roleLabels[role]} signs the account out on every device. The new rights apply after '
                'they sign in again.';
          }
          return 'Demoting to ${roleLabels[role]} applies on their next request. Their sessions stay signed in.';
        },
      ),
    );
    if (r != null) await controller.changeRole(r.role!, r.reason, r.ticketRef);
  }

  Future<void> _revoke(BuildContext context, AdminSession? s) async {
    final r = await _ask(
      context,
      ActionDialog(
        title: s == null ? 'Sign out everywhere?' : 'Revoke this session?',
        target: user.email,
        reasonKind: 'sessions',
        confirmLabel: s == null ? 'Sign out everywhere' : 'Revoke session',
        destructive: true,
        effect: s == null
            ? 'Every live session of this account ends now. The owner can sign in again; use Suspend to block that.'
            : 'The session "${s.deviceName}" ends now. The owner can sign in again.',
      ),
    );
    if (r != null) {
      await controller.revokeSessions(
        sessionId: s?.id,
        reason: r.reason,
        ticketRef: r.ticketRef,
      );
    }
  }
}

class _Sessions extends StatelessWidget {
  const _Sessions({required this.controller, required this.user});
  final ConsoleController controller;
  final AdminUser user;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final t = Theme.of(context).textTheme;
    final Widget body = switch (c.sessionsLoad) {
      Load.idle || Load.loading => const Padding(
        padding: EdgeInsets.all(16),
        child: Center(
          child: CircularProgressIndicator(key: Key('sessions-loading')),
        ),
      ),
      Load.failed => Row(
        children: [
          Expanded(
            child: Text(
              c.sessionsError ?? 'Sessions could not be loaded.',
              key: const Key('sessions-error'),
            ),
          ),
          TextButton(onPressed: c.reloadSessions, child: const Text('Retry')),
        ],
      ),
      Load.loaded when c.sessions.isEmpty => const Text(
        'No live sessions.',
        key: Key('sessions-empty'),
      ),
      Load.loaded => Column(
        children: [
          for (final s in c.sessions)
            ListTile(
              key: Key('session-${s.id}'),
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.devices),
              title: Text('${s.deviceName} (${s.platform})'),
              subtitle: Text(
                'Signed in ${fmt(s.createdAt)} · last seen ${fmt(s.lastSeenAt)}',
              ),
              trailing: user.can('revoke_sessions')
                  ? TextButton(
                      key: Key('revoke-session-${s.id}'),
                      onPressed: c.mutating
                          ? null
                          : () => _Actions(
                              controller: c,
                              user: user,
                              self: false,
                            )._revoke(context, s),
                      child: const Text('Revoke'),
                    )
                  : null,
            ),
        ],
      ),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Signed-in devices', style: t.titleMedium),
        Text(
          'Device names are set by the client and are not proof of identity.',
          style: t.bodySmall,
        ),
        const SizedBox(height: 8),
        body,
      ],
    );
  }
}
