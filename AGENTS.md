# Veea English Notes

Offline-first Flutter vocabulary app (iOS/Android) plus the optional Go account/sync backend
in `backend/`, the only supported backend. The app is fully usable with no server; cloud is enabled only when
built with `--dart-define=VEEA_API_BASE_URL=...` (see `lib/core/config/app_config.dart`).

## Where things are

**Flutter app** (repo root, `pubspec.yaml`)
- `lib/main.dart` entry; `lib/{models,providers,screens,services,widgets,core,arcade_sdk}`.
- Local data: `lib/data/local/` (SQLite schema/migrations in `app_database.dart`).
- Go client: `lib/data/remote/go/`, sync transport in `lib/data/remote/`,
  `lib/services/sync_service.dart`, `lib/providers/go_auth_provider.dart`.
  Shared base interfaces and compatibility adapters remain in `lib/data/remote/`
  and `lib/providers/auth_provider.dart`.
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

**Go backend** (`backend/`, the only supported backend; see
`docs/trd/01-email-authentication-account-foundation.md` and `backend/README.md`)
- So far: config, pgx pool, `/healthz`, `/readyz`, `cmd/migrate`, a disposable-PostgreSQL test
  harness, migrations 00001 to 00015 (`backend/migrations/`) and sqlc queries
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
  Free/Premium plans (TRD 09) are `backend/internal/entitlements/` (reads, export section) and
  `admin.ChangePlan` (the only grant writer). Plans are not roles. Evaluate plans only through
  `entitlement_premium_until()` at database time. Both plans share the TRD 05 limits, and TRD 10 gates new Premium cartridge downloads/installs only. Export schema 3 includes the plan; keep staff IDs and tickets out of it.
  Server-delivered cartridges (TRD 10) use migration 00015 and `learning/cartridges.go`:
  immutable shared PostgreSQL versions, audited `bin/admin publish-cartridge --file FILE --ticket-ref REF`,
  and owner installation watermarks. Install reuses TRD 05 import admission/apply under L4c and stays
  behind its closed gate. Entry IDs are stable and versions cumulative, so updates only add new entries.
  Watermarks are exported and explicitly purged. Flutter's `CartridgeProvider` keeps pending requests
  in owner-scoped SQLite `cartridge_local_state`; never replace an uncertain request's version/epoch.
  Only the Free starter is offered bundled; server fixtures are synthetic pending real classification.
  Alert rules (TRD 08) are `backend/monitoring/prometheus/veea-alerts.yml`, tested by
  `make test-alerts` (promtool) and `go test ./monitoring` (names must exist in the registry).
  Edit scenarios in `gen_tests.py`, not the generated `veea-alerts.test.yml`. Renaming a metric or
  label value breaks alerts: change the rules and tests in the same change.
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

Backend conventions and contracts are defined in the Go TRDs, `backend/README.md`,
`backend/api/openapi.yaml` and the implementation.

## Staging readiness

The consolidated checklist through TRD 10 is `docs/staging-verification.md`. Local-only
checks run through `backend/scripts/verify-staging-local.sh`; the separately tagged synthetic
`pg_dump`/`pg_restore` drill is `backend/scripts/test-restore-drill.sh`. Operator-only isolated
restore SQL is in `backend/ops/restore/`; it never opens sync. Staging/provider/device gates
and cartridge review-resolution limitations remain explicit in the checklist.
Independent deletion checkpoints use `cmd/admin ledger {archive,status,recover}` and
`internal/recoveryledger/`, with dedicated `VEEA_RECOVERY_KEYS` and an independently held
source UUID. Follow `docs/deletion-ledger-recovery.md`: `202` is DB acceptance, not independent
publication. Missing/behind coverage blocks restored access. The private POSIX adapter is
locally tested; shared storage, scheduling, key custody and freshness monitoring require deployment.

## Commands

Run from the repo root for Flutter and from `backend/` for Go (`make -C backend <target>` also works).

| Purpose | Command | Needs locally |
|---|---|---|
| Flutter lint | `make analyze` (`flutter analyze`) | Flutter SDK |
| Flutter tests | `make test` (`flutter test`) | Flutter SDK |
| Update goldens | `make test-update-goldens` | Only after an intentional visual change |
| Native Screen Time tests | `bash tool/test_native_screen_time.sh` | macOS with `swiftc` |
| Admin console lint/tests | `cd admin_console && flutter analyze && flutter test` | Flutter SDK |
| Admin console vs real Go | `make -C backend test-flutter-admin` | Flutter SDK, Go, Docker |
| Unsigned iOS build | `flutter build ios --release --no-codesign` | macOS, Xcode (not run; from README) |
| Go build | `go build ./...` (from `backend/`) | Go SDK matching `backend/go.mod` |
| Go unit tests | `go test ./...` (from `backend/`) | Go SDK |
| Go race tests | `go test -race ./...` (from `backend/`) | Go SDK and C compiler |
| Local Go backend stack | `make backend-up`, `make backend-down`, `make backend-logs`, `make backend-ps`, `make backend-migrate-status` (root or `make -C backend`) | Docker Compose, openssl |
| Flutter with Go | `make run-cloud` after `make backend-up` | Flutter SDK; resolves running Go port |

`make backend-down` preserves the Go volume; `backend-down-v` explicitly deletes it.
Compose orchestration is in `backend/Makefile`; root targets delegate there. Use the same
`COMPOSE_PROJECT_NAME` / `COMPOSE_ENV_FILE` overrides on every call; relative env paths are
always backend-relative. `backend-env` generates private Go keys once and never overwrites.
`backend-run` is a detached Go startup alias. Existing Go test scripts use separate
disposable services/ports. Android build CI is `.github/workflows/build-apk.yml`;
there is no CI for Flutter tests or Go checks. Run the documented local checks.

Production Docker uses the separate `backend/compose.production.yaml` and `backend-prod-*`
Make targets (root delegates to backend). It uses Resend without Mailpit, a private
`PROD_ENV_FILE` (default `.env.production`, backend-relative), and `PROD_PROJECT_NAME`
(default `veea-production`). Preserve its database/keys; no production wipe target exists.
Fresh roles and post-migration grants are in `backend/ops/production/`; API audit remains
append-only, maintenance can minimize it. API/metrics bind loopback; production ingress,
backup/ledger custody and release gates remain operator responsibilities, never implied by
local Compose verification. Never point local tests at a deployed production database.

Baseline as of 2026-11-10 on `main` (check before blaming your change):
5 tests in `test/golden/screens_golden_test.dart` fail with pixel diffs on one macOS
machine. Do not regenerate goldens or reformat unrelated files to hide these.

## Review rules

Treat these as blocking when reviewing or changing the backend or sync/auth client.

- **Authentication.** Protected Go routes use `authenticated`; admin routes also use
  `requireStaff` and revalidate authorization under lock. Account-rights capabilities
  are the explicit exception described above. Refresh tokens stay in secure storage,
  never SharedPreferences, logs or fixtures.
- **Resource ownership.** Scope every user-data read/write by the authenticated owner,
  never solely by an ID in the body or path. Plans are separate from staff roles.
- **Account deletion.** Use the TRD 04 fresh-mailbox proof, durable jobs and receipt
  contract. New owned tables must participate in purge and, for product data, export.
  Unknown outcomes and generic 401/404 responses never justify wiping local notebooks.
- **Migrations.** Add a new Go migration; never edit an applied one. Run it through
  `cmd/migrate` before deployment. Regenerate and verify SQLC after query/schema changes.
  Flutter SQLite has its own versioned migrations in `app_database.dart`.
- **Retry-sensitive writes.** Preserve owner-scoped revisions, queues, tombstones and
  unknown outcomes. Authenticate before any idempotency replay and scope replay by
  user, method and path; never add a router-wide unauthenticated replay layer.
- **Auth or sync contracts.** Review `backend/api/openapi.yaml`, matching Go handlers
  and domain modules, Flutter's `lib/data/remote/go/` and sync transports,
  `lib/services/sync_service.dart`, `lib/providers/go_auth_provider.dart` and their
  tests together. Update `docs/account-feedback-rollout.md` if the user flow changes.

## Verification and data hygiene

- Verify against local services only: the Go Compose stack in `backend/` or a disposable
  local Postgres, and `--dart-define=VEEA_API_BASE_URL=http://localhost:18386`. Never point a
  test, script or app build at a deployed server.
- Use synthetic fixtures (example.test email addresses, fake OTP delivery and generated UUIDs).
- Keep credentials and production user data out of prompts, logs, fixtures and commits.
  `make backend-env` generates independent local Go keys in gitignored `backend/.env`.
  Never read or print existing deployment secrets. Retired service credentials, if
  present locally, are archived under gitignored `.local/retired-backend/`; they are
  not Go configuration and must not be loaded by tooling.
- Simulators and unsigned builds do not prove Screen Time enforcement; see the README
  Verification section for the signed-device checks.

## First paid release (TRD 11, 2026-11-17)

Production keeps one offline device notebook across account changes (`accountNotebooks:false`).
Account deletion keeps those local words; the separate opt-in sync adapters keep their legacy
account isolation/purge tests. `AppConfig.isVocabularySyncEnabled=false` disables word transport
and remote cartridge installs. Do not re-enable by flipping a flag without a reviewed ownership
migration and user consent. Payment routes must authenticate, revalidate the acting session under
L3 user then L4a session locks, verify fresh Apple data, and enforce account-token/environment
ownership. Durable Sandbox and production purchases use separate databases and a matching
`apple_iap_control`. A Production API may explicitly enable fresh Sandbox
acknowledgements for TestFlight/App Review, but must never persist those test
proofs, grant server Premium or refresh a real Production proof with one.
See `docs/payment-environments.md`.
Payments are disabled by default; never simulate paid success in production. Full purge removes
Apple rows, export includes five retained proof periods, manual grants remain independent.

## Current offer: one free app and word, one-time Pro (2026-11-26)

The owner explicitly replaced the 24 November free-first offer. Production
`AppConfig.isFreeLaunch` and `NativeGateReleasePolicy.isFreeLaunch` are false.
Free includes unlimited local vocabulary, dictionary, Listen, Review, custom
lists, one app lock and one word per unlock. Owner UX update (27 November):
selecting words is the only learning-rule control. Every unlock reviews every
active selected word once; there is no separate count or rotating larger pool.
Free selects one replaceable word. Pro selects multiple words and reviews all of
them. New notebook words do not join automatically. A single non-consumable Pro
purchase enables BOTH multiple app locks (existing 50-app safety limit) and
multiple selected unlock words.
The target Vietnam price is 99,000 VND once, with no trial or subscription; show
only StoreKit's actual localized price. Never invent a price or paid success.
All default/custom/per-app unlock durations, pronunciation, OFF and removal are
free. Preserve verified purchase ownership, account/environment isolation,
refund handling and offline ownership. Sign in before checkout/restore; free
usage does not require sign-in. Notebook transport remains disabled.

Saved extra apps are paused on Free without deleting their selections/times;
the saved Pro word list remains intact while only its first word is active on Free.
Explicitly editing Free selection replaces it with one word. Retain the legacy
words_per_unlock column for compatibility, synchronized to the saved selection;
never expose it as an independent user control.
Restoring Pro does not silently re-enable paused locks; the user can turn them
on again. Upgrading mid-challenge affects the next opening; closing releases
the temporary target but retains saved answers. Downgrades immediately
permit the one-word Free rule. Apple guideline 4.10 remains an unresolved review
gate: educational positioning is not an exemption. Describe both paid benefits
explicitly; do not hide them or claim Apple approval. See
`docs/pro-99k-model.md` and `docs/app-store-submission.md`.

Account-only Go builds must not call retired config/feedback routes.
`VEEA_FEEDBACK_DELIVERY_ENABLED` defaults off independently of the API URL.
Feedback uses local drafts and explicit share/copy; a share handoff is not proof
of receipt. Support email, public HTTPS privacy-policy URL and Zalo community
must be real team-provided destinations, never invented. See
`docs/app-store-submission.md` and `docs/account-feedback-rollout.md`.
