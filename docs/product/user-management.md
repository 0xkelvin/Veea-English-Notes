# Veea English Notes — User Management Product Doc

**Version:** v0.2 (Phase 1 decisions approved; later phases still proposals)
**Date:** 2026-11-13
**Audience:** Product, backend and Flutter engineers, QA
**Next document:** TRD 01 — *Email Authentication & Account Foundation*

### Changes since v0.1
- Two registration paths: email OTP without a password, and email + password followed by email OTP verification (Q1 resolved).
- Same acknowledgement for registered and unregistered emails within each public flow. Only eligible requests send email. Signup with an existing email changes nothing and signs nobody in (Q2 resolved).
- Email change moved to follow-up scope (Q3 resolved).
- Setting a first password while signed in now preserves the current session and revokes all others, like a password change.
- Phase 1 session scope narrowed to: session creation, refresh, current-device sign-out and automatic revocation. Device listing, revoking individual other sessions and user-initiated sign-out on all devices moved to follow-up scope.
- AC-17 to AC-19 rewritten; AC-26 to AC-28 added.

## How to read this document

Every requirement carries one of three tags.

| Tag | Meaning |
|---|---|
| **[Approved]** | Decided. Treat as source of truth. Changing it needs a new decision. |
| **[Proposed]** | Recommended behavior, not yet signed off. Review and accept or change it. |
| **[Open]** | Unresolved. Listed in §12. |

This document says *what* the product does and how we know it works. API endpoints, schema, OTP lifetimes, rate-limit thresholds and library choices belong in TRD 01.

---

## 1. Context and constraints

Veea English Notes is an offline-first vocabulary app. It stays fully usable without an account. An account exists so a learner can keep their notebook across devices and recover it.

- **[Approved]** The new backend uses Go and PostgreSQL as a modular monolith.
- **[Approved]** The existing Rust backend is local-only. API contracts, schema and migrations may be redesigned from scratch.
- **[Approved]** Flutter will be rebuilt after the backend. Existing Flutter contracts do not constrain this design.
- **[Proposed]** The app remains usable signed-out. An account is required only for cloud features (sync, multi-device, entitlements).
- **[Approved]** Payments are deferred. Entitlements are modeled, but no purchase flow is in scope.

## 2. Goals and non-goals

**Goals**
1. One person has one account with one stable `user_id`, however they sign in.
2. Sign-in is secure, recoverable and works across several devices.
3. Operators can support users, and every sensitive action is traceable.
4. Learning data syncs per account without cross-user leakage.
5. Free and Premium differ through server-enforced entitlements, ready for payments later.

**Non-goals (this document)**
- Payment, billing and receipt validation.
- Phone/SMS OTP, Facebook sign-in, Apple sign-in (later, see §3).
- Teacher, classroom or organization accounts.

## 3. Roadmap

| Phase | Scope | Status |
|---|---|---|
| **1** | Email OTP registration, email + password registration with OTP verification, email OTP sign-in, email + password sign-in, verified-email requirement, first-password set, password change and reset, session creation, refresh, current-device sign-out, automatic session revocation | **[Approved]**, detailed in §5 and §13 |
| 2 | Account and profile management. **Follow-up scope [Approved]:** email change, device listing, revoking individual other sessions, user-initiated sign-out on all devices. Account status and data lifecycle (deactivate, delete, export) | Follow-up items approved as deferred; the rest **[Proposed]** |
| 3 | Learning data sync | **[Proposed]** |
| 4 | RBAC and user administration | **[Proposed]** |
| 5 | Audit and monitoring | **[Proposed]** |
| 6 | Free/Premium entitlements (no payments) | **[Proposed]** |
| Later | Phone/SMS OTP, Facebook sign-in, Apple sign-in | **[Approved]** as later; no design yet |

Phase order after 1 is a proposal. Audit logging (Phase 5) should capture Phase 1 events from the first release, even before admin tooling exists (§10).

## 4. Personas and roles

| Role | Who | Notes |
|---|---|---|
| **User** | A learner | Default role. Manages only their own account and data. |
| **Admin** | Support/operations staff | Manages users within granted limits. |
| **Super Admin** | Owner-level operator | Manages admins and system-wide settings. |

- **[Approved]** The three roles are Super Admin, Admin and User.
- **[Proposed]** Role is held on the account, not on the session or device. A role change takes effect on the user's next request.

---

## 5. Phase 1 — Email authentication & account foundation

### 5.1 Approved decisions

**Registration**
1. **[Approved]** Two registration paths:
   - email OTP, with no password
   - email + password, followed by email OTP verification.
2. **[Approved]** Both paths require a verified email before any session is issued. Successful OTP verification during registration verifies the email.
3. **[Approved]** Verification is bound to the specific registration attempt. A code from one attempt cannot complete a different attempt.
4. **[Approved]** Signup with an email that already has an account leaves that account unchanged and issues no sign-in code and no session.

**Sign-in**

5. **[Approved]** OTP sign-in is a separate flow, for existing accounts only. It never creates an account.
6. **[Approved]** Email + password sign-in and email OTP sign-in resolve to the same account and the same stable `user_id`.

**Public acknowledgements**

7. **[Approved]** Public signup, OTP sign-in and password-reset requests each return the same acknowledgement within their flow, whether the email is registered or not. Only eligible requests send email.

**Passwords and session revocation**

8. **[Approved]** Setting a first password while signed in preserves the current session and revokes all other sessions.
9. **[Approved]** Changing a password while signed in preserves the current session and revokes all other sessions.
10. **[Approved]** Password reset by email revokes every session and requires the user to sign in again.

**Scope**

11. **[Approved]** Phase 1 session scope: session creation, refresh, current-device sign-out and automatic revocation.
12. **[Approved]** Follow-up scope: email change, device listing, revoking individual other sessions, and user-initiated sign-out on all devices.
13. **[Approved]** Phone/SMS OTP, Facebook and Apple sign-in come later.

### 5.2 Account identity

- **[Approved]** The account is keyed by a stable `user_id` that never changes and is not derived from the email.
- **[Proposed]** Email is the sign-in identifier in Phase 1. It is unique per account, compared case-insensitively, and stored in a normalized form.
- **[Approved]** An account may have no password (OTP registration). Its password state is "not set" until the user sets one.
- **[Approved]** Email change is follow-up scope. Phase 1 must not tie `user_id` to the email so it can be added later.
- **[Proposed]** No account exists until registration is verified. An unverified password registration is a pending attempt, not an account, so it cannot block the real owner of the address.

### 5.3 Eligibility for public requests

**[Approved]** Each public flow returns the same acknowledgement whatever the eligibility. Only eligible requests send email.

| Flow | Eligible when | Ineligible behavior |
|---|---|---|
| Signup (either path) | No account exists for the email | Same acknowledgement. No email, no change to any account, no session. |
| OTP sign-in | An account exists and is in good standing | Same acknowledgement. No email, no account created. |
| Password reset | An account exists and is in good standing | Same acknowledgement. No email. |

**[Proposed]** Acknowledgement copy in the app covers both cases. For signup, for example: "If this email can be used for a new account, we've sent a code. Already have an account? Sign in."

### 5.4 Phase 1 user flows

Steps are product behavior, not API design.

#### Flow A — Register with email OTP (no password) [Approved]
1. User enters an email and submits.
2. App shows the signup acknowledgement. If eligible, a one-time code is emailed for this attempt.
3. User enters the code on the same attempt.
4. On success the account is created with a verified email and no password, and a session starts on this device.
5. **[Proposed]** The app offers "Set a password" as optional (Flow E).

Failure paths:
- Wrong or expired code: clear error. The user may retry or request a new code.
- Too many attempts: the attempt ends; the user starts again.
- The email gained an account before this attempt was verified (another attempt finished first): no account change and no session; the user is pointed to sign-in.

#### Flow B — Register with email + password [Approved]
1. User enters an email and a password that meets policy.
2. App shows the signup acknowledgement. If eligible, a code is emailed for this attempt. No account and no session exist yet.
3. User enters the code on the same attempt.
4. On success the account is created with a verified email and the chosen password, and a session starts on this device.

Failure paths:
- Same as Flow A.
- Password that fails policy: rejected before anything is sent.
- **[Proposed]** Abandoned attempts expire; the password from an unverified attempt is never usable for sign-in.
- **[Proposed]** Starting a new signup for the same email (either path) replaces the earlier pending attempt.

#### Flow C — Sign in with email OTP [Approved]
1. User enters their email and requests a code.
2. App shows the sign-in acknowledgement. A code is emailed only if the account is eligible (§5.3).
3. User enters the code; on success a session starts on this device.

Failure paths: unknown email means no account is created and no email is sent. Wrong or expired codes behave as in Flow A.

#### Flow D — Sign in with email + password [Approved]
1. User enters email and password.
2. On success a session starts on this device.

Failure paths:
- Wrong password, unknown email, account without a password, or pending (unverified) registration: one generic "email or password is incorrect" message. The app offers "Sign in with a code" and "Forgot password".
- Account not in good standing: rejected (see §6).

#### Flow E — Set a first password while signed in
1. A signed-in user whose account has no password chooses "Set password".
2. **[Proposed]** The system requires fresh proof of email control (a new code), because there is no current password to confirm.
3. User enters a password that meets policy.
4. On success the current session stays signed in and **every other session is revoked [Approved]**.

#### Flow F — Change password [Approved]
1. A signed-in user enters current and new password.
2. On success the current session stays signed in and every other session is revoked.

Failure paths:
- Wrong current password: error, nothing changes.
- New password fails policy: error with the reason.

#### Flow G — Reset password by email [Approved]
1. A signed-out user requests a reset for their email.
2. App shows the reset acknowledgement. A code is emailed only if eligible.
3. User enters the code and a new password.
4. On success every session is revoked, including any on this device, and the user must sign in again.

**[Proposed]** Reset also lets a passwordless account set its first password.

#### Flow H — Sign out of this device [Approved]
- Ends the current session only. Sessions on other devices stay active.

#### Follow-up flows (not Phase 1) [Approved as deferred]
- View signed-in devices.
- Revoke an individual other session.
- Sign out on all devices.
- Change account email.

### 5.5 Password policy

- **[Proposed]** Length 15 to 128 characters, and a block-list of common and breached passwords. No composition rules and no forced periodic rotation.
- Exact rules are TRD 01.

### 5.6 Sessions

- **[Approved]** No session is issued for an unverified email or a pending registration.
- **[Approved]** Each successful sign-in or verified registration creates its own session. Signing in on a second device does not end the first.
- **[Approved]** Current-device sign-out ends only that session.
- **[Approved]** Only an active session can be refreshed. A signed-out, revoked or expired session cannot obtain new access.
- **[Approved]** Automatic revocation applies to:
  - first-password set (others)
  - password change (others)
  - password reset (all).
- **[Proposed]** Further automatic revocation: an account that stops being in good standing, and a session showing signs of token theft. TRD 01 defines both.
- **[Proposed]** Revocation takes effect quickly: a revoked device must not keep using the account beyond a short, bounded window. TRD 01 defines the bound.

### 5.7 Notifications

- **[Proposed]** The user receives an email when a password is set, changed or reset, so an unexpected change is noticed.
- **[Proposed]** Email content is English only in Phase 1.

---

## 6. Account status and data lifecycle (Phase 2 outline)

**[Proposed]** states:

| State | Set by | Effect |
|---|---|---|
| **Active** | — | Normal use |
| **Suspended** | Admin | Cannot sign in; data retained |
| **Deactivated** | User | Reversible |
| **Pending deletion** | User | Leads to Deleted |
| **Deleted** | System | — |

- A non-Active account cannot start a session. Existing sessions end when the status changes.
- Account deletion needs fresh proof of identity, removes the user's personal data, and leaves a minimal record that confirms deletion to a client that lost the response.
- The user can export their own data.
- **[Open]** Grace period before permanent deletion, and what is retained for legal or abuse reasons (Q-L1).

Phase 1 must reserve the notion of account status so sign-in can reject non-Active accounts.

## 7. Profile and device management (Phase 2 outline)

- **[Proposed]** Profile: display name, avatar (optional), learning preferences (interface language, daily goal), time zone.
- **[Approved, deferred]** Email change, device listing, revoking individual other sessions, sign-out on all devices.
- **[Proposed]** Email change will require proof of control of both the old and the new address.

## 8. Learning data sync (Phase 3 outline)

- **[Proposed]** Every vocabulary record belongs to exactly one account. One user can never read or change another's data.
- **[Proposed]** A client can resend the same change safely: a retry or a lost response must not duplicate or corrupt data.
- **[Proposed]** Deletes propagate across devices. Conflicting edits resolve by a documented rule (TRD).
- **[Proposed]** First sign-in on a device with existing local-only data offers to merge that data into the account.
- **[Open]** Conflict rule: last write wins, or field-level merge (Q-L2).

## 9. RBAC and user administration (Phase 4 outline)

| Capability | User | Admin | Super Admin |
|---|---|---|---|
| Manage own account and data | Yes | Yes | Yes |
| View and search users | No | Yes | Yes |
| Suspend / reinstate a user | No | Yes | Yes |
| Revoke a user's sessions | No | Yes | Yes |
| Trigger a password reset for a user | No | Proposed: Yes | Yes |
| View a user's learning content | No | **[Open]** | **[Open]** |
| Grant/revoke Admin role | No | No | Yes |
| Change system-wide settings | No | No | Yes |

- **[Proposed]** Admin actions require a stated reason and are audited.
- **[Proposed]** Admins cannot act on Super Admins, and nobody can remove the last Super Admin.
- **[Proposed]** Admins cannot see passwords, codes or tokens.

## 10. Audit and monitoring (Phase 5 outline)

- **[Proposed]** An append-only audit trail records each event with who, what, when, target and outcome. Events covered:
  - authentication: sign-in success and failure, registration, OTP requests
  - credentials and sessions: password set, change and reset; session revocation
  - administration: role and status changes, and every admin action
  - data: export and deletion.
- **[Proposed]** Audit entries never contain secrets (passwords, codes, tokens).
- **[Proposed]** Operators can see sign-in failure spikes, OTP send volume and delivery failures, and account-creation rate.
- **[Proposed]** Phase 1 events are recorded from the first release, even before admin viewing exists.
- **[Open]** Audit retention period (Q-L3).

## 11. Free / Premium entitlements (Phase 6 outline)

- **[Approved]** Payments are deferred.
- **[Proposed]** Two plans, Free and Premium. The server is the authority on what a user may do; the app only reflects it.
- **[Proposed]** Premium is granted manually or by an admin in the interim, with no purchase flow.
- **[Proposed]** Downgrading never deletes user data; it limits new use.
- **[Open]** Which features are Premium, and the Free limits (Q-L4). Earlier discovery work suggests cartridges, AI-assisted word help and cosmetic themes as candidates.

---

## 12. Questions

### Resolved in v0.2

| ID | Question | Resolution |
|---|---|---|
| Q1 | Password-based signup as well as OTP signup? | **Both.** Password signup is completed by email OTP verification bound to that attempt. |
| Q2 | Reveal whether an email is registered? | **No.** Same acknowledgement within each public flow. Only eligible requests send email. Existing-email signup changes nothing and signs nobody in. |
| Q3 | Email change in Phase 1? | **No.** Follow-up scope. |

### Still open (later phases)

| ID | Question | Affects |
|---|---|---|
| Q-L1 | Deletion grace period and retention | Phase 2 |
| Q-L2 | Sync conflict rule | Phase 3 |
| Q-L3 | Audit retention | Phase 5 |
| Q-L4 | Premium feature list and Free limits | Phase 6 |

## 13. Phase 1 acceptance criteria

Each criterion is testable.

### Registration
- **AC-1** Given an unregistered email, when the user completes OTP registration, then an account exists with a verified email and no password, and a session is active on that device.
- **AC-2** Given a completed OTP registration, when the user later signs in with the same email by OTP, then the same `user_id` is returned.
- **AC-3** Given a wrong or expired code, then no account is created and no session is issued.
- **AC-4** Given a registration that has not been verified, then no account exists for it and no session is issued for that email.

### Sign-in
- **AC-5** Given an account with a password, sign-in by email + password and by email OTP both resolve to the same `user_id`.
- **AC-6** Given an email with no account, OTP sign-in never creates an account.
- **AC-7** Given a passwordless account, an unknown email or a pending registration, email + password sign-in fails with the same generic message.
- **AC-8** Given email case differences (`A@x.com` vs `a@x.com`), then both identify the same account.
- **AC-9** Given a non-Active account, then sign-in is rejected and no session is issued.

### Passwords
- **AC-10** Given a passwordless account, when the signed-in user proves email control and sets a valid password, then email + password sign-in works afterwards.
- **AC-11** Given the user is signed in on devices A and B, when they change their password on A with the correct current password, then A stays signed in and B is signed out on its next request.
- **AC-12** Given a wrong current password, then the password is unchanged and no session is revoked.
- **AC-13** Given the user is signed in on devices A and B, when they complete an email password reset, then both A and B are signed out and the user must sign in again.
- **AC-14** Given a reset code that is wrong, expired or already used, then the password is unchanged and no session is revoked.
- **AC-15** Given a password that fails policy (in registration, first-password set, change or reset), then it is rejected with a reason and nothing changes.
- **AC-16** After a change or reset, the old password no longer works and the new one does.

### Sessions
- **AC-17** Each successful sign-in or verified registration creates a separate session. Signing in on device B leaves device A's session active.
- **AC-18** Given sessions on devices A and B, when the user signs out on A, then A's session ends and B's session remains active.
- **AC-19** Only an active session can be refreshed. A signed-out, revoked or expired session receives no new tokens.

### Abuse and safety
- **AC-20** Given repeated failed sign-in or code attempts, then further attempts are slowed or blocked (thresholds in TRD 01).
- **AC-21** A used code cannot be used again.
- **AC-22** No password, code or token appears in logs, audit entries or error messages.
- **AC-23** First-password set, password change and password reset each send a notification email to the account address.

### Audit
- **AC-24** Each registration, sign-in (success and failure), password set/change/reset and session revocation produces an audit entry with no secrets in it.

### Retry safety
- **AC-25** Repeating a registration, verification, password or session request after a lost response does not create duplicate accounts and does not leave the account in an inconsistent state.

### Added in v0.2
- **AC-26** Password registration issues no session, and creates no usable credential, before successful email OTP verification of that attempt.
- **AC-27** Within each public flow (signup, OTP sign-in, password reset), eligible and ineligible requests receive the same acknowledgement. Only eligible requests send email. A duplicate registration for an existing account cannot change its credentials and cannot sign anyone in.
- **AC-28** Given sessions on devices A and B for a passwordless account, when the user sets a first password on A, then A stays signed in and B is signed out on its next request.

## 14. Delivery sequence

1. **Product Doc approval:** this document (v0.2).
2. **TRD approval:** **TRD 01: Email Authentication & Account Foundation** (API, schema, OTP lifetimes, rate limits, session mechanics, library choices). Later TRDs follow the roadmap in §3, starting with the follow-up session and email-change scope.
3. **Tickets:** split TRD 01 into reviewable tickets, each tied to acceptance criteria above.
4. **Implementation:** Go modular monolith on PostgreSQL, then the rebuilt Flutter client.
5. **Verification:** run every acceptance criterion against local services with synthetic data, and record results before release.
