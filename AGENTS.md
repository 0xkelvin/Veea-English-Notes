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

**Admin console** (`admin_console/`, its own `pubspec.yaml`; TRD 07)
- Flutter **web** package, separate from the learner app; calls only the TRD 06 `/v1/admin/*`
  routes plus sign-in and `/v1/me`. The Go API is the authorization authority: show only actions
  from the server's `allowed_actions`/`assignable_roles`, and map every refusal (TRD 07 §6).
- Credentials stay in memory (no browser storage). Deployment (approved, TRD 07 §3.1): dedicated
  admin origin proxying `/v1/` same-origin (no CORS), operator-network only, and `/v1/admin/`
  blocked on the public learner ingress. `dart run tool/serve.dart` is the loopback dev server.
- Audit history is `GET /v1/admin/users/{id}/audit` (TRD 06 §9a): view-rule visibility, an
  explicit field allowlist, `(occurred_at, id)` cursor; never widen the allowlist without a decision.
- Tests: `cd admin_console && flutter analyze && flutter test`; against real Go:
  `make -C backend test-flutter-admin` (Docker for the disposable PostgreSQL).

**Rust backend** (`cloud/`, `cloud/Cargo.toml`, edition 2024)
- `cloud/src/main.rs` / `lib.rs`; wiring in `bootstrap/app_state.rs`.
- Routes: `interfaces/http/router.rs`; handlers in `interfaces/http/handlers/`;
  OpenAPI in `interfaces/http/openapi.rs`.
- Logic: `application/{identity,vocabulary}`; SQL: `infrastructure/persistence/postgres/`.
- Schema: `cloud/migrations/` (run automatically on startup).
- Integration tests: `cloud/tests/account_data_integration.rs`.

**Go backend** (`backend/`, replaces the Rust service once TRD 01 is implemented; see
`docs/trd/01-email-authentication-account-foundation.md` and `backend/README.md`)
- So far: config, pgx pool, `/healthz`, `/readyz`, `cmd/migrate`, a disposable-PostgreSQL test
  harness, migrations 00001 to 00009 (`backend/migrations/`) and sqlc queries
  (`backend/internal/platform/db/queries/` generates into `.../db/sqlc/`, never edit by hand).
  Identity primitives live in `backend/internal/identity/` (email normalization, password policy
  and blocklist, Argon2id hasher). Hash and verify passwords before opening a transaction; that
  package must not import database code. Rate limiting is in `backend/internal/ratelimit/` (limiter on the pool, cooldown on the caller's
  transaction) and client IP resolution in `backend/internal/platform/clientip/`. The email outbox and its worker are in `backend/internal/notify/`
  (`make mailpit-up` for local SMTP). The OTP challenge core (start and verify, used by every code
  flow) is `backend/internal/auth/otp/`; flows plug in an eligibility check and an after-accept
  callback and must not write `otp_challenges` themselves. The API now needs `VEEA_EMAIL_HMAC_KEY` and
  `VEEA_OTP_KEY` (each `openssl rand -hex 32`) and `VEEA_OUTBOX_KEY` (`1:$(openssl rand -hex 32)`) to
  start; use throwaway values locally. Signup routes (`/v1/auth/signup/*`) are wired through
  `backend/internal/app/`, which builds the router for both `cmd/api` and the integration tests.
  Token refresh authenticates by its body token; logout and `GET /v1/me` sit behind the bearer
  middleware in `backend/internal/auth/httpapi/`. Every protected Go route must be wrapped with
  `authenticated`. OTP and password sign-in are in `backend/internal/auth/signin/`; password
  set, change and reset are in `backend/internal/auth/password/`. Session listing, revoking another owned session and logout-all are
  implemented in `backend/internal/auth/session/management.go` (TRD 02). Own-profile updates and paired-proof email cutover are in `backend/internal/account/` (TRD 03); cutover alone takes `users FOR UPDATE` at L3 for the unique email key. All challenge writes, including paired proofs, remain in OTP core. Password mutations hash before their transaction and follow TRD 01 §7.5 lock order.
  Deactivation, mailbox-proven export/deletion/reactivation and the durable export and purge jobs are
  in `backend/internal/lifecycle/` (TRD 04). The `/v1/account-rights/*` routes are the one recorded
  exception to `authenticated`: `rightsAuthenticated` accepts only an action-scoped `vop_` capability,
  never a bearer, and must never yield a `Principal`. Address advisory locks (`otp.LockAddresses`, L0)
  precede every cooldown, challenge and user lock. A new user-owned table must be removed by the purge
  in `lifecycle/jobs.go` and, if it is product data, added to the export.
  Vocabulary sync (TRD 05) is `backend/internal/learning/`: every owner-scoped write holds the
  sync head (L4c, after L3 `KEY SHARE` and the acting session). Multi-row learning tables are
  `ON DELETE RESTRICT` and are drained in bounded batches by `learning.PurgeBatch`. Sync ships
  closed (`learning_sync_control.open = false`): do not open it before the Flutter checks in TRD 05
  §15.2 pass. `learning.AppendCanonical` is the only encoder for quota and export sizes.
  RBAC user administration (TRD 06) is `backend/internal/admin/` (pure matrix in `policy.go`).
  Every `/v1/admin/*` route is `authenticated(requireStaff(...))`; `requireStaff` is only a
  pre-check, and admin writes revalidate the actor's role, standing and acting session under
  lock (L3 actor and target in UUID order, then L4a). Admins act on role `user` only. Any
  transaction that can remove an active Super Admin (role change, bootstrap, suspension, owner
  deactivation, deletion acceptance) takes the Super Admin guard `accounts.LockSuperAdminGuard`
  (L2s: after L0 to L2b, before L3) and calls `accounts.CheckNotLastSuperAdmin`. First Super
  Admin and break-glass are `cmd/admin bootstrap-super-admin` only, never an API route or API
  startup. A suspended row must carry `resume_status` and `suspension_reason`, so write fixtures
  through the full column set.
  The HTTP contract is `backend/api/openapi.yaml`; a new or changed route updates it in the same
  change (`go test ./api` fails when the router and the spec disagree, and router tests fail on
  any response the spec does not describe).
  `cmd/api` also runs the §6.10 cleanup jobs (`backend/internal/maintenance/`) and serves
  Prometheus metrics on `VEEA_METRICS_ADDR` (`backend/internal/platform/metrics/`); count a
  metric only after its transaction commits, and use fixed codes as label values.
  Audit events are mapped to producers and tests in TRD 01 §11.1; a new flow adds its rows there
  and to `TestAudit_Matrix`. Loggers go through `internal/platform/logging`'s redacting handler.
- After changing a query or migration run `make sqlc` and `make sqlc-verify` (from `backend/`)
  and commit the generated code with it.
- Migrations run through `cmd/migrate` before a deploy, never on API startup.
- Commands (from `backend/`): `make check` (no database), `make test-db-up`,
  `make test-integration`, `make test-db-down`. Integration tests need Docker and refuse
  any non-local `VEEA_TEST_DATABASE_URL`.
- The Rust rules below apply to `cloud/` only. The Go service follows TRD 01.

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
| Admin console lint/tests | `cd admin_console && flutter analyze && flutter test` | Flutter SDK |
| Admin console vs real Go | `make -C backend test-flutter-admin` | Flutter SDK, Go, Docker |
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
