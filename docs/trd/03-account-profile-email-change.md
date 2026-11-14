# TRD 03 — Account Profile & Email Change

**Status:** v1.0 — implemented and locally verified; Nin's product decisions were recorded on 2026-11-14 before implementation.
**Scope:** Own-account profile and verified sign-in email; account suspension, export and deletion remain separate work.

## 1. Authority and approved decisions

Sources: [AGENTS.md](../../AGENTS.md), [Product Doc v0.2](../product/user-management.md), [TRD 01](01-email-authentication-account-foundation.md), [TRD 02](02-session-management.md), and the current Go account, OTP, session, outbox, audit and OpenAPI code. Existing staged TRD 02 changes are dependencies and are preserved.

Nin approved the following, superseding the earlier draft options:

- Editable profile: `display_name`, `preferred_language` (`en`/`vi`), `time_zone` (IANA), and `daily_goal` (target words reviewed per day). No avatar or learning-progress counters.
- Email change requires a live session and two distinct OTP proofs, one for the current address and one for the proposed address. Both bind to the same request, owner and acting session. Existing OTP timing, attempts, cooldown and rate limits apply. Recovery without the old mailbox is deferred.
- Completion atomically revalidates the account/session, enforces normalized uniqueness, consumes both proofs, replaces the email, invalidates old-address login/reset proofs, revokes **all sessions including the caller**, and writes audits plus old/new notifications. The old inbox notification omits the new address.
- `user_id`, password state and all data ownership stay unchanged. The old address is released after commit; it is not an alias. A subsequent signup there has a different ID and receives none of the original data.
- No receipt endpoint or authenticated replay exception in this release. Lost-response recovery is the confirmation email or signing in with the new address. There is no unauthenticated reversal link.

Technical choices below implement those decisions. No old draft proposal for keeping the caller signed in, password-only recovery, staged proof grants, avatars or receipt reads remains binding.

## 2. Required OTP-core changes — specified before shared-code edits

The current core owns every challenge write. Keep that boundary and existing single-code behavior.

1. Add caller-bound `email_change_current` and `email_change_new` purposes and an immutable `change_id` binding. New challenge uniqueness is per `(change_id, purpose)`; existing public-purpose supersession excludes these rows. Other claimants on one destination cannot supersede each other's proofs. Recipient-wide cooldowns still protect the mailbox. Unlike public inert challenges, an occupied-destination proof retains the request owner/session binding, but `delivery=none` can never be consumed or queued; this narrow schema exception does not bind it to the destination owner.
2. Add core-owned pair start: precompute both tokens/codes, count existing limits outside the transaction, take both cooldowns in fixed purpose order (L1), then invoke a flow hook. The hook locks the prior pending change (L2b), user (L3) and acting session (L4a), closes a prior request and inserts a new owned request. The core inserts bound challenges/FKs, outbox and audit at L5. There is no early user FK key-share insert before the user lock.
3. Add core-owned pair verification: check both verify limits before the transaction; lock the challenge rows in UUID order at L2; validate distinct purposes/tokens, change ID, user/session binding, expiry and each five-attempt budget. Compare both codes. A wrong proof commits its own attempt/failure event and neither proof is consumed. Both valid proofs are consumed in the same transaction as the flow callback; internal or flow rollback restores both.
4. Add an `email_revision` snapshot to existing-user challenges and accepted data. Login/reset/set-password callbacks compare address and revision with the locked user. Password sign-in also compares the pre-hash-read email/revision at its final user lock, not only the password hash. This prevents old-address work from issuing credentials after cutover, including A → B → A reuse.
5. The cutover's revision increment logically invalidates all earlier bound proofs atomically. Do **not** lock/sweep old OTP rows after L3: an old verifier may hold L2 while waiting on that user. Existing bounded expiry cleanup eventually removes stale rows. Extend worker eligibility reads to reject stale revision/address and closed email-change requests; previously reserved sends may finish but their codes cannot work.
6. The unique email update needs a stronger L3 lock. Acquire `users FOR UPDATE` from the outset only for final cutover, before any session lock, rather than upgrading `FOR NO KEY UPDATE` later. This is a narrow amendment to TRD 01's user-lock-mode rule; other flows retain their existing mode. [PostgreSQL 17 row locking](https://www.postgresql.org/docs/17/explicit-locking.html#LOCKING-ROWS) documents the stronger mode for qualifying unique-key updates. Test FK inserts and competing issuance against it.

These changes do not make TRD 02 logout-all cancel OTP proofs. The invalidation is specific to committed email cutover. Existing opaque tokens, strict refresh rotation, provider timeout/lease/send budget and outbox idempotency are unchanged.

## 3. Profile contract

`GET /v1/me` retains its account fields and adds a required `profile` object, also used in the shared `User` embedded in token responses. The email field now describes the current verified sign-in address.

| Field | Validation / technical default |
|---|---|
| `display_name` | Nullable; trim/NFC, 1–64 Unicode characters when non-null, no controls; default null |
| `preferred_language` | `en` or `vi`; default `en` |
| `time_zone` | Valid IANA identifier, including UTC; reject `Local`, empty and invalid paths/offsets; default `UTC`; packaged tzdata available |
| `daily_goal` | Integer target words reviewed/day, 1–1000; default 20. A preference, never a counter or entitlement |
| `revision` | Read-only nonnegative profile version, initially 0 |

`PUT /v1/me/profile` replaces the four editable fields; all are required along with `expected_revision`. This full-replacement operation avoids implying partial-patch semantics. Example:

```json
{"expected_revision":0,"display_name":"Nin","preferred_language":"vi","time_zone":"Asia/Ho_Chi_Minh","daily_goal":20}
```

Return `200 User`. L3 user lock → eligibility → L4a acting revalidation → compare revision → update through `identity/accounts` → L5 audit → commit. Identical effective values at the expected revision are a no-op; stale revision gives `409 profile_conflict`. No session revocation or notification for profile updates. Lost responses are reconciled by GET me, without overwriting later edits. User ID, email, role, account status, password state, progress and avatars cannot be supplied as editable fields.

## 4. Email API and semantics

All new operations use `authenticated`. Only principal IDs authorize ownership; unknown and foreign request IDs have the same `404 not_found`. No role bypass. JSON writes use strict existing JSON decoding (16 KiB, exact keys, duplicates/unknown keys rejected); unsupported query parameters are refused.

| Operation | Input | Success |
|---|---|---|
| `POST /v1/me/email-change/start` | `new_email` | `202` with `change_id`, `current_email` and `new_email` challenge acknowledgements |
| `POST /v1/me/email-change/{change_id}/complete` | `current_challenge_token`, `current_code`, `new_challenge_token`, `new_code` | `204`, no tokens/body, after commit |

Each acknowledgement contains `challenge_token`, `expires_at`, `resend_after`. Both proofs expire after the existing ten minutes and allow five wrong attempts independently. Tokens and numeric codes are distinct; neither proof can be substituted for a login/reset/set/signup or another request/user/session. Start is not an email reservation. A repeated start closes the prior request, requires both codes again and observes normal cooldown/limits; it does not extend existing proofs.

Same-normalized-as-current gives `409 email_unchanged`. An occupied proposed address gets the same `202`, but its proposed-address challenge is inert and no mail is sent to that address. An available destination may be claimed by another account/signup before completion; final uniqueness then gives `409 email_unavailable`. Never disclose its owner's ID or merge accounts.

Completion takes L2 proof locks → L2b owned request → L3 user `FOR UPDATE` → L4a acting session. Source revision/address, active account, request expiry and origin session must still match. Replace the same user's display/normalized email, increment email revision, set verification time, revoke every unrevoked owned session at L4b with `email_change`, close the request, enqueue notifications and audit at L5. Core cancellation of the two consumed code emails is also L5. Commit before `204`.

A named email-unique violation rolls the **entire** transaction back (both proofs, email, sessions, notices and success audits). Map it to `409 email_unavailable` and record a fixed failure after rollback; do not write into an aborted transaction. Valid proofs may be retried until expiry, but cannot override the winner. Other internal failures roll back similarly. Whole-transaction retries reset local counts and do not duplicate events/notices.

After a successful completion, all access and refresh tokens fail, including any pair a concurrent winning refresh returned. A repeat normally gets `401`; a request authenticated before the winning commit may instead see consumed proofs and get `400 invalid_code`. Both are safe: no duplicate change, notification, account or grant. Do not treat either as proof that a previous request committed. On a timeout/lost response, keep the proposed address available in the client's recovery UI and instruct the user to check the confirmation email or sign in at the new address. No receipt/status endpoint, revoked-bearer replay or public result lookup exists.

Old address sign-ins stop working for the original account at commit. Issuance committing first is revoked by cutover; old-address work waiting on L3 is rejected by revision/address checks afterwards. Valid new-address sign-ins serialized later may issue a session. A stale challenge never becomes valid by cleanup delay or changing back to the same address.

## 5. Schema, messages and audit

Forward migration(s), never edits to applied files, add profile fields/revision and email revision to users; owned email-change requests; challenge revision/change binding; new purposes/templates; and the `email_change` revocation reason. Initial user/challenge revision is 0, matching the pre-feature immutable-email model; there is no NULL-means-skip path. New eligible bound challenges capture their account revision. Deploy revision-aware grant paths on all API instances before enabling email cutover in a mixed-version rollout.

Keep normalized uniqueness in `users_email_normalized_key`, existing normalization unchanged (NFC/lowercase, dots/+tags preserved). Pending signup is not ownership. Requests record immutable old/new addresses, owner, origin session, source revision, expiry and closure. FKs preserve user ownership/cascade conventions; request records are internal, not a receipt API. A bounded `email_changes` cleanup job removes requests 24 hours after expiry only when their challenge rows are gone. It uses an expiry index and the existing challenge-to-outbox cascade; no request grants survive expiry/closure.

Notifications use snapshotted recipients inside the successful transaction: one to the old inbox and one confirmation to the new inbox. The old body/subject contains **no new address**, including client-provided device text that could accidentally echo it; use fixed safe change context. Neither email offers an unauthenticated rollback. Send asynchronously using existing encrypted outbox behavior; delivery failure after commit does not revert the account. Provider acceptance is not inbox delivery.

| Producer | Transactional event |
|---|---|
| Profile effective update | `account.profile.update`, actor/target caller, acting session; changed field names/revision, no raw values |
| Pair start | Core purpose start events plus `account.email.change.start`, owner/session/request binding; no raw addresses/codes |
| Failed proof | Core fixed verification failure for the failed purpose; attempt increment commits, no successful change |
| Completion | `account.email.change.complete` plus `auth.session.revoke` reason `email_change`, actual string count, actor/target caller and acting session |
| Unique conflict | Fixed `email_unavailable` failure after rollback, no mutation-success event |

Audit writer/metadata conventions and redacting logging apply. No raw email/profile values, codes, challenge/session tokens/hashes, payloads or provider text in logs/audit. Metrics count transitions only after commit. Notification/audit failure rolls back the identity change and proof consumption.

## 6. Acceptance and verification

Router-level disposable-PostgreSQL tests must cover profile defaults/validation/revisions/ownership; proof purposes, distinct tokens/codes, user/session/request bindings, expiry, independent attempts and cooldown; concurrent claims including signup; all-token revocation; stable ID/password/data ownership after new-address sign-in; old-address release and stale login/reset/set proofs (including ABA); deterministic refresh/issuance/cutover orders; audit/outbox rollback and retry; notification recipient snapshots and omission of new address from old inbox; strict OpenAPI status/code/header checks and hygiene scans.

Follow the actual lock order using observed database waiters/barriers, not only random scheduling. Empty/previous-schema/replay tests cover migration constraints and old rows. Run from backend: `make sqlc`, `make sqlc-verify`, `make check`, `make build`, then existing loopback PostgreSQL/Mailpit scripts and the full `go test -race -tags=integration -count=1 -json ./...` with local test variables. Actual evidence is appended after implementation.

## 7. Conflicts resolved from the draft

Field names/goal semantics now match Nin's decision; profile uses full replacement PUT. Both proofs are consumed together, not staged grants. Completion revokes the caller too, returns 204 and has no receipt endpoint. Recovery without the old mailbox, avatars and counters are deferred. Old notification omits rather than masks the new address. Unique conflicts use whole-transaction rollback rather than a committed terminal proof failure. The narrow stronger L3 mode and pair OTP hooks above explicitly amend shared-code assumptions before editing them.

## 8. Implementation and verification record — 2026-11-14

Implemented on the existing branch without staging, committing or pushing. Existing staged TRD 02 work remains intact. Migration **00009_account_profile_email_change.sql** adds the profile/revision fields, owned request table and expiry cleanup index, paired-proof schema/indexes, email templates and revocation reason. `identity/accounts` owns user persistence; OTP core owns both proof writes. Router handlers use `authenticated`, the existing transaction/audit/outbox helpers, and the shared `User` projection. No Flutter implementation is included; the Product Doc explicitly schedules its rebuild after the backend.

Commands actually run from `backend/` (all service addresses are disposable loopback instances):

```sh
scripts/test-postgres.sh start
scripts/test-mailpit.sh start
make sqlc
make sqlc-verify
make check
make build
VEEA_TEST_DATABASE_URL=postgres://postgres@127.0.0.1:54329/postgres \
VEEA_TEST_SMTP_ADDR=127.0.0.1:1025 \
VEEA_TEST_MAILPIT_API=http://127.0.0.1:8025 \
go test -race -tags=integration -count=1 -json ./...
```

Final results: `make check` passed formatting, vet in both build modes and unit tests; `make build` built API and migration binaries; sqlc compile/regeneration verification passed. The full race run passed **907 tests/subtests, 0 failures, 0 skipped tests** (369 top-level tests): **402 unit + 505 integration**. Sixteen packages passed; twelve additional packages have no test files, not skipped test cases. Mailpit delivery ran and passed. Contract coverage checked **142 operation/status/code combinations**; the four existing explicit exclusions remain readiness `503`/`not_ready` (HTTP unit coverage) and GET me `500`/`internal_error` (shared error mapper). No new exclusions were added.

Acceptance evidence in `backend/test/integration/account_test.go` and `TestAudit_Matrix`:

| Tests | Actual evidence |
|---|---|
| `TestAccount_Profile` | Defaults, editable-field normalization/validation, revision conflicts/no-op, strict inputs, own-account isolation and transactional audit |
| `TestAccount_EmailCutoverAndRecovery` | Distinct current/new proofs and mailbox delivery; atomic consumption; caller/other access and refresh rejection; foreign session survives; original user ID/password/profile after new-email sign-in; old address released to a different new account; both notices and old-notice omission |
| `TestAccount_ProofBindingExpiryAndAttempts` | Owner, acting session, request and purpose binding, substituted login/duplicate/swapped tokens, either proof expiry, request expiry/closure, independent five-attempt budget and occupied-address inert proof/no mail |
| `TestAccount_ConcurrentEmailClaims`, `TestAccount_PendingSignupLosesToCutover` | Observed database waiters/advisory barriers force either user to win the same normalized address and signup/cutover to win in both orders; losing cutover is `409`, preserves its proofs/account/sessions, and cannot replace the winner |
| `TestAccount_EmailAuditOutboxRollback`, `TestAccount_CommitRetryAndDuplicateCompletion`, `TestAccount_ConcurrentCompletionIsSafe` | Injected audit/outbox failures roll back email, consumption, sessions and notices; forced `40001` retries commit once; an authenticated overlapping duplicate gets `400`, subsequent revoked-bearer retry gets `401`; no duplicate success/notifications/metrics |
| `TestAccount_StaleChallengesAndABA`, `TestAccount_PasswordReadBeforeCutoverRejected` | Old login/reset/set proofs rejected; fresh B sign-in works; A → B → A does not restore old proofs; password verification paused before cutover cannot issue on the stale email snapshot |
| `TestAccount_EmailVsIssuance`, `TestAccount_EmailVsRefresh`, `TestAccount_ActingRevalidationInsideTransaction` | Deterministic issuance-before/cutover-before and refresh-before/cutover-before (caller and other device); winning issued/rotated pairs are revoked; later stale issuance/refresh refused; logout after authentication prevents each management write |
| `TestAccount_EmailContractErrors`, `TestAccount_RateLimitsAndWriteFailures`, existing spec-driven router checks | Real router status/code/header contract, unknown/foreign request equivalence, strict body/media/query validation, all new route limits and internal errors |
| `TestMigrations_AccountUpgradeFrom8`, existing clean/replay/schema tests, `TestAccount_ExpiredRequestCleanup` | Empty/previous schema, populated version 8 → 9 without data loss, replay and constraint compatibility, initialized defaults/revisions, bounded expired-request cleanup preserving live requests |

The first regression attempts exposed obsolete outbox fixtures that bound login mail to an address different from its user, historical migrations expecting the newest schema, an unquoted YAML flow description, and a media-type test sending literal path placeholders. These were corrected and the final full run above passed. Hygiene scans include nested proof tokens, OTPs and passwords; no provider/live-account credentials were used.

**Contract amendments, with no unresolved design conflict:** three authenticated operations were added; `User.profile` is required in GET me and token responses; four new fixed error codes are `invalid_profile`, `profile_conflict`, `email_unchanged` and `email_unavailable`. Profile uses revision-checked full replacement PUT. TRD 01 now explicitly records the narrow stronger L3 email-key lock, L2b request lock, revision-aware grant checks, and owned inert-pair binding exception. Public OTP inert behavior and TRD 02 logout-all semantics remain as recorded.

**Remaining release gates:** deploy migration 00009 before the matching binaries and ensure all instances enforce email revisions before enabling cutover; verify the Resend sending domain/permission and real OTP/security-notification inbox delivery; measure AC-7 timing in staging. Local passing tests establish neither real delivery nor timing indistinguishability. Old-mailbox recovery, receipt endpoints, account suspension/export/deletion, avatar/progress work and Phase 5 alerting remain in their separate existing scope. R12 remains **Resend selected**, with its existing delivery-readiness gates.
