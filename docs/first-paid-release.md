# First paid release: offline notebook and one-time Pro

Branch: `feat/offline-pro-purchase-20261117`, based on `main` `05f66c4`.
Prepared 17–18 November 2026 with actual agy implementation/review and Claude independent QA.
No App Store product, payment key, production server setting, TestFlight upload or phone installation was changed by this work.

## Current owner decision — 28 November 2026

Free includes all existing learning, one app lock and one selected word per
unlock. One Pro purchase enables multiple apps and multiple selected words.
Standalone Practice Rounds and all unlock durations remain free. Preserve Nin's
StoreKit-first payment changes: guests purchase/restore without Veea sign-in;
matching signed-in transactions retain the Go ownership and environment checks.
See [the product matrix](pro-99k-model.md) and [TRD 11 §7](trd/11-apple-pro-purchases.md#7-storekit-first-ownership-amendment-a).

## Historical free-first decision — superseded

On 24 November 2026 the owner chose **free first**. That branch removed
new sales and makes all app-lock counts/custom/per-app times free without an
account. See [current App Store submission](app-store-submission.md). The paid
boundary and prices below are historical design, not the current customer offer.
Retain verified ownership and restore rights for any earlier purchases; future
paid learning features require a new decision.

## Historical product decisions

- Free: unlimited local words, Listen, Review, learning rules, one app lock, and default unlock presets of 5, 15 or 30 minutes.
- Pro: one-time non-consumable, multiple app locks, custom 5-minute–24-hour default and per-app unlock times. Existing learning rules remain available.
- Business target: 99,000 VND early access, then 149,000 VND regular. Configure one lifetime SKU and change its App Store price; do not make early buyers purchase again. Checkout always displays Apple's current localized price. Confirm the available Vietnamese price point before advertising it.
- Sign in before purchase and restore. Pro is linked to the authenticated Veea account UUID using Apple's appAccountToken. Free learning and the free app lock require no account.
- **One notebook on this phone** stays visible through sign-in, sign-out and account switching. Authentication manages accounts and Pro, not notebook ownership. Confirmed online account deletion keeps device words and clears this device's account/purchase identity when applicable. The dialog explains that a new account cannot automatically inherit the deleted account's purchase.
- Existing alternate local account archives remain untouched; this release does not silently merge those archives into the active notebook. Internal testers who previously used separate cloud notebooks should export any inactive notebook they want to keep accessible before migrating.
- Device JSON/CSV backups are portable and do not need account sign-in. Restoring a user-selected file is local only. Word upload, cloud sync/import prompts and remote cartridge installations are disabled in production; cloud account/payment operations stay independent.
- Disabling/removing locks, reading/exporting words and account rights are never paywalled. Extra locks are paused on Free without deleting their selections or custom rules. The current challenge app is preferred when applying a downgrade.

## Release behavior

Guest StoreKit purchase and restore require no account. Locally verified Apple
ownership enables Pro, including after Veea account deletion.
Only a matching account token can authorize a server Apple claim. Existing
server verification, bounded leases, refunds and environment isolation remain.

## Nin: configuration needed before TestFlight payment testing

The release product is Veea Pro Lifetime (`com.nintran.veeaEnglishApp.pro`), a
Non-Consumable for bundle `com.nintran.veeaEnglishApp`. Confirm the App Store Connect
record, localized pricing and signed build independently.

1. In App Store Connect, confirm the correct Veea app/team/bundle ID. Create or identify **one non-consumable** lifetime Pro product. Keep Family Sharing disabled for this first implementation; shared-family transaction ownership is intentionally not accepted. Complete its metadata and select the Vietnamese price.
2. Build the final TestFlight/review IPA from the repository root. Replace the example API URL with the release origin. The script rejects missing or invalid inputs before invoking Flutter. Existing development builds can continue to use the ordinary Flutter commands.

   ```sh
   VEEA_API_BASE_URL=https://api.example.test \
     VEEA_APPLE_PRO_PRODUCT_ID=com.nintran.veeaEnglishApp.pro \
     bash tool/build_ios_release.sh --build-number 42
   ```
   The script accepts `--build-number`, `--build-name`, `--export-method`,
   `--export-options-plist`, `--split-debug-info`, `--obfuscate`, and `--no-pub`.
   Give valued options as separate arguments or with `=`. The API URL must be
   a root HTTPS origin with a DNS hostname. Python 3 removes trailing slashes
   and the default HTTPS port. The script rejects localhost, IP literals,
   paths, credentials, queries, and fragments. Check that the release hostname
   resolves to the intended ingress before distribution.

   An explicit build number accepts one to three numeric `CFBundleVersion`
   components. The major must be positive with one to four digits. Optional
   minor and patch components accept one or two digits each. Choose an unused
   build number for the release version. The script rejects extra Dart defines
   and alternate entry points. [Apple bundle version rules](https://developer.apple.com/documentation/BundleResources/Information-Property-List/CFBundleVersion) · [Flutter iOS build numbering](https://docs.flutter.dev/deployment/ios)

3. Run migration 16 and apply the existing database permissions before deploying the billing API. Keep the release database's `apple_iap_control.environment` as `Production` (its default); do not switch it to Sandbox for review. This environment-handling fix adds no new migration.
4. Follow the [private server configuration and key delivery instructions](payment-environments.md#nin-deployment-settings). Keep the existing email/account service working and deploy it before distributing the candidate. Leave App Store Server Notifications V2 deferred. Use the [payment rollback procedure](payment-environments.md#roll-back-apple-iap) if checkout must be disabled or the API image reverted.
5. Build/upload through the paid Veea team with the existing Screen Time/App Groups entitlements. A personal-profile installation is not a valid substitute for this signed-device test.
6. The release API acknowledges Apple review/TestFlight Sandbox purchases without storing test proofs or granting Production account Pro. If a dedicated staging API is used instead, give it a separate database pinned to `Sandbox`, `VEEA_APPLE_IAP_ENVIRONMENT=Sandbox` and `VEEA_APPLE_IAP_ALLOW_SANDBOX=false`. Follow [payment environment deployment and acceptance](payment-environments.md). Do not direct automated tests at deployed services.

## No-charge phone acceptance

Use the signed-device [Option A acceptance matrix](pro-99k-qa.md). On the unsigned
and local test paths, use synthetic data. The exact TestFlight build must
show the StoreKit price, support guest checkout and restore, and keep Screen
Time available within the one-app Free limit after refund. Confirm within App Store Connect
that the intended Vietnamese price is 99,000 VND and Family Sharing is off.

## Verification evidence and limits

- The full integration suite has a known baseline failure in
  `TestMigrations_UpgradeFromVersion6KeepsDataAndAddsIndexes`, reproduced on
  clean `HEAD` (`66f8dd2`). The full Flutter suite has five baseline pixel
  differences in `test/golden/screens_golden_test.dart`, also reproduced on
  that snapshot. Focused IAP acceptance runs separately from those baselines.

Logs are in `/tmp/veea-pro-20261117/` on the development Mac.

- Go `make check` (format/vet/unit), SQLC generation/reproducibility, and new purchase/account/export/migration integration tests against a disposable local PostgreSQL were run.
- A full `go test -race -tags=integration` run reached Go's 10-minute limit near the session-management cases. It found five migration expectations still targeting version 15. Those were updated to assert version 16 and the exact new tables/indexes; replay idempotence was fixed. All uncompleted/new/failed top-level groups were then run separately with `-race`: combined **1,343 unique test/subtest passes, zero remaining failures, one optional Mailpit delivery test skipped** at that checkpoint. Later purchase readiness/error cases and targeted regressions have their own logs; do not describe the initial timed-out run as one fully green run.
- Latest focused Flutter run: **91 passed** for Pro, account/session races, device notebook, backups, Settings/app locks, durations and sync suppression. Lint checks pass. Native portable policy/state tests and Swift iPhone SDK type checking pass. The release Flutter AOT framework was also built for arm64 iOS; native code was type-checked against the iPhoneOS 27.2 SDK. This is not a signed archive or phone installation.
- Claude independently reviewed the implementation, executed 16 fake-channel/widget tests, and reported passing results; its findings and agy's findings were addressed with focused regressions. These are not real payments.
- Admin console: 43 tests passed, 10 environment-dependent E2E cases skipped, analyzer clean. The broad Flutter suite still has unrelated failures reproduced on unchanged `main` `05f66c4`: dictionary/context expectation mismatches, a Settings fixture missing AuthProvider, and phone-feedback flow failures/timeouts. Do not call the entire app's baseline green or treat this draft as launch approval.
- Worst-case account export header with manual grants, cartridge watermarks and five Apple proofs: **15,915 / 16,384 bytes**, checked in a unit test.

Before public release, finish the no-charge device checklist, resolve the baseline feedback/launch findings, update customer-facing privacy/account-deletion wording and explain account-linked Pro to App Review. The submitted build must demonstrate guest purchase and restore.
