# First paid release: offline notebook and one-time Pro

Branch: `feat/offline-pro-purchase-20261117`, based on `main` `05f66c4`.
Prepared 17–18 November 2026 with actual agy implementation/review and Claude independent QA.
No App Store product, payment key, production server setting, TestFlight upload or phone installation was changed by this work.

## Product decisions

- Free: unlimited local words, Listen, Review, learning rules, one app lock, and default unlock presets of 5, 15 or 30 minutes.
- Pro: one-time non-consumable, multiple app locks, custom 5-minute–24-hour default and per-app unlock times. Existing learning rules remain available.
- Business target: 99,000 VND early access, then 149,000 VND regular. Configure one lifetime SKU and change its App Store price; do not make early buyers purchase again. Checkout always displays Apple's current localized price. Confirm the available Vietnamese price point before advertising it.
- Sign in before purchase and restore. Pro is linked to the authenticated Veea account UUID using Apple's appAccountToken. Free learning and the free app lock require no account.
- **One notebook on this phone** stays visible through sign-in, sign-out and account switching. Authentication manages accounts and Pro, not notebook ownership. Confirmed online account deletion keeps device words and clears this device's account/purchase identity when applicable. The dialog explains that a new account cannot automatically inherit the deleted account's purchase.
- Existing alternate local account archives remain untouched; this release does not silently merge those archives into the active notebook. Internal testers who previously used separate cloud notebooks should export any inactive notebook they want to keep accessible before migrating.
- Device JSON/CSV backups are portable and do not need account sign-in. Restoring a user-selected file is local only. Word upload, cloud sync/import prompts and remote cartridge installations are disabled in production; cloud account/payment operations stay independent.
- Disabling/removing locks, reading/exporting words and account rights are never paywalled. Extra locks are paused on Free without deleting their selections or custom rules. The current challenge app is preferred when applying a downgrade.

## What is implemented

1. Settings → Veea Pro: free/paid benefits, actual localized Apple price, sign-in entry, restore, cancelled/pending/error outcomes. Temporary manual Premium grants can buy lifetime; an already-paid account cannot start another payment.
2. StoreKit 2 verifies local transactions and account tokens. Pending purchases/refunds survive unfinished-transaction recovery; transactions are finished only after the server commits the ownership proof. A local StoreKit lifetime entitlement does not depend on a redundant server lifetime lease.
3. An unknown network refresh outcome keeps the last verified purchase identity solely for local StoreKit verification. It is not an API credential. Explicit sign-out, definite server rejection or confirmed applicable account deletion clears it. Switching accounts never transfers its entitlement.
4. Go `POST /v1/me/purchases/apple`: bearer auth, strict input, per-user verification rate limit, fresh authenticated Apple lookup, pinned Apple certificate chain/JWS checks, bundle/product/environment checks, account-token ownership, session revalidation under lock, durable retry-safe proof and committed refunds.
5. Manual grants are independent of Apple purchases. Apple outages preserve a valid manual grant and prevent a new checkout during uncertainty. Owner reads reconcile stale proofs; other server consumers accept an unrevoked proof for at most 24 hours without re-verification.
6. Migration 16 isolates Sandbox/Production namespaces and the database billing environment. Apple proofs participate in export and full account purge; the five retained proof periods keep the worst-case export header within 16 KiB. Admin UI distinguishes an Apple lifetime purchase from a temporary manual grant.

## Nin: configuration needed before TestFlight payment testing

GitHub's tracked app configuration contains no confirmed Pro product ID or public account API URL. GitHub cannot prove whether the App Store Connect product already exists; check that service separately.

1. In App Store Connect, confirm the correct Veea app/team/bundle ID. Create or identify **one non-consumable** lifetime Pro product. Keep Family Sharing disabled for this first implementation; shared-family transaction ownership is intentionally not accepted. Complete its metadata and select the Vietnamese price.
2. Set the app build values `VEEA_API_BASE_URL` (a dedicated staging API for testing) and `VEEA_APPLE_PRO_PRODUCT_ID` (the exact product ID). No provider/private keys go into the app or GitHub.
3. On the staging server only, run migration 16, apply the updated database permissions, and explicitly set the dedicated staging database's `apple_iap_control.environment` to `Sandbox`. Its default is `Production`; the API refuses an enabled verifier/database environment mismatch. Use a separate production database.
4. In the server's private configuration, set `VEEA_APPLE_IAP_ENABLED=true`, `VEEA_APPLE_IAP_ENVIRONMENT=Sandbox`, `VEEA_APPLE_IAP_ISSUER_ID`, `VEEA_APPLE_IAP_KEY_ID`, `VEEA_APPLE_IAP_PRIVATE_KEY` (Apple In-App Purchase P-256 private key), `VEEA_APPLE_IAP_BUNDLE_ID` and `VEEA_APPLE_IAP_PRODUCT_IDS` (the same SKU). Keep the existing email/account service working. Default/missing billing configuration does not allow checkout.
5. Build/upload through the paid Veea team with the existing Screen Time/App Groups entitlements. A personal-profile installation is not a valid substitute for this signed-device test.
6. Production later uses `Production` server verification, the production database/environment gate, the production API URL and the same approved non-consumable product. Do not direct automated tests at deployed services.

## No-charge phone acceptance

[Apple confirms that TestFlight purchases use sandbox and do not charge testers](https://developer.apple.com/in-app-purchase/). They do not become real purchases after App Store release. Xcode's local StoreKit simulation is separate and its transactions are deliberately not accepted by this production verifier.

On a signed TestFlight build pointing at staging:

1. Start Free without an account: save words, Listen/Review, select practice words and protect one app. Try a second app/custom time, then open Pro. Confirm OFF/remove/export always work.
2. Sign in: the same words, dates and practice choices stay visible. Buy Pro using the sandbox payment sheet. Verify the account-linked Premium response and multiple apps/custom timers.
3. Complete challenges for two apps; each timer/relock stays independent. Reopen/restart offline and confirm paid access and local words remain available.
4. Cancel a purchase; test pending approval and later approval; cancel messages must not reappear on passive refresh. No repeated payment sheet for an already-paid account.
5. Restore after reinstall (export notebook first, because reinstall removes local words). Verify the same account restores Pro; a different account cannot claim that purchase. Restore queued during sign-in must actually run.
6. Test a refund/revocation: native owned access is removed, a current manual grant remains independent, and a fresh server verification records the refund. An older proof cannot override a newer refund or reinstatement. Verify that a newer Apple refund reversal restores Pro. Server-only access has the documented bounded offline lease.
7. Disconnect the network during session refresh: verified local ownership persists. Explicit sign-out/definite server rejection clears account-bound access; the notebook stays. Test confirmed account deletion with an exported notebook backup.

These device/payment checks remain unperformed. Local tests do not prove App Store configuration, Apple review acceptance, or real-device Screen Time enforcement.

## Verification evidence and limits

Logs are in `/tmp/veea-pro-20261117/` on the development Mac.

- Go `make check` (format/vet/unit), SQLC generation/reproducibility, and new purchase/account/export/migration integration tests against a disposable local PostgreSQL were run.
- A full `go test -race -tags=integration` run reached Go's 10-minute limit near the session-management cases. It found five migration expectations still targeting version 15. Those were updated to assert version 16 and the exact new tables/indexes; replay idempotence was fixed. All uncompleted/new/failed top-level groups were then run separately with `-race`: combined **1,343 unique test/subtest passes, zero remaining failures, one optional Mailpit delivery test skipped** at that checkpoint. Later purchase readiness/error cases and targeted regressions have their own logs; do not describe the initial timed-out run as one fully green run.
- Latest focused Flutter run: **91 passed** for Pro, account/session races, device notebook, backups, Settings/app locks, durations and sync suppression. Lint checks pass. Native portable policy/state tests and Swift iPhone SDK type checking pass. The release Flutter AOT framework was also built for arm64 iOS; native code was type-checked against the iPhoneOS 27.2 SDK. This is not a signed archive or phone installation.
- Claude independently reviewed the implementation, executed 16 fake-channel/widget tests, and reported passing results; its findings and agy's findings were addressed with focused regressions. These are not real payments.
- Admin console: 43 tests passed, 10 environment-dependent E2E cases skipped, analyzer clean. The broad Flutter suite still has unrelated failures reproduced on unchanged `main` `05f66c4`: dictionary/context expectation mismatches, a Settings fixture missing AuthProvider, and phone-feedback flow failures/timeouts. Do not call the entire app's baseline green or treat this draft as launch approval.
- Worst-case account export header with manual grants, cartridge watermarks and five Apple proofs: **15,915 / 16,384 bytes**, checked in a unit test.

Before public release, finish the no-charge device checklist, resolve the baseline feedback/launch findings, update customer-facing privacy/account-deletion wording and explain account-linked Pro to App Review. Requiring sign-in for a local-feature purchase may need review discussion under [Apple's account-sign-in guideline](https://developer.apple.com/app-store/review/guidelines/#account-sign-in); this implementation follows the user's explicit sign-in-before-purchase decision.
