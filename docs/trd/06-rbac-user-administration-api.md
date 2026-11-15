# TRD 06 — RBAC & User Administration API

**Status:** v1.0. Nin approved the matrix and decisions on 2026-11-15, before implementation. Implemented and locally verified (§13).
**Date:** 2026-11-15
**Audience:** Backend and QA engineers, and the author of TRD 07.
**Next document:** TRD 07, *Admin UI*. This TRD defines only the server contract the UI will call.

## 0. How to read this TRD

| Tag | Meaning |
|---|---|
| **[Approved]** | Decided by Nin or by a cited document. Changing it needs a new decision. |
| **[Existing]** | A fact about the code before this change. |
| **[Technical]** | An implementation choice made within the approved decisions. |

The v0.1 draft listed five product decisions. §2 records how Nin settled them; where the answer differs from the draft's recommendation, §2 says so.

## 1. Authority, baseline and scope

Read with [AGENTS.md](../../AGENTS.md), the [User Management Product Doc](../product/user-management.md) §9, [TRD 01](01-email-authentication-account-foundation.md), [TRD 02](02-session-management.md), [TRD 04](04-account-lifecycle-data-rights.md) and [TRD 05](05-learning-data-sync.md).

Code baseline: commit `8c9f4a1` on `feat/go-email-auth-account-foundation`, migrations 00001 to 00011, plus the uncommitted Flutter/E2E work already in the index, which this change does not touch.

### 1.1 Inputs approved before this TRD

| # | Requirement | Source |
|---|---|---|
| A1 | The three roles are Super Admin, Admin and User. | Product Doc §4 |
| A2 | Suspension denies password and OTP sign-in, refresh and every protected API, and revokes **all** sessions at the transition commit. Data is retained. | TRD 04 §3.1, §1.1 |
| A3 | Suspension saves the state it interrupted (active or deactivated); reinstatement restores exactly that state. Neither creates a session; reinstatement never revives revoked sessions or old proofs. | TRD 04 §3.2, §11 decision 1 |
| A4 | A suspended owner cannot self-reactivate, but can still export or delete through mailbox proof. | TRD 04 §1.1 |
| A5 | Pending deletion is irreversible; the email is released only when the purge completes. | TRD 04 §1.1 |
| A6 | Self-service routes (`/v1/me/*`) give admins no cross-account exception. | TRD 02 §3 |
| A7 | Audit rows are kept 180 days; a purge minimizes them, keeping action, outcome, `reason`, time, actor and target. | TRD 04 §12.4 |
| A8 | Every protected Go route is wrapped with `authenticated`; routes change with `openapi.yaml`; metrics count after commit; only `identity/accounts` writes `users`. | AGENTS.md |

### 1.2 Existing facts

- **[Existing]** `users.role` was `user`, `admin` or `super_admin` (migration 00001), but no code changed it or authorized with it.
- **[Existing]** `AuthenticateAccessToken` joins `users` on every request and returns the role in `Principal.Role`. There is no authentication cache, so a committed role change is visible to the next request.
- **[Existing]** `users.status` allowed `suspended`, but nothing produced it, and migration 00010 had no `resume_status`. Migration 00012 adds it (§7).

### 1.3 Scope

In scope:

- authorization for `/v1/admin/*`;
- listing, searching and viewing accounts and their live sessions;
- suspension and reinstatement;
- role changes;
- revoking one or all sessions of another account;
- first Super Admin bootstrap, CLI-only break-glass recovery, and the last-Super-Admin guard.

Out of scope, by decision: the admin UI (TRD 07), any suspension email, admin-triggered password reset, viewing learning content, system settings, audit viewing, and admin export or forced deletion.

## 2. Approved decisions (Nin, 2026-11-15)

| ID | Decision |
|---|---|
| D1 | **Matrix.** Admins can view and manage User accounts only: they cannot list, view or act on Admin or Super Admin accounts, including their own. Super Admins can act on other accounts at every role level, including other Super Admins. The **only** self-admin mutation is a Super Admin stepping down to `user`, and only while another active Super Admin remains. *(The draft let Admins view staff accounts, and let a Super Admin step down to `admin`. Both were narrowed.)* |
| D2 | **Bootstrap.** A CLI promotes an existing active, verified account, and only when no active Super Admin exists. Audited break-glass recovery exists only in the CLI. Super Admins grant roles, including `super_admin`, through the API. |
| D3 | **Last Super Admin.** One database guard is used by bootstrap, break-glass, role changes, suspension (and reinstatement), owner self-deactivation and owner deletion acceptance. The last active Super Admin cannot step down, deactivate or accept deletion (`409 last_super_admin`). This amends TRD 04 for that one account. |
| D4 | **Session effects.** Promotion revokes every target session. Demotion applies on the next request and preserves sessions. Suspension revokes sessions and saves the prior state. Reinstatement restores that state without old sessions or OTPs. Admin mutations of pending-deletion targets are refused. |
| D5 | **Reasons and visibility.** Admin searches, views and mutations are audited. Mutations need a fixed reason code and accept an optional validated ticket reference. Raw search text never enters audit metadata. Admin responses exclude IP addresses, user agents and learning content. |

## 3. Actor–action–target matrix (approved, D1)

A **User** gets `403 forbidden` on every `/v1/admin/*` route.

| Action | Admin → User | Admin → Admin, Super Admin or self | Super Admin → User, Admin or other Super Admin | Super Admin → self |
|---|---|---|---|---|
| List or search | Sees role `user` only; a `role` filter for another role is `403 target_not_permitted` | — | Sees every role | Included in results |
| View detail | Yes | `403 target_not_permitted` | Yes | Yes |
| View or revoke sessions | Yes | `403 target_not_permitted` | Yes | `403` (use `/v1/me/sessions`) |
| Suspend, reinstate | Yes | `403 target_not_permitted` | Yes | `403` |
| Change role | `403` | `403` | Any other role | To `user` only, guarded (§4) |

Target-state rules, applied after the matrix:

| Action | active | deactivated | suspended | pending_deletion | purged |
|---|---|---|---|---|---|
| View; view or revoke sessions | yes | yes | yes | yes | `404` |
| Suspend | → suspended (resume active) | → suspended (resume deactivated) | `200` no-op | `409 status_conflict` | `404` |
| Reinstate | `200` no-op | `200` no-op | → saved state | `409 status_conflict` | `404` |
| Promote | yes | `409 status_conflict` | `409 status_conflict` | `409 status_conflict` | `404` |
| Demote | yes | yes | yes | `409 status_conflict` | `404` |

The pure function `admin.Permits` encodes the matrix and is unit-tested cell by cell. The service always applies it to the actor and target rows it has locked, never to `Principal.Role` alone. Detail responses include server-computed `allowed_actions` and `assignable_roles`.

## 4. Super Admin provisioning and protection (approved, D2 and D3)

**Invariant.** An *active Super Admin* has `role = 'super_admin'`, `status = 'active'` and a verified email. Once at least one exists, no application transaction commits a state with none.

### 4.1 The guard lock (L2s)

`accounts.LockSuperAdminGuard` takes a transaction-scoped advisory lock (`pg_advisory_xact_lock`) on one global key: the first 8 bytes of SHA-256 of `veea:rbac:super_admin_guard`. It sits after L2b and before L3, and is never taken after a `users` row lock.

These transactions take it **unconditionally**:

- API role changes;
- bootstrap and break-glass;
- admin suspension and reinstatement;
- owner self-deactivation (`POST /v1/me/deactivate`);
- owner deletion acceptance (inside the `account_delete` completion, after locking the operation).

**Guarded recheck.** `accounts.CheckNotLastSuperAdmin` runs while the transaction holds L2s and the subject's L3 row, just before a change that removes an active Super Admin from the set. It counts the other active Super Admins and refuses with `ErrLastSuperAdmin` when there are none. Every decreasing transition holds L2s until commit, and READ COMMITTED reads the latest committed rows after the wait, so the count is exact. Without the shared lock, two Super Admins stepping down at once would each count the other (write skew).

Reactivation by mailbox and promotion only add members to the set. Purge only removes `pending_deletion` accounts, which already do not count. None of these needs the recheck.

### 4.2 Bootstrap CLI

```sh
bin/admin bootstrap-super-admin (--user-id UUID | --email ADDRESS) \
    [--mode first|break_glass] [--reason-code CODE] [--ticket-ref REF]   # reads VEEA_DATABASE_URL
```

- **`first`** (the default) uses reason `bootstrap`. It requires zero active Super Admins, otherwise it exits with code 1.
- **`break_glass`** requires a reason of `lost_access`, `account_compromise` or `other`. It skips only the zero-count check. The HTTP API has no break-glass path.
- **Both modes:**
  1. Take L2s, then the target row at L3.
  2. Require the target to exist, be active and verified, and not already be a Super Admin.
  3. Set `role = super_admin`, increment `role_revision` and revoke every target session (`role_change`).
  4. Commit `admin.role.bootstrap` with a null actor and metadata `mode` and `source=cli`.
- The CLI never creates accounts, never sets passwords, never runs on API startup, and never prints an email address. It prints `user_id`, `role_revision`, `revoked_sessions` and `mode`. Who may run it is a deployment control (§12).

### 4.3 TRD 04 owner flows (amended)

- `POST /v1/me/deactivate` by the last active Super Admin returns `409 last_super_admin`. Nothing changes, and an `account.deactivate` failure event with reason `last_super_admin` is committed separately.
- Deletion completion for the last active Super Admin rolls back through `otp.Rollback("last_super_admin", …)`. The response is `409 last_super_admin` and the proof is **not** consumed: once a successor exists, the same unexpired proof is accepted. `account.delete.verify` records the failure. The public start remains generic and reveals no role.

### 4.4 Concurrent outcomes (tested both orders, §11)

| Overlap | Outcome |
|---|---|
| The only two Super Admins both step down | L2s serializes them. The first gets `200`, the second `409 last_super_admin`. |
| A demotes B while B demotes A | The first commits. The second revalidates its actor under L3, finds it is no longer staff, and gets `403 forbidden`. |
| A steps down while B self-deactivates | The first wins; the second gets `409 last_super_admin`. |
| A steps down while B accepts deletion | The first wins; the second gets `409 last_super_admin`, with B's proof kept. |
| Two `first` bootstraps | Exactly one succeeds; the other gets `ErrAlreadyProvisioned`. |
| A Super Admin suspends another | The actor remains active, so the guard passes. A suspended Super Admin no longer counts for later checks. |

## 5. When changes take effect (approved, D4)

General rule: a change is effective at its commit for every request whose authentication snapshot starts afterwards. A request authenticated earlier may finish a read. Every admin **write** revalidates the actor's standing, role and acting session under lock, so it never acts on a stale role. There is no authentication cache.

| Change | Target sessions | Effect |
|---|---|---|
| Promotion (`user` → `admin` or `super_admin`, `admin` → `super_admin`) | All revoked, reason `role_change` | Admin rights exist only in sessions issued after the grant. Does not touch `lifecycle_revision`. |
| Demotion | Kept | The next request carries the lower role. Staff routes refuse it (`403 forbidden`); refresh and `/v1/me` keep working. |
| Suspension | All revoked, reason `account_suspended`, including expired but unrevoked rows | `status = suspended`, saved `resume_status`, reason, ticket reference and actor. `lifecycle_revision` is incremented, which invalidates OTP proofs and rights operations. Pending exports are cancelled (`account.export.cancel` with the admin as actor). Sign-in, refresh and protected routes fail. Export and deletion by mailbox stay available. Reactivation is refused. No email is sent. |
| Reinstatement | Never revived | `status = resume_status`; suspension fields are cleared; `lifecycle_revision` is incremented; exports created while suspended are cancelled. Old access and refresh tokens and pre-suspension OTPs stay dead. A `deactivated` resume state still needs mailbox reactivation, which returns no session. |
| Owner deletion while suspended | — | `SetAccountState` clears the saved suspension in the same update. The account is then `pending_deletion`, and every admin mutation other than session revocation (which finds nothing live) is `409 status_conflict`. After the purge, every admin route for the ID returns `404`. |

Concurrent outcomes (tested both orders):

| Overlap | Outcome |
|---|---|
| Suspension and the target's refresh | If refresh wins its row lock, the rotated pair is then revoked. If the suspension wins, refresh returns `401`. |
| Suspension and the target's password sign-in | L3 on the target. If the sign-in commits first, its new pair is revoked. If the suspension commits first, sign-in fails. |
| Suspension and the owner's deletion completion | Both take L2s. If the suspension commits first, deletion gets `409 lifecycle_conflict` and the owner can start a new proof while suspended. If deletion commits first, the suspension gets `409 status_conflict` with `account_status: pending_deletion`. |
| An admin write while the actor is demoted, suspended or logged out | The write waits on the actor's L3 row, then revalidates and gets `403 forbidden` or `401`. Nothing changes. |

## 6. API contract

### 6.1 Conventions

- TRD 01 §5.1 and TRD 02 §3 apply: problem+json, `X-Request-Id`, `Cache-Control: no-store`, strict JSON bodies (exact keys, every field present), `415` for a wrong content type, 36-character non-nil path UUIDs, `HEAD` refused.
- Every route is `h.authenticated(h.requireStaff(op, handler))`. `requireStaff` is a fast pre-check on `Principal.Role` that answers `403 forbidden` and records the denial. The service decides authorization again inside its transaction.
- Order of checks:
  1. `401` authentication.
  2. `403 forbidden` staff pre-check.
  3. `400` or `415` validation.
  4. `429` rate limit.
  5. In the transaction: actor revalidation (`401` or `403 forbidden`), target existence (`404`), matrix (`403 target_not_permitted`), no-op (`200`), target state (`409 status_conflict`), expected revision (`409 lifecycle_conflict` or `role_conflict`), and the guard (`409 last_super_admin`).
- **[Technical]** Rate limits are autocommit counters per acting user: `admin_read_user_1m` (120 per minute) and `admin_write_user_1m` (30 per minute), on top of the existing 600 per minute per-session limit.
- OpenAPI is `1.5.0-trd06`, with tag `admin`.

### 6.2 Endpoints

| Operation | Route | Success |
|---|---|---|
| `listAdminUsers` | `GET /v1/admin/users` | `200 {items, next_page_token}` |
| `getAdminUser` | `GET /v1/admin/users/{user_id}` | `200 AdminUser` |
| `listAdminUserSessions` | `GET /v1/admin/users/{user_id}/sessions` | `200 {sessions}` |
| `revokeAdminUserSessions` | `POST /v1/admin/users/{user_id}/session-revocations` `{session_id \| null, reason_code, ticket_ref}` | `200 {revoked_sessions}` |
| `transitionAdminUser` | `POST /v1/admin/users/{user_id}/lifecycle-transitions` `{action: suspend \| reinstate, reason_code, ticket_ref, expected_lifecycle_revision}` | `200 AdminUser` |
| `changeAdminUserRole` | `PUT /v1/admin/users/{user_id}/role` `{role, reason_code, ticket_ref, expected_role_revision}` | `200 AdminUser` |
| `listAdminUserAudit` (2026-11-15, §9a) | `GET /v1/admin/users/{user_id}/audit?limit&page_token` | `200 {items, next_page_token}` |

### 6.3 List and search

| Parameter | Rule |
|---|---|
| `email` | Exact match after `identity.NormalizeEmail`; an invalid address is `400 invalid_email`. Not combinable with `email_prefix`. |
| `email_prefix` | 3 to 254 characters after NFC and lowercasing. `%`, `_` and `\` are escaped, so the prefix is literal. |
| `role`, `status` | Single enum values. |
| `limit` | 1 to 100, default 50. |
| `page_token` | Opaque, from the previous page. |

Any other parameter, or a repeated one, is `400 invalid_request`.

- Ordering is `created_at DESC, id DESC`, keyset-paginated with `limit + 1` rows fetched.
- `page_token` is `a1.` plus base64url of 32 bytes: the last row's `created_at` in microseconds, its `id`, and an 8-byte SHA-256 fingerprint of the filters. A token that does not decode, or does not match the current filters, is `400`.
- Pages are not a snapshot, and there is no total.
- Each item has `id`, `email`, `status`, `role`, `created_at` and `state_changed_at`.

### 6.4 Detail

`AdminUser` contains:

- `id`, `email`, `email_verified_at`, `has_password`, `password_changed_at`;
- `display_name`, `preferred_language`, `time_zone`, `created_at`;
- `status`, `lifecycle_revision`, `state_changed_at`;
- `suspension` (`reason_code`, `ticket_ref`, `suspended_at`, `suspended_by_user_id`, `resume_status`), or null;
- `pending_deletion` (`accepted_at`), or null;
- `role`, `role_revision`, `role_changed_at`;
- `sessions` (`live_count`, `last_seen_at`);
- `allowed_actions` and `assignable_roles`.

`assignable_roles` omits promotions of inactive targets, every role for pending deletion, and any demotion of the last active Super Admin.

It never contains password or token hashes, OTP data, IP addresses, user agents, pending email-change addresses, outbox data, rights tokens or learning content. The target session list uses the TRD 02 projection without `is_current`.

### 6.5 Reason codes and ticket references

| Action | `reason_code` |
|---|---|
| Suspend | `abuse`, `fraud`, `account_compromise`, `policy_violation`, `legal_request`, `owner_request`, `other` |
| Reinstate | `appeal_upheld`, `issue_resolved`, `suspended_in_error`, `other` |
| Role change | `staffing_change`, `access_review`, `account_compromise`, `other` |
| Session revocation | `account_compromise`, `owner_request`, `security_review`, `other` |
| Bootstrap (CLI) | `bootstrap`; break-glass `lost_access`, `account_compromise`, `other` |

`ticket_ref` is null or matches `^[A-Za-z0-9][A-Za-z0-9._-]{0,39}$` with no token prefix. That leaves no room for spaces, `@` or prose. The reason goes in `audit_events.reason`, which survives minimization; the ticket reference goes in metadata. There is no free text.

### 6.6 Errors and retries

| HTTP and code | Meaning |
|---|---|
| `400 invalid_request` / `invalid_email` | Malformed path, query, body, page token, reason or ticket reference; invalid `email` filter |
| `401 unauthorized` | Bearer invalid, or actor session or account no longer qualifies |
| `403 forbidden` | Actor is not staff, or lost its role before revalidation |
| `403 target_not_permitted` | The matrix refuses this actor, target and action |
| `404 not_found` | Unknown or purged account; a session not owned by the target (identical to unknown) |
| `409 lifecycle_conflict` / `role_conflict` | Stale expected revision |
| `409 status_conflict` | Target status forbids it; extension `account_status` |
| `409 last_super_admin` | No other active Super Admin would remain (role change; owner deactivation and deletion) |
| `415`, `429`, `500` | As existing |

**Retry rule.** If the requested end state already holds, the response is `200` with no change and no event. The end states are: suspended; not suspended (and not pending deletion); the requested role; no live target session. Otherwise the expected revision must match. Role changes use their own `role_revision`, so they never invalidate OTP proofs. A stale retry cannot undo a later change (ABA).

## 7. Persistence: migration 00012

[`00012_rbac_admin.sql`](../../backend/migrations/00012_rbac_admin.sql) is expand-only and runs through `cmd/migrate` before the binaries. It adds:

- **Columns on `users`:** `role_revision`, `role_changed_at`, `resume_status` (`active` or `deactivated`), `suspension_reason` (a lowercase code), `suspension_ticket_ref` (the pattern above) and `suspended_by`. `suspended_by` has no foreign key, so it survives the admin's purge and adds no cross-user cascade locks.
- **Constraint `users_suspension_state`:** a row is `suspended` if and only if it has both `resume_status` and `suspension_reason`; the ticket reference and actor are null when not suspended. Any hand-edited `suspended` row from version 11 is backfilled with resume `active` and reason `other` first.
- **Revocation reasons:** `admin_revoked`, `account_suspended` and `role_change`.
- **Indexes:** `users_admin_order (created_at DESC, id DESC)`, `users_email_pattern (email_normalized text_pattern_ops)` and the partial `users_active_super_admins`.

No new user-owned table is added, so the purge and export inventory is unchanged. `SetAccountState` (lifecycle) now clears the suspension fields.

## 8. Transactions and lock order

| Level | Rows | TRD 06 use |
|---|---|---|
| L0 to L2b | Address locks, cooldowns, challenges, owned requests and operations | Unchanged |
| **L2s** | Super Admin guard (global advisory transaction lock) | **New**. Never taken after L3. |
| L3 | `users` | Admin writes lock **actor and target** `FOR NO KEY UPDATE` in ascending UUID order (one row when they are the same) |
| L4a | Acting session | Admin writes revalidate it after L3 |
| L4b | Target sessions | Revoke one or all |
| L5 | Insert-only rows, export cancellation, audit | Unchanged |

| Flow | Sequence |
|---|---|
| Suspend or reinstate | L2s → L3 actor and target → actor standing and staff role → L4a → matrix, no-op, state, revision, guard → `accounts.Suspend` or `Reinstate` → L4b (suspend) → cancel exports → L5 |
| Role change | L2s → L3 actor and target → revalidation → L4a → matrix, no-op, assignable, state, revision, guard (when demoting a Super Admin) → `accounts.SetRole` → L4b on promotion → L5 |
| Session revocation | L3 actor and target → revalidation → L4a → L4b → L5. No L2s. |
| Owner deactivation | **L2s** → L3 → L4a → revision → guard → existing steps |
| Owner deletion completion | L0 → L2 → L2b → **L2s** → L3 → eligibility → guard → existing steps |
| Bootstrap | L2s → L3 target → checks → `SetRole` → L4b → L5 |
| Admin reads | One `REPEATABLE READ` transaction: revalidate the acting session, standing and role in the snapshot; read; insert the read audit event; commit; then respond. An audit failure returns `500` with no data. |

No cycle can form:

- Nothing takes L2s after L3.
- Two-row L3 is acquired in a global order, and single-row L3 holders never request a second user row.
- Refresh and logout still take only L4a → L5.
- Admin writes refuse `pending_deletion` targets after waiting, so they never contend with the final purge.

All writes use the existing READ COMMITTED helper with whole-transaction retry; per-attempt counters reset on each attempt. Metrics are counted after commit.

## 9. Audit, logging and metrics

For admin events, the actor is the admin, the target is the account and the session is the acting session. IP, user agent and request ID come from the existing helpers. These rows are added to TRD 01 §11.1.

| Action | Outcome and fields |
|---|---|
| `admin.user.search` | success. `filters` (names only, or `none`), `result_count`, `page` (`first` or `next`). `email_hmac` only for an exact `email` filter. Never the search text. |
| `admin.user.view`, `admin.user.sessions.view`, `admin.user.audit.view` (§9a) | success. Committed in the read transaction. The history view adds `result_count` and `page`. |
| `admin.user.suspend` | success. `reason` is the code. `from_status`, `lifecycle_revision`, `ticket_ref?`. Preceded by `auth.session.revoke` (`account_suspended`) and any `account.export.cancel`. |
| `admin.user.reinstate` | success. `reason`, `to_status`, `lifecycle_revision`, `ticket_ref?`. |
| `admin.role.change` | success. `reason`, `from_role`, `to_role`, `role_revision`, `ticket_ref?`. Preceded by `auth.session.revoke` (`role_change`) when a promotion revoked rows. |
| `admin.sessions.revoke` | success. `reason`, `count`, `target_session_id?`. Preceded by `auth.session.revoke` (`admin_revoked`). None when the count is 0. |
| `admin.role.bootstrap` | success. Null actor. `reason`, `mode`, `source=cli`, `from_role`, `role_revision`, `ticket_ref?`. |
| `admin.access.denied` | failure. Reason `insufficient_role`, `target_not_permitted` or `last_super_admin`; metadata `operation`. At most one per acting session, operation and reason per minute (a companion counter commits with the row). |
| `account.deactivate`, `account.delete.verify` | Gain failure reason `last_super_admin`. |

No-ops, validation failures and revision or status conflicts write no event. An audit failure rolls the mutation back, and a forced `40001` retry commits each event once.

Logs go through the redacting handler and never contain emails, prefixes, ticket references or page tokens.

Metrics:

- `admin_actions_total{action,result}`, with result `success`, `noop`, `denied`, `conflict` or `error`;
- `auth_sessions_revoked_total` with the three new reasons;
- the gauge `admin_active_super_admins`.

## 9a. Per-account audit history (added 2026-11-15)

`GET /v1/admin/users/{user_id}/audit` is the read side of the mutation events above. It lives in [`internal/admin/audit_history.go`](../../backend/internal/admin/audit_history.go), uses the `AdminAuditHistory` query in [`queries/admin.sql`](../../backend/internal/platform/db/queries/admin.sql), and its handler is in `httpapi/admin.go`.

**Visibility.** It applies the same rule as `getAdminUser`, through the same `read` path:

- the actor is revalidated in one `REPEATABLE READ` snapshot (`401` or `403 forbidden`);
- the target must exist (`404`);
- `Permits(…, ActView)` decides access (`403 target_not_permitted`). An Admin sees User accounts only; a Super Admin sees every account, including its own.

`admin.user.audit.view` commits in that transaction before any data is returned. Pending-deletion targets remain visible until the purge, then the account is `404`.

**What is listed.** Only the five TRD 06 mutation actions on `target_user_id`, with this public mapping:

| Stored action | Public `action` |
|---|---|
| `admin.user.suspend` | `suspend` |
| `admin.user.reinstate` | `reinstate` |
| `admin.role.change` | `role_change` |
| `admin.role.bootstrap` | `role_bootstrap` |
| `admin.sessions.revoke` | `sessions_revoke` |

Reads, denials, owner and system events (`auth.*`, `account.*`) are never returned.

**Field allowlist.** Each item is exactly:

| Field | Source |
|---|---|
| `occurred_at` | `occurred_at` |
| `action` | mapped as above |
| `outcome` | `outcome` |
| `actor_user_id` | `actor_user_id`; null for the CLI bootstrap |
| `reason_code` | `reason` |
| `ticket_ref` | `metadata.ticket_ref`, or null |

Nothing else leaves the server: no IP, user agent, request ID, session, email HMAC or other metadata. An explicit DTO enforces this, and the OpenAPI schema has `additionalProperties: false`.

**Ordering and cursor.**

- Newest first by `occurred_at DESC, id DESC`. The `bigint` identity is the tie-breaker, so equal timestamps page deterministically, with no duplicates or gaps.
- `limit` is 1 to 100 (default 50), fetching `limit + 1` rows.
- `page_token` is `h1.` plus base64url of 24 bytes: the last row's `occurred_at` in microseconds, its `id`, and an 8-byte SHA-256 fingerprint of the target UUID. A token from another account, or a malformed one, is `400 invalid_request`. A forged but well-formed token only moves the start position within rows the actor may already read.
- The existing `audit_events_target (target_user_id, occurred_at DESC)` index serves the query; no migration was needed.

**Retention is unchanged.**

- The 180-day `CleanupOldAudit` job and TRD 04 minimization are untouched.
- The query also excludes rows older than 180 days, so a lagging cleanup can never make the API serve an expired event.
- A row minimized because its actor or target was purged keeps action, outcome, reason and actor, but its `ticket_ref` becomes null ("where available").

**Rate limit and metrics:** the read rule (`admin_read_user_1m`) and `admin_actions_total{action="audit_view"}`.

## 10. Code map

| Area | File |
|---|---|
| Matrix, reasons, ticket validation | [`internal/admin/policy.go`](../../backend/internal/admin/policy.go) |
| Reads, writes, page tokens, denial audit | [`internal/admin/service.go`](../../backend/internal/admin/service.go) |
| Bootstrap | [`internal/admin/bootstrap.go`](../../backend/internal/admin/bootstrap.go), [`cmd/admin`](../../backend/cmd/admin/main.go) |
| Guard, pair lock, user writes | [`internal/identity/accounts/roles.go`](../../backend/internal/identity/accounts/roles.go) |
| Owner-flow guard | [`internal/lifecycle/service.go`](../../backend/internal/lifecycle/service.go) (`Deactivate`, `Complete`) |
| Routes and projection | [`internal/auth/httpapi/admin.go`](../../backend/internal/auth/httpapi/admin.go) |
| SQL | [`queries/admin.sql`](../../backend/internal/platform/db/queries/admin.sql), `SetAccountState` in `lifecycle.sql` |
| Contract | [`api/openapi.yaml`](../../backend/api/openapi.yaml) `1.5.0-trd06` |

## 11. Router-level PostgreSQL tests

The tests use the production `app.New` router, a migrated disposable loopback PostgreSQL, the runtime OpenAPI checker, and the hygiene scan. Races hold a real lock (L2s, a user or session row, or an audit-insert gate) and observe the waiters in `pg_stat_activity` before releasing it. Token rejection is always asserted through the real `/v1/me` and refresh routes.

| Test (`test/integration/`) | Evidence |
|---|---|
| `TestAdmin_AuthorizationMatrix` | 3 actor roles × {self, user, admin, super_admin} × 6 operations. Checks the status and code, no mutation on refusal, `allowed_actions` and `assignable_roles`, Admin list restriction and role filter refusal, and that a Super Admin sees every role |
| `TestAdmin_RoleChangeAndExistingSessions` | Promotion revokes both pairs (`role_change`), and a fresh sign-in has admin access. A retried promotion is a no-op. Demotion keeps sessions and refresh, and the next admin request is `403`. ABA retry gets `role_conflict`. Promotion of a suspended account gets `status_conflict` with `account_status`. A suspended admin can be demoted. Super Admin step-down goes to `user` only |
| `TestAdmin_ActorRevalidationInsideTheTransaction` | Actor demoted, suspended or logged out while the write waits on its L3 row: `403` or `401`, target unchanged |
| `TestAdmin_SuspendReinstate` | Ticket and actor recorded. Both token types fail. Pending export cancelled with the admin as actor. Password sign-in refused and no OTP mail sent. Mailbox export allowed and reactivation refused. No-op retry. Stale revision gets `409`. Reinstatement restores `active` with old tokens and a pre-suspension OTP still dead and an export made while suspended cancelled. Fresh sign-in works. A deactivated owner resumes `deactivated` and still reactivates by mailbox |
| `TestAdmin_PendingDeletionTargets` | From active and from suspended: deletion clears the saved suspension. Detail shows `pending_deletion`. All four mutations get `status_conflict`. Revoke returns 0. After the purge every route is `404` |
| `TestAdmin_SessionRevocation` | Projection has 7 fields. Foreign and unknown session IDs give identical `404`. Single and all revocation (`admin_revoked`). Silent retry. Actor untouched. The target can sign in again. Body validation, including token-shaped ticket references |
| `TestAdmin_ListSearchPagination` | Keyset pages with `created_at` ties ordered by ID. Token bound to filters, forged token refused. Literal `_` and `%` prefixes. Exact email after normalization. `invalid_email`. Parameter validation. No search text in audit, and an email HMAC only for exact searches |
| `TestAdmin_DetailProjection` | Exact key set. No hash, token, IP or user agent in detail or session list |
| `TestAdmin_Bootstrap` | Ineligible targets (suspended, unverified, unknown, unknown email, already a Super Admin). Invalid modes, reasons and tickets. `first` by email revokes both sessions and audits with a null actor. A second `first` is refused. Break-glass with a reason. Two concurrent `first` runs promote exactly one |
| `TestAdmin_LastSuperAdminSingle` | Last Super Admin: empty `assignable_roles`; step-down, deactivation (with failure event) and deletion all `409 last_super_admin`. The kept proof is accepted once a successor exists. A suspended Super Admin does not count |
| `TestAdmin_LastSuperAdminRaces` | Both step down; mutual demotion; step-down against self-deactivation; step-down against deletion acceptance. Each in both orders, and exactly one active Super Admin remains |
| `TestAdmin_SuspensionRaces` | Against password sign-in, refresh and owner deletion completion, each in both orders |
| `TestAdmin_AuditEvents`, `TestAudit_Matrix` "TRD06 admin" | Exact events for search, view, sessions view, revocation, suspension, no-op, reinstatement, promotion, demotion, last-Super-Admin denial, deduplicated `insufficient_role` and `target_not_permitted`. Metrics |
| `TestAdmin_TransactionalAuditAndRetry` | A failing audit insert rolls back the suspension and fails the view. A forced `40001` retries once with one event set and one metric |
| `TestAdmin_ContractErrors`, `TestAdmin_RateLimitsAndInternalErrors` | Every route, including the audit history: `403 forbidden`, path, query and body `400`, `404`, `429` with no state change, and `500` |
| `TestAdminAudit_TargetVisibility` (§9a) | 3 actor roles × {self, user, admin, super_admin} against the `view` matrix; unknown `404`; pending deletion visible; demoted actor `403 forbidden`; target promoted `403 target_not_permitted` |
| `TestAdminAudit_PaginationWithTiedTimestampsAndRetention` (§9a) | Six real mutations forced to one timestamp, paged two at a time in exact ID-descending order. Excludes other accounts, reads, denials and no-op revocations. Token bound to the account; malformed tokens and parameters refused. A 181-day-old event is not served |
| `TestAdminAudit_FieldAllowlist` (§9a) | Exact top-level and item key sets; no user agent, IP, request ID or metadata leaks; the read is audited and not listed; bootstrap has a null actor; a minimized row loses only its ticket |
| `TestMigrations_RBACUpgradeFrom11` | A populated version 11 upgrades without row loss. A legacy suspended row is backfilled. Constraints reject inconsistent rows and invalid ticket references. Old and new revocation reasons are accepted. Replay works |
| Unit: `internal/admin`, `cmd/admin`, `metrics` | The matrix cell by cell, assignable roles, reasons, ticket references, page-token round trip and binding, LIKE escaping, CLI parsing and refusals (never printing the address), metrics |

Existing fixtures that wrote `status = 'suspended'` directly now also write `resume_status` and `suspension_reason`, because the new constraint requires them.

## 12. Release gates

1. Run migration 00012 with `cmd/migrate`, then roll every API instance before any admin route is used. Older binaries do not clear the suspension fields when a suspended owner accepts deletion.
2. Provision the first Super Admin with `bin/admin bootstrap-super-admin`, then grant a second one through the API so the guard never blocks routine work. Record who may run the CLI (production database access) in the runbook.
3. Alert on `admin_active_super_admins < 1` and on spikes of `admin.access.denied`. Phase 5 owns alerting. **Delivered in [TRD 08](08-monitoring-alerting.md)** as `VeeaNoActiveSuperAdmin`, gated on the bootstrap marker so a fresh deployment stays silent. Alerting on `admin.access.denied` spikes needs a metric and remains open.
4. TRD 07 builds the UI: confirmation before suspension and promotion, reason pickers, `allowed_actions`, and re-reading after a conflict. Delivered in [TRD 07](07-admin-console.md) (`admin_console/`), which records the remaining audit-history and CORS gaps.

## 13. Implementation and verification record — 2026-11-15

Implemented on `feat/go-email-auth-account-foundation`, without staging, commits or pushes. The migration version is **12**.

Commands, from `backend/`, against loopback-only disposable services (`scripts/test-postgres.sh`, `scripts/test-mailpit.sh`):

```sh
make sqlc && make sqlc-verify && make check && make build
VEEA_TEST_DATABASE_URL=postgres://postgres@127.0.0.1:54329/postgres \
VEEA_TEST_SMTP_ADDR=127.0.0.1:1025 VEEA_TEST_MAILPIT_API=http://127.0.0.1:8025 \
go test -race -tags=integration -count=1 -json ./...
```

| Check | Actual result |
|---|---|
| `make sqlc`, `make sqlc-verify` | Passed; generated code reproducible (`admin.sql` new, `SetAccountState` changed) |
| `make check` | Passed: gofmt, vet with and without the integration tag, and unit tests |
| `make build` | Passed: `bin/api`, `bin/migrate` and the new `bin/admin` |
| Full race run (PostgreSQL + Mailpit) | **1197 passed, 0 failed, 0 skipped** tests and subtests (441 top-level). 20 packages passed; 12 have no test files. Integration package: 763 passed. TRD 06 tests and subtests: 125 passed. `TestOutbox_DeliversThroughMailpit` ran and passed |
| Runtime OpenAPI contract checker | **318** distinct operation, status and code combinations, no violations. The only unexercised entries are the four pre-existing exceptions (`GET /readyz 503` / `not_ready`, `GET /v1/me 500` / `internal_error`); no TRD 06 response is exempted |

All verification used disposable loopback PostgreSQL and Mailpit with synthetic accounts, never a deployed server. The release gates in §12 (rollout order, provisioning, CLI access control, alerting) are deployment work that these tests do not prove. There are no known implementation blockers.

### 13.1 Audit history addendum — 2026-11-15

Added §9a: `GET /v1/admin/users/{user_id}/audit`. OpenAPI is now `1.6.0-trd06-audit`. There is no migration; the version stays **12**. Verified with the same commands against loopback PostgreSQL and Mailpit:

| Check | Actual result |
|---|---|
| `make sqlc-verify`, `make check`, `make build` | Passed |
| Full race run | **1206 passed, 0 failed, 0 skipped** tests and subtests (445 top-level). 20 packages passed; 12 have no test files. Integration package: 771 passed. The 3 `TestAdminAudit_*` tests with their subtests: 7 passed. Mailpit delivery ran and passed |
| Runtime OpenAPI contract checker | **326** combinations, no violations. Only the four pre-existing exceptions remain unexercised; every documented audit-history status and code was produced |
| Console against real Go (`make test-flutter-admin`) | Go test passed. Dart: 6 ran, 6 passed, 0 skipped (TRD 07 §10) |
