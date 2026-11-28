# Veea English App Store submission

Release preparation for the owner-selected 28 November 2026 model.
See the [product matrix](pro-99k-model.md) and [release instructions](first-paid-release.md).

## App Store metadata

- Product: **Veea Pro Lifetime**. Non-Consumable, `com.nintran.veeaEnglishApp.pro`.
- Bundle: `com.nintran.veeaEnglishApp`. Vietnam target: 99,000 VND. Confirm
  the storefront price and use StoreKit to display it. Disable Family Sharing.
- English: “Save, listen to and review your own words for free. Lock one app
  and review one selected word to unlock it. Veea Pro Lifetime is a one-time
  purchase for multiple app locks and multiple selected words per unlock.
  Purchase and Restore Purchases work without a Veea account.”
- Vietnamese: “Lưu, nghe và ôn từ vựng miễn phí. Khóa 1 ứng dụng và ôn 1 từ đã
  chọn để mở khóa. Mua Veea Pro trọn đời một lần để khóa nhiều ứng dụng và ôn
  nhiều từ đã chọn mỗi lần mở khóa. Không cần tài khoản Veea để mua hoặc khôi phục.”

## Screenshot capture list

Capture real signed-build screenshots in each release language: free learning,
one app/word on Free, multiple apps/selected words on Pro, and localized checkout
with Restore Purchases. Remove private account and notification details.

## App Review notes

Veea English stores and reviews vocabulary offline. Notebook, dictionary,
Listen, ordinary Review, standalone multi-word Practice Rounds and custom lists
are free. Optional Screen Time protection supports one app and one selected
word per unlock on Free. The existing non-consumable Pro purchase enables
multiple apps and multiple selected words per unlock. All timers, disabling
and removal remain free. StoreKit purchase and restore work without Veea sign-in.
Optional sign-in supports account features and deletion. State these actual paid
limits openly; an educational category does not resolve guideline 4.10 review
risk, and implementation/tests are not Apple approval.

1. Add sample words and use the free learning features without Screen Time.
2. Without Pro, authorize Screen Time and choose one app/word. Replacing them
   and setting custom times are free. Selecting more offers Pro.
3. Complete a Sandbox purchase and choose multiple apps/words. Every selected
   word is required per unlock. Test Restore Purchases while signed out of Veea.
4. Exercise optional sign-in/deletion and confirm device vocabulary survives.
   Use App Store Connect's private review field for actual access instructions.

## App Privacy checklist

Use the exact submitted build and live operator settings. Apple asks about data
collected by the developer and its partners. Device-only processing and Apple's
own processing are handled separately. Confirm the actual answers before
submission. [Apple App Privacy Details](https://developer.apple.com/app-store/app-privacy-details/)

| Area | Repository evidence and answer to verify |
| --- | --- |
| Contact info and identifiers | Optional Go accounts use an email address and account UUID. Session and security flows may process IP, user agent and pseudonymous keys. Check Email Address and User ID for App Functionality, linked to the account. Confirm extra identifiers, IP handling and log retention at the live proxy and hosting provider. |
| Purchase History | A signed-in claim sends a transaction ID and Go looks up signed Apple information. Account-owned purchase records store product/environment/transaction data and timestamps, retain at most five recent proofs and are purged with the account. Check linked Purchase History for App Functionality for this optional path. Guests send no purchase claims to Veea. Confirm Apple reporting access and any independent bookkeeping retention. |
| Payment details | Apple processes the checkout. The app does not send card or bank details to Veea. Confirm any separate merchant collection. |
| Notebook and on-device data | SQLite stores words/reviews, platform secure storage holds account credentials, and settings/Screen Time data use local preferences or App Groups. Release builds disable notebook sync. Check sharing, exports, OS/device backups and signed-build flags before classifying off-device use. |
| Dictionary lookup | Explicit online lookup can send the query to Google Translate or MyMemory. Check User Content or Search History as appropriate after confirming which providers are active, retention, linkage, purpose and provider data practices. Local dictionary lookups stay on-device. |
| Email and support | Go uses the configured delivery provider for account email. Confirm the Resend deployment, provider retention and purposes. Feedback drafts start locally and can be shared explicitly. Verify support inbox, enabled transport, retention, and user-content disclosures. |
| Diagnostics and telemetry | Go Prometheus counters use fixed codes without account or transaction IDs. Application and ingress logs, alert routing, crash reporting, App Analytics access and retention depend on deployed settings. Verify incident tooling before answering Diagnostics, Usage Data or tracking. |
| SDKs and tracking | Review resolved Flutter/iOS dependencies and privacy manifests in the signed archive, including storage, HTTP, speech/audio and sharing plugins. No advertising or third-party analytics SDK was identified in the checked-in direct dependencies. Confirm transitive SDKs and actual provider behavior before submitting tracking or advertising answers. |
| Retention and deletion | Confirm live email, proxy, backup, support, audit, and deletion-ledger retention against the account-rights policy. Deleting Veea data removes server purchase ownership. Valid StoreKit purchases remain with the Apple Account. |
| Public policy and support | Use confirmed team URLs and inbox. Direct users to Restore Purchases on the purchasing Apple Account. Support cannot relink another account's token. Refund requests go through [Apple](https://reportaproblem.apple.com/). |

## Live setup and acceptance

Suggested operator: Nin. Record actual configuration/evidence, not private keys.

- Confirm the intended app/team and Family Controls distribution permission for
  Runner and all three Screen Time extensions. Source entitlements alone are
  insufficient. [Apple entitlement instructions](https://developer.apple.com/documentation/familycontrols/requesting-the-family-controls-entitlement).
- Confirm app version/build, source commit, public HTTPS API origin and release
  configuration match the exact signed binary being reviewed.
- Publish the final privacy policy at a real public HTTPS URL, add it in App Store
  Connect and configure the in-app link. Confirm the operator/contact and actual
  account, email-provider, purchase, log and deletion retention practices.
- Confirm a real support destination. No sender/recipient mailbox is considered
  working solely because an address is present in source.
- Complete age rating, categories, encryption/export-compliance questions, regions,
  privacy disclosures and any displayed agreements/business/tax/banking requirements.
- Configure the existing non-consumable, the intended 99,000 VND Vietnam price, actual localized
  price and server verification. Keep durable staging Sandbox and Production purchases isolated.
  The release Production API must also enable Sandbox acknowledgements for App Review,
  without granting Production Pro from test purchases; follow [payment environments](payment-environments.md).
  Add the first in-app purchase and app version to the same review submission.
  [Apple purchase submission instructions](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/submit-an-in-app-purchase/).
- Run signed-device checks for five-minute background relock, two independent
  protected apps and multiple words per unlock on Pro, one app/word on Free, native sheet labels,
  custom/per-app times without sign-in, account
  deletion and offline notebook preservation. Record device/OS, exact build and
  expected/observed outcomes. Earlier-purchase restore/refund scenarios remain
  required alongside sandbox checkout and the mid-challenge plan-change cases.
- Resolve meaningful test failures before release. Do not replace physical Screen
  Time or live email/purchase acceptance with a host widget-test result.

No production setup, mailbox delivery, physical-phone test, publication, upload,
purchase or Apple agreement is marked completed by this document.
