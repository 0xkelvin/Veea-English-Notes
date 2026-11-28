# Free learning and one-time Pro unlocks

Owner decision, 28 November 2026. This replaces the 27 November product-scope
change while preserving Nin's StoreKit-first ownership and payment implementation.

| Capability | Free | Veea Pro Lifetime |
| --- | --- | --- |
| Notebook, dictionary, pronunciation, Listen, Review, Practice Rounds, custom lists, backups | Included | Included |
| Active app locks | 1 app | Multiple apps, up to the existing 50-app technical limit |
| Selected words reviewed at every unlock | 1 explicit word | Every selected word, bounded by the saved notebook |
| Default/custom/per-app unlock times, turning locks off, removing apps | Included | Included |

Selection defines the challenge size; there is no separate words-per-unlock quota.
See [Learning rules](selected-unlock-words.md). Free users may replace their word
or their protected app without buying Pro. A confirmed downgrade pauses extra
locks and words without deleting their saved settings or vocabulary. The current
challenge app is preferred, otherwise the app with the latest live pass; its
earned pass stays intact. Pausing another app keeps the existing OFF behavior.
Unknown purchase status, including an expired offline account lease, must not
be treated as a confirmed downgrade. Confirming the same Free word preserves
paused words/progress. A Free app-picker edit over a retained multi-app list
switches the active free app while keeping paused apps and custom times; it
does not delete that hidden list. Explicit removal remains available.

Use the existing non-consumable `com.nintran.veeaEnglishApp.pro` for
`com.nintran.veeaEnglishApp`. Target 99,000 VND once in Vietnam; the checkout
always displays the actual localized StoreKit price. Family Sharing stays off.

## Customer wording

English: Free includes your learning features, 1 app lock and 1 selected word per
unlock. Buy Pro once to lock multiple apps and review multiple selected words
per unlock. No subscription. Restore Purchases works without a Veea account.

Vietnamese: Miễn phí các tính năng học từ, khóa 1 ứng dụng và ôn 1 từ đã chọn
mỗi lần mở khóa. Mua Pro một lần để khóa nhiều ứng dụng và ôn nhiều từ đã chọn
mỗi lần mở khóa. Không có phí định kỳ. Không cần tài khoản Veea để khôi phục giao dịch.

## Ownership and release

[TRD 11 §7](trd/11-apple-pro-purchases.md#7-storekit-first-ownership-amendment-a)
continues to define guest StoreKit ownership, authenticated claims, refunds,
account deletion and environment isolation. No payment routes or database rules
change with this product correction. Sandbox acknowledgement is not Production
server Pro. Signed TestFlight purchase, restore, refund and Screen Time acceptance
remain required. App Review must see the actual paid app-count and word-count
limits; do not describe those controls as unlimited on Free. The known guideline
4.10 review concern remains unresolved by this implementation or by an educational
category; no approval is claimed.
