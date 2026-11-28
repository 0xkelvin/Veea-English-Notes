# Apple payment environments — TestFlight, App Review and App Store

## Behavior

The same release app/API supports Apple's Sandbox testing and real Production
purchases. The client never selects the verifier environment. Apple documents
[Production-first lookup with Sandbox retry only for error 4040010](https://developer.apple.com/documentation/appstoreserverapi).
[App Review uses Sandbox purchases](https://developer.apple.com/help/app-review/before-submitting-for-review/configure-in-app-purchases/).

| Server configuration | Verified proof | Result |
|---|---|---|
| Production, Sandbox acknowledgement off (default) | Production | Existing durable account purchase/plan |
| Production, Sandbox acknowledgement on | Production | Existing durable account purchase/plan |
| Production, Sandbox acknowledgement on | Sandbox | Acknowledged for this device; no stored purchase or server Pro grant |
| Dedicated Sandbox API/database, acknowledgement off | Sandbox | Existing durable test-account purchase/plan in the separate test database |

Production lookup happens first. Only HTTP 404 with Apple's explicit JSON
`errorCode:4040010` retries against the fixed Sandbox endpoint. Bare/other 404,
400, bad signatures, wrong product/bundle/environment, Apple auth failures,
429, timeouts and outages never trigger fallback. The second endpoint performs
all the same Apple certificate/signature/claim checks, including signed
`appAccountToken == authenticated Veea user UUID`.

Sandbox acknowledgement revalidates the active user and acting session under
the existing locks. It does not insert, prune or change any purchase rows,
manual grants, export data or production entitlement. The response includes
`purchase_environment:Sandbox`, `purchase_recorded:false`, and Apple's
`purchase_revoked` state. Its `plan` is the actual Production account plan,
normally Free. It is not a lifetime server lease. Any existing real-purchase
reconciliation/manual fallback remains independent; a colliding Sandbox proof
cannot refresh a stored Production proof.

StoreKit ownership is independent of the Veea account. A matching signed-in
claim finishes on Go acknowledgement. Guest and differently bound transactions
finish after local delivery, and active matching proofs remain recoverable through
StoreKit current entitlements. Server leases are scoped by environment, API origin
and path, account and product. Device revocation markers are scoped by transaction
environment and product.
Xcode/unknown transaction environments are rejected. A cached verified app
transaction scopes leases and rejects known unsupported installations; it does
not select or require the IAP signing environment. An unavailable app transaction
does not erase otherwise verified offline StoreKit ownership. A fresh authenticated
server plan also remains available through a bounded, process-local lease when
Apple's app lookup is unavailable. This memory is cleared on account, product or
API changes and a Free reply; it is never persisted without a verified namespace.
A signed-in account with unknown status is not reconciled as Free until ownership,
a valid lease or an authoritative server plan is available. A Free reply clears
both possible scoped lease caches before a late app lookup can reveal one.

The entitlement response reports server claim availability and pending server
verification. StoreKit checkout remains available when the backend or upstream
Apple verification cannot confirm an account purchase and StoreKit shows no
local ownership. This accepts the risk of a duplicate purchase across Apple
Accounts during an outage.

## Nin: deployment settings

Both tracked Compose environments default to `VEEA_APPLE_IAP_ENABLED=false` and
`VEEA_APPLE_IAP_ALLOW_SANDBOX=false`. Sandbox acknowledgement requires enabled
IAP and a Production verifier. Other IAP settings are optional while disabled.

For the **real release API** used by both TestFlight/review and App Store:

- Keep `VEEA_APPLE_IAP_ENABLED=true` and `VEEA_APPLE_IAP_ENVIRONMENT=Production`.
- Set `VEEA_APPLE_IAP_ALLOW_SANDBOX=true` to enable acknowledgements.
- Keep the production database's `apple_iap_control.environment` as `Production`.
  Never switch it to Sandbox for review. There is no schema migration in this fix.
- Configure the existing issuer ID, key ID, private In-App Purchase key, bundle ID
  and product allowlist in the server's private settings. Use
  `VEEA_APPLE_IAP_BUNDLE_ID=com.nintran.veeaEnglishApp` and
  `VEEA_APPLE_IAP_PRODUCT_IDS=com.nintran.veeaEnglishApp.pro`. The Sandbox verifier
  shares the same credentials and product allowlist.
- Build with the public release `VEEA_API_BASE_URL` and exact
  `VEEA_APPLE_PRO_PRODUCT_ID=com.nintran.veeaEnglishApp.pro` via the
  [signed IPA build command](first-paid-release.md#nin-configuration-needed-before-testflight-payment-testing).
- Deploy the updated backend before distributing the updated signed app. The
  additive acknowledgement response also works with the existing app client.
- App Store Server Notifications V2 is deferred. StoreKit and owner reconciliation handle refund verification.

For a **dedicated staging API**, keep its separate Sandbox database and
`VEEA_APPLE_IAP_ENVIRONMENT=Sandbox`, with `VEEA_APPLE_IAP_ALLOW_SANDBOX=false`.
Enabling Sandbox fallback on a Sandbox verifier/database is refused at startup.
Payments remain disabled without the existing explicit billing configuration.
There is no client switch, reviewer-only secret or fake paid-success path.

### Private key delivery

Set the App Store Connect issuer UUID and key ID through `VEEA_APPLE_IAP_ISSUER_ID`
and `VEEA_APPLE_IAP_KEY_ID`. The enabled API accepts exactly one nonempty key
source. `VEEA_APPLE_IAP_PRIVATE_KEY` accepts the PEM text with real or escaped
newlines. `VEEA_APPLE_IAP_PRIVATE_KEY_FILE` reads a PEM file at startup. Supplying
both, or supplying an unreadable, non-regular, invalid or oversized file, fails
startup. The PEM file limit is 16 KiB. Disabled IAP
does not read the key file. Configuration errors omit key content and file paths.

For production Docker Compose, place the P-256 `.p8` outside the repository and
set `VEEA_APPLE_IAP_KEY_HOST_FILE` to its absolute host path in the private
production env file. Leave the inline key empty. Set
`PROD_IAP_DOCKER_SECRET=true` on each `backend-prod-*` invocation, for example
`make backend-prod-config PROD_IAP_DOCKER_SECRET=true`. The overlay mounts
the key read-only at `/run/secrets/veea_apple_iap_key` for the API and sets
`VEEA_APPLE_IAP_PRIVATE_KEY_FILE` to that path. File-backed Compose secrets
use a bind mount. On Linux, give container UID/GID 10001 read access (for
example, owner 10001 and mode 0400 where host UID mapping permits it) and
verify readability with the deployed container identity. Recreate the API
after key rotation. The local Compose file can also be paired with
`-f compose.iap-secret.yaml` using the same host path variable.

### Reconciliation and restore

Get Transaction Info tolerates additional response fields and still requires
Apple's signed transaction. Owner reconciliation has a five-second Apple I/O
deadline and uses the original request context for the subsequent database
transaction. Each API replica admits up to four concurrent reconciliation
lookups, for an aggregate of up to four times the replica count. Each replica
starts its own five-second cooldown after an upstream failure, runs one recovery
probe after it expires, and doubles the cooldown on failed probes up to 60
seconds. A definitive Apple response resets that replica's gate. An Apple 429
opens the cooldown without an immediate retry. The lookup releases its slot at
verifier exit, including cancellation or panic, before database work starts.
Only a completed verifier response can advance or reset the cooldown.

When all four lookup slots are occupied and the gate is healthy, up to four
requests per replica can wait up to 250 ms. Saturation returns temporary
unavailability and does not start a cooldown. Requests skip the wait during
cooldown or a recovery probe. A busy owner can occupy available slots, and a cooldown affects every owner
routed to that replica who needs a lookup. Different replicas can probe at the
same time. Explicit purchase claims bypass the gate and keep their existing
per-user rate limit. Cached, fresh proofs are served without a lookup.

On restore, a confirmed active transaction or the verified account lifetime
plan is sufficient. The latter is Premium with an explicit null expiration
and no pending verification. Manual grants have a finite expiration. A
verified Sandbox acknowledgement can coexist with pending reconciliation of
an unrelated Production proof. Restore labels this as access on the device in
Apple Sandbox. The acknowledgement gives no Production purchase row or server
Premium lease. An explicit revoked outcome is reported as
a refund or revocation if no active Apple entitlement was confirmed.

### StoreKit-first guest purchases

StoreKit provides local educational Pro for the purchasing Apple Account.
Guests buy and restore without Veea sign-in. Guest purchases have no account
token and never go to Go. A matching signed-in purchase may be claimed using
the existing authenticated route. A different or deleted account's token can
never be transferred. Valid local purchases survive Veea account deletion.
A Production API acknowledgement of Sandbox remains device-only.

## Roll back Apple IAP

To stop new sales, remove this IAP from sale in App Store Connect. Existing
buyers keep any valid Apple entitlement. The Go IAP flags only control server
verification and account claims. Once a production guest purchase is sold,
keep a StoreKit-first client available for purchase restoration. An
account-only client rollback would strand those buyers. [Apple IAP statuses](https://developer.apple.com/help/app-store-connect/reference/in-app-purchases-and-subscriptions/in-app-purchase-statuses)

Record the deployed image digest, Compose project and env selection, ingress,
and key delivery mode before rollout. Preserve the same database and backups.

- **Disable server Apple claims as an emergency measure.** In the private env, set
  `VEEA_APPLE_IAP_ENABLED=false` and `VEEA_APPLE_IAP_ALLOW_SANDBOX=false` together,
  then apply the selected production model using the commands below.
  The API rejects claims and stops re-verifying stored purchases. Owners with
  existing purchase rows can get `503 purchase_unavailable` on entitlement reads
  immediately. An independent active manual grant may still be returned with
  verification pending. The 24-hour proof freshness limit still applies to
  other server consumers. Valid StoreKit purchases still work locally. The switch affects account
  proof renewal and account-based refund reconciliation.
- **Roll back the image.** Choose a known-good digest that is compatible with
  migration 16 and the current database schema. Pull it, update
  `VEEA_PROD_IMAGE` in the same private env file, and apply the same production
  project and ingress. If the old image accepts inline PEM only, restore the
  previous inline key via the private deployment process, remove the file
  setting, and select `PROD_IAP_DOCKER_SECRET=false`. For a file-capable image,
  restore the previous secret mount and use `PROD_IAP_DOCKER_SECRET=true`.
  Keep key IDs and key material paired. Never print the env or resolved Compose
  model with real settings.
- **Preserve payment state.** Migration 16 is forward-only. Keep its schema.
  Never change `apple_iap_control` as a shortcut, delete purchase records,
  or switch to a different database or volume for rollback.

```sh
# Reuse the actual production project, env, and ingress selection.
# Set PROD_IAP_DOCKER_SECRET to true or false for the image's key delivery mode.
make backend-prod-config
make backend-prod-up
make backend-prod-migrate-status
make backend-prod-health
make backend-prod-ps
```

After rollback, verify the running image digest, schema 16, internal and public
readiness, and account sign-in. With billing disabled, confirm authenticated claims are
unavailable and existing purchase rows remain. With billing enabled, verify a
review/TestFlight Sandbox acknowledgement remains device-only, confirm same-owner
restore, and review purchase errors and Prometheus alert state. Follow the
[ingress runbook](../backend/README.md#production-docker-resend-no-mailpit) for the selected proxy.

## Acceptance before public release

Automated checks use synthetic Apple certificates/proofs and a disposable local
PostgreSQL only. They never call a deployed account server or charge a card.
Signed TestFlight/device testing and App Review remain separate release gates.

1. Install the signed build using the same API settings intended for review.
2. Follow the [Option A acceptance matrix](pro-99k-qa.md). Confirm Free app
   protection supports multiple apps, multiple words per unlock and all timings.
   Check the free one-word standalone round and Pro's configurable multi-word
   standalone rounds from Home.
3. Buy and restore with StoreKit in Sandbox as a guest, then test a separate
   signed-in purchase. Verify local Pro survives restart, offline use and Veea
   account changes. Only the matching Veea account can claim a bound transaction.
   Confirm finishing after local guest delivery or successful signed-in acknowledgement.
4. Refund or revoke in Sandbox and confirm device Pro updates when StoreKit learns
   of the change. Confirm that Production purchase rows, independent manual grants
   and protection settings stay intact.
5. When moving from TestFlight to an App Store installation, no test ownership,
   lease or revocation cache may become a real paid entitlement. Keep notebook
   data; do not uninstall without backing it up.
6. Confirm the exact signed App Review build handles the app/purchase environment
   reported by StoreKit. Simulators and source checks do not prove this step.

The app-installation lookup runs once in the background; it never holds up
configuration, offline ownership or a purchase, and never calls
`AppTransaction.refresh()`. Server-only legacy grants require online confirmation
after this update because their old cache had no trusted environment.

The 99,000 VND price still requires App Store Connect configuration. Apple
review, including guideline 4.10, is not guaranteed by these changes.
