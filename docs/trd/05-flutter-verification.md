# TRD 05 Flutter implementation and verification — 2026-11-14

Branch: `feat/go-email-auth-account-foundation`. This records local verification, not release approval. The server gate remains closed. No server control row, applied Go migration, staging environment, commit or push was changed by this work.

## Takeover inventory

At takeover, ten files were staged, with no unstaged or untracked files. The existing work supplied SQLite v12 partition/queue/review/staging tables, notebook archive switching, the Go sync HTTP transport, a mostly implemented sync engine, the canonical encoder and shared Go fixture generator/Dart test. Those were retained and extended.

Incomplete behavior included production wiring (the app still used timestamp sync), durable uncertainty before transmission, persisted import reconfirmation, request grouping, reset/rebase handling, backup ownership/provenance, session-expiry cache closure, review/import controls and acceptance tests. The staged fake repository also needed its new interface methods. The index changed externally during the takeover; this work issued no staging commands.

## Completed behavior

- The application coordinator uses `LearningSyncApi` and the persistent engine. One writer lane serializes sync, imports and review mutations. Sign-out/session expiry wait for that lane and open guest; transactions fence late results against the open owner.
- SQLite **v13** extends v12 with request boundaries, a durable import confirmation latch and immutable review origins. Uncertainty commits **before** sending. A v12 queued request upgrades conservatively to unknown. Stored mutation bytes are inserted verbatim into retries; a later refusal cannot free an unknown sequence. Writer state proves processing, not application.
- Expired results reconcile against the authoritative record or enter per-item review. Retired-writer and pre-restore queues retain original writer/sequence/BLOB in review. Deletes remain deletes; missing updates require the distinct new-ID recreation action. There is no bulk replay. Unknown imports also become review-only after expiry/reset.
- Snapshot pages and every catch-up page, including an empty tail, stage before atomic replacement. Compaction discards staging. A restore discovered by a fresh snapshot upgrades the reset to pre-restore review. Dirty never-sent fields rebase without overwriting unrelated server fields; edits made during a send survive its canonical result.
- Account UUIDs partition caches, queue, cursor, writer and review. Confirmed deletion clears the identified account even if its cache is already closed; guest and other accounts survive. No Go ownership is derived from email.
- Migration marks pre-rebuild vocabulary `legacy_untagged`, including current and archived notebooks. Archived vocabulary opens in guest; ID collisions preserve both versions. Original pre-Go local history remains in `__legacy__:*` archives, which cannot be opened as Go account caches. Explicit guest erasure removes those archives too.
- JSON and CSV notebook exports include source ownership and per-word provenance. Foreign-account backups are refused. Untagged/guest backups require the guest notebook (the user signs out first); editing or round trips cannot upgrade legacy provenance. Own-account backup candidates stay locally held until explicitly selected in Sync review and sent through the capacity-checked import route.
- Import consent is stored per owner/dataset. Selection is bounded by canonical bytes and word capacity; exclusions remain local. `capacity_changed` refreshes capacity and durably blocks background resubmission until a second confirmation. Unknown attempts keep their original selection/mutations; only the capacity basis changes. Quota-held words require **Back up now**.
- Settings provides per-item review, explicit local import and quota retry controls. Shared Go fixtures now also cover invalid/normalizing timestamp boundaries; the Dart validator rejects dates that `DateTime.parse` would silently normalize.

## Commands and actual results

Run from the repository root unless stated otherwise:

```sh
flutter analyze
flutter test test/data test/services test/providers \
  test/screens/settings_screen_test.dart \
  test/screens/sync_review_screen_test.dart --reporter json
```

- Analysis: **passed**, no issues.
- Affected Flutter suite: **323 passed, 0 failed, 0 skipped**. Counts exclude the test runner's file-loading pseudo-tests. This includes 21 sync-engine acceptance tests, 38 canonical tests (36 Go-generated vectors plus limits and lone-surrogate checks), two review/import widget tests, and storage/auth/backup/settings regressions.
- Existing tests that expected guest adoption or account writes after sign-out were changed to assert TRD 05 isolation. No goldens were regenerated. The unrelated golden suite and signed-device checks were not run.

From `backend/`:

```sh
# Export the shared fixture with the actual Go encoder/validator and verify it.
VEEA_UPDATE_VECTORS=1 go test -race -json ./internal/learning ./api

# Existing disposable local PostgreSQL; no deployed service involved.
VEEA_TEST_DATABASE_URL=postgres://postgres@127.0.0.1:54329/postgres \
  go test -race -json -tags=integration -count=1 ./test/integration/... \
  -run 'TestLearning'
```

- Go learning unit/OpenAPI contract tests: **23 passed, 0 failed, 0 skipped**.
- Go PostgreSQL learning/data-rights router tests: **21 passed, 0 failed, 0 skipped** (tests and subtests). Includes closed-by-default behavior, lost responses/expiry, snapshots/compaction, restore fencing, import capacity, export bounds, deletion/purge and re-registration.
- No Go SQL changed; sqlc regeneration was unnecessary. Mailpit-specific delivery tests were outside this sync change and were not run.
- Both staged and unstaged `git diff --check` passed.

## §15.2 result mapping

“Passed” below means the named behavior passed the local SQLite/HTTP/widget tests, with Go contract/router verification above. It does not certify an end-to-end Go sign-in/deletion flow or authorize opening sync.

| Check | Result | Test evidence / reason |
|---|---|---|
| 1. Three queue states and original identity/bytes | **Passed** | `sync_engine_test.dart`: immutable retry across reopen and 401/429/503, authoritative `last_seq`, SHA-256/body equality, noncanonical raw JSON bytes, v12 uncertainty migration, later edit during send |
| 2. Expired mutation | **Passed** | Reflected result reconciles; differing result enters review; sequence remains 1; expired unknown import becomes review-only |
| 3. Snapshot staging and catch-up | **Passed** | Multi-page snapshot, concurrent feed update, empty terminal tail, compaction restart, restore discovered on fresh snapshot, owner switch during snapshot |
| 4. Per-item review | **Passed** | Retired and pre-restore mixed queues, preserved delete/origin, absent-delete resolution, missing update refuses Apply and recreates under a new ID; widget has operation-specific actions and no bulk replay; check 10 clears review |
| 5. Sign-out and cache closure | **Passed** | Engine and real auth-provider tests open guest, leave account queue unsent, restore owned caches and keep later guest edits separate; generic expiry closes rather than deletes |
| 6. Consent and capacity | **Passed** | Dataset/owner decision, later explicit action, over-capacity selection, local exclusions, refreshed capacity and persisted reconfirmation across reopen; unknown import bytes remain unchanged; widget requires the second click |
| 7. Pre-rebuild provenance | **Passed** | Real v11 upgrade exercises current and archived data, guest opening, old account-key isolation and edits that retain `legacy_untagged` |
| 8. Backup provenance/ownership | **Passed** | Wrong account refused while signed in or out; untagged refused in account; guest JSON/CSV round trips preserve both provenance values; own-account backup is held until capacity-checked import |
| 9. Over-quota local words | **Passed** | Repeated sync does not send the held word; explicit **Back up now** permits a new create |
| 10. Confirmed deletion local erasure | **Passed** | Closed-account erasure removes cache, queue, partition/cursor/writer, staging, review and import decisions while preserving guest; existing provider confirmation/receipt tests exercise its callback |
| 11. Shared canonical format | **Passed** | `canonical_vectors_test.dart` runs Go-produced exact bytes, byte sizes, Unicode scalar counts, validation order and limits; Go rejects stale fixtures |

## Remaining contract gap and production gates

**Blocked: end-to-end Flutter → Go identity/lifecycle integration.** `AuthApi`, token refresh and phone-account screens still use the Rust `/api/v1/auth/*`, `/users/me` and challenge-based deletion receipt contract. Go's current OpenAPI uses email authentication under `/v1/auth/*`, `/v1/me`, opaque session tokens and operation-scoped `/v1/account-rights/*` proof/receipt capabilities. The new sync transport uses the correct Go `/v1/learning/sync/*` routes, but this work does not claim the existing phone UI can establish/refresh a Go session or consume a Go deletion acceptance/receipt. The local deletion erasure hook is ready; the Go acceptance/polling adapter remains required. These are earlier authentication/lifecycle client ports, not a reason to fall back to email-based ownership or replay old caches.

Keep `learning_sync_control.open = false`. Before an operator considers opening it: port and verify the Go email/session and account-rights adapters; run the rebuilt Flutter flow against the local Go router with real sign-in/refresh, offline restart and a lost deletion response; then perform the intended device/staging checks under separate authorization. No staging action, gate-opening SQL, commit or push was performed.
