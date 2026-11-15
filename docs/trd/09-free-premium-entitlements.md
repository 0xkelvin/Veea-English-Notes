# TRD 09 — Free/Premium Entitlements

**Status:** v1.0. Nin approved the decisions on 2026-11-15. Plan management is implemented and locally verified (§11). No capability is gated by plan, and there are no payments.
**Date:** 2026-11-15
**Audience:** Backend, console and Flutter engineers, QA.
**Follow-up:** [TRD 10](10-server-delivered-cartridges.md), server-delivered cartridges as the proposed first Premium feature.

## 1. Decisions (Nin, 2026-11-15)

These replace the v0.1 draft's open items E1 to E5. They are recorded in Product Doc v0.5 §11.

| ID | Decision |
|---|---|
| E1 | Free and Premium are two plans, **separate from RBAC**. Premium is granted manually by staff. When a grant expires or is revoked, the account returns to Free and keeps all its data. |
| E2 | **Plan management only.** No capability is gated by plan in this change. Server-delivered cartridges are the *proposed* first Premium feature (TRD 10). Payments and plan-based enforcement are out of scope. |
| E3 | The TRD 05 limits stay **identical for both plans**: 50,000 live words, 64 MiB of content, 8 KiB per word, 20 sync writers. Export, deletion and reactivation access is unchanged and independent of plan. |
| E4 | Admins manage grants for User accounts; Super Admins for every other account; **nobody manages their own plan**. Every change needs a fixed reason code and a validated ticket reference. A grant must end at most 366 days after it is made. |
| E5 | The owner export includes the effective plan and the retained grant periods. It excludes staff identifiers, ticket references, reason codes and internal audit metadata. Retention and size limits are explicit (§4), and the worst-case export bound is re-verified (§7). Grant history is part of the account purge. |

Approved inputs that still hold:

- Product Doc §1: payments deferred, entitlements modeled.
- TRD 05 D7: the limits, and the rule that a lowered limit refuses only growth and never deletes words. No limit is lowered now.
- TRD 04: data rights.
- TRD 06: the actor revalidation, matrix, revision and no-op conventions.

## 2. Capabilities by plan

| Capability | Free | Premium |
|---|---|---|
| Everything that exists today (account, sessions, profile, email change, vocabulary sync at the TRD 05 limits, devices) | Yes | Yes, with the same limits |
| Export, deletion, deactivation, reactivation (TRD 04) | Yes | Yes. Never gated, on any plan, in any state |
| Admin console and RBAC (TRD 06, TRD 07) | By role only | By role only |
| Premium-only capabilities | — | None yet (TRD 10 proposes cartridges) |

## 3. Model

- **Plans are not roles.**
  - `users.role` decides administrative permission; the plan decides product capability.
  - A Super Admin is Free unless granted, and Premium gives no admin access (tested).
  - Plan changes never touch the role, sessions, `lifecycle_revision` or learning data, and role changes never touch the plan (tested).
- **Effective plan at database time `t`:** Premium if the account has an open grant with `starts_at <= t < ends_at`; otherwise Free.
  - There is one definition, the SQL function `entitlement_premium_until(user, t)`.
  - The owner read, the admin view and the mutation's no-op check evaluate it at `clock_timestamp()` when they read. The export evaluates it at its snapshot time.
  - Expiry is exact (Free from `ends_at` on) and needs no job.
- **One open grant per account** (unique partial index).
  - A new grant closes the previous open one as `replaced`. A revocation closes it as `revoked`.
  - An expired grant stays open until replaced or removed by retention. It is never effective.
- `entitlements.LimitsFor(plan)` returns the same TRD 05 limits for both plans (E3). A later decision changes only that function.

## 4. Storage: migration `00014_entitlements.sql`

- **`users.entitlement_revision`:** the retry guard. It is separate from `lifecycle_revision` and `role_revision`, so a plan change never invalidates proofs or role retries.
- **`entitlement_grants` columns:**
  - `id`, `user_id`, `plan = 'premium'`, `source = 'manual'`;
  - `starts_at`, `ends_at` (required);
  - `granted_by`, `reason_code`, `ticket_ref` (required);
  - `closed_at`, `closed_reason` (`replaced` or `revoked`), `closed_by`;
  - `close_reason_code` and `close_ticket_ref` (required exactly when revoked);
  - the generated `period_end = LEAST(ends_at, COALESCE(closed_at, ends_at))`.
- **Constraints:** `ends_at > starts_at`, `ends_at <= starts_at + 366 days`, and consistency of the closed fields. Indexes: `entitlement_grants_one_open`, `_owner` and `_retention`.
- **Ownership:**
  - `user_id` is `ON DELETE RESTRICT`: an erase that forgot the rows fails closed (tested).
  - The TRD 04 purge deletes them explicitly in step 2, before the final erase (`DeleteAccountEntitlementGrants`).
  - `granted_by` and `closed_by` have no foreign key, so they survive a staff purge.
- **Retention (explicit):**
  - A period is kept **180 days after `period_end`**, the audit retention. A bounded batch, `CleanupEntitlementGrants`, runs in the existing account-job cleanup list, so no new job key is needed.
  - **At most 50 retained periods per account:** each new grant prunes the oldest closed periods in the same transaction, keeping 49 plus the new one.
  - The export applies the same 180-day filter, so a period past retention is never exported, even before cleanup removes it.

## 5. Checks and effects

- **No capability check exists** (E2). The plan is readable by the owner and staff, and nothing refuses a request because of it.
- **Effect timing:** a grant or revocation is effective for every read that starts after its commit; expiry happens at `ends_at` by database clock.
- **Downgrade** (revocation or expiry) returns the account to Free. Because the limits are identical, nothing is refused, hidden, truncated or deleted: sync, export and deletion behave exactly as before (TRD 05 and TRD 04 suites unchanged).
- **Account states:** suspension, deactivation and reinstatement never change grants, and the expiry clock keeps running. A pending-deletion account refuses plan changes (`409 status_conflict`); the purge removes its grants.

## 6. API (OpenAPI `1.7.0-trd09`)

### 6.1 Owner: `GET /v1/me/entitlements`

This route is bearer-authenticated through `authenticated` and serves the caller only. No query parameters are allowed.

```json
{ "plan": "premium", "plan_expires_at": "2026-12-15T10:00:00Z",
  "limits": { "live_words": 50000, "content_bytes": 67108864, "writers": 20 },
  "checked_at": "2026-11-15T10:00:00.123456Z" }
```

`plan_expires_at` is the active grant's exclusive end, and null on Free. `checked_at` is the database time of the evaluation. `GET /v1/me` is unchanged.

### 6.2 Staff: `PUT /v1/admin/users/{user_id}/entitlement`

The route is `authenticated(requireStaff("plan_change", …))`. The body is strict:

```json
{ "plan": "premium" | "free", "ends_at": "<RFC 3339>" | null,
  "reason_code": "…", "ticket_ref": "…", "expected_entitlement_revision": 0 }
```

| Rule | Behavior |
|---|---|
| Who | `admin.Permits(…, ActPlan)`. An Admin manages User targets; a Super Admin every other account; never itself (`403 target_not_permitted`). A User actor gets `403 forbidden`. The actor's role, standing and acting session are revalidated **inside the write transaction** (L3 actor and target in UUID order, then L4a), exactly as in TRD 06. |
| Reasons | Premium: `support_courtesy`, `beta_access`, `partner`, `promotion`, `other`. Free: `granted_in_error`, `abuse`, `owner_request`, `ended_early`, `other`. |
| Ticket | Required for every change, using the TRD 06 pattern; nothing token-shaped. |
| Expiry | `premium` requires `ends_at`, and `free` requires null (`400 invalid_request` otherwise). `ends_at` must be after the **database time of the change** and at most 366 days later; otherwise `400 invalid_expiry`. It is stored at microsecond precision. |
| Order | Matrix → no-op → target state → revision → expiry range → write. |
| No-op | When the end state already holds (`free` on an effective Free plan, or `premium` with the same `ends_at` as the active grant), the answer is `200` with the current detail, no change and **no audit event**. This makes a retry after a lost response safe. |
| Revision | Otherwise `expected_entitlement_revision` must match, or the answer is `409 entitlement_conflict`. That blocks stale writes and ABA undo. |
| Write | `premium`: close the open grant (`replaced`), prune to 49 closed periods, insert the new grant starting at database time. `free`: close the active grant (`revoked`, with the reason and ticket). Then `entitlement_revision + 1` and the audit event, all in one transaction. |
| Response | `200 AdminUser`, which now has `plan`, `plan_expires_at` and `entitlement_revision`. `allowed_actions` includes `manage_plan` when permitted and the target is not pending deletion. |

Errors: `400 invalid_request` / `invalid_expiry`, `401`, `403 forbidden` / `target_not_permitted`, `404`, `409 entitlement_conflict` / `status_conflict`, `415`, `429` (the admin write limit), `500`.

### 6.3 Audit

| Event | Contents | History action |
|---|---|---|
| `admin.entitlement.grant` | Admin actor, target, acting session; `reason` = code; metadata `ticket_ref`, `ends_at`, `replaced`, `entitlement_revision` | `premium_grant` |
| `admin.entitlement.revoke` | Same; metadata `ticket_ref`, `entitlement_revision` | `premium_revoke` |

Both join the TRD 06 §9a audit history, whose field allowlist is unchanged. Expiry writes no event, because no transaction happens at expiry. The metric is `admin_actions_total{action="plan_change"}`, with results `success`, `noop`, `denied`, `conflict`, `invalid` and `error`.

## 7. Owner export (schema 3) and its bound

The export header gains an `entitlements` section between `account` and `vocabulary`, encoded by `entitlements.AppendExport` from the same REPEATABLE READ snapshot:

```json
"entitlements": { "plan": "free", "plan_expires_at": null, "retention_days": 180,
  "grants": [ { "starts_at": "…", "ends_at": "…", "ended_at": "…" | null,
                "status": "active" | "expired" | "replaced" | "revoked", "source": "manual" } ] }
```

- **Grants:** at most 50, newest first, only periods with `period_end` inside retention.
- **Status:** `expired` also covers a grant that was closed only after it had run out.
- **Excluded:** `granted_by`, `closed_by`, ticket references, reason codes, revisions and audit metadata (tested by scanning the downloaded file).
- **Schema version 3:** `account_operations.schema_version` is 3. Schema-2 artifacts published before the upgrade stay downloadable for their 24-hour window, because the chunk format is shared. OpenAPI `AccountExport` adds the optional `entitlements` object and `schema_version` `[2, 3]`.

**Bound.** Every value in the section has a fixed width: timestamps use the fixed `ExportTime` format, plus fixed enum strings. The section's maximum, `MaxExportSectionBytes`, is therefore **7,812 bytes** at 50 periods. `TestExportHeaderWorstCaseWithEntitlements` builds a pessimistic schema-3 header:

- the widest escaped display email: 1,024 input bytes, of which 254 ASCII escape to 6 bytes each and the rest are U+2028;
- 64 escaped display-name characters;
- a 255-character escaped time zone;
- 9999-12-31 timestamps and the maximum revision;
- 55 widest periods, capped to 50.

It measures **13,138 of 16,384 bytes** (`learning.MaxHeaderBytes`). The TRD 05 §11.1 total bound stays **79,225,248 plaintext bytes in 76 chunks**, unchanged, and the runtime header check still fails closed. The real-router test with 50 retained periods exports all 50 inside the bound.

## 8. Contracts preserved

| Contract | Result |
|---|---|
| TRD 05 vocabulary sync | Unchanged. The `word_limit` and `content_byte_limit` enums, quota outcomes and sync tables are untouched; the full TRD 05 suite passes. |
| TRD 04 export | Schema 3 is additive. Existing export, deletion and reactivation flows pass unchanged. Download accepts schema 2 or 3. |
| TRD 04 purge | Grant rows are removed in step 2. RESTRICT makes a missing step fail closed. Re-registration after purge starts Free with no history. |
| TRD 06 admin | Same conventions. `AdminUser` gains three fields and `allowed_actions` gains `manage_plan`, an **additive contract change** (§10). |
| TRD 07 console | Shows effective plan/expiry, capability-gated grant/revoke and labeled history actions. The UI amendment is delivered in TRD 07 §5b, verified in §10.1. |

## 9. Tests

The tests run through the production router against PostgreSQL in `backend/test/integration/entitlements_test.go`, plus unit tests.

| Test | Evidence |
|---|---|
| `TestEntitlements_GrantRevokeAndExpiry` | Free before a grant, with the TRD 05 limits and a database `checked_at`. Premium on the next request after a grant. Free after revocation. A grant ending 1.5 s later is Premium until database time passes `ends_at`, then Free with no row change. Role, lifecycle, learning heads and sessions are untouched. Export still works. |
| `TestEntitlements_ExpiryBoundaryIsExact` | At `starts_at - 1µs` Free; at `starts_at` Premium; at `ends_at - 1µs` Premium; at `ends_at` and after, Free. A closed grant is never effective. |
| `TestEntitlements_GrantAuthority` | 3 actor roles × {self, user, admin, super_admin} against E4. Refusals write nothing. Pending deletion `409`, unknown `404`. Nine invalid bodies `400`. A past or 367-day expiry gives `invalid_expiry`; 366 days minus a minute is accepted. |
| `TestEntitlements_RevisionRetryAndAudit` | Exact events. A grant retry and a revoke retry are no-ops with **no new audit event**. A stale revision gets `entitlement_conflict`. Replacement closes the old period. ABA: an old revoke cannot undo a newer grant. The history shows the four plan actions with the six allowlisted fields. Metrics. |
| `TestEntitlements_ConcurrentChanges` | Two Admins grant the same User while its row is held. Exactly one wins and the other gets `409`, leaving one grant, one event and revision 1. Grants to different accounts both succeed. |
| `TestEntitlements_IsolationAndRoleSeparation` | A grant to A leaves B Free. Users cannot grant to anyone. Premium gives no admin access. A role change keeps the plan. A Super Admin cannot grant itself, and `manage_plan` is never offered on one's own account. |
| `TestEntitlements_ExportContentsAndSize` | Revoked and replaced periods with statuses and no staff ID, ticket, reason or revision in the file. An active grant with its expiry. **60 seeded periods plus a new grant are pruned to 50** and the export stays inside its bounds. A period ended 181 days ago is not exported; one 179 days ago is. Schema version 3 in the operation row. |
| `TestEntitlements_PurgeAndRetention` | Direct erase blocked by RESTRICT. Deletion acceptance and purge remove the grants, then the account. Retention cleanup removes the 181-day-old period and keeps the 179-day-old one. |
| `TestEntitlements_ContractErrors` | Owner `400` and `429`; owner and admin `500`; admin path and body `400`; admin `429` with no state change. |
| `TestMigrations_EntitlementsUpgradeFrom13` | A populated version 13 upgrades without row loss. One-open-grant, 366-day period and closed-consistency constraints. Replay works. |
| `TestAudit_Matrix` "TRD09 plan management" | Exact grant and revoke events. |
| Unit | Plan matrix and reasons (`admin`), identical limits and export statuses and allowlist (`entitlements`), the worst-case schema-3 header (`lifecycle`). |

Updated existing tests for the additive contract: `manage_plan` in the TRD 06 matrix and suspension views, the new detail keys, export schema 3, the audit-history action count, and the schema and index lists. The console e2e expectations also include `manage_plan`.

## 10. Contract changes and open points

- **Additive changes for existing clients:**
  - `AdminUser` gains `plan`, `plan_expires_at` and `entitlement_revision`.
  - `allowed_actions` and the audit-history `action` enum gain new values.
  - Exports are schema 3.

  The TRD 07 console ignores unknown actions and supports the new plan actions and fields (§5b of that TRD); its 10 real-Go E2E tests pass (verification below). A client that rejects unknown enum values must be updated. Nothing in this repository does.
- **No unresolved contract conflict.**
- **Open:**
  - the first gated capability (TRD 10);
  - payments.

## 11. Verification record — 2026-11-15

Run from `backend/` against loopback-only disposable PostgreSQL and Mailpit. The migration version is now **14**.

| Check | Actual result |
|---|---|
| `make sqlc`, `make sqlc-verify` | Generated code up to date and reproducible |
| `make check` (gofmt, vet with and without the integration tag, unit tests) | Passed |
| `make build` | Passed (`bin/api`, `bin/migrate`, `bin/admin`) |
| `make test-alerts` (TRD 08, regression) | 11 rules; unit tests SUCCESS |
| Full race run, PostgreSQL + Mailpit (`go test -race -tags=integration -count=1 -json ./...`) | **1242 passed, 0 failed, 0 skipped** tests and subtests (465 top-level). 22 packages passed; 12 have no test files. Integration package: 800 passed. TRD 09 tests and subtests: 25 passed. Mailpit delivery ran |
| Runtime OpenAPI contract checker | **343** combinations, no violations. Only the four pre-existing exceptions are unexercised; every documented TRD 09 status and code was produced. The checker caught the missing `entitlements` property on `AccountExport` during implementation, and it was added |
| Admin console (`admin_console/`) | `flutter analyze`: no issues. `flutter test`: 31 passed, 6 skipped (e2e without its environment). `make test-flutter-admin` against real Go: 6 ran, 6 passed, 0 skipped |
| Worst-case export header | 13,138 of 16,384 bytes; the section bound is 7,812 bytes; the total export bound is unchanged at 79,225,248 bytes |

**Subsequent console UI verification (2026-11-15):** `cd admin_console && flutter analyze` has no issues. `flutter test --reporter json` passes **42**, fails **0** and skips **10** (E2E without its environment), including **11 new plan widget tests**. `make -C backend test-flutter-admin` runs all **10 E2E tests: 10 passed, 0 failed, 0 skipped**, including four new plan scenarios; the Go host passes **1**, fails **0**, skips **0** with `-race`. Its OpenAPI exchange and hygiene checks pass. TRD 07 §10.1 records coverage and commands. No backend contract changed or gap was found; the full backend suite above is the prior backend verification, not a new run for the console UI.

Staging, commits and pushes are left to Nin.
