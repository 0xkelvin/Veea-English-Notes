# TRD 10 — Server-Delivered Cartridges

**Status:** v1.0, decisions approved by Nin on 2026-11-15; implemented and locally verified (§9). Real content classification and device/deployment gates remain (§8).
**Date:** 2026-11-15
**Depends on:** [TRD 05](05-learning-data-sync.md), [TRD 09](09-free-premium-entitlements.md).

## 1. Approved decisions

| ID | Decision |
|---|---|
| C1 | Keep one Free starter pack bundled and usable offline, including by guests. Signed-in active accounts can read Free and Premium catalog metadata. Use clearly synthetic Free/Premium server fixtures until Nin supplies real pack classification. |
| C2 | Content is immutable, versioned PostgreSQL reference data. Each content download evaluates `entitlement_premium_until()` at database time; a Free account downloading Premium gets `403 plan_required`. Publishing is an audited operator CLI, never an unauthenticated HTTP write. |
| C3 | Installation copies entries into owned vocabulary through the TRD 05 import quota/admission and mutation helpers. Installed words remain editable, usable offline and syncable after downgrade. Plans do not change vocabulary quotas. |
| C4 | Stable entry IDs survive versions. Explicit updates add previously unseen entries, leaving earlier entries untouched even if edited, deleted or compacted. Installation is retry-safe and records account-scoped durable state. |
| C5 | Flutter provides catalog, explicit install/update confirmation, plan/quota refusals and retry recovery. Remove real Premium content from future bundles only in the rollout order in §8. Payments remain out of scope. |

TRD 09 E2 described the scope of the earlier plan-management release; this approved TRD adds the first gated download. Existing account/data-rights and sync operations remain independent of plan.

## 2. Technical choices

- At most **16 catalog packs**, IDs of 1–48 lowercase ASCII letters/digits/underscore/hyphen, each with at most **200 cumulative entries**. Versions are positive int32 and published consecutively. A complete publish input is at most **1 MiB**, UTF-8 JSON with no unknown fields; titles have 1–100 Unicode code points. Each entry has a nonzero UUID and the TRD 05 content fields, validated with its canonical encoder, field and 8 KiB limits. No credentials or content enter errors or audit.
- Every version retains all prior entry IDs; entries cannot disappear and an ID cannot be reassigned to a different logical entry. Authoring may revise content for new installers, but updates never overwrite an installed entry. `first_version` is recorded once in an append-only entry registry. Pack plan classification is immutable. Changing real classification requires an explicit follow-up migration/design, not silent relabeling.
- PostgreSQL stores exact validated JSON content bytes and their SHA-256 digest. Catalog, versions and entry identity are append-only (database triggers). A transaction advisory lock serializes publishing and enforces pack/version bounds; the CLI requires a validated ticket and records `cartridge.publish`, source `cli`, pack/version/ticket. Identical republish is a no-op without a duplicate event; a different document at an existing version is refused. Database operator access controls who can publish; there is no HTTP publisher or new RBAC permission.
- `cartridge_installations` stores `(user_id, cartridge_id, installed_version)` with a restrictive owner FK. A monotonically advanced watermark survives vocabulary tombstone cleanup and is shared across devices. Word IDs are deterministic UUIDv5 over pack ID and entry UUID, scoped by user as in TRD 05. At most 16 installation rows exist per owner.
- Install is a specialized **atomic vocabulary import**, using the existing `admitImport`, `apply`, head counters, feed revisions, lock order and rollout gate; it does not create a second vocabulary/quota system or reuse a device writer sequence. The durable installation watermark is its idempotency identity. All entries with `first_version > installed_version` are considered once. Existing IDs (live or tombstoned) are preserved. The watermark advances in the same transaction as the imported words. A retry/older version at or below the watermark changes nothing, even after record/tombstone cleanup; an update is explicit. There is no reinstall/restore-deleted action in this release.
- Install transaction: gate/rate admission → L3 active user `KEY SHARE` → L4a acting session → L4c head → check epoch → installation watermark → download authorization at database time → import capacity check → creates/head/watermark commit. A completed retry returns the current watermark before plan/capacity checks and returns no content. A new install/update also checks the plan; a previously downloaded file is no authority to install. Deactivation/deletion races follow TRD 05 §14.
- Content downloads are authorized at the statement's database instant; expiry while streaming does not claw back already authorized bytes. Grant revocation affects subsequent reads. Responses are private, `Cache-Control: no-store`; only installed owned words are an offline entitlement.

## 3. HTTP contract

All routes require an active bearer session through `authenticated`. Catalog/content work while sync is closed; install stays closed with the existing sync gate. No owner ID is accepted from the client.

| Route | Contract |
|---|---|
| `GET /v1/cartridges` | Latest metadata for each pack: `id`, `title`, `version`, `required_plan`, `word_count`, `sha256`, plus the caller's `installed_version` (0 if absent). No word content. At most 16 rows, ordered by ID, no pagination or query parameters. |
| `GET /v1/cartridges/{cartridge_id}/versions/{version}/content` | Exact immutable JSON document `{id,title,version,required_plan,entries:[{entry_id,content:{word,meaning,pronunciation,part_of_speech,source,examples,tags}}]}`; 403 `plan_required` for Premium on Free. |
| `POST /v1/cartridges/{cartridge_id}/versions/{version}/install` | Strict body `{epoch,capacity_basis:{live_words,content_bytes}}`. Returns `{installed_version,added,head_revision}`. Whole-pack admission: 409 `capacity_changed` imports nothing and returns refreshed counters. No silent partial pack selection. |

Common errors: 429 `rate_limited` (the existing per-session request limiter), 400 `invalid_request` (including bad IDs/version/query), 401 `unauthorized`, 404 `not_found`, 500 `internal_error`. Install also has 403 `plan_required`, 409 `capacity_changed`, 410 `sync_reset_required`, 415 `unsupported_media_type`, 413 `payload_too_large`, 429 `rate_limited`, 503 `sync_unavailable`. No plan inference from roles or a client clock.

## 4. Flutter installation and local state

The bundled starter uses the existing offline installer and account-partitioned SQLite state instead of global SharedPreferences flags. New bundled entry IDs are valid deterministic UUIDs. Legacy installed words are preserved, and old flags are not treated as proof of account ownership. The old real technical pack stays in source for authoring/migration reference but is not offered by the new catalog; no real pack is classified as Premium in this release.

Server packs use the existing Go transport (single-flight refresh/session-generation fence), `SyncEngine` catch-up, and vocabulary cache. A download precedes an explicitly confirmed install. Before a new install, settle the vocabulary queue and obtain the current epoch/capacity. Persist the exact install request, pack/version and owner before transmission in SQLite; unknown outcomes retry the same request and epoch, including after restart. The server watermark makes accepted/lost-response retries harmless. A conclusive capacity refusal refreshes capacity and requires confirmation; never retry automatically. After an earlier unknown attempt, retain that attempt until a successful authoritative result or explicit review, even if a later refusal occurs.

A restore (`410`) blocks the stored attempt for explicit review, with no automatic move onto a new epoch. The existing vocabulary queue/review semantics are unchanged. Install success is durable even if subsequent cache catch-up fails; show that synchronization is pending and allow retry. The account cache is replaced only by the verified paginated TRD 05 core. No raw downloaded Premium content is persisted as a reusable entitlement. Sign-out opens guest; account switches fence late results. Confirmed deletion clears that owner's installation requests/state alongside its cache; same-email signup uses a new user ID.

## 5. Export, purge and size

Installation watermarks are owner product data. The TRD 04 export adds optional `cartridge_installations` to schema 3 in the same snapshot (no old artifact invalidation), containing only pack IDs and installed versions. At 16 × (48-byte ID + int32 version), its exact JSON bound is **1,612 bytes**; the existing 16 KiB header and overall export bound remain sufficient, verified with the worst-case schema-3 header. Vocabulary remains in its normal canonical format, without duplicate cartridge content. Purge explicitly removes at most 16 watermarks before erasing the owner; shared catalog content survives. No new retention job is needed. Local install state is cleared only for the deleted owner.

## 6. Verification requirements

- Router/PostgreSQL: Free metadata visibility; Free/Premium download permission and exact expiry at database time; inactive/rights/foreign isolation; immutable publication, validation, identical retry/audit atomicity and bounded migration; install retry after response loss/compaction, quota refusal/rollback, concurrent install, update preserving edited/deleted entries, owner export/purge.
- Flutter: catalog and plan refusal; durable pending request/restart/unknown outcome; explicit capacity reconfirmation; explicit updates; guest starter offline; account isolation/deletion; installed words offline after downgrade; existing TRD 05 core regressions.
- Commands and actual pass/fail/skip counts are recorded in §9 after execution.

## 7. Operator publishing

`bin/admin publish-cartridge --file <synthetic-or-approved.json> --ticket-ref REF` reads `VEEA_DATABASE_URL`. Only local disposable services are used by tests. The CLI bounds the file before decoding, validates it before a transaction, emits fixed errors, and prints only whether a version was published or was already present. Fixture examples live under `backend/testdata/cartridges/`; they are synthetic, never auto-seeded into production.

## 8. Rollout dependencies

1. Run migration 00015 before deploying API/CLI binaries; retain the closed sync gate.
2. Publish synthetic packs only in disposable development databases. Real content must fit the 200-cumulative-entry/1-MiB pack bounds (split larger packs before publishing). Nin must provide real Free/Premium classification, content approval and stable IDs before production publishing. The bundled Free starter remains available without network or account.
3. Ship the client catalog, error handling and durable install recovery; verify signed-device offline learning and sign-out/account deletion, staging expiry/download behavior and restore fencing. Complete TRD 05's existing device/deployment gates before deliberately opening sync/install.
4. Publish approved real versions, then remove Premium words/assets from future public bundles and check release artifacts. Already released bundles and public Git history cannot be made private retroactively. Installed owned words remain available. No revocation or deletion of existing user vocabulary is part of rollout.
5. Use the existing TRD 07 operator network/ingress controls for plan grants. Publishing DB credentials, deployment backups and restore drills remain operational gates; payments and store integrations remain separate.

## 9. Implementation and verification record

All verification used loopback-only disposable PostgreSQL/Mailpit and synthetic accounts/content. The rollout sync gate remains closed; only the tagged E2E fixture opens its isolated gate and asserts it closed again.

| Check | Command | Actual result |
|---|---|---|
| SQL generation | `make -C backend sqlc`, `make -C backend sqlc-verify` | Generated code reproducible; passed |
| Go static/unit checks and binaries | `make -C backend check`, `make -C backend build` | Passed |
| Full PostgreSQL + Mailpit race suite | From `backend/`: `VEEA_TEST_DATABASE_URL="$(scripts/test-postgres.sh url)" VEEA_TEST_SMTP_ADDR=127.0.0.1:1025 VEEA_TEST_MAILPIT_API=http://127.0.0.1:8025 go test -race -tags=integration -count=1 -json ./...` | **1,269 passed, 0 failed, 0 skipped**, tests and subtests; **473 top-level**. Mailpit ran |
| OpenAPI runtime checker | Included in full suite | **367** operation/status/code combinations; no violations. Every new route/status/code was produced. Only the four pre-existing exclusions remain |
| Flutter analysis | From root: `flutter analyze` | No issues |
| Relevant Flutter regressions | `flutter test test/screens/cartridge_library_screen_test.dart test/models/cartridge_test.dart test/providers/cartridge_provider_test.dart test/providers/cartridge_server_test.dart test/data/sync test/data/go_session_test.dart test/providers/go_auth_provider_test.dart test/data/app_database_test.dart test/screens/go_account_screen_test.dart --reporter json` | **108 passed, 0 failed, 0 skipped** |
| Flutter → local Go/PostgreSQL/Mailpit | `make -C backend test-flutter-go` | **Dart: 7 passed, 0 failed, 0 skipped**. **Go host: 1 passed, 0 failed, 0 skipped**, with `-race`; OpenAPI/hygiene/gate checks passed |
| Migration and export bounds | Included in Go runs | Empty database, populated 14→15 upgrade and SQL replay passed. Watermark section **1,612 bytes**; worst-case full header **14,700 / 16,384 bytes**. Overall bound unchanged at **79,225,248 bytes** |

**Go evidence:** `TestCartridges_*` covers Free/Premium metadata and downloads, plan expiry at database time, inactive/unauthenticated access, owner isolation, unknown version/validation/media/size/rate/gate/internal errors, identical retries, concurrent install, quota rollback, last capacity slot, explicit update preserving an edit and a deleted/compacted entry, epoch refusal, immutable publishing/consecutive versions/entry retention/size limits, exact audit/no-op, owner export, purge and independent same-email owner state. Shared `TestAudit_Matrix` includes operator publication. Unit tests reject invalid fields, duplicate keys, invalid Unicode, oversized items/documents and excessive entry counts. Existing TRD 05 quota/restore/race and TRD 09 plan suites pass unchanged.

**Flutter evidence:** nine durable provider cases cover unknown accepted response and provider restart, downgrade receipt recovery without another download, later refusal retaining original bytes, epoch refusal blocking replay, plan refusal, explicit version update, capacity confirmation, owner deletion/isolation, offline starter edits/deletes/retries and SQLite 13→14 upgrade. Two widget cases cover guest offline availability, signed-in Premium metadata, cancellation and plan refusal. The real-Go case loses an installation response after commit, reopens the SQLite and secure stores, resolves the saved request after downgrade, then updates while preserving edited/deleted words, syncs on Free and opens those words on a cold offline restart. Existing auth/refresh/deletion E2E cases still pass.

The initial broader checks found media-type validation ordering, a null capacity-basis acceptance gap, and a mismatch between the declared body-size refusal and the decoder; these were fixed and the affected checks and full race suite rerun. Flutter quota reconfirmation now captures the displayed capacity before confirmation. No unresolved normal-operation API conflict remains. A pre-restore unresolved installation is deliberately retained and blocked for review, never automatically moved to the new epoch; restore/operator recovery remains a deployment gate, as in TRD 05.

No real cartridge was classified or published to a deployed service. Real pack approval (and splitting any pack above the implementation bounds), staging/device/restore checks, deployment order and deliberate sync opening remain release dependencies (§8). The full Flutter/golden suite and signed-device enforcement were not run; the relevant regression selection and local E2E evidence above are the scope of these checks. Staging, commits and pushes remain with Nin.


**Staging preparation through TRD 10 (2026-11-15):** the remaining deployment/provider/device/restore checks are consolidated in [the executable staging checklist](../staging-verification.md). Its §7 records the new local run, including the real synthetic dump/restore drill and the cartridge closed-gate/epoch/restart block test. Historical verification totals above are unchanged; no staging gate is closed by local evidence.
