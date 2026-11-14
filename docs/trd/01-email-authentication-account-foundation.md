# TRD 01 — Email Authentication & Account Foundation

**Status:** v0.4. Decisions R1–R11 and R13–R15 approved (2026-11-13); R12: Resend selected (2026-11-14)
**Date:** 2026-11-13
**Source of scope:** [User Management Product Doc **v0.2**](../product/user-management.md), §5 (Phase 1 approved decisions) and §13 (acceptance criteria AC-1 to AC-28)
**Audience:** Backend engineers implementing the Go service, QA, and the engineers who will rebuild the Flutter client

### Changes in TRD v0.4
- **Approval record (§14, 2026-11-13):** R1–R11 and R13–R15 are recorded as approved. R12 was subsequently selected as Resend on 2026-11-14; see §8.3 and §14.
- **Lock order (§7.1, §7.3, §7.5):**
  - Code validation is one shared procedure V that touches only the challenge row (L2).
  - Outbox cancellation is an L5 write, made after the user and session locks the flow needs.
  - Each flow's transaction boundaries are explicit: pre-check, main transaction, failure-audit transaction, and post-commit counter.
- **Outbox send budget (§6.7, §6.10, §8.2, §8.3):**
  - At most 5 application-initiated provider sends per row, each durably reserved under a live lease before the call.
  - Skipped claims consume no budget.
  - A reaper makes exhausted or expired rows terminal after a crash.
  - Every result write requires a matching, **unexpired** lease and `pending` status.
- **Change password (§5.2, §5.4, §12.2):** `password_changed_at` is informational only, and the client-clock comparison is removed. Unknown-outcome UX is documented, and the AC-25 test expectations are updated. This replaces v0.3's "confirm via `password_changed_at`".
- **Tests (§12.3):** lock-order, transaction-boundary, send-budget and crash-recovery tests added or updated.

### Changes in TRD v0.3
- **Locking (§7.1):**
  - One global lock order and one lock mode per table.
  - The `users` row is locked `FOR NO KEY UPDATE` (TRD 03 final email cutover alone takes `FOR UPDATE` from the outset for its unique key), never `FOR SHARE`, so no transaction upgrades a shared lock to an exclusive one.
  - Password mutations re-validate the acting session and the account state inside their transaction.
- **Ineligible challenges (§4.4, §6.3, §7.3):** `delivery = 'none'` challenges can never authenticate or change a credential. This is enforced in code and by a table constraint. Their errors and failed-attempt accounting are identical to a wrong code.
- **Consumed refresh tokens (§6.6, §8.4, §8.5):** retention uses the old token's recorded refresh expiry, and lookup enforces that cutoff.
- **Outbox worker (§6.7, §8.3):** results are written only under the worker's current lease. Duplicate delivery after an ambiguous provider result is documented and accepted.
- **Change password (§5.3, §5.4, §6.2, §7.5):** the 5-minute `204` retry exception is removed. Lost-response behavior is documented, and `password_changed_at` is exposed on `User` so the client can confirm the outcome (superseded in v0.4: the field is now informational only).
- **Tests (§12):** concurrency and failure-path tests are updated to match.

### Changes in TRD v0.2
- Rebased on Product Doc v0.2. Q1–Q3 are resolved there, so this TRD no longer carries assumptions about them.
- **Registration:**
  - Two signup paths (OTP and password), both completed by an OTP bound to the signup attempt by a client-held challenge token.
  - Existing-email signup sends nothing, changes nothing and never signs in. This replaces v0.1's "send a sign-in code" behavior.
- **Passwords:**
  - First-password set now revokes all other sessions.
  - Password policy is 15–128 characters.
- **Sessions:**
  - Device listing, revoking one other session, and logout-all are removed (follow-up TRD).
  - Refresh rotation has no grace window. Consumed refresh tokens are retained and reuse revokes the session.
- **Concurrency and data protection:**
  - Concurrent first OTP issuance is specified through an atomic cooldown row and a one-open-challenge index.
  - OTP codes in the email outbox are encrypted and scrubbed.
- **Tests:** the test matrix is extended to AC-28.

## 0. How to read this TRD

| Tag | Meaning |
|---|---|
| **[Approved]** | An approved Product Doc v0.2 decision. Not open to change here. |
| **[Proposed]** | A technical default from this TRD. Binding only once the TRD is approved. Alternatives are listed in §14 where they matter. |

Flow letters (A–H) and AC numbers refer to the Product Doc v0.2.

---

## 1. Scope

### In scope

**Registration and sign-in**
- Flow A: OTP registration.
- Flow B: password registration with OTP verification.
- Flow C: OTP sign-in.
- Flow D: password sign-in.

**Passwords**
- Flow E: first-password set while signed in.
- Flow F: change password.
- Flow G: reset by email.

**Sessions [Approved]**
- Session creation, refresh, current-device sign-out (Flow H), and automatic revocation.

**Supporting services**
- Email delivery, OTP lifecycle, rate limits, password handling.
- Audit events for Phase 1 actions.
- `status` and `role` reserved on the account.

### Out of scope

**Follow-up scope [Approved]**
- Email change.
- Device listing.
- Revoking an individual other session.
- User-initiated sign-out on all devices.

The schema in §6 already supports these, so the follow-up TRD needs no session migration for them.

**Later phases**
- Profile, deletion, export (Phase 2).
- Sync (Phase 3).
- Admin endpoints and RBAC enforcement (Phase 4).
- Audit viewing (Phase 5).
- Entitlements (Phase 6).
- Phone/SMS, Facebook and Apple sign-in.
- The Flutter client.

---

## 2. Architecture

### 2.1 Service shape

**[Approved]** A Go modular monolith on PostgreSQL. One binary, one database. Modules talk through Go interfaces, never through each other's tables.

**[Proposed]** Layout:

```
backend/                      # location in the repo: see §14 R9
  cmd/api/main.go             # HTTP server + background workers
  cmd/migrate/main.go         # applies migrations, then exits
  api/openapi.yaml            # contract, normative for §5
  migrations/                 # SQL migrations (§6)
  internal/
    platform/                 # config, db pool, tx helper, clock, random, crypto, logging, middleware
    identity/                 # users, email normalization, password policy and hashing
    auth/                     # OTP challenges, signup, sessions, tokens, auth handlers
    notify/                   # email outbox, templates, Sender interface
    audit/                    # append-only audit writer
    ratelimit/                # Postgres-backed counters
  test/integration/           # AC-mapped tests (§12)
```

### 2.2 Module rules

**[Proposed]**

**Ownership**
- `auth` orchestrates the use cases. It calls `identity`, `notify`, `audit` and `ratelimit` through interfaces.
- Only `identity` writes `users`.
- Only `auth` writes `otp_challenges`, `otp_cooldowns`, `sessions` and `refresh_tokens_consumed`.
- Only `notify` reads and writes `email_outbox`.
- Only `audit` writes `audit_events`.

**Transactions**
- One use case means one database transaction, unless §7 says otherwise.
- Repositories accept a `DBTX` interface, satisfied by both the pool and a transaction. The `auth` service opens the transaction and passes it down.

**Testability**
- Time (`Clock`) and randomness (`Random`) are injected, so tests control expiry, codes and tokens.

### 2.3 Library choices

**[Proposed]** All pinned in `go.mod`.

| Concern | Choice |
|---|---|
| Go | Current stable release |
| HTTP | `net/http` with method and path patterns |
| Postgres driver | `jackc/pgx/v5` + `pgxpool` |
| Queries | `sqlc` (no ORM) |
| Migrations | `pressly/goose/v3`, SQL files embedded, applied by `cmd/migrate` |
| Password hashing | `golang.org/x/crypto/argon2` (argon2id) |
| Outbox encryption | `crypto/aes` + `crypto/cipher` (AES-256-GCM, standard library) |
| Text normalization | `golang.org/x/text/unicode/norm` |
| Logging | `log/slog` (JSON) |
| Metrics | `prometheus/client_golang`, internal port |
| Contract checks | `kin-openapi`, validating test responses against `api/openapi.yaml` |
| Local mail | Mailpit container in docker-compose |
| Production email | **Open.** Any provider behind the `Sender` interface (§8.3) |

---

## 3. Identity model

### 3.1 Account

**Identity**
- **[Approved]** `user_id` is stable, never reused, and not derived from email.
- **[Proposed]** It is a UUIDv7 generated in the application.

**Verification**
- **[Approved]** No session is issued unless the email is verified.
- **[Proposed]** Accounts are created only by a verified signup (§4), so in Phase 1 `email_verified_at` is always set when the row is inserted.
- **[Proposed]** The column stays nullable for later providers.
- **[Proposed]** The session-issue path and the per-request check still test it explicitly (AC-4).

**Pending registrations are not accounts**
- **[Proposed]** A pending password registration lives only on its OTP challenge, never in `users`.
- **[Proposed]** So an attacker who starts a signup for someone else's address cannot squat it.
- **[Proposed]** And no credential is usable before verification (AC-26).

**Status and role**
- **[Proposed]** `status` is one of `active`, `suspended`, `deactivated`, `pending_deletion`.
- **[Proposed]** Phase 1 only produces `active`, but every sign-in, refresh and authenticated request rejects other values (AC-9).
- **[Proposed]** `role` is one of `user`, `admin`, `super_admin`, default `user`. Phase 1 exposes it read-only through `GET /v1/me`.

**Future identities**
- **[Proposed]** A later phase adds `user_identities (user_id, provider, subject)`. Email stays on `users` as the contact address.

### 3.2 Email normalization

**[Proposed]**
1. Trim surrounding whitespace.
2. Parse with `net/mail.ParseAddress` and require the parsed address to equal the input, so display names and angle brackets are rejected.
3. Apply Unicode NFC, then lowercase the whole address.
4. Store the result in `email_normalized`, which is unique. Keep the user's spelling in `email` for display.
5. Maximum 254 octets after normalization.
6. Do not strip dots or `+tags`.
7. Reject control characters and invalid UTF-8 (a NUL byte cannot be stored in a PostgreSQL `text` column).
8. After normalizing, parse the result again and require it to equal itself. Normalization can change validity: U+037E (Greek question mark) is accepted by the parser, but its NFC form is `;`, which is not. Without this check the stored value could be an invalid address and normalization would not be idempotent.

Normalization uses Go's simple case mapping, which is independent of locale, so `U+0130` becomes `i`. The result is kept in NFC after lowercasing. Implemented in `internal/identity/email.go` and covered by a fuzz test for idempotence.

Every lookup uses `email_normalized` (AC-8).

### 3.3 Eligibility

**[Approved]** Each public flow returns one acknowledgement per flow; only eligible requests send email. **[Proposed]** Eligibility is evaluated inside the start transaction (§7):

| Flow | Eligible when |
|---|---|
| Signup (OTP or password) | No `users` row for `email_normalized` |
| OTP sign-in | `users` row exists, `status = 'active'`, `email_verified_at IS NOT NULL` |
| Password reset | Same as OTP sign-in |

---

## 4. OTP challenges and signup binding

### 4.1 Challenge token

**[Approved]** Verification is bound to the specific attempt.

**[Proposed]**
- Every OTP start creates one `otp_challenges` row and returns a **challenge token**: `vct_` + 32 random bytes, base64url.
- The server stores only `SHA-256(token)`.
- Verification requires **both** the challenge token and the emailed code.
- A code is therefore valid only for the attempt that requested it, and only for the client holding that attempt's token. A code from attempt X cannot complete attempt Y, even for the same email.
- For password signup, the pending password hash is stored on the challenge row. Verifying that challenge is the only way it can become an account credential.

### 4.2 Code

**[Proposed]**

| Parameter | Value |
|---|---|
| Format | 6 decimal digits from `crypto/rand` with rejection sampling |
| Lifetime | 10 minutes for every purpose |
| Max verify attempts per challenge | 5. After that the challenge is exhausted, and the right code no longer works |
| Resend cooldown | 60 s per `(purpose, email)`, enforced atomically (§7.2) |
| Open challenges | At most one per `(purpose, email_normalized)`. A new start supersedes the previous one |
| Storage | `HMAC-SHA256(VEEA_OTP_KEY, challenge_id ‖ code)`. A plain hash of a 6-digit code could be brute-forced from a database dump |
| Comparison | `hmac.Equal` |
| Single use | `consumed_at` is set in the verify transaction (AC-21) |

### 4.3 Purposes

| Purpose | Started by | Bound to | Verified by |
|---|---|---|---|
| `signup` (method `otp` or `password`) | Signup start endpoints | Email and challenge token; for the password method, a pending password hash | `POST /v1/auth/signup/verify` |
| `login` | OTP sign-in start | Existing `user_id` | `POST /v1/auth/otp/verify` |
| `password_reset` | Reset start | Existing `user_id` | `POST /v1/auth/password/reset/complete` |
| `set_password` | Signed-in user | Caller's `user_id` and session | `POST /v1/me/password/set` |

A challenge presented to the wrong endpoint returns `invalid_code`.

### 4.4 Ineligible requests

**[Proposed]**

**Same code path as an eligible request**
- An ineligible request creates a challenge row with `delivery = 'none'`, a random code that is never sent, and a real challenge token.
- The response is byte-identical apart from token and timestamps.
- Nothing is written to `email_outbox`.
- No `users` row is locked or changed.
- For password signup, the submitted password is hashed (equal timing) and the hash is discarded, not stored.

**Categorically ineligible**
- A `delivery = 'none'` challenge can **never** authenticate, create an account, issue a session, or set or change a credential. This holds even if the presented code happens to equal the stored random code.
- Verify, reset-complete and set-password treat it exactly like a wrong code (§7.3):
  - The HMAC comparison still runs, for equal timing.
  - Its result is ignored.
  - `attempts` and the per-email failure counter are incremented and committed.
  - The failure audit event records `reason = invalid_code`.
  - The response is `invalid_code`, or `code_attempts_exceeded` once attempts are exhausted.
- From the outside, an ineligible challenge is indistinguishable from an eligible one with a wrong code.

**Belt and braces**
- The `otp_none_inert` table constraint (§6.3) makes it impossible to mark such a challenge consumed.
- The same constraint forbids attaching a `user_id` or a pending password hash to it.

### 4.5 Lifecycle

```
open ──verify ok──────────────▶ consumed
 │ ├─verify wrong (attempts<5)─▶ open (attempts+1, committed)
 │ ├─5th failure──────────────▶ exhausted
 │ ├─new start, same purpose+email ─▶ superseded
 │ └─now > expires_at─────────▶ expired
 └─ every terminal state: pending_password_hash := NULL; row deleted 24 h after expiry

delivery = 'none': open ─(every verify is a failure)─▶ exhausted | superseded | expired
                   never consumed
```

---

## 5. API contract

### 5.1 Conventions

**[Proposed]**

**Format and contract**
- Base path `/v1`, JSON (UTF-8).
- `backend/api/openapi.yaml` is normative; this section summarizes it.

**Authentication**
- `Authorization: Bearer <access_token>`.
- Every authenticated route goes through the auth middleware.
- A route test asserts that every non-public route returns `401` without a token.

**Errors**
- RFC 9457 `application/problem+json` with a stable `code` and `request_id`.
- `429 rate_limited` carries `Retry-After` in seconds.

**Implementation notes** (Tickets 07 and 12)
- **Strict request bodies.** A JSON endpoint first requires `Content-Type: application/json` (parameters such as `charset` allowed). A missing or other content type is `415 unsupported_media_type`, before the body is read. The body must then be:
  - exactly one JSON object;
  - spelled with exactly the documented keys: no other case, no duplicates, no unknown keys;
  - complete: every field present, including inside `device`.
  Anything else is `400 invalid_request`, so `{}` sent to refresh is a malformed request, not an unknown token. Bearer-protected endpoints authenticate first, so a request without a valid token gets `401` whatever its content type.
- **Unmatched requests are problem documents too.** An unknown path gets `404 not_found`, and a known path with another method gets `405 method_not_allowed` with `Allow`. `HEAD` is refused with `405`, because `http.ServeMux` would otherwise serve `HEAD` for every `GET` route, and the contract does not list it.

**Responses**
- Every response has `X-Request-Id`. Timestamps are RFC 3339 UTC.
- No response contains a password, code, password hash or token hash.
- Tokens appear only in the responses defined below.

### 5.2 Shared shapes

**`Device`** (request)
```json
{ "name": "Pixel 9", "platform": "android" }
```
- `name`: 1–64 characters.
- `platform`: one of `ios`, `android`, `web`, `other`.

**`Acknowledgement`** (202)
```json
{ "challenge_token": "vct_...", "expires_at": "2026-11-13T10:10:00Z", "resend_after": "2026-11-13T10:01:00Z" }
```

**`TokenResponse`** (200)
```json
{
  "session_id": "0192...",
  "access_token": "vat_...",
  "access_expires_at": "2026-11-13T10:15:00Z",
  "refresh_token": "vrt_...",
  "refresh_expires_at": "2026-12-13T10:00:00Z",
  "user": { "$ref": "User" }
}
```

**`User`**
```json
{ "id": "0192...", "email": "learner@example.test", "email_verified_at": "...",
  "has_password": true, "password_changed_at": "2026-11-13T10:05:00Z",
  "status": "active", "role": "user", "created_at": "..." }
```
`password_changed_at` is `null` until a password is first set.

**It is informational only.** It is shown, for example, as "Password last changed …" in settings. It is set by any password set, change or reset, from any device. The server's clock is not comparable to the client's. So it is **not** proof that a particular request succeeded, and clients must not compare it with a client-side timestamp (§5.4).

### 5.3 Endpoints

| # | Method and path | Auth | Flow |
|---|---|---|---|
| 1 | `POST /v1/auth/signup/otp/start` | Public | A |
| 2 | `POST /v1/auth/signup/password/start` | Public | B |
| 3 | `POST /v1/auth/signup/verify` | Public + challenge token | A, B |
| 4 | `POST /v1/auth/otp/start` | Public | C |
| 5 | `POST /v1/auth/otp/verify` | Public + challenge token | C |
| 6 | `POST /v1/auth/password/login` | Public | D |
| 7 | `POST /v1/auth/password/reset/start` | Public | G |
| 8 | `POST /v1/auth/password/reset/complete` | Public + challenge token | G |
| 9 | `POST /v1/auth/token/refresh` | Refresh token | Session refresh |
| 10 | `POST /v1/auth/logout` | Bearer | H |
| 11 | `GET /v1/me` | Bearer | — |
| 12 | `POST /v1/me/password/set/start` | Bearer | E |
| 13 | `POST /v1/me/password/set` | Bearer + challenge token | E |
| 14 | `PUT /v1/me/password` | Bearer | F |
| — | `GET /healthz`, `GET /readyz` | Public | Liveness; readiness checks the DB |

#### 1. `POST /v1/auth/signup/otp/start`
- **Request:** `{ "email": "..." }`
- **Response:** `202 Acknowledgement`, the same for eligible and ineligible emails (AC-27).
- **Eligible:** creates a `signup` challenge (method `otp`) and queues the `signup_code` email.
- **Ineligible (account exists):** creates a `delivery = 'none'` challenge, sends no email, and does not touch the account.
- **Errors:**
  - `400 invalid_email`
  - `429 rate_limited`, applied identically whatever the eligibility.

#### 2. `POST /v1/auth/signup/password/start`
- **Request:** `{ "email": "...", "password": "..." }`
- **Response:** `202 Acknowledgement`.
- **Order of steps:**
  1. Validate the email and the password policy (§9.1). Violations return `422` before anything else, so the response does not depend on eligibility.
  2. Hash the password with argon2id outside the transaction.
  3. Run the start transaction (§7.2).
- **Eligible:** a `signup` challenge (method `password`) with `pending_password_hash`, plus the `signup_code` email.
- **Ineligible:** a `delivery = 'none'` challenge. The hash is discarded and no email is sent.
- **Errors:** `400 invalid_email`, `422 password_policy_violation`, `429 rate_limited`.

#### 3. `POST /v1/auth/signup/verify`
- **Request:** `{ "challenge_token": "vct_...", "code": "123456", "device": {...} }`
- **Response:** `201 TokenResponse`.
- **On a matching code (§7.3):**
  - insert the user with `email_verified_at = now()`
  - set `password_hash` to the pending hash (password method) or NULL (OTP method)
  - create a session.
- **If an account for the email appeared after the attempt started** (for example, another attempt verified first): the insert conflicts. The challenge is consumed, no account field changes, no session is issued, and the response is `409 signup_unavailable` (AC-27).
  - Only the holder of a valid code for the address can reach this response, so it does not enumerate accounts to third parties.
  - The client tells the user to sign in.
- **Errors:**
  - `400 invalid_code`, the same for: unknown token, wrong code, expired, consumed, superseded, `delivery = 'none'`, wrong purpose.
  - `400 code_attempts_exceeded`, `409 signup_unavailable`, `429 rate_limited`.

#### 4. `POST /v1/auth/otp/start`
- **Request:** `{ "email": "..." }`
- **Response:** `202 Acknowledgement`.
- **Eligible (§3.3):** a `login` challenge and the `login_code` email.
- **Ineligible:** a `delivery = 'none'` challenge and no email. No account is created (AC-6).
- **Errors:** `400 invalid_email`, `429 rate_limited`.

#### 5. `POST /v1/auth/otp/verify`
- **Request:** `{ "challenge_token": "...", "code": "...", "device": {...} }`
- **Response:** `200 TokenResponse`.
- **Before issuing a session:** re-checks that the bound user is still active and verified. If not, `invalid_code`.
- **Errors:** `400 invalid_code`, `400 code_attempts_exceeded`, `429 rate_limited`.

#### 6. `POST /v1/auth/password/login`
- **Request:** `{ "email": "...", "password": "...", "device": {...} }`
- **Response:** `200 TokenResponse`.
- **Unknown email, passwordless account, or pending registration (no `users` row):** argon2id runs against a fixed dummy hash, then `401 invalid_credentials` (AC-7, AC-26).
- **Correct password on a non-active account:** `403 account_unavailable`, returned only after the password verifies.
- **Outdated hash parameters:** the password is rehashed in the same transaction.
- **Errors:** `400 invalid_request`, `401 invalid_credentials`, `403 account_unavailable`, `429 rate_limited`.

#### 7. `POST /v1/auth/password/reset/start`
- **Request:** `{ "email": "..." }`
- **Response:** `202 Acknowledgement`.
- **Eligible:** a `password_reset` challenge and the `reset_code` email.
- **Ineligible:** a `delivery = 'none'` challenge and no email.

#### 8. `POST /v1/auth/password/reset/complete`
- **Request:** `{ "challenge_token": "...", "code": "...", "new_password": "..." }`
- **Response:** `204`, and no session is returned **[Approved]**.
- **Policy check first:** the policy is checked before the code is looked at, so a policy failure does not use an attempt.
- **On success:**
  - set the hash and revoke **all** sessions (`password_reset`)
  - queue `password_reset_done`
  - write an audit event.
- **Passwordless accounts:** this also sets a first password **[Proposed]**.
- **Errors:** `400 invalid_code`, `400 code_attempts_exceeded`, `422 password_policy_violation`, `429 rate_limited`.

#### 9. `POST /v1/auth/token/refresh`
- **Request:** `{ "refresh_token": "vrt_..." }`
- **Response:** `200 TokenResponse`.
- **Behavior:** §8.4.
- **Errors:** `401 unauthorized`, the same for unknown, consumed, revoked and expired tokens (AC-19). `429 rate_limited`.

#### 10. `POST /v1/auth/logout`
- **Request:** no body. **Response:** `204`.
- **Effect:** revokes the caller's session only (`logout`). Other sessions are untouched (AC-18).
- **Retry:** a retry gets `401`, which clients treat as done.

#### 11. `GET /v1/me`
- **Response:** `200 User`.

#### 12. `POST /v1/me/password/set/start`
- **Request:** no body. **Response:** `202 Acknowledgement`.
- **Effect:** a `set_password` challenge bound to the caller's user and session, and the `set_password_code` email.
- **Proposed** fresh proof of email control (Product Doc Flow E).
- **Errors:** `409 password_already_set`, `429 rate_limited`.

#### 13. `POST /v1/me/password/set`
- **Request:** `{ "challenge_token": "...", "code": "...", "new_password": "..." }`
- **Response:** `204`.
- **Binding:** the challenge must belong to the caller's user **and** session.
- **Inside the transaction (§7.5):** the acting session and the account are re-validated.
- **On success:**
  - set the hash while `password_hash IS NULL`
  - **keep the current session and revoke all others** (`password_set`) **[Approved]** (AC-28)
  - queue `password_added`
  - write an audit event.
- **Errors:**
  - `400 invalid_code`, `400 code_attempts_exceeded`.
  - `401 unauthorized`: the acting session was revoked or expired, or the account stopped being active, after the request was authenticated. Nothing changes.
  - `409 password_already_set`, `422 password_policy_violation`, `429 rate_limited`.

#### 14. `PUT /v1/me/password`
- **Request:** `{ "current_password": "...", "new_password": "..." }`
- **Response:** `204`.
- **On success:**
  - update the hash
  - keep the current session and revoke all others (`password_change`) **[Approved]**
  - queue `password_changed`
  - write an audit event.
- **Inside the transaction (§7.5):** the acting session and the account are re-validated, and `current_password` is checked against the hash read under the lock.
- **No retry exception.** A repeated request is evaluated like any other. After a lost response, see §5.4.
- **Errors:**
  - `401 unauthorized`: the acting session was revoked or expired, or the account stopped being active. Nothing changes.
  - `403 invalid_current_password`: nothing changes (AC-12).
  - `409 password_not_set`: use endpoint 12.
  - `422 password_policy_violation`, `429 rate_limited`.

### 5.4 Retry and lost-response outcomes (AC-25)

**[Proposed]** No endpoint stores and replays responses. Tokens are never cached server-side.

| Endpoint | Repeated after a lost response | Outcome |
|---|---|---|
| Any `*/start` | Within 60 s: `429` with `Retry-After`, the same for every eligibility. After that: a new challenge supersedes the lost one, and an eligible request sends a new email. | The client waits, then restarts. Only the newest code works. |
| `signup/verify` | Challenge already consumed: `invalid_code`. A new signup start is ineligible, because the account now exists. | One account. The user signs in by OTP or password. No credential changes. |
| `otp/verify` | `invalid_code` | The user requests a new code. The orphan session expires. |
| `password/login` | Creates another session | The orphan session expires or is evicted by the session cap. |
| `reset/complete` | `invalid_code` | The new password is in effect. The user signs in with it. |
| `me/password/set` | `invalid_code` or `409 password_already_set` | The client re-reads `GET /v1/me`. `has_password = true` shows the account now has a password, but not which request set it. |
| `PUT me/password` | See below | Consistent: exactly one change, one revocation of other sessions, and one notification |
| `token/refresh` | §8.4 | The session is revoked; the user signs in again |
| `logout` | `401` | Done |

**Change password after a lost response [Proposed]**
- **If the first request committed:**
  - The password is now the new one, and other sessions were revoked once.
  - `password_changed` was queued once.
  - The **current session is still valid**, because change keeps it.
  - Repeating the same body returns `403 invalid_current_password`, since the old password no longer matches. Nothing changes.
  - The retry counts once toward the wrong-current-password limit (§10).
- **If the first request did not commit:** the retry is evaluated normally.
- **Either way:** the current session stays signed in, so the user is never locked out of this device by an unknown outcome.

**The server offers no per-request proof [Proposed]**
- Phase 1 has no endpoint that confirms whether a *particular* change request committed.
- `password_changed_at` is informational (§5.2).
- A `403` on a resend cannot tell "already changed" from "mistyped current password".

**Unknown-outcome UX: client contract [Proposed]**
1. The client **never resends automatically.** A timeout, a dropped connection or a `5xx` after sending the request is treated as **unknown outcome**, not failure.
2. It shows an unknown-outcome message, for example: *"We couldn't confirm whether your password was changed. You're still signed in on this device. If it worked, we've emailed a confirmation to your account address."*
3. It offers three actions:
   - **"Try again":** re-opens the form with both fields empty. The user re-enters them, so nothing stale is resent.
   - **"Forgot password":** Flow G. It always ends in a known state, at the cost of signing out every session.
   - **"Done":** close.
4. If the user retries and gets `403 invalid_current_password`, the client shows: *"That current password wasn't accepted. If your earlier change went through, your new password is already active. Check your email for a confirmation, or use Forgot password."*
5. The client does not read `password_changed_at` to decide success or failure. It may still show it as information.

**What the user can rely on**
- The `password_changed` notification email (AC-23), which is queued only by a committed change.
- Being signed out on other devices.
- The result of their next password sign-in.

None of these is an API-level proof. An optional server-side mechanism is listed as an alternative in §14 R10.

---

## 6. PostgreSQL schema

### 6.1 Migration files

**[Proposed]** Goose SQL files, up only. Once a file is applied in a shared environment it is never edited. Every statement uses `IF NOT EXISTS`. Every table holding user-owned data references `users(id) ON DELETE CASCADE`. `audit_events` is the exception (§6.8).

| File | Contents |
|---|---|
| `00001_users.sql` | `users` |
| `00002_otp.sql` | `otp_challenges`, `otp_cooldowns` |
| `00003_sessions.sql` | `sessions`, `refresh_tokens_consumed` |
| `00004_email_outbox.sql` | `email_outbox` |
| `00005_audit_events.sql` | `audit_events` |
| `00006_rate_limit_counters.sql` | `rate_limit_counters` |
| `00007_cleanup_indexes.sql` | Indexes for the §6.10 cleanup jobs and the cascades their deletes trigger (release hardening) |
| `00008_session_management.sql` | Extend session revocation reasons for [TRD 02](02-session-management.md) |

### 6.2 `users`
```sql
CREATE TABLE IF NOT EXISTS users (
    id                          uuid        PRIMARY KEY,
    email                       text        NOT NULL,
    email_normalized            text        NOT NULL,
    email_verified_at           timestamptz,
    password_hash               text,                    -- PHC string; NULL = no password
    password_changed_at         timestamptz,             -- exposed on User (§5.2)
    status                      text        NOT NULL DEFAULT 'active'
                                CHECK (status IN ('active','suspended','deactivated','pending_deletion')),
    role                        text        NOT NULL DEFAULT 'user'
                                CHECK (role IN ('user','admin','super_admin')),
    created_at                  timestamptz NOT NULL DEFAULT now(),
    updated_at                  timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT users_email_len CHECK (octet_length(email_normalized) <= 254)
);
CREATE UNIQUE INDEX IF NOT EXISTS users_email_normalized_key ON users (email_normalized);
```

### 6.3 `otp_challenges`
```sql
CREATE TABLE IF NOT EXISTS otp_challenges (
    id                     uuid        PRIMARY KEY,
    token_hash             bytea       NOT NULL,        -- SHA-256 of the vct_ token
    purpose                text        NOT NULL
                           CHECK (purpose IN ('signup','login','password_reset','set_password')),
    signup_method          text        CHECK (signup_method IN ('otp','password')),
    pending_password_hash  text,                        -- password signup only; NULLed on any terminal state
    email                  text        NOT NULL,        -- as entered, for the account row on signup
    email_normalized       text        NOT NULL,
    user_id                uuid        REFERENCES users(id) ON DELETE CASCADE,  -- login, reset, set_password
    session_id             uuid,                        -- set_password only
    code_hash              bytea       NOT NULL,        -- HMAC-SHA256(otp_key, id || code)
    delivery               text        NOT NULL CHECK (delivery IN ('code','none')),
    attempts               int         NOT NULL DEFAULT 0,
    max_attempts           int         NOT NULL,
    created_at             timestamptz NOT NULL DEFAULT now(),
    expires_at             timestamptz NOT NULL,
    consumed_at            timestamptz,
    superseded_at          timestamptz,
    request_ip             inet,
    CONSTRAINT otp_signup_method CHECK ((purpose = 'signup') = (signup_method IS NOT NULL)),
    -- IS NOT DISTINCT FROM, not "=": for non-signup purposes signup_method is NULL, "NULL = 'password'"
    -- is NULL, and a CHECK accepts NULL, so "=" would let a login or reset challenge hold a pending hash.
    CONSTRAINT otp_pending_pw    CHECK (pending_password_hash IS NULL
                                        OR signup_method IS NOT DISTINCT FROM 'password'),
    -- delivery='none' challenges are inert: never consumed, never bound to an account or credential (§4.4).
    CONSTRAINT otp_none_inert    CHECK (delivery = 'code'
                                        OR (consumed_at IS NULL AND user_id IS NULL
                                            AND session_id IS NULL AND pending_password_hash IS NULL))
);
CREATE UNIQUE INDEX IF NOT EXISTS otp_challenges_token_hash_key ON otp_challenges (token_hash);
-- At most one open challenge per purpose and email (backstop for §7.2).
CREATE UNIQUE INDEX IF NOT EXISTS otp_challenges_one_open
    ON otp_challenges (purpose, email_normalized)
    WHERE consumed_at IS NULL AND superseded_at IS NULL;
CREATE INDEX IF NOT EXISTS otp_challenges_expires ON otp_challenges (expires_at);
```
An expired or exhausted challenge still counts as open for the unique index until a newer start supersedes it. That is intended: the next start always supersedes first.

`otp_pending_pw` is written with `IS NOT DISTINCT FROM` because a CHECK constraint passes when its condition is NULL. This is the form in `00002_otp.sql`, and `TestSchema_OTPChallenges` covers it (a `login` challenge holding a pending hash is rejected).

### 6.4 `otp_cooldowns`
```sql
CREATE TABLE IF NOT EXISTS otp_cooldowns (
    purpose         text        NOT NULL,
    email_hmac      bytea       NOT NULL,     -- HMAC(email_key, email_normalized); no raw email
    last_issued_at  timestamptz NOT NULL,
    PRIMARY KEY (purpose, email_hmac)
);
```

### 6.5 `sessions`
```sql
CREATE TABLE IF NOT EXISTS sessions (
    id                   uuid        PRIMARY KEY,
    user_id              uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    auth_method          text        NOT NULL CHECK (auth_method IN ('signup_otp','signup_password','otp','password')),
    access_token_hash    bytea       NOT NULL,
    access_expires_at    timestamptz NOT NULL,
    refresh_token_hash   bytea       NOT NULL,
    refresh_expires_at   timestamptz NOT NULL,     -- idle expiry, extended on each rotation
    absolute_expires_at  timestamptz NOT NULL,
    rotation_counter     bigint      NOT NULL DEFAULT 0,
    device_name          text        NOT NULL CHECK (char_length(device_name) BETWEEN 1 AND 64),
    platform             text        NOT NULL CHECK (platform IN ('ios','android','web','other')),
    user_agent           text,
    created_ip           inet,
    last_seen_at         timestamptz NOT NULL DEFAULT now(),
    last_seen_ip         inet,
    created_at           timestamptz NOT NULL DEFAULT now(),
    revoked_at           timestamptz,
    revoked_reason       text CHECK (revoked_reason IN
                           ('logout','password_set','password_change','password_reset',
                            'refresh_reuse','session_limit','account_inactive'))
);
CREATE UNIQUE INDEX IF NOT EXISTS sessions_access_token_hash_key  ON sessions (access_token_hash);
CREATE UNIQUE INDEX IF NOT EXISTS sessions_refresh_token_hash_key ON sessions (refresh_token_hash);
CREATE INDEX IF NOT EXISTS sessions_user_active ON sessions (user_id) WHERE revoked_at IS NULL;
```

### 6.6 `refresh_tokens_consumed`
```sql
CREATE TABLE IF NOT EXISTS refresh_tokens_consumed (
    token_hash    bytea       PRIMARY KEY,
    session_id    uuid        NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    consumed_at   timestamptz NOT NULL,
    retain_until  timestamptz NOT NULL       -- the old token's recorded refresh expiry:
                                             -- sessions.refresh_expires_at as it was just before rotation (§8.5)
);
CREATE INDEX IF NOT EXISTS refresh_tokens_consumed_retain ON refresh_tokens_consumed (retain_until);
```

### 6.7 `email_outbox`
```sql
CREATE TABLE IF NOT EXISTS email_outbox (
    id                   uuid        PRIMARY KEY,
    user_id              uuid        REFERENCES users(id) ON DELETE CASCADE,   -- NULL for signup codes
    challenge_id         uuid        REFERENCES otp_challenges(id) ON DELETE CASCADE,
    to_email             text        NOT NULL,
    template             text        NOT NULL CHECK (template IN
                           ('signup_code','login_code','reset_code','set_password_code',
                            'password_added','password_changed','password_reset_done')),
    payload_ciphertext   bytea,                  -- AES-256-GCM; NULLed on any terminal state
    payload_key_id       smallint,
    status               text        NOT NULL DEFAULT 'pending'
                         CHECK (status IN ('pending','sent','failed','expired','cancelled')),
    send_attempts        int         NOT NULL DEFAULT 0
                         CHECK (send_attempts BETWEEN 0 AND 5),  -- durably reserved provider sends (§8.3)
    last_send_started_at timestamptz,
    next_attempt_at      timestamptz NOT NULL DEFAULT now(),
    lease_token          uuid,                   -- set by the claiming worker; writes require it, unexpired (§8.3)
    lease_expires_at     timestamptz,
    not_after            timestamptz NOT NULL,   -- OTP mail: the challenge's expires_at; notifications: created_at + 24 h
    provider_message_id  text,
    last_error           text,                   -- provider error class only, never payload
    created_at           timestamptz NOT NULL DEFAULT now(),
    finished_at          timestamptz,
    CONSTRAINT outbox_payload_only_pending CHECK (status = 'pending' OR payload_ciphertext IS NULL)
);
CREATE INDEX IF NOT EXISTS email_outbox_due ON email_outbox (next_attempt_at) WHERE status = 'pending';
```

### 6.8 `audit_events`
```sql
CREATE TABLE IF NOT EXISTS audit_events (
    id              bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    occurred_at     timestamptz NOT NULL DEFAULT now(),
    action          text        NOT NULL,
    outcome         text        NOT NULL CHECK (outcome IN ('success','failure')),
    reason          text,
    actor_user_id   uuid,                 -- no FK: retention decided in Phase 2 / Q-L3
    target_user_id  uuid,
    session_id      uuid,
    email_hmac      bytea,
    ip              inet,
    user_agent      text,
    request_id      text,
    metadata        jsonb       NOT NULL DEFAULT '{}'::jsonb
);
CREATE INDEX IF NOT EXISTS audit_events_target ON audit_events (target_user_id, occurred_at DESC);
CREATE INDEX IF NOT EXISTS audit_events_action ON audit_events (action, occurred_at DESC);
```
**[Proposed]** The application role has `INSERT` and `SELECT` on `audit_events` only. Retention cleanup uses a separate maintenance role.

### 6.9 `rate_limit_counters`
```sql
CREATE TABLE IF NOT EXISTS rate_limit_counters (
    key           text        NOT NULL,      -- e.g. otp_start:email:<hmac hex>, login_fail:ip:<prefix>
    window_start  timestamptz NOT NULL,
    count         int         NOT NULL,
    PRIMARY KEY (key, window_start)
);
```

### 6.10 Cleanup jobs

**[Proposed]** Each job runs every 5 minutes under `pg_try_advisory_lock`, so only one instance runs it. Deletes are batched (1,000 rows per statement).

| Data | Action |
|---|---|
| Open `otp_challenges` past `expires_at` | Set `pending_password_hash = NULL` |
| `otp_challenges` | Delete 24 h after `expires_at`. Cascades to any remaining outbox rows |
| `otp_cooldowns` | Delete where `last_issued_at` is older than 24 h |
| `email_outbox` rows still `pending` past `not_after`, or with `send_attempts = 5`, and no live lease | Terminalized by the worker's reaper step (§8.3). This job runs the same statement as a backstop |
| `email_outbox` rows not `pending` | Delete 7 days after `finished_at` |
| `refresh_tokens_consumed` | Delete where `retain_until <= now()`. Correctness does not depend on this job, because lookup enforces the same cutoff (§8.4) |
| `sessions` | Delete 30 days after revocation or absolute expiry. Cascades to consumed tokens |
| `rate_limit_counters` | Delete windows older than 48 h |
| `audit_events` | Not deleted in Phase 1 (Q-L3) |

**Implementation notes** (`internal/maintenance`, release hardening)
- **The runner lives in the API process.** `cmd/api` runs every job once at start and then every 5 minutes. On shutdown it is stopped before the pool closes; a job in progress is interrupted.
- **One advisory lock per job.** The keys are `0x5645_4541_434c_0000` plus the job's index. Each job takes its lock with `pg_try_advisory_lock` on one dedicated connection, and every statement of the job runs on that same connection, so the lock is held for the whole job. Another session holding the lock means the job is skipped this time (`Result.Ran = false`).
- **Release is verified.** `pg_advisory_unlock` must return true. If the release fails or returns false, or a batch failed, the connection is taken out of the pool and closed, which ends its session and every lock with it. A lock can therefore never leak into the pool, also after a cancellation mid-statement.
- **Bounded batches.** Deletes run 1,000 rows per statement and at most 100 statements per job per run; the next run continues.
- **Indexes (migration `00007_cleanup_indexes.sql`).**
  - New: `sessions_revoked_at` (partial, revoked rows) and `sessions_absolute_expires`, which the planner combines for the stale-session `OR` (BitmapOr); `rate_limit_counters_window`; `otp_cooldowns_last_issued`; `email_outbox_finished` (partial, non-pending rows).
  - New, for the cascades: `refresh_tokens_consumed_session` (session delete) and `email_outbox_challenge` (challenge delete, and the per-challenge cancel run by every start and redemption).
  - Reused: `otp_challenges_expires` (challenge delete and its `ORDER BY`, pending-hash scrub), `refresh_tokens_consumed_retain`, and `email_outbox_due` (reaper).
  - Built with plain `CREATE INDEX` inside goose's transaction, because the tables are empty or small before the first release. `CONCURRENTLY` cannot run in a transaction, and a failed concurrent build would leave an invalid index that `IF NOT EXISTS` then skips forever. If this ever runs against a large live database, build the indexes concurrently by hand first.
- **Batch deletes by tuple id.** All six batched deletes select tuple ids through the retention indexes and use `ctid = ANY(ARRAY(...))` for the outer delete. On the representative data below, this avoids the whole-table hash joins chosen for `IN (subquery)`. Tuple ids are used only within one statement and snapshot. Each outer delete repeats its retention predicate so PostgreSQL rechecks eligibility if a concurrent writer updates a selected row. Only challenge deletion specifies batch ordering (`ORDER BY expires_at`), supplied by the existing expiry index without a sort; the other batches have no ordering guarantee.
- **Plans are checked.** `TestMigrations_CleanupQueriesUseTheirIndexes` loads 20,000 synthetic rows per cleanup table and runs `ANALYZE` followed by plain `EXPLAIN` on the actual statements extracted from the query files. It checks all six batched deletes, both unbatched updates, cancellation and the cascade lookups with default planner settings. On version 6, the four deletes gaining retention indexes have sequential scans. These are plan checks on this fixture, not measured execution times or a guarantee that PostgreSQL will choose indexes for every data distribution.
- **Two unbatched statements.** The pending-hash scrub and the outbox reaper backstop are single `UPDATE`s. A backlog can make them large; the batch bound applies only to deletes.
- **Order.** The pending-hash scrub (AC-26) runs before challenge deletion, and session deletion runs before consumed-token deletion so the cascade does most of that work.
- **Tests.** `TestCleanup_*` run the real runner against PostgreSQL:
  - AC-26 end to end through the router;
  - every retention threshold, a minute on either side;
  - the batch bound;
  - a held lock skips the job, and of four simultaneous runners exactly one runs it;
  - the lock is released after a failed batch and after a cancellation mid-statement.

---

## 7. Transaction rules

### 7.1 General rules

**[Proposed]**
1. READ COMMITTED isolation. Contended rows are locked explicitly with `SELECT ... FOR UPDATE`, or with atomic upserts whose `WHERE` clause decides the outcome.
2. A state change, its outbox email and its success audit event commit together or not at all.
3. **Failed attempts are committed.** A verify mismatch increments `attempts`, the per-email failure counter and the failure audit event, and **commits** before the error is returned. Failure paths never roll back counters. Otherwise an attacker could reset them by forcing an error.
4. Argon2id runs outside transactions and holds no connection.
5. Session-token generation (random bytes) happens before the transaction. Only hashes are written.
6. **Rate-limit counters are not part of the lock order.** Each counter increment (`rate_limit_counters`) is a single autocommit statement, run before or after the main transaction, never while that transaction holds row locks. Counter failures are therefore committed independently, as rule 3 requires.
7. **Deadlock or serialization failure** (`40P01`, `40001`): the transaction helper retries the whole transaction up to 3 times with jittered backoff. This is safe because nothing commits before the failure. If the order below is followed, a retry indicates a bug, and `db_tx_retries_total{reason}` is alerted on in Phase 5.

#### Lock order and lock modes

**[Proposed]** Every transaction takes row locks in this order and skips the levels it does not need. No transaction takes a lower level after a higher one.

| Level | Table and rows | Mode | Taken by |
|---|---|---|---|
| L1 | `otp_cooldowns` (one row) | Upsert row lock | Start (§7.2) |
| L2 | `otp_challenges`: the one row by `token_hash`, or the open row for `(purpose, email)` | `FOR UPDATE` (or the `UPDATE` of supersede) | Start, verify, reset complete, set password |
| L2b (TRD 03) | `email_changes`: prior pending or completing owned request | `FOR UPDATE`, prior rows in UUID order; after proof locks, before users | Paired start/complete |
| L3 | `users`: one row | `FOR NO KEY UPDATE`; TRD 03 final email cutover alone uses `FOR UPDATE` from the outset, before sessions, for the unique email-key change. A signup verify instead inserts a new row and waits on the unique index | Session issuance, all password mutations, Phase 2 status changes |
| L4a | `sessions`: the **acting** session (by `id`) | `FOR UPDATE` | Password set and change (re-validation), refresh, logout, the per-request `account_inactive` revocation |
| L4b | `sessions`: the user's **other** active sessions | `UPDATE ... WHERE user_id = $u AND id <> $current AND revoked_at IS NULL`, or one row for cap eviction | Password set, change and reset; session cap |
| L5 | Insert-only rows: `sessions` (new), `refresh_tokens_consumed`, `email_outbox`, `audit_events`. Plus **every** `email_outbox` write by a request transaction, including the cancel `UPDATE` keyed by `challenge_id`. Always the last level, after any L3 and L4 the flow needs | Row-exclusive on new or own rows | Any |

**TRD 03 amendment.** Paired proofs lock at L2 in UUID order and then the owned request at L2b. Final cutover takes the stronger L3 mode before L4; no weaker lock is upgraded. Existing-user OTP and password sign-in revalidate email/revision under L3. Public inert challenges retain null owner/session; TRD 03 inert destination proofs retain the request owner/session while remaining unconsumable and unmailed. Bounded request cleanup runs 24 h after expiry after the code rows are gone. See TRD 03 §2–5 for the complete amendment.

**Why these modes**
- **No lock upgrade.**
  - `users` is never locked `FOR SHARE`. The v0.2 pattern of `FOR SHARE` followed by an `UPDATE` (rehash, cap eviction) could deadlock two concurrent sign-ins of the same user.
  - `FOR NO KEY UPDATE` is the same mode an `UPDATE` of non-key columns takes implicitly. So a transaction that locks the user and later updates `password_hash` or `updated_at` never upgrades.
  - `FOR NO KEY UPDATE` still lets other transactions insert rows that reference the user (foreign-key checks take `FOR KEY SHARE`, which does not conflict). So outbox and audit inserts are never blocked by it.
- **Serialization per user.** All session issuance and every password mutation for one user serialize on L3. Bulk revocation (L4b) therefore never runs concurrently with another bulk revocation or with a session insert for the same user.
- **Transactions that lock a session row without L3** never take L3 afterwards: refresh, logout, and the per-request revocation. These read `users` without a lock, through a join, and only lock their own session row (L4a). A user-level transaction (L3 → L4b) may wait for them, but they never wait for it, so there is no cycle.
- **The outbox worker** locks only `email_outbox` rows. It never locks challenges, users or sessions.

| Use case | Locks in order |
|---|---|
| Start | L1 → L2 (supersede) → L5 |
| Signup verify | L2 → L3 (insert, unique index) → L5 |
| OTP verify (login) | L2 → L3 → L4b (cap eviction, if needed) → L5 |
| Password login | L3 → L4b (cap) → L5 |
| Reset complete | L2 → L3 → L4b (all) → L5 |
| Set password | L2 → L3 → L4a → L4b → L5 |
| Change password | L3 → L4a → L4b → L5 |
| Refresh | L4a → L5 |
| Logout, per-request `account_inactive` | L4a → L5 |
| Outbox worker | `email_outbox` rows only |

### 7.2 Start (all purposes): concurrent first issuance

**Before the transaction:** hourly and daily rate-limit increments for the email and the IP (§10), as autocommit statements (§7.1 rule 6). If any limit is exceeded, return `429`.

Then a single transaction (lock order L1 → L2 → L5):

1. **Atomic cooldown claim.** This runs whatever the eligibility, so `429` reveals nothing:
   ```sql
   INSERT INTO otp_cooldowns (purpose, email_hmac, last_issued_at)
   VALUES ($purpose, $email_hmac, now())
   ON CONFLICT (purpose, email_hmac) DO UPDATE
       SET last_issued_at = EXCLUDED.last_issued_at
       WHERE otp_cooldowns.last_issued_at <= EXCLUDED.last_issued_at - interval '60 seconds'
   RETURNING last_issued_at;
   ```
   If no row is returned, the cooldown is active: roll back and return `429` with `Retry-After`.
   - **Concurrent first requests:** both race to insert. The second blocks on the unique key until the first commits. It then takes the `DO UPDATE` path, whose `WHERE` fails against the committed row, so it gets no row and a `429`.
   - **First transaction rolls back:** the second inserts normally.
   - **Outcome:** exactly one challenge is issued per 60 s per `(purpose, email)`.
2. *(Rate limits were applied before the transaction.)*
3. **Eligibility check** (§3.3), reading `users` without a lock.
4. **Supersede the open challenge:**
   ```sql
   UPDATE otp_challenges SET superseded_at = now(), pending_password_hash = NULL
   WHERE purpose = $1 AND email_normalized = $2 AND consumed_at IS NULL AND superseded_at IS NULL
   RETURNING id;
   ```
   The superseded challenge's pending email is cancelled in the same transaction (L5): `UPDATE email_outbox SET status = 'cancelled', payload_ciphertext = NULL, finished_at = now(), lease_token = NULL, lease_expires_at = NULL WHERE challenge_id = $old AND status = 'pending'`. A worker already sending it then records nothing (§8.3).
5. **Insert the new challenge.** The `otp_challenges_one_open` partial unique index is the backstop. A unique violation here, which should not happen after step 1, is mapped to `429`.
6. **If eligible:** insert the `email_outbox` row with the encrypted payload (§8.2).
7. **Insert the audit event,** then commit.

The email is sent by the worker after commit, so response timing does not depend on eligibility.

### 7.3 Shared OTP validation and verify flows

**[Proposed]**

Every flow that redeems a code uses the same validation procedure, **V**:
- signup verify
- OTP verify
- reset complete
- set password.

V touches only L2. The flow then continues **in the same transaction** with L3, L4 and L5, in order. In particular, the cancellation of the challenge's pending outbox email is an L5 write. It happens **after** all user and session locks the flow needs, never inside V.

#### Transaction boundaries

| Name | Kind | Contents |
|---|---|---|
| **P** (pre-check) | Autocommit read, before any transaction | Per-email verify-failure limit (§10). Exceeded → `429`, no transaction is opened |
| **T-main** | The flow's single transaction | V, then the flow-specific steps, then commit |
| **T-fail** | A new short transaction, only after T-main was **rolled back** | The failure audit event only |
| **C** (counter) | Autocommit, after T-main commits | Per-email verify-failure counter + 1. Only after a counted failure |

#### Procedure V (inside T-main, L2 only)

1. **L2:** `SELECT ... FROM otp_challenges WHERE token_hash = $1 FOR UPDATE`.
2. **Unusable.** The row is missing, has the wrong purpose, or fails the flow's binding. For `set_password` the binding is `user_id` and `session_id`. Or the row is consumed, superseded or expired.
   - Result: **`Reject(invalid_code)`**, not counted.
3. **Exhausted:** `attempts >= max_attempts`.
   - Result: **`Reject(code_attempts_exceeded)`**, not counted.
4. **Compare.** Always run the constant-time HMAC compare, then:
   ```
   ok := hmac.Equal(...) && challenge.delivery == "code"
   ```
   - If not `ok`: `UPDATE otp_challenges SET attempts = attempts + 1`.
   - Result: **`Reject(invalid_code)`, counted.**
   - A `delivery = 'none'` challenge always ends here (§4.4). Its response, attempt accounting and timing are identical to a wrong code on a real challenge.
5. **Accept.**
   - `UPDATE otp_challenges SET consumed_at = now(), pending_password_hash = NULL`. The pending hash is kept in memory for signup.
   - Result: **`Accept`**.
   - V writes nothing to `email_outbox`.

#### On a V rejection

- Insert the failure audit event (L5) in T-main, then **commit** T-main. The attempt increment is now durable (§7.1 rule 3).
- Run C if the result was counted.
- Return the error.

#### After `Accept`: per-flow steps, still in T-main

| Flow | Steps after V (in lock order) | Commit outcome |
|---|---|---|
| **Signup verify** | **L3:** `INSERT INTO users (...) VALUES (...) ON CONFLICT (email_normalized) DO NOTHING RETURNING id`. This waits on the unique index if another attempt for the email is in flight. **L5:** cancel this challenge's pending outbox row; insert the session; insert the audit success. | `201 TokenResponse` |
| ↳ insert returned no row | **L5:** cancel this challenge's pending outbox row; insert the audit failure (`account_exists`). No `UPDATE users` is ever executed (AC-27). | Commit, then `409 signup_unavailable`. The consumption stays committed |
| **OTP verify (login)** | **L3:** `SELECT ... FROM users WHERE id = $u FOR NO KEY UPDATE`. Re-check `status = 'active'` and `email_verified_at IS NOT NULL`. **L4b:** session-cap eviction if needed. **L5:** cancel the outbox row; insert the session; insert the audit success. | `200 TokenResponse` |
| ↳ account re-check fails | Roll back T-main, so the consumption is undone. **T-fail:** audit failure (`account_unavailable`). | `invalid_code` |
| **Reset complete**, **set password** | §7.5 | §7.5 |

**Concurrent verifies**
- Two verifies of the same token serialize on the L2 row. The second sees `consumed_at` and gets `invalid_code`.
- Two verifies of different signup attempts for one email serialize on the `users` unique index. Exactly one creates the account; the other gets `409`.

**Implementation notes** (`internal/auth/otp`, Ticket 06). These fill gaps in §7.2 and §7.3; none changes an approved decision.
- **Shape.** `otp.Service.Start` and `otp.Service.Verify` are the shared core. A flow supplies only an eligibility check, which runs in the start transaction after the cooldown claim, and an after-accept callback, which runs in T-main after V. The callback ends the redemption in one of four ways: commit; `CommitFailure(reason, err)`, which keeps the consumption and writes the failure audit in T-main (signup `409`); `Rollback(reason, err)`, which rolls back and writes the T-fail audit (account no longer active); or any other error, which rolls back with no audit. The core cancels the challenge's pending email as the last L5 write, after the callback returns.
- **Order of outbox writes in start.** §7.2 step 4 describes the superseded email's cancellation next to the supersede, but labels it L5. The code supersedes, inserts the new challenge, and only then cancels the old email and enqueues the new one. So every `email_outbox` write follows every `otp_challenges` write.
- **Ineligible requests.** The core drops `user_id`, `session_id` and any pending hash from an ineligible result before inserting, and never enqueues for it. The flow cannot bind a `delivery = 'none'` challenge even by mistake.
- **P needs an email the request does not carry.** Verify requests hold only the token. P therefore reads `email_normalized` by token hash in an unlocked autocommit statement (`GetOTPChallengeEmailByTokenHash`) and peeks the per-email failure counter. An unknown token has no email to limit; V rejects it without counting. The per-IP verify limit (§10) is counted, in autocommit, before P.
- **Clock.** Expiry, `resend_after`, supersession and the expiry check in V all use the transaction's database `now()`, like the cooldown claim. No application clock is involved, so the fake clock of §12.1 is not used here. Tests move `expires_at` or `last_issued_at` directly.
- **Randomness.** Tokens and codes come from an injectable `Random` (default `crypto/rand`). Start reads the 32 token bytes, then 4 bytes per code candidate (rejection sampling below 4,294,000,000). Tests use this to learn the code of a `delivery = 'none'` challenge.
- **Responses at the limit.** Failures 1 to 5 return `invalid_code`, and the 5th leaves `attempts = 5`. From then on even the right code gives `code_attempts_exceeded`, and that rejection is not counted (§4.4, §12.3). Audit reasons are `invalid_code` and `attempts_exceeded` for every verify action, not only `auth.signup.verify`.
- **Backstop index.** A unique violation on `otp_challenges_one_open` maps to `429` with `Retry-After` equal to the cooldown (60 s). The TRD names no value.
- **Programming errors are not code errors.** `set_password` verification without the caller's user and session, or another purpose with them, returns an internal error, not `invalid_code`.
- **Retries.** `platform/db.Tx` runs every transaction at READ COMMITTED and retries the whole transaction up to 3 times on `40P01` or `40001` (§7.1 rule 7). Until Prometheus exists, a retry is a warning log plus an `OnTxRetry` hook. The integration tests assert it never fires.
- **Audit.** A minimal `internal/audit` writer exists so start and V can write their events. It refuses metadata keys that name a secret and any value that looks like a `vct_`, `vat_` or `vrt_` token. `auth.rate_limited` events and the §11.3 OTP metrics are not written yet (Tickets 11 and 12).
- **Left to the flow tickets.** The per-IP password-signup limit runs before argon2 hashing, so it belongs to the signup flow (Ticket 07), not the core.

### 7.4 Password login

1. Outside a transaction: load the user by `email_normalized`. Run argon2id against the stored hash, or against the dummy hash.
2. **Failure:** a short transaction with the failure counters and the audit event, committed; then `401`.
3. **Success:** one transaction.
   - **L3:** `SELECT ... FROM users WHERE id = $1 FOR NO KEY UPDATE`.
   - Confirm that `password_hash` is byte-equal to the hash verified in step 1. If it changed (a concurrent change or reset), return `401 invalid_credentials` without a session.
   - Check active; optionally rehash (same lock, no upgrade); enforce the session cap (L4b); insert the session and the audit event; commit.

**Implementation notes** (Ticket 09: `internal/auth/signin`). These fill gaps in §5.3 endpoints 4 to 6, §7.3 and §7.4; none changes an approved decision.
- **Order in password login.**
  1. Validate the email and device. A malformed request gives `400 invalid_request`: §5.3 lists no `invalid_email` here, and a malformed address is not a credential. Nothing is counted.
  2. Count the per-IP login limit, then peek at the per-email failure counter. Either refusal is `429` before any Argon2id work.
  3. Read the account unlocked and run exactly one Argon2id: against the stored hash, or `VerifyDummy` for an unknown email, a passwordless account or a pending registration. The test hasher counts runs, so every failure path is shown to cost one, but there is no wall-clock timing test.
  4. Then the success transaction, or the failure accounting below.
- **Failure accounting.** §7.4 step 2 says "a short transaction with the failure counters and the audit event". Following §7.1 rule 6, the counter is an autocommit increment and the audit event an autocommit insert, so neither can be rolled back. Ten failures are allowed; the eleventh request is refused until the 15-minute window ends (fixed windows, §10).
- **Lockout scope.** The lockout counter (`login_fail_email_15m`) is read only by password login. OTP sign-in and reset keep working during it (`TestPasswordLogin_LockoutStillAllowsOTPSignin`).
- **Rehash outside the transaction.** When `Verify` reports outdated parameters, the new hash is computed right after it, still outside any transaction. The success transaction stores it with a compare-and-set on the hash that verified, under the L3 lock already held. `password_changed_at` is not touched.
- **Re-checks under L3.**
  - A hash that changed between verification and the lock gives `401 invalid_credentials` and no session. It is audited as `password_changed_concurrently` and not counted as a wrong guess.
  - "Active" also requires a verified email. Either failing gives `403 account_unavailable`, only after the password verified; a wrong password on such an account still gets the generic `401`.
- **OTP sign-in.**
  - Eligibility is §3.3 (active and verified), and the code goes to the stored `users.email`, not the typed spelling.
  - At verify, the account is locked (L3) and re-checked. If it fails, everything rolls back, the code stays usable, the T-fail event records `account_unavailable`, and the response is `invalid_code`.
  - Otherwise the consumption, the session (cap, L4b; insert, L5), the cancellation of the challenge's pending email and `auth.otp.verify` commit together.

### 7.5 Password set, change and reset

**[Proposed]**

The new password is policy-checked and hashed **outside** the transaction. For change, `current_password` is also verified outside it, against the hash read at that time; call that hash `H0`.

**Common re-validation, inside the transaction after L3**

These checks run on the locked rows, not on what the auth middleware saw.

| Check | Applies to | On failure |
|---|---|---|
| `users.status = 'active'` and `email_verified_at IS NOT NULL` | Set, change, reset | Set and change: `401 unauthorized`. Reset: `invalid_code`, with the attempt committed. Nothing changes |
| Acting session, locked with `SELECT ... FROM sessions WHERE id = $current AND user_id = $u FOR UPDATE` (L4a): it exists, `revoked_at IS NULL`, `absolute_expires_at > now()`, `access_expires_at > now()` | Set, change | `401 unauthorized`. Nothing changes. Covers a logout, revocation or reset that committed after the middleware check |
| Set: `password_hash IS NULL` | Set | `409 password_already_set` |
| Change: `password_hash IS NOT NULL` | Change | `409 password_not_set` |
| Change: `password_hash = H0` (byte-equal) | Change | `403 invalid_current_password`. The password changed concurrently, so the verified current password is stale. Nothing changes |

**Per use case.** Each runs in one T-main, with the boundaries P, T-fail and C as defined in §7.3. Writes to a row the transaction already holds (the locked `users` row) do not count as taking a new lock level.

| Use case | T-main steps, in lock order |
|---|---|
| **Set (E)** | (P) → **L2:** V with purpose `set_password`, bound to the caller's `user_id` and `session_id` → **L3:** `users FOR NO KEY UPDATE`; re-validate the account and `password_hash IS NULL` → **L4a:** acting session `FOR UPDATE`; re-validate it → write `password_hash`, `password_changed_at = now()` on the locked user row → **L4b:** `UPDATE sessions SET revoked_at = now(), revoked_reason = 'password_set' WHERE user_id = $u AND id <> $current AND revoked_at IS NULL` → **L5:** cancel the challenge's pending outbox row; insert `password_added`; insert the audit success → commit, `204`. |
| **Change (F)** | (No V) **L3:** `users FOR NO KEY UPDATE`; re-validate the account, `password_hash IS NOT NULL`, and `password_hash = H0` → **L4a:** acting session `FOR UPDATE`; re-validate it → write `password_hash`, `password_changed_at = now()` → **L4b:** revoke others (`password_change`) → **L5:** insert `password_changed` and the audit success → commit, `204`. |
| **Reset (G)** | (P) → **L2:** V with purpose `password_reset` → **L3:** `users FOR NO KEY UPDATE` (the user from the challenge); re-validate the account → write `password_hash`, `password_changed_at = now()` → **L4b:** revoke **all** sessions (`password_reset`) → **L5:** cancel the challenge's pending outbox row; insert `password_reset_done`; insert the audit success → commit, `204`. |

**Failure accounting and boundaries**

| Failure | Where detected | Transaction handling | Response |
|---|---|---|---|
| V rejection (wrong code, `delivery = 'none'`, exhausted, unusable) | L2 | Audit failure in T-main, **commit**. Then C if counted | `invalid_code` or `code_attempts_exceeded` |
| Account not active or not verified | L3 | **Roll back** T-main (undoing any consumption). Then T-fail: audit | Set: `401`. Reset: `invalid_code`. Change: `401` |
| Set: `password_hash IS NOT NULL` | L3 | Roll back. Then T-fail | `409 password_already_set` |
| Change: `password_hash IS NULL` | L3 | Roll back. Then T-fail | `409 password_not_set` |
| Change: `password_hash <> H0` (changed concurrently) | L3 | Roll back. Then T-fail (`reason = stale_current_password`). Not counted as a wrong guess | `403 invalid_current_password` |
| Acting session revoked or expired | L4a | Roll back. Then T-fail | `401 unauthorized` |
| Change: wrong `current_password` | Before T-main (argon2id) | No T-main. T-fail with audit, and C on the per-user wrong-current-password counter | `403 invalid_current_password` |

A rollback after V accepted the code leaves the challenge unconsumed. The user can retry with the same code once the condition is fixed, within its lifetime and attempt limit.

**Implementation notes** (Ticket 10: `internal/auth/password`). These fill gaps in §5.3 endpoints 7, 8 and 12 to 14 and in §7.5. Item 1 resolves a conflict between two TRD rows; the rest change no approved decision.
1. **Reset on an account that left good standing.** The table above says "Reset: `invalid_code`, with the attempt committed", but the failure-accounting table says "Roll back T-main (undoing any consumption)". The code follows the rollback: the code was correct, so no attempt is charged; nothing changes; T-fail records `account_unavailable`; the response is `invalid_code`. This matches OTP sign-in (§7.3).
2. **Verify limits before Argon2id.** Set and reset must hash the new password before the code is looked at, but the verify limits (per IP, and P per email) are part of `otp.Verify`. `otp.Service.CheckVerifyLimits` runs them first, and `VerifyRequest.Prechecked` stops `Verify` from counting the IP twice. So a limited request costs no Argon2id (`TestPasswordCodes_VerifyLimitsRunBeforeArgon2id`).
3. **The `contains_email` rule on reset.** The reset request carries no email, so the challenge's `email_normalized` is read by token hash (unlocked) before the policy check. For an unknown token the rule is checked without an email, and V then rejects it. A policy answer that depends on the email reveals nothing to a third party, because only the token holder can ask.
4. **Order in change.** Policy (`422`), then `password_not_set` (`409`), then a peek at the wrong-current-password limit (`429`), then `current_password` verified against H0, then the new password hashed. All of it runs before the transaction.
   - A wrong current password increments the per-user counter and writes the failure event in autocommit statements, so neither can roll back.
   - Under L3, a hash that is no longer H0 gives `403` with `stale_current_password`, not counted.
5. **Set start.**
   - Besides `409 password_already_set`, an account that is no longer in good standing gets `401`.
   - The password state is checked again inside the start transaction, where a refusal also releases the cooldown claim.
6. **Notifications.** `password_added` and `password_changed` name the acting session's device. `password_reset_done` is not tied to a session and says "Reset with an emailed code". Device names are cut to 64 bytes at a character boundary, because session names allow 64 characters, which can be more bytes.
7. **Audit.** Each success event carries `metadata.revoked_sessions`, and each revocation also writes `auth.session.revoke`. T-fail reasons:
   - Set: `account_unavailable`, `password_already_set`, `session_invalid`.
   - Change: the same, plus `password_not_set` and `stale_current_password`.
8. **Races covered** (§12.3): refresh against change, refresh against reset, and logout against change on the acting session. The logout-versus-change test forces each interleaving, including one where the change waits on the acting session row (L4a) while holding L3 and logout queues behind it. In every run both orders occurred, with no deadlock.

**Concurrent mutations of the same user**
- They serialize on L3.
- The second one re-validates against the first one's committed state. For example, a reset that commits first revokes the acting session of a concurrent change, so the change returns `401`.
- A change that commits first makes a concurrent reset revoke all sessions afterwards. The final password is the reset's, which committed last.

### 7.6 Refresh

Defined in §8.4. One transaction.

### 7.7 Logout

```sql
UPDATE sessions SET revoked_at = now(), revoked_reason = 'logout'
WHERE id = $current AND user_id = $u AND revoked_at IS NULL;
```
Plus the audit event, in one transaction.

### 7.8 Outbox worker

Described in §8.3.

---

## 8. Sessions, tokens and email

### 8.1 Token design

**[Proposed]** Opaque tokens, checked in PostgreSQL on every request.

| Token | Format | Lifetime | Stored as |
|---|---|---|---|
| Access | `vat_` + 32 random bytes, base64url | 15 minutes | SHA-256 in `sessions.access_token_hash` |
| Refresh | `vrt_` + 32 random bytes, base64url | 30 days idle, 90 days absolute | SHA-256 in `sessions.refresh_token_hash` |

**Why opaque tokens**
- Every authenticated request runs one indexed query, so revocation takes effect on the **next request** (AC-11, AC-13, AC-18, AC-28). That is the "short, bounded window" in Product Doc §5.6, with a bound of zero.
- SHA-256 is enough for 256-bit random tokens.
- The prefixes let log redaction and secret scanners spot leaked tokens.

The per-request check:

```sql
SELECT s.id, s.user_id, u.status, u.role
FROM sessions s JOIN users u ON u.id = s.user_id
WHERE s.access_token_hash = $1
  AND s.revoked_at IS NULL
  AND s.access_expires_at > now()
  AND s.absolute_expires_at > now()
  AND u.status = 'active'
  AND u.email_verified_at IS NOT NULL;
```

**On a failed check**
- No row means `401 unauthorized`.
- If the row exists but the user is no longer active, the session is also revoked (`account_inactive`) in a short transaction. This is the automatic revocation for accounts that leave good standing.

**`last_seen_at`**
- Updated at most every 5 minutes per session, using `UPDATE ... WHERE last_seen_at < now() - interval '5 minutes'`.

### 8.2 Outbox payload protection

**[Proposed]** The outbox is the only place a plaintext code ever exists, and only in encrypted form.

**Encryption**
- The payload (template variables, including the code for OTP templates) is encrypted with AES-256-GCM under `VEEA_OUTBOX_KEY`. The row `id` is the associated data, so ciphertext cannot be moved between rows.
- `payload_key_id` identifies the key, so keys can be rotated.

**Who can decrypt**
- Only the worker decrypts, in memory, immediately before calling the `Sender`.
- The decrypted value is never logged.
- `last_error` stores only the provider's error class.

**When the payload is removed**

| Event | Action |
|---|---|
| Sent | `payload_ciphertext = NULL`, status `sent` |
| Failed: permanent rejection, or 5 reserved sends used | `payload_ciphertext = NULL`, status `failed` (§8.3) |
| Challenge consumed or superseded before sending | Row `cancelled` and payload NULLed at L5 of that same transaction (§7.2 step 4; §7.3 per-flow steps; §7.5) |
| Past `not_after` | The reaper sets `expired` and NULLs the payload (§8.3) |

The `outbox_payload_only_pending` constraint enforces that no non-pending row keeps a payload.

**Re-check before sending**
- The worker checks that the linked challenge is still open (not consumed or superseded, and `now() < expires_at`). If it is not, the row is recorded `cancelled` under the worker's lease (§8.3) without sending.

**Notification emails**
- `password_added`, `password_changed` and `password_reset_done` carry no secrets. They use the same encryption anyway, for uniformity.

### 8.3 Email delivery

**[Proposed]**

**R12: Resend selected (2026-11-14)**
- Production uses `ResendSender` behind the existing `Sender` interface: `POST https://api.resend.com/emails`, Bearer API key, and the rendered From, recipient, subject, text and HTML. SMTP remains loopback-only Mailpit for local development; fake remains available for tests.
- `VEEA_EMAIL_SENDER=resend` requires `VEEA_RESEND_API_KEY`. Only that selection reads and validates the key. `VEEA_EMAIL_FROM` is reused as a bare sender address. Startup validates syntax locally, without checking credentials or domain ownership online.
- Each call uses the outbox row UUID as `Idempotency-Key`. Retries reuse the same key and rendered body, including across worker restarts. Resend's retention is **24 hours**, not indefinite deduplication. Keep From and template rendering stable while retries are pending; a changed-payload conflict must never be bypassed by generating a new key.
- The adapter adds no retry loop, redirect following, or backoff sleeps. Request-body replay in Go's HTTP transport is disabled. The worker retains the approved 30 s timeout, live-lease guard, reservation margin, five-send cap and fixed backoff. Throttling and quota rejections consume the normal retry budget; recovery after a quota reset is not guaranteed before the row expires or exhausts that budget.
- Response text, transport errors and request data never enter errors or logs. Errors contain fixed local classes/codes; only a validated UUID provider message ID is returned on acceptance. Provider response reads are bounded.

| Resend outcome | Sender outcome |
|---|---|
| Successful HTTP response with a valid nonzero UUID email ID, including an idempotent replay | Accepted; worker records `sent`. This proves provider acceptance, not inbox delivery |
| `429` (rate or quota limit); connection refused during dial | Retryable, with worker backoff |
| `409 concurrent_idempotent_requests` | Retryable: this attempt was refused while the original is in progress; reuse the same key |
| `409 invalid_idempotent_request` | Permanent: same key with a changed payload; fail the row without changing the key |
| Other `4xx` rejections, including invalid key, unverified domain and invalid content, except `408`/unknown `409` | Permanent |
| Timeout/cancellation, reset after request, `408`, `5xx`, unknown conflict, malformed success/conflict response, missing/invalid ID or unexpected redirect/status | Ambiguous; retry within the existing worker limits |

Contract sources checked 2026-11-14: [Send Email](https://resend.com/docs/api-reference/emails/send-email), [Idempotency Keys](https://resend.com/docs/dashboard/emails/idempotency-keys), [Errors](https://resend.com/docs/api-reference/errors). The ambiguity policy for transport failures, `5xx` and unknown responses follows this TRD's outcome classes below.

**Send budget**
- At most **5 application-initiated provider sends** per outbox row, over the row's whole life, across workers, retries and crashes.
- A "send" is one call to `Sender.Send`.
- The budget is `send_attempts`: it is incremented durably **before** each call, and capped at 5 by a table `CHECK`.
- Provider-internal retries are outside the application's control and outside this count.

**Clock**
- All lease and expiry comparisons use the database clock (`now()`), never the worker's clock.

**Worker cycle.** Every statement below is a single autocommit statement. The worker never holds a transaction or a lock while calling the provider.

1. **Reap.** Terminalize rows that can no longer be sent and that no live lease protects. This covers rows left behind by a crash.
   ```sql
   UPDATE email_outbox
   SET status = CASE WHEN now() >= not_after THEN 'expired' ELSE 'failed' END,
       last_error = CASE WHEN now() >= not_after THEN 'not_after_passed' ELSE 'send_budget_exhausted' END,
       payload_ciphertext = NULL, finished_at = now(), lease_token = NULL, lease_expires_at = NULL
   WHERE status = 'pending'
     AND (now() >= not_after OR send_attempts >= 5)
     AND (lease_expires_at IS NULL OR lease_expires_at <= now());
   ```
   - **Crash recovery:** a worker that crashed after reserving its 5th send leaves the row `pending` with `send_attempts = 5`. Once the lease expires, the next reap marks it `failed`. It is never claimed again, so no 6th send is possible.
   - The cleanup job (§6.10) runs the same statement as a backstop.

2. **Claim.** Takes a lease; does **not** consume budget.
   ```sql
   UPDATE email_outbox o
   SET lease_token = gen_random_uuid(), lease_expires_at = now() + interval '2 minutes'
   WHERE o.id IN (
       SELECT id FROM email_outbox
       WHERE status = 'pending' AND send_attempts < 5
         AND next_attempt_at <= now() AND now() < not_after
         AND (lease_expires_at IS NULL OR lease_expires_at <= now())
       ORDER BY next_attempt_at
       LIMIT 20
       FOR UPDATE SKIP LOCKED)
   RETURNING o.id, o.lease_token, o.lease_expires_at, o.send_attempts, ...;
   ```

3. **Pre-send checks.** These are **skipped claims**: no budget is consumed. Each outcome is written with the lease guard `G`, defined in step 6.

   | Check | Outcome written under G |
   |---|---|
   | Linked challenge no longer open (consumed, superseded, expired), read without locks | `cancelled`, payload NULL, lease cleared |
   | Payload cannot be decrypted (unknown `payload_key_id`) | `failed` (`decrypt_error`), payload NULL; alert |
   | Worker shutting down, or the lease is too short for step 4 to succeed | Release: `lease_token = NULL, lease_expires_at = NULL`. The row stays `pending` with `send_attempts` unchanged, and is re-claimed later |

   If a G-guarded write affects zero rows, the claim was lost (step 6). The worker drops the row.

4. **Reserve.** Durably reserve one send under a **live** lease, with enough lease left to cover the send timeout:
   ```sql
   UPDATE email_outbox
   SET send_attempts = send_attempts + 1, last_send_started_at = now()
   WHERE id = $id AND status = 'pending'
     AND lease_token = $my_lease AND lease_expires_at > now() + interval '45 seconds'
     AND send_attempts < 5 AND now() < not_after
   RETURNING send_attempts;
   ```
   - **One row returned:** the reservation is committed, and the worker may call the provider exactly once.
   - **Zero rows returned:** the worker does **not** call the provider. If the lease still matches, it releases the lease as in step 3, so the row is re-claimed later.
   - This is the only place `send_attempts` increases. Every provider call is preceded by a committed reservation. A crash anywhere after the reservation still counts that send.

5. **Send.**
   - Decrypt in memory and call `Sender.Send` with a hard 30 s timeout. That is shorter than the 45 s margin required in step 4, so the lease is still live when the call returns.
   - Pass the outbox `id` as the provider idempotency key where the chosen provider supports one.

6. **Record.** Every result write uses the lease guard **G**:
   ```sql
   WHERE id = $id AND status = 'pending'
     AND lease_token = $my_lease AND lease_expires_at > now()      -- G: matching, unexpired lease, still pending
   ```

   | Provider result (§ Outcome classes) | Write under G |
   |---|---|
   | Definite success | `status = 'sent'`, `provider_message_id`, payload NULL, `finished_at`, lease cleared |
   | Permanent rejection | `status = 'failed'`, payload NULL, lease cleared |
   | Ambiguous or retryable, with `send_attempts < 5` | Stay `pending`, `next_attempt_at = now() + backoff(send_attempts)`, `last_error`, lease cleared |
   | Ambiguous or retryable, with `send_attempts = 5` | `status = 'failed'` (`send_budget_exhausted`), payload NULL, lease cleared |

   - **Zero rows updated** means the worker no longer owns the row. Possible reasons:
     - its lease expired (even if no one has re-claimed it yet)
     - another worker holds a newer lease
     - the row was cancelled, expired, reaped or deleted.
   - In that case the worker discards its result, increments `email_outbox_stale_result_total`, and logs only the row `id`. It never overwrites a newer state.
   - The send it made is already counted in `send_attempts`.

**Outcome classes**

| Provider result | Classification | Recorded as |
|---|---|---|
| Accepted, with a message id | Definite success | `sent` |
| Permanent rejection (invalid recipient, content rejected) | Definite failure | `failed`, no retry |
| Timeout, connection reset after the request was written, 5xx, or a response that cannot be parsed | **Ambiguous**: the provider may have accepted it | Retryable: `pending` with backoff, until the 5-send budget is used or `not_after` passes |
| Throttled (429) or connection refused before sending | Definite non-delivery | Retryable |

**Duplicate delivery is possible and accepted [Proposed]**
- **When it happens:**
  - An ambiguous result is retried.
  - A worker's result write fails G after a successful send (lease expired, or the worker crashed before recording), so the row is sent again by a later claim.
- **Upper bound:** at most 5 provider calls per row, enforced by the reservation in step 4 and the `CHECK`. So the recipient gets the same email at most 5 times. Typically it is once, and rarely twice.
- **What a duplicate contains:**
  - Every attempt for a row sends the **same** payload. A duplicate OTP email repeats the same code for the same challenge, never a different valid code.
  - A duplicate after the challenge was consumed or superseded is harmless: that code no longer works.
  - A duplicate notification email is only noise.
- **Mitigations:**
  - The provider idempotency key, where supported.
  - The pre-send challenge re-check.
  - The 30 s send timeout, shorter than the 45 s reservation margin.
- **Never** is a different code generated for an existing row on retry.

**Retry and polling**
- Backoff after send `n` (`n = send_attempts`): 30 s, 1 min, 2 min, 4 min. Every retry is still bounded by `not_after`.
- After the 5th reserved send there is no further send: the result write (or, after a crash, the reaper) makes the row terminal.
- The worker runs reap, then claim, every 1 s.

**Templates**
- English only, plain text plus minimal HTML.
- Code emails state the code, its 10-minute lifetime, and "if this wasn't you, ignore this email".
- Code emails contain **no sign-in links**, so a stolen email link cannot sign anyone in.

**Security notifications (AC-23)**
- `password_added`, `password_changed`, `password_reset_done`.
- Each includes the time and the device name, and says "If this wasn't you, reset your password."

**Implementation notes** (`internal/notify`, Ticket 05). These fill gaps the text above leaves open; none changes an approved decision.
- **Payload and AAD.** The payload is JSON (`{"code":...}` or `{"device_name":...,"occurred_at":...}`), sealed with AES-256-GCM as `nonce || ciphertext || tag` with the 16-byte row id as associated data. `Enqueue` takes a `pgx.Tx`, so a row exists exactly when the caller's transaction commits.
- **Deadline.** Code emails must pass the challenge's `expires_at` as `not_after`. Notifications pass nothing and the insert sets `now() + 24 h` on the database clock.
- **Pre-send re-check** reads `consumed_at`, `superseded_at`, `expires_at > now()` and also `delivery = 'code'`. A missing challenge counts as closed. A database error during the re-check releases the claim instead of guessing.
- **`last_error`** is `<class>:<code>` (for example `retryable:throttled`, `permanent:smtp_rcpt_550`, `ambiguous:timeout`) or a worker reason (`challenge_closed`, `decrypt_error`, `render_error`, `send_budget_exhausted`, `not_after_passed`). Codes are reduced to `[a-z0-9_]`, at most 40 characters, so no provider text reaches the database.
- **Unclassified sender errors are ambiguous**, including timeouts and cancellations: the provider may have accepted the email, so the row is retried within the budget.
- **Concurrency inside a batch.** Claimed rows are processed up to 4 at a time. Rows late in a batch whose lease has fallen under the 45 s margin are released, not sent.
- **Shutdown.** Claimed but unreserved rows are released. A send that is already reserved is not cancelled: it runs to its 30 s timeout and records its result, because cutting it short would only turn it into an ambiguous result.
- **Senders.** `fake` records in memory (tests). `smtp` is plain SMTP without TLS or authentication, refused for any non-loopback host, so codes never cross a network in clear text. It is for Mailpit only. Before the end of DATA, connection errors and 4xx replies are retryable and 5xx replies permanent. A lost reply after the final "." is ambiguous. The Message-ID is `<outbox id@veea.local>` and is stored as `provider_message_id`.
- **Not yet built:** the scheduled cleanup job (backstop reaper, `DeleteFinishedOutbox`) and the Prometheus metrics. The worker exposes the counts, including stale results, through `Worker.Totals()`.

### 8.4 Refresh: atomic rotation without grace

**[Proposed]** One transaction, for a presented token with hash `h`:

1. Rotate atomically:
   ```sql
   SELECT s.*, u.status, u.email_verified_at FROM sessions s JOIN users u ON u.id = s.user_id
   WHERE s.refresh_token_hash = $h FOR UPDATE OF s;
   ```
2. **Row found:** the session must not be revoked, `refresh_expires_at` and `absolute_expires_at` must be in the future, and the user must be active and verified. If any check fails, return `401`; an inactive user's session is also revoked with `account_inactive`. If all pass:
   - Insert `(h, session_id, now(), retain_until = <the locked row's current refresh_expires_at>)` into `refresh_tokens_consumed`. That value is the old token's own recorded expiry, read before the update.
   - Update the session with a new access hash and expiry, a new refresh hash, `refresh_expires_at = least(now() + 30 days, absolute_expires_at)`, and `rotation_counter + 1`.
   - Commit, and return the new pair.
   - The old access token stops working at once, because its hash was replaced.
3. **No row found:** look up the consumed token **with the retention cutoff enforced**:
   ```sql
   SELECT session_id FROM refresh_tokens_consumed
   WHERE token_hash = $h AND retain_until > now();
   ```
   - **Found: reuse.** Revoke **that session only** (L4a), with `UPDATE sessions SET revoked_at = now(), revoked_reason = 'refresh_reuse' WHERE id = $sid AND revoked_at IS NULL`. Write the audit event, increment `auth_refresh_reuse_total`, commit, and return `401`.
   - **Session-scoped:** other sessions of the same user are untouched. The user's other devices did not leak.
   - **Not found, or past `retain_until`:** a plain `401` with no revocation. This includes a consumed row that the cleanup job has not yet deleted. The token would already have expired, so presenting it is not treated as evidence of theft.

**Outcomes the client must handle**

| Case | What happens | Outcome |
|---|---|---|
| **Two concurrent refreshes with the same token** (for example two app threads) | The first locks the row and rotates. The second blocks on the row lock. Under READ COMMITTED it re-evaluates `refresh_token_hash = $h` against the committed row, finds no match, and falls to step 3. There it finds `h` in `refresh_tokens_consumed`, so it is treated as reuse. | **The session is revoked.** The first caller's new tokens also stop working, and the device must sign in again. |
| **Lost response** | The client retries with the old token, which is in `refresh_tokens_consumed`. | Reuse: the session is revoked and the device must sign in again. The account is unaffected (AC-25: consistent, no duplicates). |
| **Refresh racing a password change or reset on another device** | The mutation holds L3 (`users FOR NO KEY UPDATE`) and then updates sessions (L4b). The refresh holds only its session row (L4a) and reads `users` without a lock, so there is no lock cycle. If the refresh commits first, the mutation's `UPDATE` waits for it, re-evaluates against the rotated row (still `revoked_at IS NULL`) and revokes it. If the mutation commits first, the refresh's `SELECT ... FOR UPDATE` returns the now-revoked row, and the refresh returns `401`. | Always ends with the session revoked |

**Client contract**
- The rebuilt Flutter client must single-flight refresh per session: one refresh in flight, and other requests wait for it.
- It must persist the new refresh token before using it.

This is the price of having no grace window. It is accepted in exchange for strict, unambiguous reuse detection (§14 R2).

### 8.5 Consumed-token retention

**[Proposed]**

**How long**
- `retain_until` is the old token's **recorded** refresh expiry. That is `sessions.refresh_expires_at` as stored for that token, read under the row lock just before rotation replaces it.
- The value was set when the token was issued: `least(issued_at + 30 days, absolute_expires_at)`. So retention never outlives the token's own validity, and never exceeds the session's absolute expiry.
- It is **not** computed from `consumed_at`. A token rotated late in its life is retained only for the little validity it had left.

**Cutoff enforced at lookup**
- The reuse lookup filters on `retain_until > now()` (§8.4 step 3). A consumed token past its recorded expiry gets a plain `401` and never revokes a session, whether or not cleanup has deleted its row yet.
- Cleanup (§6.10) is for storage only. Rows also go when their session is deleted (cascade, 30 days after the session ends).

**Storage bound**
- At most one row per refresh whose token would still be valid. That covers at most the last 30 days of a session.
- With 15-minute access tokens and continuous use that is under 3,000 rows per active session. In practice it is far fewer, because clients refresh only while in use.

**Storage format**
- Hashes only. Raw tokens are never stored.

**Implementation notes** (Ticket 08: `internal/auth/session`, `internal/auth/httpapi`). These fill gaps in §8.1, §8.4, §8.5 and §10; none changes an approved decision.
- **Refresh needs its session before the transaction.**
  - The refresh limit is per session (§10), but the request carries only the token. So an unlocked read (`FindSessionForRefreshToken`) runs first and finds the session: as its current refresh hash, or as a consumed hash with `retain_until > now()`. Both branches run in one statement, so they see one snapshot: a token being rotated at that moment is in one branch or the other.
  - No row means the token is unknown or past retention: plain `401`, with no transaction and no audit event. Only then is the per-session limit counted and the §8.4 transaction run.
  - A limited refresh therefore rotates nothing; the token stays current.
  - Retention is enforced twice, in this pre-check and in the reuse lookup (`FindReusedRefreshToken`, which also returns the owner for the audit event).
- **Audit volume.**
  - §11.1 audits refresh "failures and reuse". Failures are audited only when a session is identified: a revoked session (`session_revoked`), an expired one (`session_expired`), an inactive account (`account_inactive`) and reuse (`refresh_reuse`). All of these sit behind the per-session limit.
  - An unknown token is not audited, so a flood of random tokens cannot grow `audit_events`.
  - Every revoking operation also writes `auth.session.revoke` with `metadata.reason` and `metadata.count`: reuse, logout, `account_inactive` and the cap.
- **Rotation expiries.** The new `refresh_expires_at` is `least(now + 30 days, absolute_expires_at)`, as specified. The new access expiry is capped at the absolute expiry as well (the TRD is silent). `retain_until` is the locked row's `refresh_expires_at`, read before the update.
- **Per-request check.**
  - The bearer middleware wraps every protected route. A request is refused unless it carries exactly one `Authorization: Bearer vat_…` header (scheme case-insensitive).
  - It then runs the §8.1 query. On no match, it re-reads the session's owner, and if the session is live but the account is not active or not verified, revokes that session only (`account_inactive`, §8.7).
  - The per-session request limit is counted after a successful authentication; unauthenticated requests do not count. `last_seen_at` is updated in autocommit, at most every 5 minutes; a failure there is logged and does not fail the request.
- **Responses.**
  - Every refused token gives the same `401 unauthorized` with `WWW-Authenticate: Bearer`, byte-identical apart from `request_id`.
  - Refresh bodies are strict like the others: unknown fields give `400 invalid_request`.
  - Logout returns `204` with no body. A retry after logout gets `401`.
- **Rate-limit error type.** `ratelimit.Error` is the one 429 type across modules; `otp.RateLimitedError` is an alias.
- **Not done yet.**
  - `auth_refresh_reuse_total` and the other §11.3 metrics (no Prometheus yet).
  - The races of refresh against password change and reset (§12.3) need Ticket 10.

### 8.6 Session creation and cap

**[Proposed]**

**When sessions are created**
- Each successful signup verify, OTP verify or password login inserts a new `sessions` row. No existing session is reused or ended (AC-17).

**Cap**
- A user may have at most 20 active sessions.
- Inserting the 21st revokes the session with the oldest `last_seen_at` (`session_limit`), in the same transaction (L4b).
- Concurrent sign-ins of the same user serialize on L3 (`SELECT ... FROM users WHERE id = $u FOR NO KEY UPDATE`), so the count and the eviction are consistent.

**Implementation notes** (Ticket 07: `internal/auth/session`, `internal/auth/signup`, `internal/auth/httpapi`, `internal/identity/accounts`, `internal/app`). These fill gaps; none changes an approved decision.
- **Session issuance primitive.**
  - `session.NewPending` generates the id and both tokens before the transaction (§7.1 rule 5).
  - `session.Issue(ctx, tx, pending, request)` runs inside the caller's transaction. The caller must hold the user at L3: a `FOR NO KEY UPDATE` lock, or the row it just inserted (signup).
  - It applies the cap (L4b), inserts the session with SHA-256 token hashes (L5), and writes `auth.session.revoke` when it evicts.
  - All three expiries come from one database `now()`.
  - The cap is enforced here, not deferred to Ticket 08, because every issuance must keep it.
- **Who writes `users`.** §2.2 says only `identity` writes `users`, but `internal/identity` must stay free of database code (Ticket 03). The writer is the subpackage `internal/identity/accounts`. `CreateVerified` is the `ON CONFLICT DO NOTHING` insert of §7.3.
- **Signup verify.**
  - The after-accept steps are: L3 account insert, then L4b/L5 session, then `auth.signup.verify` success (metadata `method`).
  - The OTP core then cancels the challenge's pending email and commits. Tokens are written to the response only after `Verify` returns, so after commit.
  - On conflict, the flow returns `otp.CommitFailure("account_exists", ...)`: the consumption commits, the existing row is never read or updated, and the response is `409`.
  - Any other failure, including a failed session insert, rolls back the account, the consumption and the email cancellation together.
- **`password_changed_at` on password signup.** It is set to the verification time, because the account has a password from creation (§5.2: null until a password is first set). OTP signups leave it null.
- **Order in password signup start.** Email validation, then the password policy (`422`), then the per-IP password-signup limit, then argon2id, then the OTP start. The OTP start's own per-email and per-IP limits run after hashing, so a request refused by those limits still costs one hash. The per-IP password-signup rule bounds that cost.
- **Request contract details §5 leaves open.**
  - Bodies are decoded strictly (§5.1 implementation notes): a missing or other `Content-Type` is `415 unsupported_media_type`; a malformed body or a missing field is `400 invalid_request`.
  - A missing or invalid `device` on verify is also `400 invalid_request`, before the challenge is touched.
  - `503 busy` (hasher saturated) carries `Retry-After: 1`.
  - Timestamps are RFC 3339 in UTC with sub-second precision.
  - Problem titles come from a fixed table in `httpx`; an unknown code falls back to `internal_error`.
- **Client-supplied text.**
  - The stored `User-Agent` is limited to 256 characters without control characters, and dropped entirely if it contains `vct_`, `vat_` or `vrt_`.
  - An inbound `X-Request-Id` containing a token prefix is replaced.
  - The audit writer redacts such values in `user_agent` and `request_id` instead of refusing the event. Before this change, a client could turn every audited request into a `500` with a header like `User-Agent: vct_x`.
- **Done since:** `VEEA_ARGON2_*` is read and validated (§13), and `api/openapi.yaml` with contract validation exists (§12.2 notes).

### 8.7 Automatic revocation summary

| Trigger | Sessions revoked | Reason |
|---|---|---|
| First-password set **[Approved]** | All except current | `password_set` |
| Password change **[Approved]** | All except current | `password_change` |
| Password reset **[Approved]** | All | `password_reset` |
| Refresh-token reuse **[Proposed]** | That session | `refresh_reuse` |
| Account not active, detected on a request or refresh **[Proposed]** | That session (all sessions when Phase 2 status changes ship) | `account_inactive` |
| Session cap **[Proposed]** | Least recently seen | `session_limit` |
| Current-device sign-out **[Approved]** | Current | `logout` |
| Idle or absolute expiry | Not revoked; it simply fails the check | — |

---

## 9. Password handling

### 9.1 Policy

**[Proposed]** Applied in signup, set, change and reset (AC-15). All violations are returned together in `violations`.

| Rule | Value | Violation code |
|---|---|---|
| Normalization | Unicode NFKC before every check and before hashing | — |
| Minimum length | 15 characters (code points) | `too_short` |
| Maximum length | 128 characters | `too_long` |
| Blocklist | Rejected if in an embedded blocklist of common and breached passwords (case-insensitive, exact match after NFKC). Only entries of 15 to 128 characters are kept, since shorter ones fail the length rule anyway: 5,329 entries from the SecLists Pwdb top-1,000,000 list | `too_common` |
| Contains email | Rejected if it contains the email local part (3+ characters, case-insensitive) | `contains_email` |
| Composition rules, forced rotation | None | — |

**Why 15 characters:** the NIST SP 800-63B-4 minimum for a password used as a single factor. Passphrases fit easily, and the client should say so in its copy.

**Blocklist**
- Embedded with `go:embed` and loaded into a hash set at startup.
- Source, pinned commit, source hash, filter rules and entry count are recorded in `internal/identity/blocklist/README.md`. `backend/scripts/build-blocklist.py` regenerates the file.
- Input over 4,096 bytes is `too_long` without being normalized, so hostile input never reaches the NFKC pass or Argon2.
- No online breach lookup in Phase 1.

### 9.2 Hashing

**[Proposed]**

**Parameters**
- argon2id with `m = 19 MiB`, `t = 2`, `p = 1`, a 16-byte salt and a 32-byte key.
- Stored as a PHC string.
- Rehashed on successful sign-in when the stored memory, time, threads, salt length or key length differs from the current configuration (`Verify` returns `NeedsRehash`). A stored hash is always verified with its own parameters, never the current ones.
- A stored hash must be the canonical encoding `$argon2id$v=19$m=<m>,t=<t>,p=<p>$<salt>$<key>` (unpadded standard base64). Anything else is rejected as malformed or unsupported, and never treated as "wrong password". Stored parameters are bounded (memory up to 256 MiB, time and threads up to 16, salt 8 to 64 bytes, key 16 to 64 bytes) so a corrupted row cannot make `Verify` allocate gigabytes.

**Concurrency**
- At most `GOMAXPROCS` hashes run at once, enforced by a semaphore.
- A request waiting more than 2 s gets `503 busy`, so memory stays bounded under attack.

**Timing**
- A dummy hash, computed at startup, is checked for unknown emails, passwordless accounts and pending registrations (AC-7).
- Password signup start always hashes, eligible or not (§4.4).

**Pepper**
- None. Argon2id plus rate limits is enough; revisit if the threat model changes.

---

## 10. Rate limits

**[Proposed]**

**Mechanism**
- Postgres fixed windows (§6.9), plus the atomic cooldown (§7.2). No Redis.

**Client IP** (`internal/platform/clientip`)
- The socket peer is used unless it is in `VEEA_TRUSTED_PROXIES`. For an untrusted peer `X-Forwarded-For` is ignored entirely.
- For a trusted peer, all `X-Forwarded-For` header lines are one chain, as if joined with commas. The chain is read **right to left**: trusted hops are skipped and the first untrusted hop is the client. Everything left of it is attacker-controlled and never read. If every hop is trusted, the leftmost is used. A trusted peer that sends no header is attributed as itself.
- Hops may be IPv4, IPv6, bracketed IPv6, or either with a port. IPv4-mapped IPv6 is unmapped before any comparison, so `::ffff:10.0.0.1` is the same hop as `10.0.0.1`.
- **Malformed chain fallback (proposed):** if a hop that has to be read cannot be parsed (empty, a name, `unknown`, `for=...`, a zone), or the chain has more than 32 hops or more than 4,096 bytes, the request is attributed to the trusted peer. The client cannot choose its bucket, and cannot escape limiting by sending garbage: it only shares the proxy's bucket with other garbage senders. A peer address that cannot be parsed at all shares one `unknown` bucket.
- IPv4 is bucketed per address. IPv6 is bucketed by `/64`: `ip6:<prefix>/64`. One subscriber normally holds a whole `/64`, so per-address counting would let one host rotate through 2⁶⁴ addresses.

**Counting model** (`internal/ratelimit`)
- A counter key is `<rule name>:<subject kind>:<subject>`, for example `otp_start_email_1h:email:<64 hex>`. Email subjects are `HMAC-SHA256(VEEA_EMAIL_HMAC_KEY, normalized email)`. They are built from an `identity.Email`, so they reuse the §3.2 normalization (AC-8), and no counter key, cooldown row or audit field holds a raw email.
- **Windows are fixed, aligned to the Unix epoch and measured on database time** (`date_bin` on the database `now()`, PostgreSQL 14 or newer). Every API instance therefore agrees on boundaries, and no application clock matters. A one-hour rule resets at the top of each UTC hour, a 24-hour rule at 00:00 UTC.
- **Every check is counted, allowed or not.** `Allow` increments each check even when an earlier one is already over its limit and even if the request is rejected later. The count is the number of attempts, and the behavior cannot depend on anything that happens afterwards, such as whether the account exists (AC-27). An event is allowed while its count, including itself, is at most the limit.
- **Concurrency.** Each increment is one atomic `INSERT ... ON CONFLICT DO UPDATE`. N concurrent callers on a limit of L see exactly L allowed and N−L denied, with no check-then-act gap. (The TRD did not say whether a denied attempt still counts. Counting it keeps this single-statement and race-free; the cost is that a counter keeps growing under sustained attack until its window ends.)
- **Retry-After** is the time until the end of the window of the rule that denied, rounded up to whole seconds and never below 1. When several rules deny, the longest wait is reported, so a client that obeys it is not refused again by the other rule. Because windows are fixed, a client denied just after the window opened is told to wait out the whole window.
- **Independent of the caller's transaction.** The limiter only accepts a connection pool and runs every statement in autocommit (§7.1 rule 6). A business transaction that rolls back never rolls back a counter, and the limiter never waits on locks that transaction holds.
- **Cooldown** takes the opposite stance: `Cooldown.Claim` runs on the caller's `pgx.Tx`, so a claim commits or rolls back with the challenge it allows (§7.2 step 1). Boundary: a claim exactly 60 s after the previous one is granted. Inside a transaction the database `now()` is the transaction start. So a transaction that started before a concurrent winner computes slightly more than 60 s left. Its `Retry-After` is therefore capped at the cooldown length: the winner committed before the read, so 60 s from the real current time is always enough (`TestCooldown_RetryAfterNeverExceedsTheCooldown`; found in Ticket 07).
- **Failure mode:** if the database errors, the limiter returns the error and no allowance. Callers answer 503. Failing open would let an attacker bypass limits by stressing the database.
- **Key rotation:** counters and cooldown rows are keyed by the digest under the **current** `VEEA_EMAIL_HMAC_KEY` only. Right after a rotation these start from zero. That brief loss of history is accepted. The previous key is kept for later audit lookups.

**Uniformity**
- Every per-email rule counts and responds identically for eligible and ineligible emails (AC-27). The limiter API takes only a normalized email, never an account, so this holds by construction. `TestLimiter_SameBehaviorForEligibleAndIneligibleEmails` checks it.
- All numbers are configurable in code through `ratelimit.Rules` (environment overrides are not part of §13). A unit test pins the defaults.

| Rule | Key | Limit | On exceed |
|---|---|---|---|
| Start cooldown, per purpose | purpose + email HMAC | 1 per 60 s (§7.2) | `429` |
| Start, per email (all purposes) | email HMAC | 5 per hour, 10 per 24 h | `429` |
| Start, per IP | IP | 30 per hour | `429` |
| Verify failures, per email | email HMAC | 10 per hour, across challenges | Further verifies `429` for the rest of the hour |
| Verify, per IP | IP | 60 per hour | `429` |
| Password login failures, per email | email HMAC | 10 per 15 min | Password login `429` for 15 min. **OTP sign-in and reset still work** |
| Password login, per IP | IP | 50 per 15 min | `429` |
| Password signup start, per IP (argon2 cost) | IP | 10 per hour | `429` |
| Wrong current password | user ID | 5 per 15 min. A resend after a lost successful change counts once (§5.4) | `429` |
| Refresh, per session | session ID | 30 per minute | `429` |
| Authenticated requests, per session | session ID | 600 per minute | `429` |

**Why these values**
- 5 attempts per challenge, with 10 challenges a day per email, gives an attacker at most about 5 × 10⁻⁵ chance per day of guessing a code for one address.

---

## 11. Audit, logging and metrics

### 11.1 Audit actions (AC-24)

**[Proposed]** Each event row has `action`, `outcome` and an optional `reason`.

**Registration and sign-in**
- `auth.signup.start`: `metadata.method`, `metadata.delivery`.
- `auth.signup.verify`: failure reasons are `invalid_code`, `attempts_exceeded`, `account_exists`.
- `auth.otp.start`, `auth.otp.verify`, `auth.password.login`.

**Passwords**
- `auth.password.reset.start`, `auth.password.reset.complete`.
- `auth.password.set.start`, `auth.password.set`, `auth.password.change`.

**Sessions**
- `auth.session.refresh`: failures and reuse only, to limit volume.
- `auth.session.revoke`: one row per revoking operation, with `metadata.reason` and `metadata.count`.
- `auth.logout`.

**Rate limits**
- `auth.rate_limited`.

**Privacy**
- Unknown-email events carry only `email_hmac`.
- `metadata` must never contain a password, code, token, token hash or ciphertext.

**Implementation notes** (Ticket 11). These fill gaps; none changes an approved decision.

*Coverage.* Every event below is asserted per request (by `X-Request-Id`) in `TestAudit_Matrix` or `TestAudit_RateLimitedIsRecordedOncePerWindow`: action, outcome, reason, actor, target and session, with no missing or duplicate rows.

| Action | Outcomes and reasons | Producer | Transaction |
|---|---|---|---|
| `auth.signup.start`, `auth.otp.start`, `auth.password.reset.start` | success (`metadata.delivery`; signup also `method`) | `otp.Service.Start` | Start transaction |
| `auth.password.set.start` | success; failure `password_already_set` | `otp.Service.Start`; `password.StartSet` | Start transaction; autocommit |
| `auth.signup.verify` | success (`method`); failure `invalid_code`, `attempts_exceeded`, `account_exists` | `signup.complete`; OTP core V; `CommitFailure` | T-main |
| `auth.otp.verify` | success; failure `invalid_code`, `attempts_exceeded`, `account_unavailable` | `signin.VerifyOTP`; OTP core | T-main; T-fail |
| `auth.password.login` | success; failure `invalid_credentials`, `account_unavailable`, `password_changed_concurrently` | `signin` | Success transaction; autocommit for credential failures |
| `auth.password.set` | success (`revoked_sessions`); failure `invalid_code`, `attempts_exceeded`, `account_unavailable`, `session_invalid`, `password_already_set` | `password.Set`; OTP core | T-main; T-fail |
| `auth.password.change` | success; failure `invalid_current_password`, `password_not_set`, `stale_current_password`, `account_unavailable`, `session_invalid` | `password.Change` | Success transaction; autocommit for failures |
| `auth.password.reset.complete` | success; failure `invalid_code`, `attempts_exceeded`, `account_unavailable` | `password.CompleteReset`; OTP core | T-main; T-fail |
| `auth.session.refresh` | failure `refresh_reuse`, `session_revoked`, `session_expired`, `account_inactive`. No event for a success or an unknown token | `session.Service.Refresh` | Refresh transaction |
| `auth.session.revoke` | success (`metadata.reason`, `metadata.count`) for `logout`, `refresh_reuse`, `account_inactive`, `session_limit`, `password_set`, `password_change`, `password_reset` | `session` | Same transaction as the revocation |
| `auth.logout` | success | `session.Service.Logout` | Logout transaction |
| `auth.session.revoke` (TRD 02) | success, reasons `user_revoked` and `logout_all`; actor and target = caller, session = acting session, string count; one-target event also has `target_session_id` | `session.Service.manage` | Same management transaction as revocation |
| `auth.logout.all` (TRD 02) | success, `metadata.revoked_sessions` string count | `session.Service.manage` | Same transaction, before aggregate `auth.session.revoke` |
| `account.profile.update` (TRD 03) | success; field names and profile revision, no raw values | `account.Service.UpdateProfile` | Same transaction as the effective profile update; no event for a no-op |
| `account.email.change.start` (TRD 03) | success; owned request ID | `account.Service.StartEmailChange` | Same transaction as paired proofs/outbox; then core `account.email.change.current.start` and `.new.start` (owner/session, email HMAC, delivery) |
| `account.email.change.current.verify`, `account.email.change.new.verify` (TRD 03) | failure for invalid/exhausted proof; new verify also records fixed flow rollback reasons such as `email_unavailable` | `otp.Service.VerifyPair` | Wrong attempt + failure commit; flow failure audit follows complete rollback |
| `account.email.change.complete` (TRD 03) | success; request ID, string revoked-session count | `account.Service.CompleteEmailChange` | Same transaction as email, both consumptions, all-session revocation and old/new notices; preceded by aggregate `auth.session.revoke` reason `email_change` |
| `account.deactivate` (TRD 04) | success; owner actor/target and acting session | `lifecycle.Service.Deactivate` | Same transaction as state/revision change and all-session revocation; preceded by aggregate `auth.session.revoke` reason `deactivated` |
| `account.export.start`, `account.delete.start`, `account.reactivate.start` (TRD 04) | success; owner when eligible, email HMAC, delivery | `otp.Service.Start` | Same transaction as challenge, rights operation and outbox; inert starts are indistinguishable to the caller |
| `account.export.verify`, `account.delete.verify`, `account.reactivate.verify` (TRD 04) | failure for invalid/exhausted proof, or fixed rollback reasons `binding_invalid`, `lifecycle_changed`, `export_limit` | `otp.Service.Verify` | Wrong attempt + failure commit; flow failure audit follows complete rollback |
| `account.export.request`, `account.delete.request`, `account.reactivate` (TRD 04) | success; operation ID | `lifecycle.Service.Complete` | Same transaction as proof consumption and acceptance. Deletion also seals the account, revokes all sessions (aggregate `auth.session.revoke` reason `account_delete`), fences the address and writes the restoration ledger. Reactivation adds `auth.session.revoke` reason `account_inactive` only when it revoked a row |
| `account.export.ready`, `account.export.cancel`, `account.export.expire` (TRD 04) | success; operation ID | `lifecycle` jobs (`runJob`, `expireArtifacts`) and every transition that cancels exports (`cancelExports`) | Same transaction as publication, cancellation or artifact discard |
| `account.export.download` (TRD 04) | success; operation ID | `lifecycle.Service.Download` | Same transaction as the authorized decryption, before bytes are written |
| `account.delete.purge_step`, `account.audit.minimize`, `account.delete.complete` (TRD 04) | success; fixed step, or operation ID on completion; no client context | `lifecycle` purge job | Same checkpoint transaction; the final event commits with user erasure, ledger completion and receipt update, so a failed insert rolls all of them back |
| `auth.rate_limited` | failure, reason = the rule (`metadata.rule`, `metadata.subject`) | `ratelimit.Limiter.RecordDenial`, called by the HTTP error mapper for every `429` | Autocommit, after the refusal |

*Decisions.*
- **`auth.rate_limited` is written once per rule, scope, subject and window.** Every refusal is still refused, but a flood against one limit adds one row per window, not one per request. This is the same reasoning that keeps unknown refresh tokens out of the log (§8.4).
  - The deduplication is a limit of 1 on a companion counter (`<rule>[_<scope>]_audit`) in the same fixed window.
  - The counter increment and the audit row commit in one short transaction, so a failed insert gives the slot back.
  - It runs detached from the request's cancellation, with a 2 s timeout, so a client that disconnects right after the `429` cannot suppress the record (Ticket 12 review).
  - The cooldown is per purpose, so its record is scoped by purpose (`metadata.scope`).
  - The subject is stored as `email_hmac`, `target_user_id` or `session_id`; an IP subject is the event's `ip`.
  - The rule carries its subject and window on `ratelimit.Error`, so the HTTP layer can record it without knowing which flow refused.
- **Input-validation refusals are not audited:** `400 invalid_request`, `400 invalid_email` and `422 password_policy_violation`. They happen before any account is considered and say nothing about one.
- **A retried transaction cannot duplicate events.** Events written inside a transaction roll back with a failed attempt, so a retry (§7.1 rule 7) commits each one once (`TestAudit_RetriedTransactionsDoNotDuplicateEvents`, which forces a `40001` on the first attempt of a start and of a signup verify).
- **Client-supplied text.**
  - The HTTP layer drops a token-shaped or oversized `User-Agent` (at most 256 characters are kept) and replaces a token-shaped or malformed `X-Request-Id`.
  - The audit writer redacts any that remain instead of refusing the event, so hostile metadata never turns a valid request into a `500` (`TestAudit_HostileClientMetadataIsHarmless`, `TestAudit_WriterRedactsClientTextInsteadOfFailing`).

### 11.2 Log hygiene (AC-22)

**[Proposed]**

**What is never logged**
- Request and response bodies on `/v1/auth/*` and `/v1/me/*`.
- `Authorization` and `Cookie` headers, which are dropped.

**Redaction**
- A `slog.Handler` wrapper redacts values matching `vat_`, `vrt_` or `vct_`.
- It also redacts attributes named `password`, `new_password`, `current_password`, `code`, `token`, `payload` or `ciphertext`.

**Errors and emails**
- Client error messages come from a fixed table keyed by `code`. Internal errors return `500 internal_error`, and details are logged only by `request_id`.
- Emails are logged as `email_hmac`.

**Implementation notes** (Ticket 11: `internal/platform/logging`)
- **The redacting handler wraps every logger:** `cmd/api` and the router tests.
  - It drops the value, or the whole group, of any attribute whose name:
    - contains `password`, `token`, `secret`, `payload` or `ciphertext`;
    - ends in `_hash`, `_code`, `_key` or `_email`;
    - or is `code`, `hash`, `key`, `email`, `to`, `authorization`, `cookie` or `set-cookie`.
    Emails are logged only as `email_hmac`.
  - It replaces every `vct_`/`vat_`/`vrt_` token, whatever its case, in the message, in string values, in errors and Stringers, inside groups, and in values produced by `slog.LogValuer`.
  - Any other structured value (map, slice, struct, `http.Header`) is rendered to a string and scanned. Raw `[]byte` values are dropped entirely. A typed-nil error renders as `<nil>` instead of panicking.
- **It is a backstop, not the mechanism.** Handlers never log bodies, and the integration hygiene check scans logs, audit rows, challenge, session and outbox text columns and every error response body for each code, token and password a test issued.

### 11.3 Metrics

**[Proposed]** Prometheus, internal port.

| Area | Metrics |
|---|---|
| OTP start | `auth_otp_started_total{purpose,delivery}` |
| OTP verify | `auth_otp_verified_total{purpose,result}` |
| Signup | `auth_signup_completed_total{method}` |
| Password login | `auth_password_login_total{result}` |
| Rate limits | `auth_rate_limited_total{rule}` |
| Sessions | `auth_sessions_revoked_total{reason}`, `auth_refresh_reuse_total` |
| Email outbox | `email_outbox_pending`, `email_send_total{template,result}` (result includes `ambiguous`), `email_outbox_stale_result_total` |
| Database | `db_tx_retries_total{reason}` (deadlock or serialization retries, §7.1 rule 7) |
| Argon2 | `argon2_wait_seconds` |
| Account lifecycle (TRD 04) | `account_lifecycle_accepted_total{action}` (`deactivate`, `reactivate`, `export`, `delete`), `account_jobs_total{job,result}` (`ready`, `canceled`, `expired`, `completed`, `error`), `account_deletion_oldest_pending_seconds` |

**Implementation notes** (`internal/platform/metrics`, release hardening)
- **Where they are served.** `GET /metrics` on `VEEA_METRICS_ADDR`, a listener separate from the API, with its own registry. The Go runtime and process collectors are included. Alerting is Phase 5.
- **Counted only after the commit.** A rolled-back transaction never moves a counter. Results:
  - `auth_otp_verified_total{result}`: `success`, `invalid_code`, `attempts_exceeded`, `rejected` (the code was right but the flow refused, for example `409` or an account no longer active), `rate_limited`, `error`. A transaction whose commit failed is `error`, whatever its closure had prepared. A database failure while checking the verify limits is `error`, not `rate_limited`. Set and reset check those limits before Argon2id (`Prechecked`), and their refusals are counted there.
  - `auth_password_login_total{result}`: `success`, `invalid_credentials`, `account_unavailable`, `rate_limited`, `busy`, `invalid_request`, `error`.
  - `email_send_total{result}`: `sent`, `permanent`, `retryable`, `ambiguous`, one per provider call.
  - `auth_sessions_revoked_total{reason}`: the `sessions.revoked_reason` values, added by count.
  - `db_tx_retries_total{reason}`: `deadlock` or `serialization`.
- **Label hygiene.** Every label value passes a filter that keeps only `[a-z0-9_]{1,40}` and turns anything else into `other`. An email, an IP address or a token cannot become a label even by mistake (`TestLabelsCannotCarryPersonalDataOrTokens`, and a scan of the scraped output in `TestMetrics_RecordedThroughTheRouter`).
- **`email_outbox_pending`** is read with a count query when scraped, with a 1 s timeout. A failed read reports `-1`, not a silent `0`. At most two scrapes run at once, each bounded to 5 s, so scraping cannot tie up the API pool. The gauge registers once per `Metrics`, so building a second handler with the same instance does not panic.
- **`account_deletion_oldest_pending_seconds`** is the age of the oldest accepted, unfinished purge, read when scraped like `email_outbox_pending` (`-1` on a failed read, `0` when none). It is the measure for the TRD 04 24-hour purge target; the alert threshold belongs to deployment. An idempotent completion replay is not counted again.
- **Hooks reused.** `OnTxRetry`, the hasher's `ObserveWait` and the worker's new `OnSend` and `OnStale` hooks feed the collectors; `notify` and `db` do not import the metrics package.

---

## 12. Testing

### 12.1 Harness

**[Proposed]**

**Unit tests** (`go test ./...`, no database)
- Email normalization, password policy and blocklist.
- Code generation and HMAC, token formats.
- Outbox encryption round-trip and associated-data binding.
- Rate-limit key building, log redaction.

**Integration tests**
- Run with `go test -tags=integration ./test/integration/...`.
- `VEEA_TEST_DATABASE_URL` points at a **disposable local** Postgres, such as the docker-compose service.
- Each test gets a fresh database cloned from a migrated template.
- The server runs in process (`httptest.Server`) with:
  - a controllable fake clock
  - a deterministic `Random` where a test needs it
  - a captured `slog` handler
  - the **fake `Sender`**, which records every message in memory so tests can read codes and assert that no email was sent.
- No real email provider is used in any test.
- Fixtures are synthetic: `user-<uuid>@example.test` addresses and generated IDs.
- Nothing points at a deployed server.

**Contract and route tests**
- Every integration test validates responses against `api/openapi.yaml`.
- A route test checks that every non-public route returns `401` without a token.

### 12.2 Acceptance criteria matrix (Product Doc v0.2)

| AC | Test(s) | Asserts |
|---|---|---|
| AC-1 | `TestSignupOTP_CreatesVerifiedPasswordlessAccountAndSession` | `201`; `email_verified_at` set; `has_password=false`; `GET /v1/me` works with the returned token |
| AC-2 | `TestSignupOTP_ThenOTPLogin_SameUserID` | Same `user.id` |
| AC-3 | `TestSignup_WrongCode_NoAccount`, `TestSignup_ExpiredCode_NoAccount` (both methods) | `invalid_code`; no `users` row; no session |
| AC-4 | `TestSignup_Unverified_NoAccountNoSession`, `TestUnverifiedUserRow_CannotAuthenticate` | No `users` row while pending. A row inserted directly with `email_verified_at NULL` cannot log in, refresh or use a token |
| AC-5 | `TestPasswordAndOTPLogin_SameUserID` (account from password signup) | Same `user.id` |
| AC-6 | `TestOTPStart_UnknownEmail_NoAccount` | `202`; fake sender empty; verify gives `invalid_code` even with the stored code (deterministic `Random`); `users` count unchanged |
| AC-7 | `TestPasswordLogin_GenericFailure` (table test: wrong password, unknown, passwordless, pending registration) | Identical status, `code` and body; timing within tolerance |
| AC-8 | `TestEmailCaseInsensitive` | `A.User@Example.TEST` and `a.user@example.test` resolve to one account; mixed-case signup is ineligible |
| AC-9 | `TestNonActiveAccount_CannotSignIn` (3 statuses) | Password gives `account_unavailable` after a correct password; OTP start sends nothing; existing access and refresh give `401` and the session is revoked with `account_inactive` |
| AC-10 | `TestSetFirstPassword_EnablesPasswordLogin` | Reauth code, then set, then password login works; `has_password=true` |
| AC-11 | `TestChangePassword_KeepsCurrentRevokesOthers` | A `200`, B `401` on the next request, B refresh `401`; `password_changed_at` updated |
| AC-12 | `TestChangePassword_WrongCurrent_NoChange`, `TestChangePassword_StaleCurrentAfterConcurrentChange` | `403`; hash, `password_changed_at` and sessions unchanged; B still valid; wrong-current counter +1. The second test: `H0` no longer matches under the lock, so `403` and nothing changes |
| AC-13 | `TestResetPassword_RevokesAllSessions` | A and B `401`; response has no tokens; new password works |
| AC-14 | `TestResetPassword_BadCode_NoChange` (wrong, expired, used, superseded, `delivery=none` with the correct stored code) | Hash unchanged; sessions untouched; attempts committed for wrong and `delivery=none` |
| AC-15 | `TestPasswordPolicy` (table: 14 chars, 129 chars, blocklisted, contains email) across signup, set, change, reset | `422` with `violations`; nothing changes; no attempt consumed |
| AC-16 | `TestOldPasswordFailsNewWorks_AfterChange`, `..._AfterReset` | Old gives `invalid_credentials`; new succeeds |
| AC-17 | `TestEachSignInCreatesSeparateSession` | Signup on A, then login on B: two `sessions` rows; A's token still `200` |
| AC-18 | `TestLogout_CurrentDeviceOnly` | After A logs out: A `401`; B `200`; B can refresh |
| AC-19 | `TestRefresh_OnlyActiveSessions` (table: logged out, revoked by password change, idle-expired, absolute-expired, consumed token) | `401`, no tokens issued, `sessions` row unchanged except for reuse revocation |
| AC-20 | `TestRateLimit_StartCooldown`, `_StartHourly`, `_VerifyFailures`, `_PasswordLogin`, `_WrongCurrentPassword`, `TestRateLimit_PasswordLockKeepsOTP` | `429` + `Retry-After` at thresholds; OTP still works while password login is locked |
| AC-21 | `TestOTP_SingleUse`, `TestOTP_SupersededCodeFails`, `TestOTP_ExhaustedAfterFiveFailures` | Reuse gives `invalid_code`; an old code after re-start fails; 6th try with the right code gives `code_attempts_exceeded` |
| AC-22 | `TestNoSecretsAnywhere` | Runs every flow while recording each issued code, password and token. Asserts none appears in logs, audit rows, error bodies, `otp_challenges` or `email_outbox` (ciphertext only, NULL after send) |
| AC-23 | `TestSecurityNotifications` | `password_added`, `password_changed`, `password_reset_done` sent to the account email |
| AC-24 | `TestAuditEvents_Phase1` | Expected `action` and `outcome` rows for each flow, including failures and revocations; no secrets (shared scanner) |
| AC-25 | `TestRetry_StartWithinCooldown`, `TestRetry_SignupVerifyLost`, `TestRetry_ResetCompleteLost`, `TestRetry_ChangePasswordLost`, `TestRetry_SetPasswordLost`, `TestRetry_RefreshLost` | One user row; consistent credentials; outcomes match §5.4. Change password is tested in two variants, `TestRetry_ChangePasswordLost` and `TestRetry_ChangePasswordFailedBeforeCommit`. **(a) Response dropped after commit,** then the identical body is resent. Expected:<br>• `403 invalid_current_password`, and nothing further changes.<br>• The hash is the new one: the old password fails sign-in, the new one works.<br>• Other sessions were revoked exactly once.<br>• Exactly one `password_changed` email and one success audit row, plus one failure audit row for the resend.<br>• The current session is still `200`, and the wrong-current-password counter is +1.<br>The test does **not** use `password_changed_at` to decide the outcome; it only asserts that the field is non-null. **(b) Transaction forced to fail before commit,** then resent: `204`, and the same end state as one successful change |
| AC-26 | `TestPasswordSignup_NoSessionOrCredentialBeforeVerify` | After start: no `users` row; password login gives `invalid_credentials`; no token. After a wrong code: still none. After expiry: `pending_password_hash` NULL |
| AC-27 | `TestAck_UniformPerFlow` (signup OTP, signup password, OTP start, reset start × eligible/ineligible), `TestDuplicateSignup_NoChangeNoSession` | Same status and body shape per flow (only token and timestamps differ); fake sender has mail only for eligible requests. For an existing account, signup by either method leaves `users` unchanged (`password_hash`, `updated_at`), creates no session, sends no email, and verify of that token gives `invalid_code` even with the stored code, with attempts committed |
| AC-28 | `TestSetFirstPassword_KeepsCurrentRevokesOthers` | Passwordless account with sessions A and B; set on A: A `200`, B `401`, B refresh `401` |

**Evidence as implemented** (Ticket 12). The names above were the plan; these are the tests that carry each criterion. All run through the real router unless marked *(core)*, *(query)* or *(unit)*.

| AC | Tests | Notes |
|---|---|---|
| AC-1 | `TestSignupOTP_CreatesVerifiedPasswordlessAccountAndSession` | Also checks `GET /v1/me` with the returned token |
| AC-2 | `TestSignin_OTPSignupThenOTPLoginSameUserID` | |
| AC-3 | `TestSignup_WrongOrExpiredCodeCreatesNothing` (both methods) | |
| AC-4 | `TestSignupPassword_BindsTheHashToTheChallengeUntilVerified`, `TestAuth_ExpiryRevocationAndAccountStateAreChecked`, `TestPasswordLogin_NonActiveAccount`, `TestRefresh_RefusedForRevokedExpiredOrInactiveSessions` | An unverified row cannot use a token, sign in or refresh |
| AC-5 | `TestSignupPassword_BindsTheHashToTheChallengeUntilVerified`, `TestSignin_PasswordAndOTPResolveToTheSameUser` | |
| AC-6 | `TestOTPLogin_UnknownOrIneligibleEmailGetsTheSameAckAndNoEmail` | |
| AC-7 | `TestPasswordLogin_GenericFailure` | One Argon2id verification per case with equal reduced test parameters; problem bodies match after removing request_id. Wall-clock timing is unverified |
| AC-8 | `TestSignin_PasswordAndOTPResolveToTheSameUser`, `TestSignup_DuplicateNeverChangesTheAccount`, `TestPasswordLogin_LockoutStillAllowsOTPSignin` | |
| AC-9 | `TestPasswordLogin_NonActiveAccount`, `TestAuth_ExpiryRevocationAndAccountStateAreChecked`, `TestRefresh_RefusedForRevokedExpiredOrInactiveSessions` | |
| AC-10 | `TestSetPassword_KeepsCurrentSessionAndRevokesOthers` | |
| AC-11 | `TestChangePassword_KeepsCurrentSessionAndRevokesOthers` | |
| AC-12 | `TestChangePassword_WrongCurrentChangesNothingAndIsLimited`, `TestChangePassword_StaleCurrentAfterConcurrentChange` | |
| AC-13 | `TestReset_RevokesEverySessionAndIssuesNone` | |
| AC-14 | `TestReset_BadCodeChangesNothing`, `TestReset_RevokesEverySessionAndIssuesNone` (used code) | |
| AC-15 | `TestSignupPassword_IPLimitRunsBeforeHashing`, `TestSetPassword_PolicyAndBindingAreCheckedFirst`, `TestChangePassword_PolicyAndPasswordlessAccount`, `TestContract_RemainingValidationResponses`; *(unit)* `TestPolicy*` | Router tests use `too_short`; every rule is covered by the identity unit tests |
| AC-16 | `TestChangePassword_KeepsCurrentSessionAndRevokesOthers`, `TestReset_RevokesEverySessionAndIssuesNone` | |
| AC-17 | `TestSignin_PasswordAndOTPResolveToTheSameUser` | |
| AC-18 | `TestLogout_EndsOnlyTheCurrentDevice` | |
| AC-19 | `TestRefresh_RefusedForRevokedExpiredOrInactiveSessions`, `TestRefresh_LostResponseRetryRevokesOnlyThatSession`, `TestChangePassword_KeepsCurrentSessionAndRevokesOthers` | |
| AC-20 | `TestSignup_RequestContract` (cooldown), `TestContract_RemainingRateLimitResponses`, `TestPasswordLogin_LockoutStillAllowsOTPSignin`, `TestChangePassword_WrongCurrentChangesNothingAndIsLimited`, `TestPasswordCodes_VerifyLimitsRunBeforeArgon2id`; *(core)* `TestOTP_VerifyFailureLimitIsCheckedBeforeTheTransaction`, `TestOTP_StartLimitsAreCountedBeforeTheTransaction` | |
| AC-21 | `TestSignupOTP_CreatesVerifiedPasswordlessAccountAndSession` (reuse), *(core)* `TestOTP_ResendSupersedesAndOnlyTheNewCodeIsMailed`, `TestOTP_ExhaustedAfterFiveFailures` | |
| AC-22 | The hygiene scan of every router test (logs, audit rows, challenge, session and outbox text, every error body), `TestAC22_ErrorBodiesNeverContainTheIssuedCode`, `TestAudit_HostileClientMetadataIsHarmless`; *(unit)* `TestRedactingHandlerRemovesSecrets` | The six-digit check is scoped to each code's own error responses, with the request id removed |
| AC-23 | `TestAC23_SecurityNotificationsAreDeliveredToTheAccount`, `TestOutbox_DeliversThroughMailpit` | |
| AC-24 | `TestAudit_Matrix`, `TestAudit_RateLimitedIsRecordedOncePerWindow`, `TestAudit_IPSubjectRateLimitedOncePerWindow` | |
| AC-25 | `TestSignup_RequestContract`, `TestSignupOTP_CreatesVerifiedPasswordlessAccountAndSession`, `TestReset_RevokesEverySessionAndIssuesNone`, `TestChangePassword_LostResponseResend`, `TestChangePassword_FailedBeforeCommitThenResend`, `TestSetPassword_KeepsCurrentSessionAndRevokesOthers`, `TestRefresh_LostResponseRetryRevokesOnlyThatSession` | |
| AC-26 | `TestSignupPassword_BindsTheHashToTheChallengeUntilVerified`, `TestPasswordLogin_GenericFailure` (pending registration), `TestCleanup_AC26_ScrubsTheExpiredPendingPasswordHash` | The cleanup runner scrubs an expired challenge's hash at run time, and deletes the challenge and its email 24 h later |
| AC-27 | `TestSignup_AcknowledgementIsUniform`, `TestOTPLogin_UnknownOrIneligibleEmailGetsTheSameAckAndNoEmail`, `TestReset_AcknowledgementIsUniform`, `TestSignup_DuplicateNeverChangesTheAccount` | |
| AC-28 | `TestSetPassword_KeepsCurrentSessionAndRevokesOthers` | |

**Contract verification** (Ticket 12: `backend/api/openapi.yaml`)
- **What is checked without a database** (`go test ./api`, part of `make check`):
  - the document is valid OpenAPI 3.0;
  - its operations equal the patterns the real router registers (`httpx.Patterns`), in both directions;
  - every operation lists its problem codes in `x-error-codes`.
- **Every router test is a contract test.** The shared test server validates each exchange with kin-openapi:
  - the status must be documented, and the body and headers must match the schema (`X-Request-Id`, `Cache-Control: no-store`, `Retry-After` on 429 and on `busy`, `WWW-Authenticate: Bearer` on `unauthorized`);
  - the problem `code` must be listed both by the operation (`x-error-codes`) and by that status's response (`x-codes`), and the body's `status` must equal the HTTP status;
  - protected operations count as authenticated only with a `Bearer` credential;
  - a 2xx answer to a request the spec forbids also counts as a violation;
  - requests outside every operation must get the 404/405 problem.
  A violation fails the test that caused it. After a full run, `TestMain` fails if any documented operation, status or error code was never produced, unless it is listed with its other evidence in `notExercised`.
- **Not exercised** through the router: `GET /readyz 503` (covered by the `httpx` unit tests) and `GET /v1/me 500`.
- **Unmatched requests:** unknown paths, wrong methods and `HEAD` get problem documents (§5.1 implementation notes). They are not operations, so the info description documents them.

### 12.3 Additional tests (§7–§8)

**How concurrency tests run**
- Each test runs its parallel requests with a start barrier and a 10 s deadline. A Postgres deadlock (`40P01`) or a hang fails the test.
- Every test also asserts that `db_tx_retries_total` did not increase. If the lock order in §7.1 is followed, no retry is ever needed.

**Concurrency: OTP and signup**
- `TestConcurrent_FirstOTPIssuance`: 20 parallel starts for a new email and purpose give exactly one `202` and the rest `429`, with one open challenge row and at most one outbox row. Run for eligible and ineligible emails.
- `TestConcurrent_VerifySameToken`: exactly one success; the others get `invalid_code`; one session.
- `TestConcurrent_SignupDifferentAttemptsSameEmail`: two password signups verified at once give one `201` and one `409 signup_unavailable`; the stored hash is the winner's.
  - *Correction (Ticket 07):* two open signup attempts for one email cannot exist, because a new start supersedes the open one (§4.2, `otp_challenges_one_open`). The race that does exist is a verify of attempt Y against a new start X for the same email. `TestSignup_VerifyRacingANewAttemptForTheSameEmail` covers it. Whatever the interleaving, there is at most one account, it carries Y's hash, and X then gets `409` or `invalid_code`, never a session. `TestSignup_AccountAppearedMeanwhileGives409` covers the `409` path deterministically.

**Concurrency: sessions and password mutations**
- `TestConcurrent_SignInsSameUser_NoDeadlock`: 20 parallel password logins and OTP verifies for one user, with the session cap at 5 and some logins rehashing. No deadlock; exactly 5 active sessions afterwards; evictions recorded as `session_limit`.
- `TestConcurrent_LoginVsPasswordChange`: a login with the old password racing a change ends in one of two ways. Either the login gets `401 invalid_credentials` (hash re-check under L3), or its session exists and is revoked by the change. A session that is still active and was created with the old password must never exist.
- `TestConcurrent_ChangeVsReset`: either order commits cleanly. After the reset commits, every session is revoked and only the reset's password works.
- `TestConcurrent_SetPasswordTwiceSameUser`: two set requests from two sessions, each with its own valid challenge. One `204`, the other `409 password_already_set` or `401`. One `password_added` email.
- `TestPasswordMutation_ActingSessionRevokedMidFlight`: a hook pauses the request after authentication and before the transaction, while logout, or a reset from another client, commits. Set and change then return `401`. The hash is unchanged, other sessions are untouched by this request, and no notification is sent.
- `TestPasswordMutation_AccountInactiveMidFlight`: the same hook while the user's status is set to `suspended`. Set and change return `401`; reset with a valid code returns `invalid_code`. Nothing changes.
- `TestConcurrent_RefreshSameToken`: the session is revoked (`refresh_reuse`), and both tokens issued afterwards are invalid.
- `TestConcurrent_RefreshVsPasswordChange`, `TestConcurrent_RefreshVsReset`: the session always ends revoked, with no deadlock.
- `TestConcurrent_LogoutVsPasswordChangeOnSameSession`: either logout wins (change returns `401`, nothing changes), or the change wins (logout then revokes the kept session). No deadlock.
- `TestConcurrent_LoginVerifyVsReset`: an OTP login verify and a reset complete for the same user, run in parallel. No deadlock. If the login commits first, its session is revoked by the reset. If the reset commits first, the login still succeeds, because it proved control of the email after the reset.
- `TestConcurrent_VerifyVsStartSupersede`: a verify of challenge X racing a new start that supersedes X. They serialize on L2. Either the verify succeeds and X's outbox row is cancelled by the verify, or the verify gets `invalid_code` and X's row is cancelled by the start. Never both, and never a deadlock.
- `TestConcurrent_VerifyVsOutboxWorker`: a verify cancels the challenge's outbox row while a worker holds its lease. No deadlock. The worker's G-guarded write updates zero rows.

**Lock order and transaction boundaries**
- `TestLockOrder_StatementSequence`: a query tracer in the test harness records, per transaction, the lock level of each statement (§7.1 table). For every flow in §7.1, run happy and failure paths and assert:
  - The levels never decrease. In particular, no `email_outbox` write precedes an L3 or L4 statement in signup verify, OTP verify, reset complete or set password.
  - `users` is locked with `FOR NO KEY UPDATE`, except TRD 03 final email cutover, which takes `FOR UPDATE` from the outset.
- `TestTransactionBoundaries_VerifyFailures`:
  - A counted V rejection commits the attempt and the audit in T-main, then C.
  - A post-accept failure (account not active, acting session revoked, password already set) rolls back T-main, leaving the challenge unconsumed and `attempts` unchanged, and commits only the T-fail audit.
  - Covers signup verify, OTP verify, reset complete and set password.

**Refresh and sessions**
- `TestRefresh_ReuseRevokesOnlyThatSession`: the user's other session is still `200`.
- `TestRefresh_RetentionUsesRecordedExpiry`:
  - A token is issued at `t0` with recorded expiry `t0 + 30d`, then rotated at `t0 + 29d`. `retain_until = t0 + 30d`, not `t0 + 59d`.
  - Before `t0 + 30d`, presenting it revokes the session.
  - After `t0 + 30d`, **with the row still present** (cleanup not run), it gives a plain `401` and the session stays active.
- `TestRefresh_RetentionCappedByAbsoluteExpiry`: `retain_until` never exceeds `absolute_expires_at`.
- `TestRefresh_RotationInvalidatesOldAccessToken`.
- `TestSessionCap_EvictsLeastRecentlySeen`.

**OTP and ineligible challenges**
- `TestSignupBinding_CodeOnlyValidForItsToken`: a code from attempt X with token Y gives `invalid_code`, and an attempt is charged to Y.
- `TestFailedAttempts_PersistAcrossRequests`: failures survive a server restart (new pool) and still count. Covers verify, reset complete and set password.
- `TestDeliveryNone_NeverAuthenticates`:
  - Uses a deterministic `Random`, so the test knows the stored code of a `delivery = 'none'` challenge.
  - Presents the **correct** code to signup verify, OTP verify and reset complete.
  - Each returns `invalid_code`, then `code_attempts_exceeded` after 5 tries.
  - `attempts` and the per-email failure counter increase exactly as for a wrong code on a real challenge.
  - The audit reason is `invalid_code`.
  - No `users` row is created or changed, no session is issued, and no hash changes.
  - Response bodies match the eligible-wrong-code case byte for byte, apart from `request_id`.
- `TestDeliveryNone_ConstraintRejectsConsumption`: a direct `UPDATE ... SET consumed_at = now()` on a `delivery = 'none'` row fails with a check violation. The same holds for setting `user_id` or `pending_password_hash`.

**Outbox**
- `TestOutbox_PayloadEncryptedAndScrubbed`: ciphertext only while pending; NULL after sent, failed, expired or cancelled; the constraint rejects a non-pending row with a payload.
- `TestOutbox_SupersededChallengeNotSent`: if the user starts again before the worker runs, only the new code is mailed.
- `TestOutbox_RetryBackoffAndExpiry`, with a failing fake sender.

**Outbox: test setup**
- These tests set the lease, margin and send timeout to short values: 2 s lease, 1 s margin, 0.5 s timeout.
- The fake sender can be made to block or to ignore the timeout, to simulate a misbehaving client library.
- Lease expiry uses the database clock, so tests wait real time on those short values. They do not use the fake application clock.

**Outbox: send budget**
- `TestOutbox_MaxFiveProviderSends`: the fake sender always returns an ambiguous timeout. `Sender.Send` is called exactly 5 times. The row ends `failed` (`send_budget_exhausted`) with a NULL payload. Further worker cycles make no call.
- `TestOutbox_SendAttemptsCheckConstraint`: a direct `UPDATE ... SET send_attempts = 6` fails.
- `TestOutbox_ReservationRequiresLiveLease`: with less than the margin of lease left, reservation returns zero rows. No `Send` call is made, the lease is released, and `send_attempts` is unchanged.
- `TestOutbox_SkippedClaimsDoNotConsumeBudget`: claim then release (shutdown, short lease), repeated 10 times. `send_attempts` stays 0. The row is then sent normally.

**Outbox: crash recovery**
- `TestOutbox_CrashAfterReservation`: a worker reserves send 3, "crashes" without recording, and calls no provider. After the lease expires, another worker claims and reserves send 4. Total `Send` calls never exceed reservations.
- `TestOutbox_CrashAfterFifthReservation_Reaped`: a worker reserves send 5 and crashes. While the lease is live, the reaper does not touch the row. After expiry, the reaper marks it `failed` with a NULL payload. No 6th call ever happens.

**Outbox: result recording**
- `TestOutbox_RecordRequiresUnexpiredLease`: a worker's lease expires with no other worker re-claiming the row. Its result write, with a **matching** `lease_token`, still updates zero rows. The row stays `pending` and is re-sent by a later claim within the budget.
- `TestOutbox_StaleLeaseResultDiscarded`:
  - Worker A claims and reserves a send. The fake sender blocks A past its lease.
  - Worker B re-claims, reserves, sends and records `sent`. A's late result updates zero rows.
  - The final row reflects B. `send_attempts = 2`, and `email_outbox_stale_result_total = 1`.
  - The fake sender recorded two deliveries with the **same** code (the documented duplicate).
- `TestOutbox_AmbiguousResultRetriesSamePayload`: the fake sender records the message and then returns a timeout. The row is retried and delivered again. Both messages carry the same code. After the final success the row is `sent`, with `send_attempts = 2`.
- `TestOutbox_PermanentRejectionNotRetried`: one `Send` call; the row is `failed`.
- `TestOutbox_CancelledWhileSending`: the challenge is consumed while the worker is sending. The worker's G write updates zero rows, and the row stays `cancelled` with a NULL payload.
- `TestOutbox_NotAfterPassedIsReaped`: a pending row past `not_after` with no live lease becomes `expired`, and is never claimed.

**Other**
- `TestAuthRequiredOnAllPrivateRoutes`, `TestArgon2_RehashOnLogin`.

### 12.4 Verification before release

Run unit, integration and contract tests locally against disposable PostgreSQL and Mailpit using the scripts below. Record results in the ticket that closes TRD 01. Never run tests or scripts against a deployed server.

**Cleanup closeout evidence** (2026-11-14, before R12 integration)

*What was tested*
- **Code:** branch `feat/go-email-auth-account-foundation`, commit `d73f15d` plus the uncommitted closeout changes: migration `00007_cleanup_indexes.sql`, all six batch deletes by tuple id, and their tests.
- **Environment:** local only. Go 1.26.2 (darwin/arm64), PostgreSQL 17.11 (`postgres:17-alpine`) and Mailpit v1.33.1.
- **Local services:** the Go backend has no docker-compose file of its own. Run `scripts/test-postgres.sh start` and `scripts/test-mailpit.sh start` from `backend/` (or the Make targets below). Both bind only to `127.0.0.1` and are disposable; use each script's `stop` command afterwards to discard its data.
  - `backend/scripts/test-postgres.sh` (`make test-db-up` / `make test-db-down`) serves PostgreSQL at `127.0.0.1:54329`.
  - `backend/scripts/test-mailpit.sh` (`make mailpit-up` / `make mailpit-down`) serves SMTP `127.0.0.1:1025` and the API `127.0.0.1:8025`.

*Commands and results* (from `backend/`)

| Command | Result |
|---|---|
| `make check` (gofmt, `go vet` with and without the integration tag, unit tests) | Pass, 15 packages |
| `make build` | Pass (`bin/api`, `bin/migrate`) |
| `make sqlc` then `make sqlc-verify` | Regenerated successfully; "sqlc output is up to date and reproducible" |
| `VEEA_TEST_DATABASE_URL=postgres://postgres@127.0.0.1:54329/postgres VEEA_TEST_SMTP_ADDR=127.0.0.1:1025 VEEA_TEST_MAILPIT_API=http://127.0.0.1:8025 go test -race -tags=integration -count=1 -json ./...` | 16 test-bearing packages pass; 11 packages have no test files. **762 passed (334 top-level), 0 failed, 0 skipped tests** (counts include parent tests and subtests). The integration package alone: 405 passed. `TestOutbox_DeliversThroughMailpit` ran and passed |
| The same run's contract checker | 0 violations across 99 operation/status/code combinations. Not produced through the router: `GET /readyz 503` (covered by `httpx` unit tests) and `GET /v1/me 500` |
| `VEEA_TEST_DATABASE_URL=postgres://postgres@127.0.0.1:54329/postgres go test -race -tags=integration -count=1 -json -run 'TestCleanup_\|TestMigrations_\|TestQuery_' ./test/integration/` | **49 passed (38 top-level), 0 failed, 0 skipped**, including cleanup, empty-database and version-6 upgrade checks and EXPLAIN evidence |

*Read-only review*
- One reviewer checked the migration, cleanup-query and closeout diff. No migration or cleanup-query correctness issues were found. One confirmed AC-7 evidence overstatement was corrected in both the implemented-evidence table and this section: reduced test parameters and request-ID normalization are now explicit. The reviewer verified the correction and reported no remaining findings. The affected cleanup/migration race checks and sqlc verification passed again.

*Migration `00007` evidence*
- **From an empty database:** `TestMigrations_CleanDatabaseAppliesEveryVersion`, `TestMigrations_EmptyDatabaseGetsTheCleanupIndexes`.
- **From version 6 with existing rows:** `TestMigrations_UpgradeFromVersion6KeepsDataAndAddsIndexes`. Only version 7 is applied, the row counts are unchanged, and every index is valid and ready.
- **Replay:** `TestMigrations_StatementsAreReplayable`, so every statement is `IF NOT EXISTS`.
- **Plans:** `TestMigrations_CleanupQueriesUseTheirIndexes` (§6.10 implementation notes). On version 7:
  - all six batch selectors use retention indexes, with a TID scan for each outer delete; the challenge expiry index also supplies `ORDER BY expires_at` without a sort;
  - the password scrub uses `otp_challenges_expires`, the reaper uses the pending-only `email_outbox_due`, and both cascade lookups use the new foreign-key indexes; none of these fixture plans has a sequential scan;
  - on version 6, the session, rate-limit, cooldown and finished-outbox statements are sequential scans.

*AC-26 at run time*
- `TestCleanup_AC26_ScrubsTheExpiredPendingPasswordHash` starts a password signup through the router and moves its challenge past `expires_at`. One run of the real cleanup runner then clears `pending_password_hash`, while an open challenge keeps its own.
- Verifying the abandoned code gives `invalid_code`, and no account or session exists.
- Once the challenge is 24 h past expiry, the next run deletes it and its outbox row.
- `cmd/api` wires the same runner to start with the process and repeat every 5 minutes. This run verifies it through the integration tests, including lock release on failure and cancellation; it does not include a separate API-process smoke test. Hash scrubbing is asynchronous: it occurs on the next successful cleanup run after expiry, while code verification rejects an expired challenge immediately.

*AC-7, the verification limit*
- **Verified: equal Argon2id work in the test configuration.** Wrong password, unknown email, passwordless account and pending registration each perform exactly one real Argon2id verification (the dummy hash where there is none), using the same reduced test parameters: 64 KiB memory, one iteration, one thread. Each returns `401 invalid_credentials` with identical problem bodies after removing the per-request `request_id`. `TestPasswordLogin_GenericFailure` counts verifications through an instrumented hasher. This does not measure production-cost execution.
- **Not verified: wall-clock timing.** Response times were not measured. Differences from the account read, the failure audit insert or the counter update are not bounded by any test. A timing-tolerance check, as the AC-7 row of §12.2 sketches, remains open.

**R12 Resend implementation evidence** (2026-11-14)

- **Code:** branch `feat/go-email-auth-account-foundation`, commit `1f0ebda` plus the uncommitted Resend sender, configuration, startup wiring and tests. The cleanup closeout evidence above is preserved from the preceding change.
- **Target:** the same disposable local PostgreSQL 17.11 and Mailpit v1.33.1 services described above, plus loopback `httptest` servers standing in for Resend. No real Resend API call, credential validation, domain verification or inbox-delivery check was performed.
- **Adapter evidence:** `TestResend_AcceptedRequest` checks authentication, JSON text/HTML, row-ID idempotency, one HTTP attempt and disabled transport replay. `TestResend_OutcomeClassesAndSafeErrors` checks permanent, retryable and ambiguous responses, including both documented idempotency conflicts, quotas, invalid responses and untrusted provider text. Redirect, connection-failure, cancellation, input-validation and credential-formatting tests pass.
- **Lost response:** `TestResend_TimeoutThenRetryKeepsKeyAndPayload` models acceptance before withholding the response until timeout; the retry uses identical key/body and retrieves the modeled acceptance. `TestResendWorker_TimeoutRetryPreservesReservationAndIdempotency` exercises the real worker and PostgreSQL: first send records `pending`, one reservation and an ambiguous timeout; a new sender/worker retries the identical row ID and payload, then records `sent`, two reservations, the provider ID, cleared lease and scrubbed payload. These establish behavior against the stand-in, not live provider deduplication.
- **Configuration:** `TestResendSettingsAndSecretHygiene` confirms keys are required only for Resend, unused Resend credentials are ignored for SMTP/fake, From is shared, and the credential is absent from configuration logs. Sender errors use fixed local codes and worker logs exclude the key and email content.

Commands run from `backend/` (all exited 0 after implementation fixes):

| Command | Result |
|---|---|
| `make check` | Formatting, vet with/without integration tags and unit tests passed; 15 test-bearing packages |
| `make build` | API and migration binaries built |
| `VEEA_TEST_DATABASE_URL=postgres://postgres@127.0.0.1:54329/postgres go test -race -tags=integration -count=1 -json -run 'TestResend\|TestResendSettings' ./internal/notify ./internal/platform/config` | **45 passed (8 top-level), 0 failed, 0 skipped**, across 2 packages |
| `VEEA_TEST_DATABASE_URL=postgres://postgres@127.0.0.1:54329/postgres VEEA_TEST_SMTP_ADDR=127.0.0.1:1025 VEEA_TEST_MAILPIT_API=http://127.0.0.1:8025 go test -race -tags=integration -count=1 -json ./...` | **807 passed (342 top-level), 0 failed, 0 skipped tests**; 16 test-bearing packages passed, 11 packages have no test files. Counts include parents and subtests. `TestOutbox_DeliversThroughMailpit` passed; the contract checker covered 99 operation/status/code combinations with no violations and the same documented coverage limits as above |

*Release gates still open*
- **Resend staging checks.** Verify the sending domain and the deployed key's sending permission, then confirm real delivery of OTP and security-notification email from the configured From address. None of these live checks was run locally; R12 is selected, while delivery readiness remains unverified.
- **Phase 5 alerting.** The §11.3 metrics are exported, but alert rules on them, including `db_tx_retries_total` (§7.1 rule 7), are Phase 5 scope.
- **The closing ticket.** These results are to be copied into the ticket that closes TRD 01.
- **AC-7's wall-clock timing check.** The timing-tolerance part of §12.2 remains unverified and must be measured or explicitly accepted as a release limitation.

---

## 13. Configuration

**[Proposed]**

| Variable | Purpose | Local default |
|---|---|---|
| `VEEA_HTTP_ADDR` | Listen address | `:18386` |
| `VEEA_METRICS_ADDR` | Internal metrics listener (`GET /metrics`): `host:port` with an IP address or `localhost`, or `:port`; port 1 to 65535, not shared with `VEEA_HTTP_ADDR` on an overlapping host | `127.0.0.1:9090` |
| `VEEA_DATABASE_URL` | Postgres DSN | docker-compose value |
| `VEEA_OTP_KEY` | HMAC key for stored code hashes (§4.2): hex, at least 32 bytes (64 hex characters), as `current` or `current,previous`. New hashes use the current key; verification tries both | Generated by `make backend-env` |
| `VEEA_EMAIL_HMAC_KEY` | HMAC key for email in cooldown, rate-limit and audit keys: hex, at least 32 bytes (64 hex characters), as `current` or `current,previous` | Generated |
| `VEEA_OUTBOX_KEY` | AES-256-GCM key(s) for outbox payloads, as `id:hexkey[,id:hexkey]`, current first. Ids 1 to 32767, unique; keys exactly 32 bytes (64 hex characters). Earlier keys only decrypt old rows | Generated |
| `VEEA_TRUSTED_PROXIES` | Comma-separated CIDRs or bare IPs trusted for `X-Forwarded-For`. Empty means the header is ignored | Empty |
| `VEEA_EMAIL_SENDER` | `smtp` (Mailpit), `fake` (tests), or `resend` (R12) | `smtp` |
| `VEEA_RESEND_API_KEY` | Resend Bearer API key, required and validated only with `VEEA_EMAIL_SENDER=resend`; never logged | Unset |
| `VEEA_SMTP_ADDR`, `VEEA_EMAIL_FROM` | Mail settings. SMTP host must be loopback; From is a bare address shared with Resend and must use a verified sending domain for Resend | `localhost:1025`, `no-reply@veea.local` |
| `VEEA_ARGON2_MEMORY_KIB`, `VEEA_ARGON2_TIME`, `VEEA_ARGON2_THREADS` | Hash parameters (§9.2). They must pass the hasher's bounds; memory × time must be at least 19456 KiB × 2; and memory must be at least 7168 KiB, the smallest in the OWASP equivalent-cost table. So the cost can be tuned up or traded between memory and passes, but never below the approved floor or into a setting that is barely memory-hard | `19456`, `2`, `1` |

- Startup fails if an HMAC/encryption key is missing or too short. The Resend API key has its own syntax check and is required only when selected.
- **HMAC/encryption key rotation:** keys accept a current and a previous value. Verification tries both, and writes use the current key. `VEEA_EMAIL_HMAC_KEY` is the exception: new digests always use the current key, and counters are keyed by it only (§10). The Resend API key is a single deployment credential, not a comma-separated keyring.

---

## 14. Decisions

R1–R11 and R13–R15 were **approved on 2026-11-13** together with TRD v0.4 and are binding for implementation. **R12: Resend selected on 2026-11-14.** Verified-domain and real-delivery checks remain staging gates (§12.4).

| ID | Status | Decision | Chosen | Alternative considered | Cost of the choice |
|---|---|---|---|---|---|
| **R1** | Approved | Access token type | Opaque, one PostgreSQL check per request; revocation immediate | JWT, no DB read | One indexed read per request |
| **R2** | Approved | Refresh rotation | Atomic, **no grace**; concurrent or lost-response retries revoke the session | A short grace window | Users are signed out after a lost refresh response or a client race. Requires single-flight refresh in the client |
| **R3** | Approved | Consumed-token retention | Until the token's natural expiry, at most 30 days | Whole session lifetime, or only the last N tokens | Reuse of a token older than its natural expiry is not detected, which is acceptable because it is already unusable |
| **R4** | Approved | Reuse response scope | That session only | All of the user's sessions | A thief holding tokens from several sessions would need reuse detected on each |
| **R5** | Approved | Signup verify when the account appeared meanwhile | `409 signup_unavailable` | Generic `invalid_code` | Tells the code holder (the mailbox owner) that the account exists, which is needed to send them to sign-in |
| **R6** | Approved | First-password set requires a fresh email code | Yes | Session alone is enough | One extra step. It stops a stolen session from adding a durable credential |
| **R7** | Approved | Reset sets a first password on passwordless accounts | Yes | Reset only for accounts with a password | Reset doubles as an alternative way to add a password |
| **R8** | Approved | Password policy | 15–128 characters + about 100k blocklist + contains-email check | 8 or 12 character minimum | Longer passwords may raise signup friction; client copy should suggest passphrases |
| **R9** | Approved | Code location and migrations | New `backend/` directory; `cloud/` (Rust) stays until retired. A separate `migrate` step before deploy | Replace `cloud/` in place; migrate on startup | Two backends coexist for a while. AGENTS.md needs updating when work starts |
| **R10** | Approved | Change-password lost response | No server exception and no per-request proof. A resend returns `403`. The client shows the unknown-outcome UX (§5.4); the notification email is the user's confirmation. `password_changed_at` is informational only | A client-generated `change_id` stored on the user row and checkable on `GET /v1/me` (server-side proof, a small schema addition) | An unknown outcome cannot be resolved by the app alone. The user relies on the email, or uses Forgot password |
| **R13** | Approved | Lock order and modes | §7.1: `users FOR NO KEY UPDATE` except TRD 03 final email cutover (`FOR UPDATE` from outset); acting session re-validated under lock; deadlock retry up to 3 times | `SERIALIZABLE` isolation with retries | All same-user sign-ins and mutations serialize on one row. Fine at expected per-user concurrency |
| **R14** | Approved | Duplicate email delivery and send budget | At most 5 provider sends per row, each durably reserved under a live lease. Duplicates are accepted after an ambiguous result or a lost lease, with the same payload every time | Never retry ambiguous results (risk of no delivery); or a smaller budget | A user may occasionally get the same email twice, at most 5 times. A row whose 5 sends all failed ambiguously ends `failed`, even if one was actually delivered |
| **R15** | Approved | Outbox lease timing | 2-minute lease, 45 s minimum lease left to reserve, 30 s send timeout, reap and claim every 1 s | Longer lease (slower crash recovery); shorter timeout | A worker crash delays that row's next send by up to 2 minutes |
| **R11** | Approved | Session cap | 20 active sessions per user, least recently seen evicted | No cap | A heavy multi-device user could be signed out silently |
| **R12** | **Resend selected** | Production email provider | Resend Email API behind `Sender`; outbox UUID as idempotency key. Fake sender in tests, Mailpit locally | — | Provider deduplication lasts 24 h. Verify the sending domain and real delivery before release (§12.4) |

---

## 15. Delivery plan

### 15.1 Tickets

**[Proposed]** Each ticket is tied to the ACs it covers.

1. **Skeleton:** config, keys, pgx pool, tx helper, redacting slog, health, `cmd/migrate`, docker-compose (Postgres + Mailpit), integration harness with fake sender. *(AC-22 scanner)*
2. **Migrations** 00001–00006 and sqlc queries.
3. **Identity:** email normalization, password policy and blocklist, argon2id with semaphore and rehash. *(AC-8, AC-15)*
4. **Rate limiter, cooldown claim and trusted-proxy IP.** *(AC-20)*
5. **Email outbox:** encryption, worker, templates, SMTP and fake senders, scrub and cleanup. *(AC-22, AC-23)*
6. **OTP challenge core:** start, supersede, verify, committed failures. *(AC-3, AC-21)*
7. **Signup:** OTP and password methods, binding, eligibility. *(AC-1, AC-4, AC-26, AC-27)*
8. **Sessions:** issue, auth middleware, refresh rotation and reuse, consumed-token retention, cap, logout. *(AC-17, AC-18, AC-19)*
9. **OTP sign-in and password login.** *(AC-2, AC-5, AC-6, AC-7, AC-9)*
10. **Password set, change and reset.** *(AC-10–AC-16, AC-28)*
11. **Audit events** across all flows. *(AC-24)*
12. **OpenAPI document, contract and auth-route tests, retry and concurrency suite.** *(AC-25)*

### 15.2 Sequence

1. Product Doc v0.2 approval.
2. **This TRD's approval** (R1–R11 and R13–R15 approved; R12 Resend selected).
3. Tickets.
4. Implementation.
5. Verification (§12.4).
