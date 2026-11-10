# Account, notebook and feedback rollout

Implementation updated 10 November 2026 for `feat/first-launch-native-accounts`. The existing server and OTP provider belong to the Veea team; Nin will supply their connection details. No production service, paid SMS subscription or Zalo group was created.

## Experience in the app

- Settings → Account and backup. Learning remains available without an account. A Vietnamese mobile number accepts `0901234567` or `+84901234567` and is normalized to E.164. The same verification flow creates an account or signs in. There is no separate registration decision or password.
- With no configured server or inactive OTP adapter, the screen clearly says sign-in is coming soon. It does not send SMS or use a fake verification code.
- Codes support iOS SMS autofill, a resend countdown, validation, expiry and changing the number. Account deletion requires a fresh, account-bound verification code and an explicit confirmation in the app.
- The first account adopts the existing on-device notebook. Changing accounts archives and restores separate notebooks, including local review history, unfinished learning rounds and the chosen practice pool. Signing out keeps the active notebook available on the device; this is stated on screen. These are account-separated notebooks on one device, not a device access lock.
- Successful sign-in, app resume, edits after a short delay, and the manual backup action trigger word sync. Failed requests leave local words available. App protection, review scheduling and learning history remain device-specific in this version.
- Settings → Help and feedback. Users choose problem / feature request / other, write a message and optionally attach a screenshot. Contact details and app diagnostics are optional. Diagnostics contain app version, platform and screen, never the notebook or phone number automatically.
- Feedback is saved locally before delivery. Before the server is connected, the UI explains that saved feedback will send when delivery becomes available. Users can copy or discard unsent reports. Only a matching server acknowledgement changes the status to Received. Retries reuse the same report UUID.
- Your feedback shows Received / Under review / Planned / Completed / Closed and a team reply. Reports are private; this is not a public voting board. Feedback history is separated by account and the guest workspace on this device. It is not synced to a second device.
- A Zalo community button appears only after a valid group link is configured. Chat is a separate, optional community channel; people can submit feedback without joining Zalo or creating a Veea account.

## What Nin needs to connect

1. Confirm the existing API domain, HTTPS setup, database deployment process and OTP provider. Keep credentials in the server environment. The app receives only the public API URL.
2. Apply cloud migrations `20261107000008_phone_otp_and_feedback.sql` and `20261107000009_sync_revisions.sql`, and `20261110000010_phone_change_and_deletion_receipts.sql` through the existing migration process, with the usual database backup and deployment coordination. All API nodes that write vocabulary must run the new revision-aware code before enabling protocol 2 clients.
3. The prepared adapter is Twilio Verify, behind the `OtpDelivery` interface. **This is an optional adapter, not a decision to buy or replace the team's provider.** If the existing provider differs, implement its send/check calls against this interface and wire it in AppState. Preserve provider-owned codes and verification; do not add fixed or client-visible development codes.
4. For Twilio Verify only, set `OTP_TWILIO_ACCOUNT_SID`, `OTP_TWILIO_AUTH_TOKEN`, `OTP_TWILIO_VERIFY_SERVICE_SID`. Use a Vietnam-enabled SMS service with a 10-minute verification lifetime. Empty configuration keeps phone sign-in unavailable. Confirm Vietnam delivery and sender requirements with the existing provider before release.
5. Compile the app with `VEEA_API_BASE_URL=https://<existing-api-domain>` and `VEEA_APP_VERSION=<actual-version-and-build>`. The URL is the service origin; `/api/v1` is appended by the app. With an empty API URL, the build stays local. Legacy password UI is hidden by default; `VEEA_LEGACY_PASSWORD_ACCOUNTS=true` is available for a controlled email-account migration build.
6. Once a Veea community has been created in Zalo, set server `VEEA_ZALO_COMMUNITY_URL=https://zalo.me/g/<group-id>` or compile the same app setting. Only HTTPS group links on `zalo.me` are accepted by the app. Do not publish a placeholder or another company's group.
7. Use an existing admin account to review feedback through the admin routes below. No admin dashboard was deployed. Assign a person to check reports and post replies.

## API contract

All paths below are under `/api/v1`; normal success responses use the existing `{ "data": ... }` envelope.

| Action | Route | Request / result |
|---|---|---|
| Capability discovery | GET `/client/config` | `phone_otp_available`, optional `zalo_community_url`, `sync_protocol_version: 2` |
| Send SMS | POST `/auth/otp/request` | `{phone}` → `{challenge_id, expires_in, retry_after}` |
| Verify / create / sign in | POST `/auth/otp/verify` | `{challenge_id, code}` → `{user_id, identifier, auth_method, tokens}` |
| Send deletion code | POST `/users/me/delete-otp` | Requires access token; phone comes from the account |
| Confirm deletion | DELETE `/users/me/delete-otp` | Access token and `{challenge_id, code}`; deletes account and its cloud notebook |
| Send feedback | POST `/feedback` | `x-feedback-key` random receipt secret; `{id,kind,message,contact?,diagnostics?,screenshot_base64?}` |
| Feedback receipts | GET `/feedback` | Same receipt secret; latest 100 own statuses/replies |
| Team inbox | GET `/admin/feedback` | Admin access token; latest 100 reports |
| Team update | PUT `/admin/feedback/{id}` | Admin; `{status,team_reply?}` |
| Screenshot | GET `/admin/feedback/{id}/screenshot` | Admin only, `no-store` |
| Word sync | POST `/vocabulary/sync` | Access token, `{changes,cursor:"0"}` → `{accepted,canonical,changes,cursor,serverTime,hasMore}` |

### Abuse controls and operations

OTP challenges expire after 10 minutes, accept at most five code checks, can be consumed once, and are bound to their purpose and deletion account. Sends have a 60-second phone cooldown, five sends/hour and twenty/day per phone, plus twenty/hour per peer IP. Provider failures fail closed. OTP values are never stored or logged by this service. Challenge rows older than two days are pruned on new requests; schedule equivalent cleanup during quiet periods if needed.

The server obtains the socket peer IP. It does **not** trust arbitrary forwarding headers. Nin needs to review the existing reverse proxy topology: a proxy otherwise shares the IP quota across users. Feedback adds a 50-attempt/hour IP limit in Redis and ten new reports/hour per receipt. Missing Redis fails feedback delivery closed; the app keeps the report queued. Monitor OTP spend and delivery failures through the existing provider controls.

Feedback accepts 5–4000 characters, optional contact up to 254 characters, an explicit diagnostic allowlist and one JPG/PNG under 512 KB. Screenshots are private to admin routes. The database stores only a hash of the receipt secret; the secret stays in Keychain/Keystore. Receipt loss means statuses cannot be recovered through a phone number. Feedback has an independent retention policy; deleting a notebook/account does not automatically purge previously submitted feedback. Decide and document retention and support deletion handling before launch.

New password-based phone registrations and unverified phone linking are rejected. When OTP is enabled, password login for phones is also rejected. Existing legacy phone accounts require a deliberate migration with Nin; OTP login does not silently take over or merge an unverified legacy account. Existing email password endpoints remain for compatibility behind the optional old UI.

## Desktop-ready word data contract

- Account ownership uses the server UUID from verified login, never a client-supplied phone number. All server reads/writes are scoped to that authenticated UUID.
- Words keep client-generated UUIDs across offline creation, mobile and future desktop clients. Fields include English word, meaning, pronunciation, part of speech, source, examples, tags, captured day and timestamps.
- Conflicts use last-write-wins on `updatedAt`; equal timestamps keep the server row. A badly skewed device clock can therefore win a conflict. Conflict history and manual reconciliation are not implemented.
- Deletions travel as tombstones. Do not remove server tombstones without a separately designed device/cursor retention policy.
- Pulls use a decimal revision cursor serialized as a string. Start at `"0"`; persist a cursor only after merging its page. Keep cursors separate per account. The timestamp response remains for legacy clients, but timestamp-only pagination is not the protocol for new desktop clients.
- Per-account write locking allocates revisions in commit order. This prevents a late commit from hiding behind a newer cursor. All writers must follow the repository contract.
- `canonical` returns the server winners for uploaded IDs even when those rows are older than the current pull page. Acknowledgements only clear local edits that still have the exact uploaded timestamp. Incoming word updates preserve local learning records.
- SQLite schema 11 adds notebook archives, owner metadata and a feedback outbox. No existing word or learning-table columns are removed. Archives are not encrypted separately from the app's database. They rely on the device's normal data protection.
- The desktop app itself, cross-device learning progress/settings, feedback history sync and account phone-number changes are not included in this implementation.

## Validation and remaining release checks

Flutter checks cover normalization, staged token commit, resend/expiry, invalid codes, sign-in/sign-out UI, account notebook isolation/restoration, concurrent-edit acknowledgement, review-history preservation, offline feedback persistence, idempotent retries, diagnostics allowlisting and Zalo-link restrictions. Screen checks cover compact, large-text, landscape and dark layouts.

Rust unit checks cover provider verification responses and revision pagination/canonical winners. PostgreSQL integration tests live in `cloud/tests/account_data_integration.rs`. They are opt-in so they never run against an accidental production database. All six were executed successfully against a disposable local PostgreSQL 16 container on 10 November 2026 (zero ignored in that run). Run them with:

```
VEEA_TEST_DATABASE_URL=postgres://veea_test@127.0.0.1:5432/veea_test cargo test --test account_data_integration -- --ignored
```

The tests create and remove an isolated schema. Never point them at a production database. The local integration run covered bounded/purpose-bound OTPs, revision pagination and foreign IDs, stable UUID/notebook/cursor on phone change, proof replay/account/purpose/expiry checks, taken-number and stale-parallel-change rejection, refresh-session replacement, and deletion receipts. Real SMS delivery, deployed API integration, two-device sync, account deletion end to end, and team inbox operation remain to be verified with Nin's existing setup. No claim of production readiness should be made before those checks.

Official provider references: [Twilio verification checks](https://www.twilio.com/docs/verify/api/verification-check), [Twilio Verify API](https://www.twilio.com/docs/verify/api), [Zalo group invitations](https://help.zalo.me/huong-dan/chuyen-muc/tro-chuyen-nhom/nhan-duoc-loi-moi-vao-nhom-va-cong-dong/).


## Verified account lifecycle in the first-launch branch

Account signup and sign-in remain one optional phone-OTP flow. The client exposes
resend cooldown, code expiry without requiring another tap, provider/rate-limit
errors, and SMS autofill. With no public API URL or inactive OTP delivery, there
is no account form and no claim that a cloud backup has been made.

Signed-in phone accounts can change their phone in three steps: verify the
current number, enter a new number, then verify the new number. Losing access to
the current phone requires support; there is no insecure bypass.

| Action | POST route under `/api/v1` | Request / result |
|---|---|---|
| Code to current number | `/users/me/phone-change/current-code` | Authenticated; account phone comes from server; returns OTP challenge |
| Verify current number | `/users/me/phone-change/current-verify` | `{challenge_id,code}` → `{proof_id,expires_in:900}` |
| Code to new number | `/users/me/phone-change/new-code` | `{proof_id,new_phone}` → OTP challenge |
| Complete change | `/users/me/phone-change/confirm` | `{challenge_id,code}` → replacement session for the same `user_id` |
| Recover lost deletion response | `/auth/deletion-receipt` | `{user_id,challenge_id}` → `{deleted:bool}`; no session required |

The old-number proof is account-bound, fresh for 15 minutes, records the expected
current phone, and can complete only one change. New-code resends reuse the proof.
The server checks both phone-number advisory locks in sorted order, locks the
user, checks uniqueness and current-phone/proof freshness again, then updates the
phone, spends the proof, revokes refresh sessions, writes the outbox event and
issues one new session in a transaction. Other devices' existing access tokens
expire according to the configured JWT lifetime; refresh then requires sign-in.
The client verifies the returned UUID before storing tokens. Phone changes never
activate a different notebook or reset its sync cursor.

Deletion requires a fresh account-bound OTP and a final destructive confirmation.
The client stores a pending deletion in secure storage before the request. The
server atomically deletes the user and records a receipt containing the account
UUID and a hash of the deletion challenge ID (no phone). Receipts are retained for
30 days. A matching positive receipt can finish local cleanup after a lost
response. Generic 401/404 responses never justify wiping a notebook. A negative receipt
inside the code-expiry plus one-minute grace window is still pending. The
absolute deadline is retained in secure storage across restarts; pending work
is rechecked on restore/resume and blocks account switching, repeated deletion
and phone changes. Sync stays paused until the outcome is resolved. If a request
or receipt cannot be confirmed, words remain on the device. A receipt outside the
retention window cannot prove deletion; real-world recovery beyond that window
needs support/manual handling, not an automatic data wipe.

Signing out keeps the active notebook available. New words added while signed out
stay linked to that notebook's account; the screen says this explicitly. Switching
to another account archives it and opens the other notebook. Confirmed account
deletion removes its active notebook/archive and resets the cursor, while other
accounts' archives remain intact. Feedback already sent remains separately held,
as disclosed before deletion; the team's retention/support policy still needs
finalization.

Focused account validation on 10 November: 34 Flutter provider/widget checks
passed, including stable ownership, UUID mismatch refusal, expiry/resend, provider
failure, fresh-code deletion, lost responses, 401/404 preservation, and account
switching. Backend library checks: 79 passed. These are local/mocked client tests
and real disposable-database tests, **not** real SMS delivery or production API
validation. Nin still needs to supply/configure the public API origin and OTP
provider, run migrations through the existing deployment process, and verify SMS
and cross-device behavior before release. No production credentials belong in the
app. Privacy/terms/support URLs must be supplied by the team; no placeholder legal
links or Zalo community were invented.


### Deployment conditions to confirm with Nin

OTP and request rate limits currently use the socket peer IP. If the API is
behind a reverse proxy/CDN/load balancer, users would share its IP quota. Confirm
the topology and implement a **trusted-proxy** client-IP policy before enabling
public OTP traffic. Do not trust arbitrary forwarded headers from the internet.
The new migration adds an account-binding constraint; check old non-signin OTP
rows for null user IDs before applying it. Support/contact URLs and the privacy
policy still need the team's real values. No public account launch has been
performed by this branch.
