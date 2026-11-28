# QA: one free app/word and StoreKit-first one-time Pro

Run on the exact signed TestFlight build. Record build, device, StoreKit
environment, actual price and observed result. Use Sandbox with no real charge.
[TRD 11](trd/11-apple-pro-purchases.md#79-edge-case-and-acceptance-matrix)
retains the guest/signed-in ownership and server-isolation matrix.

1. As a guest on Free, use notebook, dictionary, Listen, ordinary Review,
   standalone multi-word Practice Rounds and custom lists without a purchase.
2. Lock one app and select one unlock word. Replace either for free. Request
   additional apps or words: offer Pro without changing saved settings. Custom
   times, disabling protection, removal and account rights stay free.
3. Cancel/defer a purchase: remain Free. Complete a verified guest purchase:
   multiple app locks and multiple selected words become available immediately.
   No Veea sign-in required. Four selected words require four distinct answers;
   no independent word-count control. New notebook words do not join silently.
4. Verify each app's timer, relock, interrupted challenge, preview and return flow.
   Restore after reinstall/device replacement on the purchasing Apple Account;
   a different Apple Account cannot restore it. Do not infer Screen Time behavior
   from a simulator, unsigned build or fake platform channel.
5. Veea sign-out/account deletion keeps the offline notebook and valid local
   StoreKit Pro. Guest proofs never go to Go. Matching signed-in proofs retain
   existing authenticated account-token checks; no account transfer.
6. Refund/revoke and refresh StoreKit: Free activates one app/word, retaining
   extra selections/settings and the retained Free app’s earned pass. Unknown purchase/server status
   must not erase or destructively downgrade them. Upgrade again restores saved
   words; paused app locks remain off until deliberately enabled. Confirm an
   unchanged Free word keeps paused word progress, and switching the Free app
   keeps paused app selections/custom times. An expired offline account lease
   is unknown until a fresh server reply, never an automatic confirmed downgrade.
7. TestFlight Sandbox acknowledgement creates no Production purchase row or
   server Premium grant. Restore must not claim Apple lifetime ownership from a
   manual grant alone. Exercise offline, outage, retry and account-switch races.
   Family Shared/unverified transactions stay rejected (synthetic cases as needed).

## Latest main baseline, 28 November 2026

Before this correction, unchanged `87a0b37` ran 827 Flutter tests successfully,
with 8 skips and two existing Home light/dark golden failures. Do not regenerate
unrelated goldens to hide them. Host tests do not replace signed-device acceptance.
