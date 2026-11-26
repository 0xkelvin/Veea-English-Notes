# TRD 11 — Apple App Store One-Time Pro Purchases

**Status:** v1.0 draft implemented in code (local verification only; App Store Connect product/key configuration and real-purchase verification remain deployment gates).
**Date:** 2026-11-17
**Depends on:** [TRD 04](04-account-lifecycle-data-rights.md), [TRD 09](09-free-premium-entitlements.md), [TRD 10](10-server-delivered-cartridges.md).

## 1. Scope and product rules

1. **Offline-first vocabulary unchanged:** Local notebooks, listening, and review remain unlimited on Free and Pro, and vocabulary remains offline without new word-sync requirements.
2. **Current owner decision (26 November 2026):** Free allows one app lock and one vocabulary word per unlock, with an unlimited rotating practice pool. Pro enables multiple app locks and multiple words per unlock, bounded by the available pool. All supported default/custom/per-app durations are free. Existing TRD 10 server cartridge gates remain closed and are not advertised as part of this offer.
3. **One-time non-consumable purchase:** Pro is sold as one App Store **Non-Consumable**, with target Vietnam price 99,000 VND, no trial or recurring subscription. Display Apple's localized price; App Store configuration and guideline 4.10 review remain release gates.
4. **Sign in before purchase & account binding:** The user must be signed in to a Veea account before purchasing or restoring. StoreKit 2 passes the authenticated Veea user UUID as `appAccountToken(.appAccountToken(owner))`.
5. **Default disabled without configuration:** Neither the public repository nor default local configuration ships live App Store product IDs, credentials, or deployment URLs. When `VEEA_APPLE_IAP_*` configuration is absent, purchase verification is disabled and fails closed (`503 purchase_unavailable`).

## 2. Apple App Store Server API verification (`backend/internal/appleiap`)

- **Package contract:**
  - `type Config struct { IssuerID, KeyID, PrivateKey, BundleID, Environment string; ProductIDs []string }`
  - `func New(Config) (*Verifier, error)`
  - `func (v *Verifier) Verify(ctx context.Context, transactionID string) (Transaction, error)`
  - `type Transaction struct { ID, OriginalID, ProductID, BundleID, Environment string; AccountToken uuid.UUID; PurchasedAt, SignedAt time.Time; RevokedAt *time.Time; RevocationReason *int32 }`
  - Sentinel errors: `ErrUnavailable` (unconfigured verifier, network/timeout failure, or Apple 401/403/429/5xx) and `ErrInvalid` (malformed or nonexistent transaction ID, invalid JWS/x5c chain, or mismatched claims).
- **Fresh server-to-server lookup:** Every `Verify` call mints a short-lived (5-minute) `ES256` JWT (`iss`, `iat`, `exp`, `aud: "appstoreconnect-v1"`, `bid`) and calls Apple's fixed `Get Transaction Info` endpoint (`https://api.storekit.apple.com/inApps/v1/transactions/{transactionId}` for `Production`, `https://api.storekit-sandbox.apple.com/inApps/v1/transactions/{transactionId}` for `Sandbox`). Arbitrary base URL overrides are not exposed in `Config`.
- **Pinned Apple PKI verification:** `signedTransactionInfo` is verified against the embedded **Apple Root CA - G3** certificate (`SHA-256: 63343abfb89a6a03ebb57e9b3f5fa7be7c4f5c756f3017b3a8c488c3653e9179`), never trusting an arbitrary root supplied in `x5c`. The leaf certificate must carry Apple's receipt-signing OID (`1.2.840.113635.100.6.11.1`) and the intermediate certificate must carry Apple's WWDR OID (`1.2.840.113635.100.6.2.1`).
- **Required claims:** `alg == "ES256"`, `transactionId` matches the requested ID, `bundleId` matches `Config.BundleID`, `productId` is in `Config.ProductIDs`, `environment` matches `Config.Environment`, `type == "Non-Consumable"`, `inAppOwnershipType == "PURCHASED"`, `!isUpgraded`, `appAccountToken` is a valid non-nil UUID, `purchaseDate` is not in the future, and `signedDate` is not before the purchase or in the future (allowing clock skew). Historical purchases are accepted: as in Apple’s official verifier with online certificate checks disabled, certificate validity is checked at the signed date. Freshness comes from the authenticated server-to-server lookup; client JWS is never accepted. If `revocationDate` is present, `RevokedAt` and `RevocationReason` are returned on `Transaction` for caller reconciliation.

## 3. Entitlements, reconciliation, environment isolation, and lifecycle rules

1. **HTTP contract (`POST /v1/me/purchases/apple`):**
   - Bearer-authenticated via `authenticated`; accepts strict JSON `{"transaction_id": "<id>"}`.
   - Verifies that `Transaction.AccountToken == principal.UserID`; refuses cross-account claims (`409 purchase_ownership_conflict`).
   - Returns `200 OK` with the `GET /v1/me/entitlements` response shape plus `purchase_revoked` (`plan`, `plan_expires_at`, `limits`, `checked_at`). An active lifetime purchase yields `plan: "premium"` with `plan_expires_at: null`.
2. **Revocation commit & 200 reconciliation:**
   - When Apple reports `RevokedAt != nil` on a transaction owned by the caller, `POST /v1/me/purchases/apple` **commits** the revocation state in PostgreSQL and returns `200 OK` with the updated effective `Entitlements` (which resolves to `"free"`, or `"premium"` with `plan_expires_at` if an independent manual grant from TRD 09 is active) rather than `403`, allowing the client to clear its local server lease and finish the StoreKit transaction cleanly.
   - Because refunds can occur after initial verification, server-side entitlement reads enforce a fresh verification TTL / server reconciliation window (re-verifying every 5 minutes when online and bounding server lease reliance to 24 hours) so refunded purchases do not remain Premium indefinitely from stale database state.
3. **Independence from manual staff grants (TRD 09):**
   - Manual grants remain in `entitlement_grants` (`source = 'manual'`, bounded to 366 days, managed by `admin.ChangePlan`). Apple purchases are stored separately so they never collide with the 366-day check constraint or `entitlement_grants_one_open`, and provider revocation never revokes a manual grant.
4. **Environment isolation (`apple_iap_control` & composite keys):**
   - Durable purchase uniqueness namespaces transaction identifiers by `(environment, original_transaction_id)` and `(environment, transaction_id)` so Sandbox transaction IDs can never collide with or poison Production records.
   - A singleton `apple_iap_control` table pins the database's active Apple environment and refuses API startup if `VEEA_APPLE_IAP_ENVIRONMENT` mismatches the database environment.
5. **Account deletion, export, and privacy:**
   - The TRD 04 account purge deletes all owned Apple purchase rows for the erased account. Because Apple's signed `appAccountToken` remains bound to the original account's UUIDv7 inside Apple's transaction record, a deleted account's purchase cannot be restored onto a newly registered account (`appAccountToken != newUser.ID`), avoiding any need to retain pseudonymous payment rows after account erasure. Any cross-account transfer after account deletion requires an explicit operator support policy.
   - The TRD 04 owner export (`AccountExport`, schema 3) includes up to the 5 latest verified purchase proofs (`MaxExportedPurchases = 5`) so the worst-case export header remains strictly within `learning.MaxHeaderBytes` (16 KiB).

6. **Review/TestFlight acknowledgements on the release API (26 November 2026):** An explicit `VEEA_APPLE_IAP_ALLOW_SANDBOX=true` on a Production verifier/database enables Production-first lookup with Sandbox retry only on Apple HTTP 404/error 4040010. A fresh, signed, account-owned Sandbox proof is acknowledged after active-user/session revalidation; it never writes/prunes purchase rows or grants Production server Premium. The response retains the actual Production plan and adds `purchase_environment`/`purchase_recorded`; device Pro comes from StoreKit. Stored Production reconciliation requires a Production proof, even for colliding IDs. Dedicated Sandbox databases keep the existing durable test path. Device caches are scoped by verified environment, API origin, owner and SKU. See [deployment and device acceptance](../payment-environments.md).

## 4. Remaining deployment and release gates

- Configure App Store Connect non-consumable product ID(s), In-App Purchase key (`.p8`), Key ID, Issuer ID, and Bundle ID, and supply `VEEA_APPLE_IAP_*` environment variables in staging/production.
- Verify real Sandbox and TestFlight purchases, restores, cross-account mismatch refusal, and refund/revocation reconciliation on a signed iOS device. Nothing in local automated tests asserts legal/tax compliance or live App Store billing execution.

## 5. Offline notebook and UI decisions (2026-11-17)

- The user confirmed **one device notebook**, unchanged on sign-in/sign-out/account switch. Production `GoAuthProvider(accountNotebooks:false)` leaves the active local notebook and practice rules intact. Confirmed online account deletion removes the session/payment link and **keeps device words**. Existing alternate workspace archives are retained untouched; they are not silently merged into the active notebook.
- `AppConfig.isVocabularySyncEnabled=false` disables the production sync service, learning engine, cloud import prompts and server cartridge installs. Accounts and purchases use the Go API independently. Do not enable vocabulary sync by merely flipping the constant: ownership migration and explicit import consent need a separate design/review.
- Backups exported by the production vocabulary provider use `source.kind=device`, with no account ID. User-selected local restores remain available while signed in or signed out. They never upload words and are not marked as eligible guest-created sync data.
- UI distinguishes **temporary Premium access** from **lifetime Pro**. Manual grants may upgrade to lifetime. A fresh server preflight prevents duplicate lifetime purchases for an already-paid account; uncertain Apple verification never opens a payment sheet.
- Restore requests made during sign-in are queued, pending StoreKit updates are coalesced, and successful claims are cached for five minutes per account/session. Explicit restore and pending refund/approval updates bypass this cache.
- Native entitlement initialization runs before the first challenge. Free downgrade pauses extra locks without deleting selections or custom rules, preferring the current challenge app when available. Turning OFF and removing remain unconditionally available.
- Manual-grant access remains available if Apple verification fails; `purchase_verification_pending` prevents a new checkout during that uncertainty.

## 6. References

- [Apple sandbox testing](https://developer.apple.com/help/app-store-connect/test-in-app-purchases/overview-of-testing-in-sandbox): no charges for sandbox/TestFlight purchases; Xcode simulation is separate.
- [Apple’s official signed data verifier](https://github.com/apple/app-store-server-library-python/blob/main/appstoreserverlibrary/signed_data_verifier.py): certificate time at signedDate with online checks disabled. Veea accepts signed data only from its fresh authenticated Apple HTTPS response.
- [Apple Root CA G3](https://www.apple.com/certificateauthority/AppleRootCA-G3.cer): downloaded public root fingerprint independently matched the embedded certificate.

- Billing readiness is explicit: `apple_purchase_available` is returned true only when the server verifier is configured. The client requires true before displaying Apple's payment sheet. An old or disabled backend cannot charge a user and leave the account link pending because of missing setup.
- Unknown transport/session-rotation outcomes retain a separate secure local purchase identity for StoreKit verification only; explicit sign-out, a definite server refusal and confirmed account deletion clear it. It is never an API credential.
- Detailed setup, no-charge TestFlight checklist, verification evidence and remaining release gates: [first paid release](../first-paid-release.md).

- Apple refund reversals are supported: durable proofs retain Apple's `signedDate`. Newer signed state can reinstate access after a reversed refund; older active/refunded responses cannot override a newer state. Refunded proofs are periodically rechecked as well. See [Apple REFUND_REVERSED](https://developer.apple.com/documentation/appstoreservernotifications/notificationtype).
