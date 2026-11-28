# Restore the Free/Pro offer — 28 November 2026

Based on latest `main` `87a0b37`, on a fresh branch after PRs 49–52 merged.
The owner explicitly requested keeping Nin's payment implementation while
restoring one free app lock/word and one-time Pro for multiple apps/words.

## Result

- Existing learning stays free: notebook, dictionary, Listen, ordinary Review,
  standalone multi-word Practice Rounds, custom lists and backups.
- Free locks one app and uses one explicit selected unlock word. Replacing
  either is free. Pro enables multiple apps and multiple selected words.
- Every active selected word is required once per unlock; no separate quota.
- Custom/default/per-app durations, OFF, removal and account rights stay free.
- Verified purchase/restore changes reach Flutter and native protection.
  A confirmed downgrade pauses extras without deleting the saved notebook or
  paid preferences. The current challenge app, otherwise the latest live pass,
  is preferred for the retained Free lock. Normal explicit OFF behavior remains.

## Payments preserved

No changes to Go services, schemas, payment routes, deployment scripts, purchase
SKU, version or dependencies. `ProProvider`, `ProRepository`, Go auth/session
transport and `ProPurchasePolicy` retain Nin's implementation. Purchase,
restore, claim, finish, revocation verification and environment routing remain
intact. `ProPurchaseManager` only exposes the existing verified ownership to
protection and tracks when a server answer is fresh enough to pause extras.

Guest StoreKit purchase/restore works without Veea sign-in. Signed-in claims
still require the matching account token. Valid Apple ownership survives Veea
sign-out/deletion. A verified Sandbox purchase enables device Pro; Production
Sandbox acknowledgement creates no Production account grant or purchase row.

## Actual Claude collaboration and review

Claude CLI restored the native policy/entitlement bridge and independently
reviewed the combined Flutter/native diff. It found three medium edge cases:

1. Unchanged Free word confirmation discarded the paused paid selection and
   unfinished answers. The provider now treats that confirmation as a no-op;
   provider and real-picker widget regressions cover restart and re-upgrade.
   Deliberately choosing another Free word still replaces the saved list, with
   explicit wording in Learning rules.
2. A Free picker over a retained multi-app list replaced hidden paused apps.
   It now edits the free app while retaining the paused apps/custom times.
   Ordinary single-app replacement and explicit removal keep their behavior.
3. An expired offline account lease could be mistaken for confirmed Free.
   Readiness now expires with that lease; an authoritative Free reply is
   separate. This never extends paid access or grants Pro from an unknown plan.

## Verification

Local synthetic checks only; never pointed tests at deployed services.

- `flutter analyze --no-pub`: clean.
- Full `flutter test --no-pub`: **838 passed, 8 skipped, 2 failures**. Both are
  the unchanged Home light/dark goldens, reproduced before edits on `87a0b37`
  (baseline: 827 passed, 8 skipped, same 2 failures). Goldens were not regenerated.
- Purchase/restore/account integration: four tests pass, including immediate
  guest Pro activation and signed-in Sandbox acknowledgement with no server Pro.
- No-op word/provider/picker regression suite: 20 pass.
- `bash tool/test_native_screen_time.sh`: native policy/state/purchase suites.
- Go unit packages `internal/appleiap`, `internal/purchases`, `internal/auth/httpapi`,
  `internal/entitlements` and `internal/lifecycle`: pass, implementation unchanged.
- Actual Claude independent Flutter run before the final two word regressions:
  836 passed, 8 skipped, same 2 baseline goldens; native suites passed.

Claude rechecked the final native corrections: all portable suites pass, and
Runner (all Swift sources plus bridging header/Flutter framework), GateMonitor,
GateShieldAction and GateShieldConfiguration typecheck cleanly with the real
iPhoneOS 27.2 SDK, arm64 iOS 16.0, Swift 5. This is a typecheck, not an Xcode
build/link/signing step. Claude also independently ran the final word regression
suite: 20 passed. No remaining blocking issue was reported. Portable tests alone
do not compile UIKit/StoreKit integration.

No phone installation, TestFlight upload, real Apple checkout, live server
acceptance or App Review approval is claimed. Run the exact signed candidate
through [device payment/protection acceptance](pro-99k-qa.md). The actual
99,000 VND storefront price is an App Store Connect setting; display StoreKit's
localized price. The known guideline 4.10 review concern remains a release issue;
do not disguise the paid controls or claim an educational-category exemption.
