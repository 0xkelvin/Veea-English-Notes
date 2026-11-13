# Veea English Notes

Offline-first Flutter vocabulary app (iOS/Android) plus an optional Rust sync/account
backend in `cloud/`. The app is fully usable with no server; cloud is enabled only when
built with `--dart-define=VEEA_API_BASE_URL=...` (see `lib/core/config/app_config.dart`).

## Where things are

**Flutter app** (repo root, `pubspec.yaml`)
- `lib/main.dart` entry; `lib/{models,providers,screens,services,widgets,core,arcade_sdk}`.
- Local data: `lib/data/local/` (SQLite schema/migrations in `app_database.dart`).
- Cloud client: `lib/data/remote/` (`api_client`, `auth_api`, `vocabulary_api`, `token_store`),
  `lib/services/sync_service.dart`, `lib/providers/auth_provider.dart`.
- Tests mirror `lib/` under `test/`; goldens in `test/golden/`; Swift tests in `test/native/`.
- Native iOS Screen Time code: `ios/` (Runner plus three extension targets). See `README.md`.

**Rust backend** (`cloud/`, `cloud/Cargo.toml`, edition 2024)
- `cloud/src/main.rs` / `lib.rs`; wiring in `bootstrap/app_state.rs`.
- Routes: `interfaces/http/router.rs`; handlers in `interfaces/http/handlers/`;
  OpenAPI in `interfaces/http/openapi.rs`.
- Logic: `application/{identity,vocabulary}`; SQL: `infrastructure/persistence/postgres/`.
- Schema: `cloud/migrations/` (run automatically on startup).
- Integration tests: `cloud/tests/account_data_integration.rs`.

**Backend conventions** (layering, errors, naming, SQL/migration style, tests) live in
`cloud/.github/copilot-instructions.md` and `cloud/.github/instructions/*.md`. That is the
source of truth; do not duplicate it here. Where it disagrees with the code, trust the code
(for example it describes `jwt_auth`/`role_guard` middleware that `router.rs` does not mount).

## Commands

Run from the repo root for Flutter and from `cloud/` for Rust (`make -C cloud <target>` also works).

| Purpose | Command | Needs locally |
|---|---|---|
| Flutter lint | `make analyze` (`flutter analyze`) | Flutter SDK |
| Flutter tests | `make test` (`flutter test`) | Flutter SDK |
| Update goldens | `make test-update-goldens` | Only after an intentional visual change |
| Native Screen Time tests | `bash tool/test_native_screen_time.sh` | macOS with `swiftc` |
| Unsigned iOS build | `flutter build ios --release --no-codesign` | macOS, Xcode (not run; from README) |
| Rust format | `cargo fmt -- --check` | Rust toolchain |
| Rust lint (CI) | `make clippy` | Rust toolchain **and `cmake`** (`--all-features` builds `rdkafka`) |
| Rust unit tests (CI) | `make test` | Rust toolchain **and `cmake`** |
| Rust unit tests, no cmake | `cargo test` (default features) | Rust toolchain only; no DB or Redis |
| Rust integration tests | `VEEA_TEST_DATABASE_URL=<disposable local db> cargo test --test account_data_integration -- --ignored` | Local Postgres (not run; from the test file header) |
| Local backend stack | `make backend-up`, `make backend-run`, `make run-cloud` | Docker, Rust toolchain |

`make backend-down-v` deletes the local database volume. CI for `cloud/` is
`cloud/.github/workflows/ci.yml` (fmt, clippy, test); there is no CI for Flutter tests.

Baseline as of 2026-11-10 on `main` (check before blaming your change):
`cargo fmt -- --check` and `cargo clippy` already fail (e.g. `phone_auth.rs`
`delete_verified_account` has 9 arguments), and 5 tests in `test/golden/screens_golden_test.dart`
fail with pixel diffs on one macOS machine. Do not regenerate goldens or reformat unrelated
files to hide these.

## Review rules

Treat these as blocking when reviewing or changing `cloud/` or the sync/auth client code.

- **Authentication.** Protected routes are not layered in `router.rs`; each handler must take
  the `AuthUser` extractor, and admin handlers must check `ctx.is_admin()` themselves. A new
  route that skips both is public. Refresh tokens belong in `token_store.dart` (secure storage),
  never SharedPreferences, logs or fixtures.
- **Resource ownership.** Every read or write of user data is scoped by the authenticated
  `user_id` from `AuthUser`, never by an ID taken from the body or path alone. In
  `word_repository_pg.rs`, upserts guard `ON CONFLICT ... WHERE words.user_id = EXCLUDED.user_id`
  and foreign word IDs are rejected; keep that when touching sync.
- **Account deletion.** Needs a fresh verified code, removes owned data via `ON DELETE CASCADE`,
  and leaves a receipt so a client that lost the response can confirm (`/auth/deletion-receipt`,
  `PendingDeletion` in `auth_api.dart`/`token_store.dart`). New user-owned tables must cascade
  from `users` and be covered by deletion and export.
- **Migrations.** Add a new file with `make -C cloud migrate-add name=...`; never edit an applied
  one. Use `IF NOT EXISTS`, and do not drop a column in the same release that removes its code.
  Migrations run on startup, so check they are safe against existing data. The Flutter SQLite
  schema in `app_database.dart` has its own versioned migrations; keep the two separate.
- **Retry-sensitive writes.** Assume any request can be repeated or its response lost: OTP
  verify, phone change, deletion, `/vocabulary/sync`, feedback. Sync uses per-owner
  `sync_revision` cursors, so do not break ordering or tombstones. The router mounts no
  `Idempotency-Key` layer (N1: it replayed cached responses before `AuthUser` ran). Do not
  re-mount `middleware/idempotency.rs` router-wide; any per-handler version must authenticate
  first and scope its key by user, method and path.
- **Auth or sync contract changes.** Review both sides in the same change. Backend:
  `interfaces/http/handlers/{auth,phone_auth,vocabulary,account}_handler.rs`, the matching
  `application/` command, and `openapi.rs`. Flutter: `lib/data/remote/*.dart`,
  `lib/services/sync_service.dart`, `lib/providers/auth_provider.dart`, plus their tests.
  Also update `docs/account-feedback-rollout.md` if the user-visible flow changes.

## Verification and data hygiene

- Verify against local services only: the docker-compose stack in `cloud/` or a disposable
  local Postgres, and `--dart-define=VEEA_API_BASE_URL=http://localhost:18386`. Never point a
  test, script or app build at a deployed server.
- Use synthetic fixtures (fake phone numbers, stub OTP delivery as in
  `account_data_integration.rs`, generated UUIDs).
- Keep credentials and production user data out of prompts, logs, fixtures and commits.
  `cloud/.env` is gitignored and may hold real secrets: do not read or paste it. Copy
  `cloud/.env.example` (`make backend-env`) and use throwaway values.
- Simulators and unsigned builds do not prove Screen Time enforcement; see the README
  Verification section for the signed-device checks.
