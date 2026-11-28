# QA: free app protection and StoreKit-first educational Pro

Run on the signed TestFlight build and record the build, device, StoreKit
environment, actual price, and outcome. The [TRD 11 matrix](trd/11-apple-pro-purchases.md#79-edge-case-and-acceptance-matrix)
covers guest and signed-in StoreKit ownership and server isolation.

1. As a guest or Free user, protect multiple apps, configure multiple unlock
   words and verify existing timers, shielding, removal and relocking. Refund
   a Sandbox purchase and confirm that the locked apps and configuration stay.
2. Start a one-word Practice Round from Home without authorizing Screen Time.
   Include zero and one eligible word. Buy Pro as a guest, choose a multi-word
   standalone round and verify the available-word bound.
3. Cancel, defer via Ask to Buy, then accept. Verify guest restore, reinstall,
   and device replacement on the same Apple Account. Confirm a different
   Apple Account cannot restore that purchase.
4. Sign in after a guest purchase and verify that device Pro remains, with
   no account claim. For a separately purchased signed-in transaction verify
   the matching authenticated claim, retry after termination and outage,
   sign-out and account switching, and deletion followed by account recreation.
5. Verify refund/reversal updates after StoreKit learns of the change, no restore
   success from manual access alone, and TestFlight Sandbox creates no
   Production account purchase row. Check rejected Family Shared and unverified
   transactions using synthetic fixtures where Apple cannot supply the scenario.

## Baselines

The five macOS Flutter goldens and the version-6 migration-index assertion
failed on clean `66f8dd2`. Keep results distinct from IAP or protection regressions.
