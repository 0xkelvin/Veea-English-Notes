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

The iPhone keeps Pro through StoreKit's independently verified, account-bound
ownership for that installation. A successful acknowledgement permits finishing
the transaction; a failed/unknown verification leaves it unfinished for retry.
Device leases and revocation lists are separated by verified environment,
configured API origin/base path, account and product. Old unscoped caches are ignored.
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

## Nin: deployment settings

For the **real release API** used by both TestFlight/review and App Store:

- Keep `VEEA_APPLE_IAP_ENABLED=true` and `VEEA_APPLE_IAP_ENVIRONMENT=Production`.
- Set `VEEA_APPLE_IAP_ALLOW_SANDBOX=true` to enable acknowledgements.
- Keep the production database's `apple_iap_control.environment` as `Production`.
  Never switch it to Sandbox for review. There is no schema migration in this fix.
- Configure the existing issuer ID, key ID, private In-App Purchase key, bundle ID
  and product allowlist in the server's secret settings. The second verifier uses
  the same credentials/products and only Apple's fixed Sandbox endpoint.
- Build with the public release `VEEA_API_BASE_URL` and exact
  `VEEA_APPLE_PRO_PRODUCT_ID`. App/API/product/bundle must match.
- Deploy the updated backend before distributing the updated signed app. The
  additive acknowledgement response also works with the existing app client.
- The production Compose file passes the new flag through; its default is off.

For a **dedicated staging API**, keep its separate Sandbox database and
`VEEA_APPLE_IAP_ENVIRONMENT=Sandbox`, with `VEEA_APPLE_IAP_ALLOW_SANDBOX=false`.
Enabling Sandbox fallback on a Sandbox verifier/database is refused at startup.
Payments remain disabled without the existing explicit billing configuration.
There is no client switch, reviewer-only secret or fake paid-success path.

## Acceptance before public release

Automated checks use synthetic Apple certificates/proofs and a disposable local
PostgreSQL only. They never call a deployed account server or charge a card.
Signed TestFlight/device testing and App Review remain separate release gates.

1. Install the signed build using the same API settings intended for review.
2. Sign in, confirm Free allows one app/one word and all durations remain free.
3. Buy Pro using Apple's Sandbox flow: no real charge; multiple apps/words work,
   no verification-error banner, and no unfinished transaction remains after ack.
4. Restore, restart, go offline and exercise vocabulary unlock/relock on two apps.
5. Refund/revoke in Sandbox and confirm device Pro updates without modifying any
   real Production purchase or independent manual grant.
6. A different Veea account must not inherit the first account's purchase.
7. When moving from TestFlight to an App Store installation, no test ownership,
   lease or revocation cache may become a real paid entitlement. Keep notebook
   data; do not uninstall without backing it up.
8. Confirm the exact signed App Review build handles the app/purchase environment
   reported by StoreKit. Simulators and source checks do not prove this step.

The app-installation lookup runs once in the background; it never holds up
configuration, offline ownership or a purchase, and never calls
`AppTransaction.refresh()`. Server-only legacy grants require online confirmation
after this update because their old cache had no trusted environment.

The 99,000 VND price still requires App Store Connect configuration. Apple
review, including guideline 4.10, is not guaranteed by these changes.
