# Staging acceptance attempt — 2026-11-15

**Overall: Blocked.** Local checks passed; no deployed staging or physical-device acceptance
is certified. Operator: Codex, at Nin's request. Local execution window:
2026-11-15 09:56–10:00:15 UTC; results recorded at 10:04:58 UTC.
Authority: [acceptance checklist](staging-verification.md) and
[independent ledger recovery](deletion-ledger-recovery.md). This record does not authorize
deployment, content publishing, rollout or sync opening.

**Access boundary:** no staging release manifest, origins, deployment/database access,
independent ledger destination/key/source/cutoff records, Resend/inbox access, monitoring
receivers or infrastructure retention configuration was supplied or found in the task's
configuration. No `VEEA_*`, Resend, staging, Prometheus or Alertmanager environment variable
names were present. Do not interpret this as evidence that the infrastructure does not exist.
Prerequisite questions were sent to Nin; independent local checks continued. No deployed
test target was guessed, and no deployment secrets or `cloud/.env` were read.

Private evidence root: `/tmp/veea-staging-acceptance-20261115`. Files there are temporary local
artifacts, not durable release-ticket attachments. Copy sanitized results/digests to the
approved evidence destination before removing them. Device identifiers, signing-authority
details and raw tool output stay private; no credentials or mailbox contents enter this record.
Machine-readable status is `results.json`; `evidence-sha256.txt` records private evidence hashes.

## 1. Candidate identity and build eligibility

| Item | Result | Observed identity / evidence |
|---|---|---|
| Local source candidate | Pass | `039fc9ffd44510363275ebfa6a1e4a00f43099bf`, committed 2026-11-15 09:55:00 UTC. Worktree clean before the run; later edits are this acceptance record/checklist link only |
| Local backend binaries | Pass | `api`, `admin`, `migrate` all report `vcs.revision=039fc9ffd44510363275ebfa6a1e4a00f43099bf`, `vcs.modified=false`. `backend-build.json` contains exact `go version -m` metadata and hashes. Last commit changing backend files is `6395abd1327c453cef7f9a91283ee4625e91485c`; that is not substituted for the binary revision |
| Deployed backend commit / artifact inventory | Blocked | No deployment manifest or per-instance binary/container digests. Cannot establish rollout consistency from the local checkout |
| Local migration and gate | Pass | Fresh generated disposable DB: `applied=15 current_version=15`; `current_version=15 pending=0`; read-only SQL returns version **15**, `sync_open=f`. `local-migration.log`. Fixture dropped afterwards |
| Deployed migration and gate | Blocked | No read-only staging DB/operator result. Deployed schema and actual gate state remain unverified; no gate mutation or migration was attempted there |
| Existing local signed IPA | Pass (signature only) | `build/ios/ipa/Veea English.ipa`: bundle `com.nintran.veeaEnglishApp`, version **2.2.2**, build **2.2.2**, Team ID `9X6SFG9KXM`, CDHash `2b9cb1d859e224c623f237df7aca367acd7b74ed`. IPA SHA-256 `3d2e1e5dc8c9993549fcdc09fd743e3992533eceabc34750769489984b72bb22`. Archive creation: **2026-11-12 05:20:27 UTC**. `artifact.json`, `ipa-artifact.json`, `ipa-signature-verify.log` |
| Signed candidate build / device eligibility | Blocked | IPA has no embedded source-revision field or supplied CI/build manifest linking it to this candidate or staging configuration. Its archive predates the cartridge review commit. It is not certified as the requested staging build. Device inventory reports **5 simulated iOS devices, 0 physical devices**; no Android artifact or `adb` available. `device-summary.json` |

Local binary SHA-256:

| Artifact | SHA-256 |
|---|---|
| `backend/bin/api` | `07628a31a35536e3560722f6cd705c3b6cf420aaaee87a42145b0f5d237d670f` |
| `backend/bin/admin` | `0d8bc0022ddbf669ad1eafe55a728ca32103eed555e00c8f11b19dbd03461ae0` |
| `backend/bin/migrate` | `b4bf93644dbdf13705755ff674f955314dc05f5d8285c558fb1c06a9db04411e` |

`codesign --verify --deep --strict` initially reported `CSSMERR_TP_NOT_TRUSTED` inside the
sandbox. Rechecking with normal host trust-service access passed for both archive and exported
IPA. The initial environment error is superseded; no certificate/trust setting was changed.
This verifies signatures, not candidate provenance, native storage or app behavior. Nothing
was installed on or launched on a device.

## 2. Independent-ledger drill — executed first

**Pass — local synthetic scope.** Command from repository root:

```sh
backend/scripts/test-restore-drill.sh
```

Evidence: `restore.jsonl`, `restore.err`, then the runner's independent repeat
`local/restore.log`. Each execution passed **3 tests/subtests, 0 failed, 0 skipped**;
do not add repeat counts together. Real local PostgreSQL 17 logical dump/restore was used,
with `pg_dump`/`pg_restore` 18.3 and Go `-race`.

The drill establishes all of the following:

- Take a real backup, then accept two deletions, one completed and one still pending.
- Interrupt checkpoint publication. The previous generation is behind the independently
  recorded required boundary and is refused. Retry publication successfully.
- Drop the source database and verify its absence. Start a new recovery CLI process with an
  unavailable source URL; retrieve the encrypted ledger from the separate local fixture.
- Restore the backup in an isolated target. Refuse missing coverage proof, behind proof and
  finish before purge. Sync stays false; no public/admin process is attached.
- Interrupt purge/session progress, reopen independent storage, recover again and retry the
  existing prepare/purge/finish/verify sequence. Deleted owners and owned data are absent;
  survivor vocabulary and shared catalog remain. Surviving epochs change and writers retire;
  restored credentials, exports and pending mail cannot be reused. No reopening occurs.

**Blocked — actual staging G9.** The fixture is a private local POSIX store, not independently
provisioned host/site storage or provider PITR. Need the real backup/PITR point, isolated
recovery target, independent store and dedicated key custody, source UUID, externally retained
minimum generation/receipt and required-through cutoff, scheduler/freshness evidence and the
approved incident window. Run checklist §6 with those inputs, without the source DB. Capture
the same assertions plus actual storage durability/retention/ACL and network isolation evidence.
Deletion `202` is DB acceptance, not independent archive acknowledgement. Missing/behind
coverage means **no reopening**; do not lower requirements or archive the restored DB to
manufacture coverage. Independent custody/provisioning remains a deployment dependency.

## 3. Staging acceptance results

Every result below is for **actual deployed staging**, not its local stand-in. All eleven
G0–G10 gates are **Blocked**, none Pass or Fail: their prerequisites are unavailable. This
does not turn missing access into an application failure or waive any release gate.

| Check | Result | Evidence / blocker | Required next action and evidence |
|---|---|---|---|
| G0 — exact release, rollback boundary and signed build | Blocked | Local identities are §1; no approved deployed release/build manifest | Nin supplies deployment ID, per-instance artifact digests/commit, recovery owner/window and CI-signed build provenance; record matching bundle/build/hash and device/OS aliases |
| G1 — migration 00015, full rollout, closed gate | Blocked | Only a fresh local DB was observed | On approved staging access, read `bin/migrate status`, per-instance build identity, health/readiness and `SELECT open FROM learning_sync_control`. Require 15/0, matching candidate everywhere and false gate. Any required migration/rollout is left to Nin |
| G2 — secrets, proxies, maintenance grants | Blocked | No approved secret-version/topology/grants evidence | Inspect designated secret-manager version IDs, From/sender, proxy CIDRs, internal metrics and maintenance privileges. Capture redacted configuration and successful operations, never key values |
| G3 — real Resend delivery | Blocked | No approved deployment, From domain, sending access or controlled receiving inbox. Local Mailpit/httptest do not establish delivery | Verify actual domain/key scope; trigger synthetic OTP and notification through the approved staging account flow; corroborate provider delivery and receipt in the inbox. Capture timestamps and redacted message/outbox correlation, not OTP/address/body |
| G4 — native secure storage/account boundary | Blocked | No candidate-linked signed build on physical iOS/Android devices; inventory is simulator-only | Run checklist §3 on approved physical devices: cold/offline/reboot/upgrade, atomic refresh, late response after sign-out/switch, deletion receipt after restart and same-email independent owner. Record signed build/device/OS aliases and redacted request counts |
| G5 — AC-7 timing | Blocked | No staging hardware/proxy/hash-cost evidence or approved numerical protocol. Local reduced-cost correctness is insufficient | Checklist G5 explicitly requires Nin's sample count, warmup, tolerance/statistic and decision rule **before measurement**. Supply that protocol and synthetic fixtures, then interleave four failure classes at deployed costs; retain sanitized raw timings, p50/p95/confidence and statuses |
| G6 — admin ingress isolation/console | Blocked | Public/admin origins, operator network and outside-network vantage unavailable | Run checklist §4 from both positions; prove public edge 404, operator-only admin reachability, inside Go 401, metrics inaccessible, same-origin console and no browser credential persistence. Retain edge/upstream trace and deployed UI/API digests |
| G7 — live metrics/alerts/routing | Blocked | No Prometheus/Alertmanager access, approved test receiver or routing ticket | Inspect live targets/series/rules; send uniquely correlated test critical/warning alerts through existing approved nonproduction receivers, observe firing **and resolved** page/ticket delivery. Controlled evaluation/fault drill requires the approved method/window; no rollout/config changes made here |
| G8 — configured retention and deletion SLO | Blocked | No infrastructure/provider settings, deployed worker or maintenance-role evidence. Defaults/tests do not prove configuration | Verify actual backup/PITR/WAL/replica ≤30d, logs 14d, minimized audit 180d, receipt 30d, ledger 90d after completion/unfinished indefinite, exports 24h and deployed purge target 24h. Record actual Resend message/recipient/log retention; perform synthetic acceptance→revocation→purge→new UUID and capture UTC/row/metric evidence |
| G9 — provider restore with independent ledger | Blocked | Local drill §2 passed; independent destination/cutoff/custody and staging isolated target unavailable | Execute checklist §6 and ledger runbook with real provider backup and independent history; prove source unavailable, replay/absence, missing/behind refusal, interruption/retry, epoch change and continued isolation before any separate cutover decision |
| G10 — signed-device cartridge smoke / opening decision | Blocked | No eligible physical signed candidate or approved isolated canary. Desktop tests do not prove the signed build | With gate closed verify blocked request/restart/offline persistence and zero POST on opening/Cancel/Discard. Explicit fresh-install success needs the approved **disposable isolated** canary under checklist §6.7, never opening shared sync. Verify fresh version/entitlement/capacity/account, confirmation, one fresh POST and account isolation. Record counts/digests, then leave canary closed. Real packs and rollout remain Nin's work |

The AC-7 requirement above is from `docs/staging-verification.md` G5: “Nin approves sample
count, warmup, tolerance/statistic and decision rule before measurement.” No numerical pass
threshold or deployed timing result has been invented. No real mail, alerts or cloud changes
were attempted without their missing destinations/access.

## 4. Independent local checks completed despite staging blockers

Command from repository root:

```sh
backend/scripts/verify-staging-local.sh /tmp/veea-staging-acceptance-20261115/local
```

All **18 runner steps passed** (`local/checks.tsv`). Exact expanded commands/tool versions and
source identity are in the existing script and `local/environment.txt`; no inherited deployment
secret is an input. No integration/E2E runner was pointed at a deployed URL.

| Check | Result | Passed | Failed | Skipped | Evidence |
|---|---|---:|---:|---:|---|
| Full PostgreSQL + Mailpit backend `-race` | Pass | **1,291** | **0** | **0** | `local/go-race.log`, 483 top-level. Includes independent ledger, lifecycle/retention, Resend httptest and admin/cartridge tests. 367 OpenAPI combinations; four pre-existing unexercised responses |
| Independent restore drill (runner repeat) | Pass | **3** | **0** | **0** | `local/restore.log`; separate tag, not included in 1,291 |
| Learner Flutter regressions | Pass | **122** | **0** | **0** | `local/flutter-regressions.log`; durable sync/account/cache, canonical fixtures and cartridge review |
| Learner → local Go/Mailpit E2E | Pass | **8** | **0** | **0** | `local/flutter-go.jsonl`; race-enabled Go host **1/0/0** in `flutter-go-host.log` |
| Standalone admin Flutter tests | Pass | **42** | **0** | **10** | `local/admin-tests.log`; ten intentionally require the Go harness; all executed below |
| Admin → local Go E2E | Pass | **10** | **0** | **0** | `local/flutter-admin.jsonl`; race-enabled Go host **1/0/0** in `flutter-admin-host.log` |
| Alert rule evaluation | Pass | **74 assertions** | **0** | **0** | `local/alerts.log`: all 11 rules validate and promtool test succeeds across the current 20 scenarios. This is not live route/receiver verification |
| Static/build/reproducibility | Pass | — | **0** | **0** | `go-check.log`, `go-build.log`, `sqlc-verify.log`, `tagged-vet.log`; both Flutter analyses clean; admin web release build passes; diff/index whitespace checks pass |

The real local cartridge scenario proves old-epoch 503/410 behavior, durable block across
SQLite restart, zero install POST from review/preflight, and one explicitly confirmed fresh
request with the new epoch. Widget/provider tests additionally prove offline Discard,
confirmation cancellation, account switching and stale-check refusals. No physical-device
Keychain/Keystore or signed-app smoke is inferred from these passes.

Count correction: `checks.tsv` contains **18**, not 21, runner steps. The current generated
promtool fixture contains **20 scenarios / 74 assertions**; the historical §7 preparation
record's 21-scenario tally is not reused for this run. Test/subtest totals above come from
JSON terminal events; hidden Dart loader/teardown events and Go packages without test files
are excluded from test/skip counts. The ten standalone admin skips were all run in local E2E.

## 5. Handoff and invariant

Resume blocked rows when Nin supplies the release/access references, candidate-linked signed
build and physical devices, approved AC-7 protocol, and provider/monitoring/retention/recovery
evidence locations. Obtain secrets through approved custody, not chat or checked-in files.
Keep restored traffic closed until coverage, replay and verification succeed. Shared sync was
**never opened or changed** by this run; its actual deployed value remains unverified without
staging access. Disposable tests alone exercise open fixture gates and close them afterwards.
No real content publication, deployment, staging mutation, rollout, git staging, commit or push
was performed. Existing local service contents were not shut down or deleted; only generated
test databases and the explicitly created migration fixture were removed by their harnesses.
