# Account, notebook and feedback rollout

Go in `backend/` is the only supported backend. The current rollout authority is
[staging verification](staging-verification.md), with the HTTP contract in
[`backend/api/openapi.yaml`](../backend/api/openapi.yaml). This runbook replaces
the retired phone-account deployment instructions. No deployment or signed-device
acceptance is implied by local checks.

## Accounts and local data

- The default app remains usable offline without an account. Configure an API only
  with `--dart-define=VEEA_API_BASE_URL=...`; use a local service for verification.
- Production `main()` constructs `GoTokenStore`, `GoApiClient`, `GoAuthApi` and
  `GoAuthProvider`; Settings selects Go email authentication. Signup verifies an
  email code; sign-in supports email OTP or password. Tokens are opaque, rotated
  as a pair and held in secure storage. Account ownership uses the server UUID.
- First paid release: one notebook stays on this phone through sign-in, sign-out
  and account switching. Authentication manages the account and Pro only; word
  sync and remote cartridge installs are disabled. Prior workspace archives remain
  on the device without a silent merge. Device backups are portable local files.
  Same-email registration after purge has a new account UUID and cannot silently
  claim another account’s purchase. See [TRD 11](trd/11-apple-pro-purchases.md).
- TRD 04 mailbox-proven account rights use action-scoped operation capabilities.
  A lost deletion response is reconciled through its durable receipt; generic
  401/404 responses never justify clearing local data. Confirmed online account deletion clears the account session and purchase link;
  device notebook words remain. The deletion dialog explains this and the lack of
  automatic purchase transfer to a new account. Legacy opt-in sync adapters retain
  their separately tested account-cache deletion contract.
- Compatibility adapters, phone screens and their tests remain in Flutter because
  Go implementations share base interfaces with them. They do not provide a
  supported server or an alternate production account path.

See [Go Flutter integration evidence](trd/05-flutter-verification.md),
[account lifecycle](trd/04-account-lifecycle-data-rights.md) and
[learning sync](trd/05-learning-data-sync.md) for exact contracts and acceptance gates.

## Local development and verification

Follow the [backend README](../backend/README.md#local-docker-compose) for private
environment setup. The current local Compose selects Resend; its key generator
does not generate email-provider settings. Automated checks must use synthetic
fixtures and the local SMTP harness, never real delivery credentials.

```sh
# Repository root; configure the private local email settings first.
make backend-env
make backend-config
make backend-up
make backend-health
make run-cloud
make backend-down  # Preserves PostgreSQL data and keys

# Disposable, local-only Go/Flutter/PostgreSQL/Mailpit verification.
make -C backend test-flutter-go
```

Go migrations run through `cmd/migrate` before API startup. The schema is currently
migrations 00001–00015. Preserve the database volume and associated keys across
restarts. Production uses separate Compose/env/roles; its ingress, independent
ledger custody, retention, email delivery and release gates require operator
verification. See [backend production instructions](../backend/README.md#production-docker-resend-no-mailpit).

## Feedback

Flutter retains its local feedback outbox, diagnostics allowlist, optional contact
field and screenshot support. Reports persist before transmission, and retries
retain the report UUID. The Go API currently has **no feedback or phone-OTP routes**.
The retained compatibility API paths must not be advertised as supported Go endpoints.
Saved reports remain on the device without compatible delivery; do not claim a
working team inbox or successful receipt. A compatible delivery contract, retention
policy and team workflow need a separate implementation decision.

The Zalo action stays hidden unless a valid Veea community URL is supplied. Real
support/privacy/terms links must come from the team. Never invent legal or support URLs.

## Sync and cartridge release gates

The vocabulary/install rollout gate ships closed (`learning_sync_control.open = false`).
Do not open it until TRD 05 device/deployment checks and operator acceptance pass.
The catalog offers one bundled Free offline starter and signed-in server metadata.
Synthetic Free/Premium fixtures remain development-only pending content classification.

Install retries retain their original version and epoch across uncertain outcomes.
Blocked installations are reviewed per account: Discard is local; Start a new install
requires fresh server checks and explicit confirmation. Opening, cancelling or restarting
review sends no install POST. Verify staging plan expiry/refusal, restart recovery,
offline installed words after downgrade and account isolation/deletion before publishing
approved content. Historical public bundles and Git history remain public.
See [TRD 10](trd/10-server-delivered-cartridges.md) and staging verification §9.

## Remaining external checks

Local tests do not prove deployed email delivery, independent deletion-ledger
publication, two-device sync, backup restoration, production ingress or signed iOS
Screen Time enforcement. Follow the consolidated staging checklist for these checks.
No automated test, script or app build should target a deployed database or API.
