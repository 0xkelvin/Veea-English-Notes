# TRD 05 Flutter implementation and verification — 2026-11-14

Branch: `feat/go-email-auth-account-foundation`. This records local verification, not release approval. The server gate remains closed. No release/staging gate or applied Go migration was changed. Disposable integration fixtures exercise both gate states. No commits or pushes were made.

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

- Go learning unit/OpenAPI contract tests: **23 passed, 0 failed, 0 skipped** (tests and subtests).
- Go PostgreSQL learning/data-rights router tests: **21 passed, 0 failed, 0 skipped** (tests and subtests). Includes closed-by-default behavior, lost responses/expiry, snapshots/compaction, restore fencing, import capacity, export bounds, deletion/purge and re-registration.
- No Go SQL changed; sqlc regeneration was unnecessary. Mailpit-specific delivery tests were outside this sync change and were not run.
- Both staged and unstaged `git diff --check` passed.

## §15.2 result mapping

“Passed” below means the named behavior passed the local SQLite/HTTP/widget tests, with Go contract/router verification above. The original matrix alone did not certify Go sign-in/deletion integration. The real-service closeout below now supplies that evidence; it still does not authorize opening sync.

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

## Flutter → Go integration closeout — 2026-11-15

The previous Go identity/lifecycle client blocker is **resolved for the sign-in, session, deletion and sync flows in this closeout**. Production `main()` now constructs `GoTokenStore`, `GoApiClient`, `GoAuthApi` and `GoAuthProvider`. Settings' account entry selects the Go email UI. The older Rust adapters and phone screens remain for explicit legacy callers/tests; the production Go path neither calls their endpoints nor adopts their credentials.

### Contracts implemented

- Email OTP sign-in, OTP/password signup followed by email verification, password sign-in, `GET /v1/me`, session listing, revocation of another session, confirmed logout-all and current-device logout use the existing Go OpenAPI. Notebook identity is exactly **`TokenResponse.user.id`**, the stable `user_id`; it is never inferred from email or a JWT. Signing up again after purge selects the new returned UUID.
- One secure-storage JSON value contains the user/session identity, a local generation, **both tokens**, expiries and refresh state. Go storage has its own namespace, without legacy fallback. Single-token save helpers cannot split a Go pair.
- Refresh is single-flight per stored session generation, shared across authenticated requests and vocabulary sync. A delayed `401` for the old access token uses the already persisted pair. The `in_flight` marker commits **before** transmission. Network/timeout, unreadable success or an ambiguous server failure requires fresh sign-in; a restarted process never resends a potentially consumed refresh token. Explicit pre-rotation refusals such as `429` permit a later attempt, without an immediate retry. The complete rotated pair is persisted before any waiter reuses it.
- Sign-out invalidates credentials before waiting for network/sync completion. Every authenticated response and refresh credential write checks the captured generation. An account switch or sign-out therefore makes old responses unusable. A late sign-in response is also fenced by the provider's intent generation. Logout is local even if the server is unreachable or the captured bearer has expired; server revocation is best effort in those cases.
- The sync core is reused through `GoLearningHttpClient`: it shares Go authentication and preserves the exact original body bytes during a safe `401`/refresh replay. Receipt requests are explicitly unauthenticated with respect to normal sessions: only `Authorization: Rights <operation_token>` is sent.
- A deletion request starts from the Go-authenticated account identity and current verified email. The operation ID, capability, challenge token and immutable target UUID are saved separately from credentials **before** submitting the fresh code. OTP values are never persisted. Completion includes `confirm: "delete_account"` after an explicit destructive confirmation.
- Local account erasure happens only after the matching operation reports `pending` or `completed` with a valid `accepted_at`, via its `202` completion or capability status. A generic `401`, `404`, unknown outcome or `awaiting_proof` never erases the cache. Accepted status persists before local cleanup, so a restart can finish that known boundary even offline. Cleanup targets only the recorded UUID; another account and guest remain intact.
- Unknown completion keeps the receipt and closes the account cache. Status can resume after restart/session revocation; the account screen polls at five-second intervals while pending, and app resume also checks it. Rejected first proofs preserve data and permit another attempt. Completed receipts remain a local confirmation; they are not credentials for any account.
- A receipt for an older account does **not** block a different account's sync or import. `blocksCloudSync` is scoped to the selected UUID. Same-email re-registration neither reuses the old cache nor inherits its pending queue, writer, cursor or review set; old tagged backups are refused.

### Reproducible local commands and actual results

From the repository root:

```sh
flutter analyze
flutter test test/data test/services test/providers \
  test/screens/settings_screen_test.dart \
  test/screens/sync_review_screen_test.dart \
  test/screens/go_account_screen_test.dart --reporter json

# Starts/reuses local disposable PostgreSQL and Mailpit; creates its own test DB.
VEEA_FLUTTER_E2E_REPORT=/tmp/veea-flutter-go-e2e.jsonl \
  make -C backend test-flutter-go
```

From `backend/`:

```sh
VEEA_TEST_DATABASE_URL=postgres://postgres@127.0.0.1:54329/postgres \
VEEA_TEST_SMTP_ADDR=127.0.0.1:1025 \
VEEA_TEST_MAILPIT_API=http://127.0.0.1:8025 \
  go test -race -tags=integration -count=1 -json ./...
go vet -tags=integration,fluttere2e ./...
make fmt
bash -n scripts/test-flutter-go.sh
```

| Verification | Passed | Failed | Skipped |
|---|---:|---:|---:|
| Affected Flutter regressions | 348 | 0 | 0 |
| Real-service Dart end-to-end scenarios | 6 | 0 | 0 |
| Go unit + PostgreSQL + Mailpit regressions, `-race` | 1,049 | 0 | 0 |
| Tagged Go host for the Dart end-to-end run, `-race` | 1 | 0 | 0 |

Analysis reported **no issues**. Go vet, formatting, shell syntax and both staged/unstaged diff whitespace checks passed. Flutter counts exclude file-loading and test-hook pseudo-tests. Go counts include subtests (**416 top-level tests** in the full regression run). The new client coverage includes 13 transport/storage tests, nine provider tests and three account-entry widget tests. The existing TRD 05 acceptance suite remains green. No Go SQL changed; sqlc regeneration was unnecessary. No unrelated goldens were regenerated or run.

The end-to-end host is compiled only with `integration,fluttere2e`. It serves **the production `app.New` router**, validates its exchanges against the current Go OpenAPI, uses an isolated `pgtest` PostgreSQL database and delivers real SMTP messages into loopback Mailpit. Dart extracts fresh OTPs from Mailpit, never from a fake sender or a test-code endpoint. Its temporary control server is test-only and loopback; it advances access expiry/cooldowns and runs the actual purge jobs. The storage restart simulation replaces the provider, transport, token store and SQLite handle using a disk-backed synthetic secure-storage boundary; it does not claim to exercise iOS Keychain or Android Keystore.

The six scenarios passed:

1. Real Mailpit signup proof, password and OTP sign-in preserve one UUID; session operations and guest sign-out work; vocabulary writes reach the real router.
2. Twenty concurrent requests with expired access rotate exactly once, persist both tokens and produce no refresh reuse.
3. Sign-out during a real committed refresh rejects the delayed response; credentials stay absent.
4. Switching accounts during a real committed refresh rejects the old response; the new UUID and credentials remain usable.
5. Losing a real committed refresh response requires sign-in; restarting does not resend the consumed token (`rotation_counter = 1`, no `refresh_reuse` revocation).
6. A real accepted deletion response is lost and receipt reads are temporarily unavailable. The old cache/queue remain until a new provider polls the saved capability after restart. Acceptance clears only that account; purge completes; same-email signup receives a different UUID, empty account cache and no old queue. The old receipt cannot wipe or sign out the new account.

The fault client intercepts selected responses **after** the real server has committed. It does not fabricate successes. Early verification exposed and fixed a logout-all completion race with notebook closure, stale Mailpit-code selection during same-email re-registration, and a receipt-scoping issue that could suppress a later account's background sync. Widget checks use real async storage outside the fake clock; the interrupted diagnostic UI run was replaced by the final passing suite above.

### Remaining release gates

**Keep `learning_sync_control.open = false`.** Only the disposable E2E database opens its gate temporarily; its initial closed state is asserted, it is closed again on exit (including failure), and the database is dropped. No deployed database or rollout control was changed.

Before release, Nin still owns the explicit gate/deployment decision, real-device Keychain/Keystore and background/restart smoke checks, the verified Resend sending domain and real email delivery check, AC-7 timing measurement, and the previously recorded retention/restore/operational configuration checks. These local results do not prove those deployment properties or expand Phase 5 alerting. No staging deployment, staging command, commit or push was performed.


**Staging preparation through TRD 10 (2026-11-15):** the remaining deployment/provider/device/restore checks are consolidated in [the executable staging checklist](../staging-verification.md). Its §7 records the new local run, including the real synthetic dump/restore drill and the cartridge closed-gate/epoch/restart block test. Historical verification totals above are unchanged; no staging gate is closed by local evidence.
