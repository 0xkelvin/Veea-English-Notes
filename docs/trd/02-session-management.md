# TRD 02 — Session Management

**Status:** v1.0 — finalized for implementation; Nin approved bearer authentication and the lock-order semantics on 2026-11-14.
**Date:** 2026-11-14
**Audience:** Backend, Flutter and QA engineers.
**Implementation status:** Implementation and verification are recorded in §9. The decisions below were recorded before implementation.

## 1. Authority and scope

Sources for this design:

- [Product Doc v0.2](../product/user-management.md), §3, §5.1 decisions 11–12, §5.4 follow-up flows, §5.6, §7 and AC-17–19, AC-24–25.
- [TRD 01](01-email-authentication-account-foundation.md), §5.1–5.3, §6.5–6.6, §7.1, §7.6–7.7, §8.1, §8.4–8.7, §10–11 and §12. Existing decisions, including R1–R4 and R11, remain in force.
- Baseline read before implementation, commit `3007890`: [session service](../../backend/internal/auth/session/service.go), [issuance primitive](../../backend/internal/auth/session/session.go), [HTTP handlers and bearer middleware](../../backend/internal/auth/httpapi/httpapi.go), [session SQL](../../backend/internal/platform/db/queries/sessions.sql), [schema](../../backend/migrations/00003_sessions.sql) and [OpenAPI contract](../../backend/api/openapi.yaml).

**[Approved product behavior]** Product Doc v0.2 approves device listing, revoking an individual other session, and user-initiated sign-out on all devices as deferred follow-up scope. Each successful sign-in creates its own session; signing out of the current device affects only that session. Revoked sessions cannot refresh. Session revocations must produce secret-free audit evidence, and retries must leave consistent account state.

**Approved decisions (Nin, 2026-11-14; recorded before implementation)**
- A valid bearer session is sufficient for all three operations; no fresh OTP or password proof is required. The client asks for explicit confirmation before logout-all, explaining that this device is included. Confirmation is client UX, not a server-supplied proof field.
- Management writes and session issuance serialize on the existing `users FOR NO KEY UPDATE` lock. Management writes revalidate the acting session inside the transaction in the existing lock order.
- Logout-all revokes every session preceding it in that lock order, including the caller. Valid sign-ins serialized afterwards may issue a new session. Pending login proofs are not cancelled. Refresh cannot restore a revoked session.

**Technical contract:** The endpoint, field, error, transaction and audit choices below finalize the draft within these decisions. Existing behavior is explicitly identified as **[Existing]**.

This TRD covers only:

1. Listing the signed-in user's live device sessions, including the current session.
2. Revoking one other session owned by that user.
3. Signing out of all sessions, including the caller's current session.

Out of scope: email/profile changes, session renaming, a persistent physical-device registry, admin revocation, account status changes, account deletion/export, token redesign, new token lifetimes, refresh grace, push disconnects, new email notifications, and blocking future sign-ins. Existing password and automatic-revocation flows are regression dependencies, not redesigned features. Audit viewing and alerting stay in their existing Phase 5 scope.

## 2. Existing model and identity

**[Existing]** `sessions` holds a PostgreSQL row per successful registration/sign-in. Its UUID is returned as `TokenResponse.session_id` and survives refresh rotation. Tokens are opaque; PostgreSQL stores hashes. Refresh replaces both current token hashes in the same row. A session has device name/platform, creation and last-seen times, idle/absolute expiry, and revocation time/reason. There is no trusted hardware identifier.

**[Technical decision]** A displayed device means one session, not one physical installation. Two logins named “My phone” remain two entries and two revocation targets. Device names and platforms are client-supplied descriptions, not authentication evidence. Clients render names as plain text.

The server identifies the current session solely from `Principal.SessionID`, obtained from the bearer token by `authenticated`. `is_current` is computed by comparing each row ID with that principal. Never accept a current-session ID, user ID, role or device name from the request as authorization. The client may use its stored `session_id` for presentation, but the response is authoritative. A UUID by itself is not a credential.

### 2.1 Active/listable criteria

**[Existing]** Access authentication checks an unrevoked row, future access and absolute expiries, and an active account with verified email. Refresh instead checks future refresh and absolute expiries and the same account eligibility. The session cap counts unrevoked, refresh-valid, absolute-valid rows; access expiry is not part of that count.

**[Technical decision]** List every owned row for which at least one credential can still be useful at database time `t`:

```sql
WHERE user_id = $authenticated_user_id
  AND revoked_at IS NULL
  AND absolute_expires_at > $t
  AND (refresh_expires_at > $t OR access_expires_at > $t)
ORDER BY last_seen_at DESC, id ASC
```

Here `$t` denotes one database `now()` value for the list statement, not a client timestamp. Equality with an expiry is expired. An expired access token does not hide a session that can refresh. A refresh-expired row with a still-valid access token remains visible because the current authentication query still permits that access token. Both credentials expired, absolute expiry, or revocation excludes the row.

Normal issuance/rotation caps access expiry at or before refresh expiry, so this normally matches the existing cap's active set. The explicit OR also covers inconsistent/legacy rows without silently hiding usable access. **Do not change the cap or authentication predicates in this feature.** Do not reuse `CountActiveSessionsForUser` as the list query.

The list is one statement snapshot, including revalidation of the caller against the existing access/account criteria. Return `401` if the caller ceased to qualify before that snapshot; otherwise the current row appears exactly once. This check uses trusted user/session IDs, like `LockActing`; an already-authenticated request need not present a second token when its current session rotates in flight. A revocation after the snapshot may make the list stale before it arrives. Listing does not lock other sessions or promise live presence.

## 3. HTTP contract

All operations require exactly one `Authorization: Bearer vat_…` header and must be wrapped by `authenticated`. Refresh tokens authenticate only the existing refresh endpoint. Admin roles receive no cross-account exception here. Reuse the existing per-session request limit (600/minute by default), `429 rate_limited` and its `Retry-After`; no additional management limit is introduced.

| Operation ID | Method and path | Success | Purpose |
|---|---|---|---|
| `listSessions` | `GET /v1/me/sessions` | `200 SessionList` | Complete list for the authenticated account |
| `revokeSession` | `DELETE /v1/me/sessions/{session_id}` | `204`, empty body | Revoke one other owned session |
| `revokeAllSessions` | `DELETE /v1/me/sessions` | `204`, empty body | Sign out all sessions, including the acting one |

`DELETE` means logical revocation, not physical deletion. Existing `POST /v1/auth/logout` remains the current-device-only operation, with its existing contract.

These operations take no request body. As with existing logout, an unexpected body is ignored and supplies no authorization or command fields; there is no JSON content-type requirement or `415` response. No query parameters are supported; **[Technical decision]** reject any supplied query parameters with `400 invalid_request` rather than imply filters were applied. The item path must be a valid nonzero, 36-character hyphenated UUID; malformed/nil UUID gives `400 invalid_request`. Authentication runs before path/query validation.

Every response has `X-Request-Id` and `Cache-Control: no-store`. JSON uses `application/json`; errors use the existing RFC 9457 `application/problem+json` shape (`type`, fixed `title`, `status`, stable `code`, `request_id`). All timestamps are RFC 3339 UTC. `204` responses have no JSON body. Preserve the existing router's `404`/`405` behavior, `Allow` header, and refusal to serve `HEAD`.

### 3.1 List response

```json
{
  "current_session_id": "019a7d93-4c00-7000-8000-000000000001",
  "sessions": [
    {
      "id": "019a7d93-4c00-7000-8000-000000000001",
      "device_name": "My phone",
      "platform": "ios",
      "created_at": "2026-11-14T01:00:00Z",
      "last_seen_at": "2026-11-14T02:00:00Z",
      "refresh_expires_at": "2026-12-14T01:00:00Z",
      "absolute_expires_at": "2027-02-12T01:00:00Z",
      "is_current": true
    }
  ]
}
```

| Field | Type and meaning |
|---|---|
| `current_session_id` | Required UUID; authenticated session ID |
| `sessions` | Required array; ordered by `last_seen_at DESC, id ASC`, never null |
| `sessions[].id` | Required session UUID; identifies the revocation target |
| `device_name` | Required string; stored sign-in label (1–64 characters) |
| `platform` | Required enum: `ios`, `android`, `web`, `other` |
| `created_at` | Required timestamp; when this session was issued |
| `last_seen_at` | Required timestamp; approximate activity, not online status |
| `refresh_expires_at` | Required timestamp; current refresh idle deadline, not a guarantee of future eligibility |
| `absolute_expires_at` | Required timestamp; fixed maximum lifetime |
| `is_current` | Required boolean, derived by the server |

**[Technical decision]** No pagination in this bounded account-management view. Normally there are at most 20 entries under the existing cap; do not enforce `maxItems: 20` or silently truncate because §2.1 deliberately also exposes any access-only live rows. Return the complete matching set. A future larger session policy would require revisiting this choice.

Use an explicit response DTO/projection, never serialize `sqlc.Session`. Do not expose access/refresh tokens or hashes, consumed tokens, IP addresses, user agent, email, rotation counter, revocation history or owner IDs. No geolocation lookup is included. `last_seen_at` may lag by five minutes because access authentication throttles touches; refresh also updates it. Middleware's existing touch is retained. Neither timestamp order nor device name is proof of identity.

### 3.2 Errors and ownership

| HTTP / code | Applies to | Meaning |
|---|---|---|
| `400 invalid_request` | All | Unsupported query parameters; item DELETE also malformed/nil path UUID |
| `401 unauthorized` | All | Missing/invalid/expired/revoked bearer, ineligible account, or acting-session revalidation failed; include `WWW-Authenticate: Bearer` |
| `404 not_found` | Item DELETE | Target does not exist or is not owned by the caller; same public response apart from request ID |
| `409 current_session_not_allowed` | Item DELETE | Target is the acting session; use existing current logout or collection DELETE |
| `429 rate_limited` | All | Existing authenticated request limit refused the request; no management mutation |
| `500 internal_error` | All | Internal failure; no database error text in the response |

Every target lookup/update uses `id = $target AND user_id = $principal_user`. Never load an arbitrary session and then disclose its owner. The ownership-scoped lookup includes retained expired/revoked rows so a repeated revocation can be recognized. A retained, already-revoked owned target returns `204` with its original timestamp/reason unchanged. An expired but unrevoked owned target is marked revoked too; stale list entries remain actionable. The acting session is always refused by item DELETE, including when no other sessions exist.

## 4. Revocation and transaction design

### 4.1 State and schema

**[Technical decision]** Reuse `sessions.revoked_at` and `revoked_reason`. Add fixed reasons `user_revoked` (one other session) and `logout_all` (all devices). Do not reuse `password_reset`, since this operation does not change credentials.

Implementation uses forward migration `00008_session_management.sql` extending the existing `sessions_revoked_reason_check` constraint. Do not edit applied migration `00003`. Preserve all existing allowed reasons and rows, make the replacement/replay safe, and verify empty-database and previous-version upgrades. No new session/device table, token columns or account-wide revocation epoch is introduced.

Keep the token hashes and consumed-token rows under existing retention/cleanup. Revocation makes the row unusable immediately without deleting history or depending on cleanup. Existing `sessions_user_active (user_id) WHERE revoked_at IS NULL` supports owner-scoped listing/bulk updates; the target uses the primary key plus owner predicate. No new index was added for this bounded account view; no new performance benchmark is claimed.

### 4.2 Management write transaction

Both writes use the existing `db.Tx` READ COMMITTED transaction helper:

1. **L3:** lock the authenticated user's row with `LockUserForNoKeyUpdate`; recheck active status and verified email. Missing/ineligible user returns `401`.
2. **L4a:** lock/revalidate the acting session by trusted user/session IDs using `LockActingSessionForUpdate`: unrevoked, access-valid, absolute-valid. Failure returns `401` and changes nothing. Middleware authentication alone is insufficient after waiting on L3.
3. **L4b:** item DELETE rejects the current ID, then locks only the owner-scoped target and marks it revoked if `revoked_at IS NULL`. Collection DELETE revokes **all unrevoked rows** for that user, including the already-locked acting row, with no keep-session exclusion. Reuse `RevokeAllSessionsForUser`'s update semantics; do not call an audit helper that omits the user actor required by §6 without adapting it.
4. **L5:** insert the required audit events in the same transaction. Commit before returning `204`; count metrics only after commit.

Collection DELETE includes retained, already-expired but unrevoked rows. Audit/metric counts are actual rows transitioning from unrevoked to revoked, not the size of the visible list. Already-revoked rows keep their earlier reason/time. No partial batch or asynchronous job is used for this account-scoped operation.

Management writes serialize through L3 with each other, sign-in issuance, password mutations and cap eviction. Never lock a target session and then request the user lock. Refresh/logout keep their existing session-only L4a → L5 order and never acquire L3 afterwards. This also prevents opposing A-revokes-B/B-revokes-A requests from locking acting rows in opposite order.

Do not acquire OTP/outbox locks or cancel pending challenges in this flow. No email, provider call or other external effect occurs inside the transaction. Reset all per-attempt result/count state when the transaction helper retries `40P01`/`40001`; failed attempts must not duplicate events or post-commit metrics.

### 4.3 Effect and retry semantics

- A revocation commit invalidates both access and refresh credentials for the affected row. A protected request whose authentication snapshot starts after commit returns `401`; there is no 15-minute grace or positive authentication cache.
- A request authenticated before commit can still complete. These management writes additionally revalidate under lock; this TRD does not promise to cancel arbitrary in-flight requests or roll back work already committed elsewhere.
- Item DELETE is state-idempotent while the caller remains authorized: first transition returns `204`; a retry against a retained revoked owned row returns `204` and adds no second revocation event/count. After retention cleanup removes the target, it may return `404`; absence is not a receipt proving who revoked it.
- Collection DELETE revokes the caller too. A retry with that bearer normally returns `401`, matching current logout. The client clears its local tokens after `204` or `401`, and does not refresh to retry logout-all. `401` alone is not proof that every other session was revoked.
- If the all-device response is lost, the client is locally signed out but cannot prove whether the transaction committed. No durable operation receipt or replay bypass is included. A later sign-in followed by a new collection DELETE is a new operation, covering a new set of sessions.
- A `500`, disconnect or client timeout may hide a committed result. Item DELETE can be retried/reconciled through a fresh list while the caller is still authorized. For collection DELETE, use the unknown-outcome behavior above; do not claim a timeout means rollback.
- Do not introduce an unauthenticated idempotency cache or accept the revoked bearer as a retry credential. Strict refresh rotation and consumed-token reuse behavior remain unchanged.

## 5. Defined concurrent outcomes

**[Technical decision]** Order is determined by database locks/commits, not HTTP arrival time or token-generation time. In each successful all-device operation, the user lock forms a boundary for session issuance. Existing credentials still permit a genuinely later sign-in; this action is not a password reset or account freeze.

| Overlap | Expected result |
|---|---|
| Target B refresh commits before A revokes B | Refresh may return `200`; revoke then updates the same stable B row after waiting. B's newly returned access and refresh tokens fail after the revocation commit |
| A revokes B before B refresh obtains its lock | Refresh sees revoked state and returns `401`; no new usable pair. A and unrelated sessions survive item DELETE |
| Collection DELETE overlaps any refresh, including the caller's | If refresh wins its row lock, its rotated row is subsequently revoked. If revocation wins, refresh fails. Final affected rows are revoked; even a delayed `200` refresh response contains unusable tokens |
| Acting session rotates after authentication but before management revalidation | If it remains otherwise eligible, the authenticated in-flight operation may continue by stable session ID. Original bearer need not still be the current hash; both pre- and post-rotation pairs are unusable if collection DELETE commits |
| Acting session is logged out, revoked, reset or evicted before management revalidation | Management returns `401`, changes no target, and writes no management-success event |
| New session C commits before collection DELETE obtains L3 | C is included and revoked, even if its sign-in response arrives later |
| Collection DELETE obtains L3 before C's issuer | Issuance waits; after revocation commits it rechecks account/credentials using its existing rules and may create a new valid C. A pending OTP login completing afterwards can likewise create C; challenges are not cancelled |
| Item DELETE overlaps a new sign-in | Only the addressed UUID is revoked. A newly issued row is unaffected, even with the same device name; existing cap eviction may independently invalidate the caller before revalidation |
| Two same-target DELETEs, or two collection DELETEs | Same-target requests from a surviving caller both return `204`, with one transition/event. Collection requests both authenticated earlier serialize; after the first commits, the second revalidation returns `401` |
| A revokes B while B revokes A | L3 serializes them. The first valid operation succeeds; the second caller is then revoked and returns `401`. No deadlock or cross-account effect |

A list concurrent with issuance/revocation may show the before or after statement snapshot; it never mixes owners or claims a refresh/liveness guarantee. Revocation always targets the supplied UUID, not “the session currently using this name.”

## 6. Audit and observability

**[Existing]** `audit.Record` writes on the caller's transaction, and its metadata is `map[string]string`. Keep fixed codes and string counts to match that writer. For all new successful user actions set `actor_user_id = target_user_id = principal.UserID` and `session_id = principal.SessionID` (the actor, not the other device). Preserve resolved IP, sanitized user agent and request ID using existing helpers.

| New flow | Events committed with the mutation |
|---|---|
| One other row transitioned | One `auth.session.revoke`, outcome `success`, metadata `reason=user_revoked`, `count="1"`, `target_session_id=<owned target UUID>` |
| All-device sign-out | One `auth.logout.all`, outcome `success`, metadata `revoked_sessions=<string count>`; plus one aggregate `auth.session.revoke`, outcome `success`, metadata `reason=logout_all`, `count=<string count>`. Acting session is included in the count |
| Already-revoked target; missing/foreign target; self-target refusal | No new successful revocation event and no revocation metric. `404`/`409` refusals are not represented as successful security mutations |
| List, validation/authentication refusal, rolled-back mutation | No new management audit event. Existing middleware/refresh/rate-limit producers keep their current behavior |

Do not emit one extra `auth.logout` for the acting row when handling collection DELETE; that action retains its current-device endpoint meaning. Do not rewrite old producer semantics to make historical `session_id` fields match this new convention. Extend TRD 01 §11.1's producer matrix and `TestAudit_Matrix` during implementation.

After commit, increment `auth_sessions_revoked_total` by actual transitions using fixed `user_revoked`/`logout_all` constants (the existing metrics helper validates label format; it has no reason allowlist). A failed/no-op attempt increments neither. Audit-insert failure rolls back the revocation; transaction retries commit each event once. Logs and audits contain no tokens, token hashes, OTPs or payloads. Do not log session-list response bodies or arbitrary device text. No new email or Phase 5 alerting project is part of this TRD.

## 7. Router-level PostgreSQL verification

The implemented tests use the production `app.New` router, bearer middleware, real use cases, migrated disposable PostgreSQL and the existing OpenAPI response-contract wrapper. Synthetic fixture issuance uses the existing transaction-scoped issuance primitive; the issuance races exercise real password-login and OTP-verify routes. SQL arranges expiry, lock scheduling and injected failures. Access and refresh rejection are asserted through the real endpoints, not inferred only from `revoked_at`.

| Implemented test | Evidence |
|---|---|
| `TestSessionManagement_ListOwnLiveSessions` | Owned membership, foreign exclusion, duplicate labels, current marker, access-only and refresh-only live rows, both-expired/absolute-expired/revoked exclusion, tie ordering and exact public projection |
| `TestSessionManagement_OwnershipRevocationAndRetries` | Passwordless bearer sufficient; admin has no ownership bypass; unknown/foreign targets return identical normalized `404`; self `409`; invalid/nil/compact UUID `400`; current and consumed token pairs fail after revocation; other sessions/accounts survive; retained no-op preserves original time/reason and metric count |
| `TestSessionManagement_LogoutAllAndContractErrors` | Current/other sessions lose both token types, expired unrevoked rows are included, foreign account survives, retry with revoked bearer is `401`, query selectors refused and supplied bodies ignored |
| `TestSessionManagement_AuthenticationAndListRevalidation` | Expired access/absolute expiry, revocation and ineligible accounts fail all routes; list snapshot rejects a caller revoked after the middleware authentication read |
| `TestSessionManagement_RateLimitsAndInternalErrors` | All operations exercise documented `429` and `500`; limited requests leave session state unchanged |
| `TestSessionManagement_TransactionalAuditAndRetry` | Audit failure rolls back revocations and the earlier bulk-command event; both tokens remain usable. A forced `40001` retries once, committing exactly one event set and one metric count |
| `TestSessionManagement_LogoutAllVsIssuance` | Both L3 orderings forced separately for password login and OTP verify: preceding issuance revoked, subsequent issuance usable with both tokens |
| `TestSessionManagement_RefreshRacesAndActingRevalidation` | Both orderings for refresh versus item/bulk revocation, including current-session refresh; returned rotated pairs fail after revocation. Acting logout after middleware authentication invalidates the management write |
| `TestSessionManagement_ConcurrentMutations` | Same-target retries, opposing A/B revocations and two bulk requests serialize without duplicate transitions/events |
| `TestAudit_Matrix` (session-management case) | Exact actor, target, acting-session ID, owned target metadata, string counts, event ordering and no-op behavior |
| `TestMigrations_SessionManagementUpgradeFrom7`, existing clean-schema/replay/schema tests | Version 7 → 8 preserves counts, accepts every old/new reason and rejects invalid reasons; empty migration and replay remain valid |

Race tests hold a transaction at a session-row lock or an audit-insert advisory gate, then observe both lock waiters before releasing it. This proves the first operation owns L3 (or the refresh row), rather than relying on goroutine timing or sleeps alone. Final state and both token types are checked after the requests finish. Existing password set/change/reset concurrency tests remain regression coverage for the shared lock order.

Every test environment runs the existing hygiene scan over logs, audit metadata, stored text and error bodies using the actual synthetic secrets it issued. The normative OpenAPI spec includes all new statuses/codes; API tests check router/spec parity and the integration wrapper checks runtime exchanges. No unauthenticated replay cache or real email provider is used.

Verification commands from `backend/`, using local services only:

```sh
make sqlc
make sqlc-verify
make check
make build
scripts/test-postgres.sh start
scripts/test-mailpit.sh start
VEEA_TEST_DATABASE_URL=postgres://postgres@127.0.0.1:54329/postgres \
VEEA_TEST_SMTP_ADDR=127.0.0.1:1025 \
VEEA_TEST_MAILPIT_API=http://127.0.0.1:8025 \
go test -race -tags=integration -count=1 -json ./...
```

The scripts bind disposable services to loopback. Use their `stop` commands to discard them after use. Do not run these tests against a deployed server or production database. Actual results are recorded in §9; earlier TRD 01 results do not stand in for TRD 02 verification.

## 8. Decision record

| ID | Status | Decision |
|---|---|---|
| SM-1 | Approved product scope | List own devices, revoke one other session, sign out all devices; approved as follow-up scope in Product Doc v0.2 |
| SM-2 | Technical decision | Three resource operations in §3; derive current device from the bearer principal; one entry per session, no hardware registry |
| SM-3 | Technical decision | List sessions with usable access **or** refresh (§2.1), keep existing issuance cap unchanged, show minimal metadata without IP/location/history |
| SM-4 | Technical decision | Reuse PostgreSQL revocation fields, add two allowed reasons by forward migration, L3 → L4a → L4b → L5 for management writes |
| SM-5 | **Approved by Nin, 2026-11-14** | Valid bearer authentication is sufficient, including passwordless accounts. Client confirmation is required before logout-all; no server step-up proof |
| SM-6 | **Approved by Nin, 2026-11-14** | Logout-all includes the caller and sessions preceding it under L3. Valid issuance afterwards may succeed. Refresh cannot resurrect revoked rows; existing credentials and pending login codes remain valid |

SM-5 and SM-6 are resolved. No account-wide credential barrier or fresh-proof flow is introduced.

## 9. Implementation and verification evidence

**Recorded 2026-11-14.** Implemented on `feat/go-email-auth-account-foundation`, baseline `3007890` plus the current uncommitted session-management changes. No staging, commit or push was performed by the implementation task; existing staged content was preserved.

- Added the three §3 operations through the real bearer-protected router. OpenAPI is now `1.1.0-trd02`; it specifies the minimal session projection, ignored bodies, rejected query parameters, standard UUID paths, retained-row retry behavior, generic owner-scoped `404`, and `409 current_session_not_allowed`.
- Added `00008_session_management.sql` for `user_revoked` and `logout_all`. Empty-schema migration, replay, populated version-7 upgrade, old/new reason acceptance and invalid-reason rejection passed. Existing cleanup-index tests still explicitly test the version-6 → 7 transition rather than treating version 8 as version 7.
- sqlc output was regenerated and verified reproducible. Management writes use existing account/session locks, revocation queries, transaction retries and `audit.Record`. Counts reach metrics only after commit. The audit producer matrix and its router test include both new flows.
- Deterministic race checks covered both orderings for real password login and OTP verification, current/other-session refresh, single-session revocation and concurrent management writes. The issued token pairs are checked through access and refresh routes after the competing operations finish.

| Check | Actual result |
|---|---|
| `make sqlc` and `make sqlc-verify` | Passed; generated code reproducible |
| `make check` | Passed formatting, vet with/without integration tag, and unit tests; 15 test-bearing packages |
| `make build` | Passed API and migration binary builds |
| Full command in §7, PostgreSQL + Mailpit with `-race -tags=integration -count=1 -json ./...` | **845 passed (352 top-level), 0 failed, 0 skipped tests**. Counts include parent tests and subtests. 16 test-bearing packages passed; 11 packages have no test files |
| Integration package | **443 passed, 0 failed, 0 skipped**; session-management cases account for 33 passes including subtests |
| Runtime OpenAPI contract checker | **116 distinct operation/status/code combinations**, no violations. Existing exceptions remain `GET /readyz 503`/`not_ready` and `GET /v1/me 500`/`internal_error`; no new operation is exempted |
| `TestOutbox_DeliversThroughMailpit` | Ran and passed |

All verification used disposable loopback PostgreSQL and Mailpit plus synthetic data, never a deployed server or live provider. Raw test-event logs are local temporary files, not committed fixtures.

**Unresolved design conflicts:** None. Client confirmation and unknown-outcome behavior are specified here for the future Flutter client; this backend change does not rebuild that UI. Existing TRD 01 release checks (Resend domain/real delivery and AC-7 timing) and Phase 5 alerting retain their prior scope.
