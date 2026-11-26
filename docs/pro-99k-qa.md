# QA: one free app and word, one-time Pro

26 November 2026. Product specification: [current offer](pro-99k-model.md).
This change is stacked on the dictionary/Listen work in PR #47. No signed build,
phone installation, App Store product/price change or production deployment was
performed. Target price 99,000 VND is a configuration requirement, not a claim
that live billing is already enabled.

## Final automated verification

- Flutter analysis: no issues.
- Complete Flutter suite: **805 passed, 8 skipped**, exit 0. Existing golden
  images were not changed. The skips are the existing environment-dependent
  cases, not newly disabled pricing tests.
- Native portable policy/state/concurrency tests: all check groups passed.
- iPhoneOS 27.2 SDK type checking: all affected native sources, purchase manager
  and AppDelegate compiled, using the real Flutter framework and generated
  Objective-C registration header. This is not a signed archive/device test.
- Backend `go test ./...`: passed using Go 1.26.2, matching go.mod. No backend
  sources, migrations, modules or API contracts changed. Tagged PostgreSQL
  integration tests were not rerun and no deployed API/database was contacted.
- Dedicated integration/layout run: 21 passed before the final full suite,
  including the actual app shell's verified-Pro/sign-out propagation, real
  SQLite word limits/rotation/persistence and simulated-StoreKit-price layouts.
- Captures inspected with system fonts: phone, 320-point/200% text, dark mode,
  owned Pro and reachable purchase/restore actions. Displayed 99,000 VND in these
  captures is a test fixture, not a live product-price check.

Useful commands:

```sh
flutter analyze --no-pub
flutter test --no-pub --reporter expanded
bash tool/test_native_screen_time.sh
cd backend
go test ./...
```

## Actual collaborator participation

Actual agy CLI implemented the upgrade screen, learning-rule upsells, free
duration editing, plan summaries and matching widget tests. The first editing
turn reached its print deadline after source edits; its follow-up completed
the three widget-test files and returned normally. Root ran and corrected the
tests' fake-time/real-SQLite waits, offscreen hit targets and legacy fixtures.

Actual Claude CLI independently ran the specified bounded Flutter regression:
**75 passed, zero failed**, plus native portable tests, then reviewed the code.
It found a stale round-target bug and three smaller concerns. Root corrected
them and added regressions; Claude's subsequent read-only closure review
confirmed all four closed and found no new correctness bugs.

Closed findings:

1. Closing a challenge now releases its temporary word target while preserving
   answered IDs. New sessions/restarts use the current rule; an upgrade cannot
   increase the target on an answer currently in progress.
2. Partial app-lock states provide an explicit free Turn off all locks action
   in both Settings and Manage. The master switch retains the owner's all-on
   aggregate behavior. Disabling/removing never opens the paywall.
3. Native Free status reads skip writes/shield reapplication when the active
   count is already at most one; downgrade mutations still recheck under lock.
4. Practice-pool adjustment copy distinguishes saved preferences from the
   effective Free one-word rule.

Integration decisions: retained extra apps stay paused on restore until the
user explicitly re-enables them. Current-challenge and earned-pass preferences
make downgrade selection predictable. Unknown entitlement readiness returns a
checking message, rather than pretending a verified purchase is absent.

## Remaining external acceptance

Nin/team must confirm the existing intended non-consumable product ID, actual
Vietnam price point 99,000 VND, correct build/API values, server verification and
isolated Sandbox environment. Test signed TestFlight purchase, cancellation,
pending approval, restore, offline cold start, refund/account changes and real
independent relocking. TestFlight/Sandbox purchases do not prove production
ownership. Current code fails checkout closed when configuration is missing.

Reviewer wording in [submission notes](app-store-submission.md) explicitly
discloses the two paid capabilities. Apple guideline 4.10 remains unresolved;
the education category and competitor listing do not establish an exemption.
