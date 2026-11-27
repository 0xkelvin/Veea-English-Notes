# One free app and word, one-time Pro

Owner decision: 26 November 2026; word-selection UX simplified on 27 November. Supersedes the free-first and unlock-trial proposals.

| Capability | Free forever | Verified Pro |
| --- | --- | --- |
| Notebook/dictionary/Listen/ordinary Review/custom lists/export | Included | Included |
| Active app locks | One | Multiple, within existing 50-app safety limit |
| Unlock selection | One replaceable word | Multiple selected words |
| Each unlock | Review that selected word | Review every selected word once |
| Default/custom/per-app times and pronunciation | Included | Included |
| Turn locks OFF or remove apps | Included | Included |

One non-consumable purchase enables both paid capabilities. Vietnam target:
99,000 VND once, no trial, subscription, per-minute payment or per-app purchase.
The pay button always uses StoreKit's actual localized product price. Missing
product/server configuration disables checkout without inventing a price.
Free usage requires no account; checkout/restore uses the existing signed-in
account-bound StoreKit/Go verification path. Cached verified ownership works
offline for its account. No word sync is enabled by this change.

## Lifecycle and saved settings

Native enforcement checks the one-app limit at picker save, aggregate enable,
individual enable and downgrade reconciliation. Extra previously configured apps
are paused and unshielded on Free; selections and timer preferences are retained.
Prefer the current pending challenge app, then an app with an earned live pass,
then the stable order shown in the app list. Restore/purchase does not silently
re-lock paused apps: users can explicitly re-enable them. The Free picker starts
with the current active app, so changing it never requires buying Pro.

The effective Free word count is one without overwriting the saved Pro preference.
Explicitly choosing one saves that new choice. An upgrade while a challenge is
open does not add questions to an answer already in progress. Closing that
screen releases its temporary target; the next opening or cold restart uses
the current rule while keeping already-answered vocabulary progress.
A downgrade immediately allows the Free one-word rule, preserving credited
learning history. Selecting words directly sets the required count; there is no
separate count picker. Newly saved notebook words never join automatically.
Legacy automatic pools become a fixed list using their old count, retaining
unfinished answer IDs. Deleted/unavailable selected words leave the effective
challenge; deleting the last selected word requires a new selection. On Free,
only the first saved word is active; additional Pro choices remain saved until
the user explicitly edits the selection. Listen/Review lists remain unlimited.

Failed/cancelled/pending/mismatched purchases never fabricate access or erase
words. Verified historical ownership is retained; duplicate lifetime checkout
stays blocked. OFF/removal does not require a successful billing request.

## Customer wording

English: Free includes one app lock and one word per unlock. Pro adds more apps
and more words per unlock. Pay once. No subscription. All unlock times are free.

Vietnamese: Miễn phí: khóa 1 ứng dụng và ôn 1 từ mỗi lần mở khóa. Veea Pro: khóa
nhiều ứng dụng và chọn nhiều từ để ôn. Mỗi lần mở khóa sẽ ôn tất cả các từ đã chọn. Thanh toán một lần, không đăng
ký định kỳ. Các tùy chọn thời gian mở khóa đều miễn phí.

## Store and review gates

Configure the existing intended non-consumable in App Store Connect at the
Vietnam price point 99,000 VND; do not create a second payment obligation for
earlier buyers. Confirm product ID, signing team/bundle, public account API,
server verifier and isolated Sandbox/Production environment through the existing
release procedure. No secrets belong in this document or repository.

Apple guideline 4.10 explicitly names Screen Time APIs. The app's education
category and a free tier do not establish an exception. Reviewer notes must
disclose the exact two paid benefits and request clarification; wording is not
proof of approval. Required signed-device Sandbox checks include real purchase,
restore, offline restart, cancellation/pending/refund/account changes, and
independent relocking with both Free and Pro. Local tests do not prove these.
