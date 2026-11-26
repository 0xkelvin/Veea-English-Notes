# Veea English App Store submission

Release preparation dated 24 November 2026. Source base: `main` `7aed10b`.
Use this with [first paid release](first-paid-release.md). This is preparation,
not a record of production deployment, a TestFlight upload or Apple approval.

## Confirmed first-release decision: free launch

The owner confirmed **launch free first; design paid learning features next** on
24 November 2026. This branch makes learning, multiple app locks (up to the
existing 50-app safety limit), default/custom unlock times and per-app overrides
available without a purchase or account. Both Flutter and native enforcement
apply this policy. New checkout and product-price loading are disabled; an old
purchase can still be restored when its original product/account are configured.
Free availability does not fabricate Pro ownership or transfer purchase records.

The earlier Pro boundary sold extra app locks and custom times. Apple
[guideline 4.10](https://developer.apple.com/app-store/review/guidelines/#monetizing-built-in-capabilities)
explicitly names Screen Time APIs among built-in technologies that must not be
monetized. Any later paid learning product needs a separate value/implementation
and review decision. Historical paid-release instructions are retained for
purchase recovery and later work, not as current launch requirements.

Accounts remain optional. The free notebook and locks require no sign-in. Do not
advertise cloud word sync: saved-word transport remains disabled. Account-based
services still need correct privacy/deletion handling under
[guideline 5.1.1](https://developer.apple.com/app-store/review/guidelines/#privacy).

## Store text draft in Vietnamese

**Name:** Veea English

**Subtitle:** Sổ từ vựng tiếng Anh của bạn

**Promotional text:** Lưu từ bạn gặp mỗi ngày, nghe lại và ôn tập theo cách của bạn. Chọn app để khóa và hoàn thành bài ôn để nhận thời gian sử dụng.

**Description:**

Veea English là cuốn sổ dành cho những từ tiếng Anh bạn muốn ghi nhớ.
Lưu từ, nghĩa và ví dụ mình gặp khi học, đọc hoặc làm việc. Nghe lại và chọn
những từ muốn ôn trong chính danh sách của bạn.

- Lưu từ vựng theo ngày, tìm kiếm và xem lại những từ đã chọn luyện tập.
- Nghe phát âm và luyện nghe từ đã lưu.
- Ôn tập bằng thẻ từ và tùy chỉnh quy tắc học.
- Chọn app muốn khóa, hoàn thành bài ôn mở khóa và nhận thời gian sử dụng.
- Tự xuất tệp sao lưu để giữ một bản riêng của sổ từ.

Từ vựng được lưu trên thiết bị. Đăng nhập không tự sao lưu hoặc đồng bộ sổ từ
lên đám mây. Sau bài ôn mở khóa, bạn quay lại app muốn sử dụng.

This text does not advertise an unapproved price, an Every Open challenge,
automatic return to another app, Android protection or guaranteed learning results.
The first release has no new in-app purchase offer. Future paid learning features
require updated store text and a separately reviewed implementation.

**Keywords draft:** từ vựng,tiếng Anh,sổ từ,ôn tập,phát âm,luyện nghe,học tiếng Anh

## Store text draft in English

**Subtitle:** Your personal vocabulary book

**Description:**

Keep the English words you want to remember in one personal notebook. Save
meanings and examples, listen to pronunciation, and review words from your own list.

- Browse words by date and search your notebook.
- Choose the vocabulary you want to practise.
- Listen and review with learning rules that suit you.
- Choose apps to lock and complete a vocabulary challenge to earn timed access.
- Export a local backup to keep a separate copy of your words.

Vocabulary stays on your device. Signing in does not upload or back up your
notebook. After an unlock challenge, return to the app you want to use.

## Screenshot capture list

Capture the final signed build; retain original screenshots. Fixtures or old
builds are not evidence of the submitted experience. Use neutral vocabulary
and remove private notifications/account details from marketing captures.

1. Notebook with saved words and Vietnamese meanings: “Từ bạn gặp, trong sổ của bạn”.
2. Review with chosen practice words: “Ôn những từ bạn muốn nhớ”.
3. Listen with settings closed: “Nghe lại từ đã lưu”.
4. Manage Apps to Lock: “Ôn từ để nhận thời gian dùng app”.
5. Learning rules with selected-word summary: “Bạn chọn từ và cách luyện tập”.

Use the screenshot dimensions accepted for the selected devices in App Store
Connect. If the app is distributed on iPad, test/capture its actual iPad layout.
An App Store preview video is optional; the unfinished social-video recording
is not a launch dependency and is not a completed preview asset.

## App Review notes draft

Veea English is a personal English vocabulary notebook with optional individual
focus controls. Its Family Controls integration lets the device owner choose
apps through Apple's picker and earn timed access after a vocabulary challenge.
It does not manage another adult's phone or expose private app identifiers to
an advertising service.

The notebook, listening and review work without an account. Words and local
backups remain on the device across account sign-in/out. Account creation and
account deletion are available in Settings → Account when the account service
is configured. The current account system uses verified email, not SMS.

Reproduction steps:

1. Add several neutral words with meanings.
2. Settings → Learning rules: choose the practice pool and words per unlock.
3. Settings → Manage Apps to Lock: authorize Screen Time, select an app and set
   the unlock duration.
4. Open the selected app and follow the shield guidance to Veea's challenge.
5. Complete the challenge and manually return to the chosen app.
6. Confirm the selected app locks again after the pass expires.

Before submission, replace this draft's access instructions with the actual
reviewer account or a functioning review-access procedure. Put credentials only
in App Store Connect's private review-information field, never this repository.
The review service must remain reachable during review if optional account
features are included. All notebook and app-lock steps above work without an
account or purchase. If earlier-purchase restore is configured, disclose that
recovery path separately; no new purchase is offered.

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
- Deferred until a separately approved paid learning candidate: configure one approved non-consumable, actual localized
  price and server verification. Keep staging Sandbox and Production isolated.
  Add the first in-app purchase and app version to the same review submission.
  [Apple purchase submission instructions](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/submit-an-in-app-purchase/).
- Run signed-device checks for five-minute background relock, two independent
  apps, native sheet labels, custom/per-app times without sign-in, account
  deletion and offline notebook preservation. Record device/OS, exact build and
  expected/observed outcomes. Earlier-purchase restore/refund scenarios remain
  required if that recovery path is configured; new sandbox checkout is deferred.
- Resolve meaningful test failures before release. Do not replace physical Screen
  Time or live email/purchase acceptance with a host widget-test result.

No production setup, mailbox delivery, physical-phone test, publication, upload,
purchase or Apple agreement is marked completed by this document.
