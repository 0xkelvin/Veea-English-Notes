# Payment environment QA — 26 November 2026

## Scope

Candidate fixes TestFlight/App Review Sandbox purchases against the release API,
without granting Production account Pro from a test transaction. The existing
Free one-app/one-word and one-time Pro offer is unchanged. See
[payment environments and Nin's deployment checklist](payment-environments.md).

## Local verification

- All Go unit packages pass (`go test ./...`). Integration-tag `go vet` passes.
- All **13** purchase integration tests pass against disposable local PostgreSQL,
  including a fresh `-race -count=1` run. Cases cover test acknowledgement with
  no account grant/rows, real ownership/refunds, retry safety, cross-account refusal,
  late session revocation/inactive users, manual grants, no Sandbox pruning of
  real proofs, colliding IDs, default-off and startup environment gates, export,
  deletion, unknown outcomes and dedicated Sandbox durability.
- Verifier/config race tests pass. The routing matrix checks Production first,
  explicit Apple 4040010 fallback only, no fallback for generic 404/400, wrong
  signature/bundle/product/environment, auth/rate errors and outages.
- **37** focused Flutter provider/repository/Pro screen/app integration tests pass.
  Sandbox checkout/restore finishes after acknowledgement, keeps independently
  verified native ownership, and never creates a paid server lease from Free.
  Refund and later Free/native ownership removal cases pass. API scope separates
  base paths even on the same host and excludes URL query/fragment data.
- Flutter analyzer is clean. No dependency/lockfile upgrade is part of this fix.
- All portable native suites pass, including environment/cache isolation and
  the process-local server lease's cap, expiry, clearing, unknown-plan readiness,
  Free-before-environment-resolution cleanup and independent manual
  grant/refund behavior. Xcode/unsupported transactions are refused; app-download
  and IAP signing environments need not match for Apple review.
- Actual iPhoneOS **27.2** SDK typechecking passes with the real Flutter framework
  and an iOS 16 deployment target. The Xcode project file parses successfully.

## Independent review

Actual **Claude CLI** and **agy CLI** independently read the source and ran local
checks. Claude additionally ran all 13 real PostgreSQL purchase integration tests
with the race detector; agy ran Go unit/vet/focused race checks, compiled integration
tests, and ran the portable native suites and SDK typecheck. Their native findings
led to the nonblocking app lookup, purchase-safe environment resolution, explicit
unsupported environment handling, post-restore account guard, and the bounded
in-memory server plan fallback. Claude's focused closure reran the native suites
and confirmed the remaining findings closed, including the two final cache-clear
and unknown-plan readiness races. The final regressions also cover completed
ownership scans across supported environment resolution, expired lifetime metadata,
and finite manual access during uncertain Apple verification. Reported native findings were fixed with
regressions before the candidate was pushed.

## Evidence limits and remaining release gates

These checks use generated synthetic Apple certificates/proofs and local test
services. Portable native tests exercise pure policy/lease helpers; SDK checks
compile the StoreKit manager. They do not exercise its real Apple transaction
streams or prove Screen Time enforcement on a signed device.

No real Apple purchase, payment-provider configuration, deployed account database,
signed archive, TestFlight upload, phone installation or App Review was performed.
Nin must configure the 99,000 VND product/keys, enable the documented Production
Sandbox acknowledgement flag, deploy the server, upload a correctly signed build,
and complete the physical-device acceptance list. Existing unscoped server caches
are ignored; legacy server-only grants need online confirmation after the update.
Public release and guideline 4.10 acceptance remain Apple review decisions.
