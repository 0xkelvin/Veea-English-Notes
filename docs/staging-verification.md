# Staging verification through TRD 10

**Owner:** Nin. **Candidate:** record commit, dirty-tree status, migration/API/CLI/Flutter/admin artifact digests and deployment ID in the release ticket. **Prepared:** 2026-11-15. This is an executable checklist, not deployment or release approval.

**Invariant: `learning_sync_control.open = false`.** This preparation neither changes staging nor opens its sync/install gate. Only disposable local test databases temporarily exercise an open gate. Deployments, provider configuration, real content publication and the eventual gate decision belong to Nin. Stop on any failed prerequisite; a local pass never marks a staging/device check complete.

Authority: [AGENTS](../AGENTS.md), [TRD 01 §12.4](trd/01-email-authentication-account-foundation.md#124-verification-before-release), [TRD 04 §§12.4–12.7](trd/04-account-lifecycle-data-rights.md#124-retention-application-enforcement-vs-deployment), [TRD 05 §8.2 and Flutter evidence](trd/05-flutter-verification.md), [TRD 07 §3.1](trd/07-admin-console.md#31-deployment-decision-approved-by-nin-2026-11-15), [TRD 08 §§5–10](trd/08-monitoring-alerting.md), [TRD 10 §§8–9](trd/10-server-delivered-cartridges.md). The body of [account-feedback-rollout](account-feedback-rollout.md) describes the superseded Rust/phone rollout; do not execute it for Go.

## 1. Run locally first

Prerequisites: local Go/Flutter/Docker, Python 3, matching PostgreSQL `pg_dump`/`pg_restore` (compatible with the local PostgreSQL 17 server), and local `promtool` or its pinned Docker image. No credentials or deployed URLs are required. The Docker PostgreSQL is tmpfs with durability disabled: it tests logical restore, not production backup durability, HA or PITR.

From the repository root:

```sh
umask 077
VEEA_VERIFY_EVIDENCE="$(mktemp -d /tmp/veea-staging-local.XXXXXX)"
backend/scripts/verify-staging-local.sh "$VEEA_VERIFY_EVIDENCE"
# To rerun only the real synthetic backup/restore drill:
backend/scripts/test-restore-drill.sh
# Console release artifact (same-origin, no external CanvasKit CDN):
(cd admin_console && flutter build web --release --no-web-resources-cdn)
```

The runner removes inherited deployment DB/email secrets from its child environment, starts only the existing loopback PostgreSQL/Mailpit services, uses isolated `pgtest` databases and writes private logs plus `checks.tsv`/`environment.txt`. It runs:

| Check | Command/action | Expected/evidence |
|---|---|---|
| Backend static/unit/build | `make -C backend check`; `make -C backend build`; tagged `go vet` | Exit 0; API/migrate/admin binaries; no formatting/vet errors |
| Schema/query reproducibility | `make -C backend sqlc-verify` | Reproducible generated code; full suite includes empty DB, replay and populated 14→15 upgrade |
| Backend and Resend stand-in regression | From `backend/`: `VEEA_TEST_DATABASE_URL="$(scripts/test-postgres.sh url)" VEEA_TEST_SMTP_ADDR=127.0.0.1:1025 VEEA_TEST_MAILPIT_API=http://127.0.0.1:8025 go test -race -tags=integration -count=1 -json ./...` | No failures/skips; retain JSON, top-level/subtest counts, Mailpit pass, OpenAPI coverage. Resend tests are `httptest`, not live provider readiness |
| Alert rules | `make -C backend test-alerts` | All 11 rules, 21 scenarios/74 checks; preserve promtool output/version. Routing is not tested locally |
| Restore SQL and real backup | `backend/scripts/test-restore-drill.sh` | Actual `pg_dump`/`pg_restore`, encrypted checkpoint recovery after the original DB is dropped, post-backup completed/incomplete deletions, interruption/retry, normal purge, survivor data retained, epochs rotated and gate closed. Missing/behind proofs and premature finish are refused |
| Learner analyzer/regressions | Root `flutter analyze`; selected tests in runner | Analysis clean, no failures/skips; includes durable queue, canonical fixtures, account/storage, snapshot/import and cartridge tests |
| Learner → Go | `make -C backend test-flutter-go` | Real Go/PostgreSQL/Mailpit; every case passes, including pre-restore cartridge request retained across 503, blocked after 410, and still blocked after SQLite/secure-store restart. Retain Dart JSON and Go host `-race` output |
| Admin analyzer/tests → Go | From `admin_console/`: `flutter analyze`; `flutter test --reporter json`; root `make -C backend test-flutter-admin` | Unit/widget tests pass; environment-gated E2E skips in the standalone run all pass through the real-Go harness |
| Worktree/index hygiene | `git diff --check`; `git diff --cached --check` | Exit 0; no staging/commit/push |

Logs and backup/ledger files are private artifacts. Publish only counts, digests, fixed error codes, sanitized timing/metric series and redacted screenshots. Never attach raw tokens, OTPs, email bodies, mailbox addresses, environment dumps or provider secrets. Temporary synthetic dumps are deleted with the tagged test's temporary directory. Local service shutdown is optional and destructive to those disposable service contents: `backend/scripts/test-postgres.sh stop`, `backend/scripts/test-mailpit.sh stop`; do not stop another person's active test run.

## 2. Ordered staging checklist (Nin executes)

Fill `operator`, `UTC start/end`, `candidate/deployment`, `result`, `evidence link` and `follow-up` for every row in the release ticket. All boxes below remain unchecked by this local preparation. Use the deployment secret manager; never paste a URL/key/token into a recorded command. No integration test, local script or test-only control endpoint is pointed at staging.

| Gate | Prerequisite | Command or operator action | Expected result | Evidence to capture |
|---|---|---|---|---|
| [ ] G0 — candidate and rollback boundary | Approved release window, deployment inventory/owner, current backup and recovery owner | Build/version all artifacts from the same candidate; record `go version -m /path/to/api` where applicable and container/binary/static artifact digests. Fence public rights/email-cutover/admin/cartridge exposure during mixed-version rollout | Known migration and rollback boundary. Migrations are up-only: use a compatible forward binary or isolated restore, never an improvised down migration | Release manifest, all instance IDs/digests, backup identifier/time, owner and recovery decision |
| [ ] G1 — migration 00015 and full backend rollout | G0; deployment DB secrets loaded privately; migration privileges; maintenance grants reviewed | In the deployment job: `bin/migrate status`, `bin/migrate up`, `bin/migrate status`. Read-only SQL: `SELECT open FROM learning_sync_control;`. Roll **every** API/outbox/cleanup process and operator CLI to the candidate; inventory again. Check `/healthz` and `/readyz` per instance and through each approved ingress | `current_version=15 pending=0`; gate **false**; every process uses the new code. No API startup migration. Old email/lifecycle/session/sync/entitlement implementations cannot remain behind the load balancer | Sanitized migration output/duration, schema version, false gate query, rollout inventory, health responses and maintenance-job success. Readiness alone does not prove version consistency |
| [ ] G2 — secrets, proxy and maintenance role | G1; designated secret/version and proxy CIDR configuration | Verify configured HMAC/OTP/outbox key versions and preserved decryption keys without exposing values; `VEEA_EMAIL_SENDER=resend`, verified-domain `VEEA_EMAIL_FROM`, restricted `VEEA_MAINTENANCE_DATABASE_URL`, internal metrics address. Confirm trusted proxies match topology and spoofed forwarded headers are ignored outside that trust boundary | Keys loaded, no secret/body logging; outbox data decryptable; maintenance can purge/minimize/clean, API audit grants cannot mutate/delete audit. Full API and cleanup operations succeed with intended roles | Secret version IDs, redacted grants/topology review, fixed-code startup/cleanup evidence, request-ID correlation, no environment dump |
| [ ] G3 — verified Resend delivery | G1–G2; controlled deliverable test mailbox(es), domain DNS access, sending permission and outbound provider connectivity | In Resend's current console verify the From domain/DNS and deployed key's sending scope. Through approved account UI/API perform fresh OTP signup/sign-in plus a security notification (e.g. password change). Inspect provider acceptance/delivery and the receiving inbox; confirm both text/HTML and correct From. If testing retry, use an approved fault proxy/worker restart, same outbox row/key and unchanged rendering within the documented 24 h idempotency window | Real OTP and notification delivered; intended proof/session behavior; provider ID recorded only under the worker lease; stable row-ID key/body on retry, no fresh key to evade conflict. Acceptance/`sent` alone is not inbox delivery | Domain-verification status/time, secret-version ID, redacted provider message ID + outbox correlation, delivery timestamps and headers. Exclude OTP/body/address. Live dedupe untested unless the approved retry drill is actually run |
| [ ] G4 — native secure storage and account boundary | G1–G3; signed iOS and Android candidate builds, device/OS matrix, test accounts A/B and controlled response-loss proxy | Execute §3 on physical devices; use the approved build pipeline's staging configuration, never a deployed target in local test scripts | Native Keychain/Keystore persistence works; token pair rotation is atomic at the app boundary; no late refresh restores old credentials; receipt survives independently; deletion clears only its owner; same-email signup uses a new UUID | Build/signing/device/OS IDs, timestamps, redacted screen recordings, session rotation/revocation counts and account IDs represented by stable aliases. Mock secure storage is insufficient |
| [ ] G5 — AC-7 timing | G1–G2; representative deployment hardware/Argon2 costs and reverse proxy; **Nin approves sample count, warmup, tolerance/statistic and decision rule before measurement** | Run operator-owned measurement for wrong password, unknown address, verified passwordless account and pending registration. Randomize/interleave classes; use unique synthetic addresses/accounts, preserve normal rate limits and background audit/outbox load. Record only class/status/code/latency/request ID, never submitted credentials | Each failure is `401 invalid_credentials`, equal normalized shape, production-cost hash work, and measurements meet the preapproved median/tail/confidence rule. Existing reduced-cost tests do not establish timing equivalence. If no agreed tolerance or insufficient valid samples, gate stays open | Approved protocol/tolerance, fixture generation method, costs/CPU/concurrency/network path, per-class raw timing samples (sanitized), p50/p95 and comparison/confidence report; any explicit accepted limitation signed by Nin |
| [ ] G6 — admin ingress and console | G1; dedicated same-origin admin host, TLS, operator VPN/IP policy, public ingress rules, approved Super Admin | Execute §4; bootstrap only through audited `bin/admin bootstrap-super-admin` if needed. Test plan grant/revoke, stale revision from second console and permission loss through the deployed console with synthetic accounts | Public `/v1/admin/*` is edge 404; outside operator network admin host unreachable; inside admin proxy unauthenticated admin request gets Go 401; metrics unavailable from both ingresses. No CORS dependency or token persistence in browser; conflict requires fresh confirmation, audit reloads | Results from both network positions, sanitized response headers, edge/upstream route trace, deployed static/API digests, audit actor/reason/ticket without credentials |
| [ ] G7 — metrics, alert evaluation and delivery | G1/G2/G6; reachable internal metrics, real Prometheus/ruler version, on-call/test ticket destinations | Load existing rules with deployed-version `promtool check rules`; job `veea-api`, one target per instance, scrape/evaluate ≤1m. Check all four gauges present/nonnegative. Send labeled **test** critical/warning notifications through the approved Alertmanager route; run §5 controlled evaluation/failure/recovery drills | Critical pages, warning tickets next business day; receiver sees firing and resolved with the intended labels. Healthy baseline silent; missing target/series and read failures never count as healthy zero. No new Phase 5 scope/rules added | Rule/config digests, target/evaluation pages, PromQL/time series, notification/ticket IDs and firing/resolution timestamps, noise/silence tests |
| [ ] G8 — retention and deletion SLO | G2/G3/G7; provider consoles and cleanup dashboards; policy owner | Verify actual backup/PITR/WAL/replica expiry ≤30d, logs 14d and documented Resend message/recipient/log retention/deletion controls. Confirm the intended **global** 180d audit policy (TRD 04 §12.7), receipt 30d, restoration ledger 90d after completion, 24h exports and 24h purge target with actual deployed workers. Run proof→acceptance→revoked access→purge→same-email new account; include entitlement and cartridge state | Application/deployment retention distinguished; incomplete deletion markers never expire. Old device cannot authenticate or attach old account cache to new UUID. Provider retention unknown means gate not complete | Redacted provider configuration, maintenance privilege check, accepted/completed UTC and oldest-pending metric, minimized audit samples, zero owned rows and independent re-registration. Do not claim immutable backup/inbox copies erased immediately |
| [ ] G9 — real restore/PITR drill | G0–G8; provisioned independent checkpoint destination, dedicated key/source custody, scheduled publication/freshness monitoring, independent cutoff/minimum-generation records, isolated target and approved restoration window | Execute §6 and [the ledger workflow](deletion-ledger-recovery.md) with actual backup/PITR. Lose the original DB, recover the independent checkpoint, prove coverage, replay/purge, rotate epochs and verify; test interrupted publication and restore retries. Keep access closed if evidence is missing/behind. Check clients only on a disposable canary | Every deletion through the independently required cutoff, **including incomplete** jobs, is reapplied; survivor data remains, exports/mail/proofs cannot replay, epochs change and old cartridge requests stay blocked. Behind coverage blocks recovery | Backup/PITR ID/start point, independent source/key version and checkpoint generation/cutoff/count/digest, storage durability/retention/ACL and job freshness evidence, missing/behind refusal, original-DB-unavailable recovery, retry/prepare/purge/finish/verify and client results. Local fixture evidence is §8; destination/scheduling remain unprovisioned |
| [ ] G10 — content and opening decision | G1–G9; Nin's real pack classification/content approval and client distribution status | Review TRD 10 limits (16 packs, 200 cumulative entries/pack, 1 MiB/document); split larger packs. Real publication is a separate Nin-run audited CLI action. Verify catalog metadata, Free/Premium expiry and owned-word use on a synthetic isolated canary. Approve removal of real Premium content only from future bundles after client support ships | This preparation publishes **no real content** and leaves the shared gate false. Existing owned words remain usable/syncable after downgrade. Opening sync/install requires a separately recorded operator decision; do not copy an unconditional `open=true` from an old runbook | Classification/license/stable-ID approval, signed client availability, canary evidence, explicit remaining-risk acceptance and separate gate-change ticket |

**Known prerequisites without repository configuration:** staging hosts/orchestrator and rollout inventory, verified Resend account/domain/inboxes, real device/signing matrix, AC-7 numerical acceptance rule, network/ingress configuration, Prometheus/Alertmanager/receivers, retention policy confirmation and independently recoverable ledger custody. The ledger CLI/POSIX adapter is implemented; shared destination, schedule, freshness alerting, key custody and incident cutoff procedure are **deployment dependencies**, not provisioned here. These are pending/blocked inputs, not failed local tests. The cartridge library currently displays a review-required block but has no cartridge-specific review-resolution UI; do not claim that restoring normal user-driven recovery is verified. Resolve that product/UX gap before treating the full restore-and-review experience as releasable; never clear a blocked row or substitute a new epoch to bypass it.

## 3. Physical-device checklist for G4

For **each** supported signed iOS/Android build and OS version, with synthetic accounts only:

1. Sign in A, record the stable owner alias, force-stop and cold-start offline, then background/lock/unlock and resume online. Verify readable owned notebook and intended authentication behavior; test device reboot and app upgrade with the same signing/storage configuration. Reinstall/OS-backup restoration is a separate platform case: record observed Keychain/Keystore behavior, never assume reinstall erases or restores secrets.
2. Expire access on a controlled synthetic test session through the approved operator method, then launch concurrent protected requests. One refresh rotation, one persisted complete pair; restart during in-flight refresh/lost response requires fresh sign-in, never a retry with a consumed token.
3. Hold refresh response, sign out or switch to B, then release. A late response cannot restore A's credentials or overwrite B's pair. Sign-out opens guest; B opens its own notebook. Test storage-write failure/full disk/locked-device behavior using approved platform tooling: it must fail closed without partial credential adoption.
4. Request and confirm deletion with a fresh mailbox proof. Simulate lost completion/receipt response, restart and resume polling from `auth.go.deletion.v1`, independent of `auth.go.session.v1`. Only authoritative acceptance clears A's cache/queue/cursor/writer/review/cartridge rows; unknown result preserves them. Other accounts and guest remain intact. Re-register the same email after purge: new UUID, no old cache/queue.
5. Keep installed words usable offline after downgrade. An old-epoch pending cartridge request must retain its version/body and show review-required after the isolated restore canary; no fresh install POST after it is blocked. Capture request **counts/digests**, not authorization or request bodies. Verify no tokens/OTPs in platform logs, SharedPreferences, SQLite, screenshots or diagnostics. Secure-store keys alone are not secrets; their values are.

## 4. Read-only ingress probes for G6 (Nin)

Use actual approved staging origins. These commands are unauthenticated and show only status, not credentials. Run them from the specified network positions, not as a local test target:

```sh
# Operator network. PUBLIC_ORIGIN and ADMIN_ORIGIN contain origins only, no credentials.
curl --silent --show-error --output /dev/null --write-out '%{http_code}\n' "$PUBLIC_ORIGIN/v1/admin/users"
# Expected 404 at the PUBLIC EDGE, corroborated by edge logs (not upstream Go 404).
curl --silent --show-error --output /dev/null --write-out '%{http_code}\n' "$ADMIN_ORIGIN/v1/admin/users"
# Expected 401 from Go through same-origin admin proxy.
# Repeat /metrics on both origins: never public metrics; check all configured aliases too.
```

Outside the operator network, the admin origin must be unreachable by the configured policy. From inside, record the Go `WWW-Authenticate: Bearer` and `X-Request-Id` headers separately. The public edge blocks the complete `/v1/admin/` prefix across methods/encoded-path handling, not just one GET. Check same-origin browser requests, no refresh token in local/session storage/cookies, security headers and no third-party CanvasKit fetch. Do not leave browser network captures containing tokens in evidence.

## 5. Controlled alert drills for G7 (Nin)

Use synthetic records, a quiet staging window and approved fault injection. Do not edit thresholds to make a test pass.

| Drill | Action/prerequisite | Expected firing/recovery evidence |
|---|---|---|
| Routing only | Operator's approved Alertmanager test-alert mechanism, unique `test=true`/ticket correlation and existing severity/job labels; approved non-production receivers | Critical test pages; warning test opens ticket; explicitly resolve and retain receiver IDs. This alone does not test Prometheus evaluation |
| Target missing/failing | Temporarily fail one known target; separately remove **all** targets for this job under the approved discovery drill | `VeeaApiScrapeFailing` after 5m; `VeeaApiScrapeTargetAbsent` after 10m; resolved after restoration. Missing series do not look like zero gauges |
| Email failure | Approved invalid **test** sender credential/configuration, synthetic mail only, then restore known secret version | Low-volume: ≥3 permanent/ambiguous failures, no sent in 1h, hold 5m. Ratio: >25% in 30m with ≥20 calls, hold 10m. Record which rule was actually exercised, then recovery |
| Pending outbox stall | Needs a way to pause claims/sends **while the metrics target remains healthy** and a synthetic non-OTP pending notification lasting >30m. No standalone worker-disable flag exists in `cmd/api`; agree isolation/fault method first | `VeeaEmailOutboxStalled` after the 20m silence window + 10m hold; restart/restore sends, then resolution. Stopping every API and losing metrics proves scrape failure, not the outbox rule |
| Purge delay | Approved fault held in one synthetic account purge, then released; no manual edit of user data as substitute for accepted deletion | `VeeaAccountPurgeSlow` at age >2h held 15m; `VeeaAccountPurgeOverdue` at >24h held 5m. Record real elapsed-time drill or explicitly identify isolated timestamp simulation; pending gauge returns to 0 |
| Low traffic/healthy recovery | Keep healthy zeros; one email failure/hour; missing-counter and negative-gauge cases in the isolated evaluation harness | Silence/appropriate diagnostic rule according to TRD 08; attach live-series result or preserve local promtool evidence without claiming live coverage |

Keep the existing 11 rules. `db_tx_retries_total` is exported but a dedicated retry alert, sign-in/OTP/account-creation dashboards, sync alerts and SLO burn-rate work remain in their existing future scope (TRD 08 §9).

## 6. Isolated restore sequence for G9 (Nin)

**Stop boundary:** no API, worker, scheduler, migration peer or user traffic may touch the target while preparing it. Follow [independent ledger recovery](deletion-ledger-recovery.md) for provisioning, archive scheduling and gap handling. Deletion `202` is DB acceptance; independent recoverability begins only at acknowledged durable checkpoint publication. A ledger stored **only inside the older backup is insufficient**. The local POSIX adapter is implemented; shared custody is not provisioned. Missing/behind/unknown coverage blocks **all** restored access and sync. Never archive the restored DB to manufacture missing history.

1. Establish source UUID, conservative backup/PITR start point, required-through cutoff and minimum generation from **independent** provisioning/backup/incident/receipt records. For planned cutover fence all source writes, record the final database-clock boundary and run a final `bin/admin ledger archive` against the authoritative primary without `--initialize`; preserve its receipt. For disaster recovery retrieve the already published independent checkpoint; the original DB need not exist. From `backend/`, with dedicated recovery keys loaded privately and requirements set from those records:

   ```sh
   set -eu
   umask 077
   mkdir -m 700 ./private-recovery
   bin/admin ledger recover --store "$VEEA_LEDGER_STORE" --source "$VEEA_LEDGER_SOURCE" \
     --backup-at "$VEEA_RECOVERY_BACKUP_AT" --required-through "$VEEA_RECOVERY_REQUIRED_THROUGH" \
     --min-generation "$VEEA_RECOVERY_MIN_GENERATION" --out ./private-recovery/recovered.sql
   ```

   Require exit 0 and retain the receipt (generation/cutoff/count/digest), operator and key version IDs. Output must use a private directory and a new filename. Transfer only through the approved encrypted restricted channel. A stale checkpoint does not prove that no later acceptance occurred. If the source is lost and coverage is short, retrieve newer independently retained checkpoints or authoritative replica/WAL evidence under the runbook; otherwise **stop**. Never lower the required cutoff/generation to make recovery pass. Include all retained completed/incomplete markers, not a manual date-filtered CSV.
2. Restore the actual provider backup/PITR into an isolated target, with outbound email denied and no ingress. Run candidate `bin/migrate up` then `status`; require 15/0. Close/verify sync **before attaching any process**, even if the backup contains `open=true`:

   ```sql
   UPDATE learning_sync_control SET open=false,changed_at=clock_timestamp();
   SELECT open FROM learning_sync_control;
   ```

3. Use **one kept-open private `psql` session**, with `ON_ERROR_STOP` and DB identity checked by Nin; do not paste connection secrets. Paths below are relative to the repository root; recovery output was created under `backend/`. The proof, incoming ledger and epoch baseline are session-local, so use this same session through step 6:

   ```sql
   \set ON_ERROR_STOP on
   SET veea.restore_isolated='yes'; -- operator acknowledgement, not an isolation mechanism
   \i backend/private-recovery/recovered.sql
   SELECT count(*) AS incoming_markers FROM restore_deletions;
   \i backend/ops/restore/prepare-isolated.sql
   ```

   The CLI authenticates the encrypted checkpoint; prepare/finish/verify additionally require its coverage proof and matching count. Do not hand-write those tables or bypass recovery with CSV. The script replays the union of recovered/restored ledgers, seals restored owners, requeues exactly their accepted deletion operations from purge step 0, revokes all restored sessions, invalidates proofs/operation capabilities, cancels exports/chunks and cancels unsent mail. Existing delete operation address digests are preserved for normal fence expiry. New restoration operations issue no capability/proof. A conflicting user/operation identity refuses the transaction. No traffic is allowed until erasure finishes; the absence of a newly generated address fence for a reconstructed operation must never be used to permit signups before then.
4. Start **one current candidate API process only inside the isolated network** to run the real cleanup jobs, with loopback HTTP, internal metrics, sender `fake`, preserved key versions and no outbound provider route. This is a maintenance surrogate: no standalone cleanup command exists. Do not attach the public/admin ingress or use restored credentials. It starts cleanup immediately and repeats every five minutes; record successes/errors and `account_deletion_oldest_pending_seconds`. Stop on any error. Wait for pending delete count and age to be 0; age 0 alone is not enough. The purge must erase vocabulary, writers/head, entitlements and installation watermarks; minimize owner audit.
5. Stop the isolated process. In the kept-open `psql` session:

   ```sql
   SELECT count(*) FROM account_operations WHERE action='delete' AND state='pending';
   SELECT count(*) FROM users u JOIN deletion_ledger d ON d.user_id=u.id;
   \i backend/ops/restore/finish-isolated.sql
   \i backend/ops/restore/verify-isolated.sql
   ```

   Finish refuses if deletions remain. It then rotates all surviving epochs and retires every writer. Verify requires false sync gate, zero restored live sessions/proofs/capabilities/exports/pending mail, no deleted owners and no unchanged surviving epochs. Preserve its counts, not private ledger contents. Inspect minimized audit and survivor data; confirm one active Super Admin or perform approved audited CLI recovery before admin traffic resumes.
6. If any SQL transaction fails, stop and `ROLLBACK` in that session; fix the cause under the ticket. Prepare can be replayed while isolated (it may restart purge checkpoints); finish/verify stay in that session. If it is lost, recover the verified independent checkpoint again to a new private output name, reload in a new session, repeat prepare/purge and record the new epoch baseline. Never skip failed assertions or set `open=true` to diagnose a purge. Interrupted publication is retried against the same store/source; a failed or lost acknowledgement is not evidence of coverage.
7. Test old access/refresh, OTP, rights/export capabilities and sync cursor/writer on a **separate isolated synthetic canary** of the restored release. An old cartridge attempt while closed gets 503 and retains its exact owner/version/body/epoch; only the deliberately opened disposable canary can return 410 `sync_reset_required`. After that response, the client stores `blocked=1`; restart and Retry send **no new install POST** and preserve the old bytes for review. Do not equate a shared closed-gate 503 with an observed epoch refusal. Record the user-review UX gap from §2.
8. Leave the restored shared gate false. Any traffic cutover, real content publication, recovery UX acceptance and eventual sync opening are separate Nin decisions after G0–G10 evidence is complete. Restore does not recreate post-backup deletion receipts/capabilities from the minimal ledger; receipt continuity beyond the backup must be recorded as a limitation, not inferred from a 401/404 or used to erase a local cache automatically.

Historical local logical backup evidence is in §7; the source-loss independent-ledger extension is in §8. Production storage durability, disaster-time ledger availability, installed scheduling/freshness monitoring, key custody, PITR retention, signed-device behavior, real mail delivery and routing still require the staging/operator checks above.

## 7. Initial staging-preparation local evidence (historical)

Executed locally on **2026-11-15**, based on `a3659a3642b9a427c8b0c1366c363ccf62f8d27f` plus this uncommitted preparation. Private evidence directory: `/tmp/veea-staging-verification-20261115` (temporary local artifact, not a durable release-ticket attachment). The runner records tool versions and worktree status in `environment.txt`; copy sanitized evidence to the release ticket before deleting local files. Go 1.26.2, Flutter 3.47.9 / Dart 3.13.7; local PostgreSQL 17 service, `pg_dump`/`pg_restore` 18.3. No deployed service or real provider was contacted.

| Check | Passed | Failed | Skipped | Evidence |
|---|---:|---:|---:|---|
| Full Go PostgreSQL + Mailpit `-race` | **1,269** | **0** | **0** | `go-race.log`; tests/subtests, **473 top-level**; 367 OpenAPI combinations, no violations, only four pre-existing exclusions |
| Actual synthetic pg_dump/pg_restore drill `-race` | **1** | **0** | **0** | `restore.log`; separate `integration,restoredrill` tag, not included in 1,269. Post-backup completed=1/incomplete=1 deletions reapplied; real purge, epoch rotation and closed-gate assertions |
| Selected learner Flutter regressions | **108** | **0** | **0** | `flutter-regressions.log`; includes sync/storage/account/cartridge and two catalog widget cases |
| Learner → local Go/Mailpit Dart E2E | **8** | **0** | **0** | `flutter-go.jsonl`; new restore-fence scenario plus previous seven. `flutter-go-host.log`: Go host **1/0/0**, `-race` |
| Standalone admin Flutter suite | **42** | **0** | **10** | `admin-tests.log`; skips require the local Go harness; all ten executed below |
| Admin → local Go Dart E2E | **10** | **0** | **0** | `flutter-admin.jsonl`; `flutter-admin-host.log`: Go host **1/0/0**, `-race` |

Both Flutter analyses, `make check`, build, sqlc verification, tagged vet, shell syntax and worktree/index whitespace checks passed. Promtool validated **11 rules**, with all **21 scenarios / 74 checks** passing. Admin release build `flutter build web --release --no-web-resources-cdn` passed (`useLocalCanvasKit: true`); it emitted a nonfatal font-family warning, so deployed browser visual/network smoke remains G6. This preparation did not run unrelated goldens or signed-device secure-storage tests.

The logical restore test executes the checked-in SQL on a **real restored database**, including restored pending encrypted mail/export chunks, source ledger markers captured after the backup, the normal checkpointed purge, minimized restored audit and a refusal to finish while deletes remain. It is not a hosted backup/PITR, physical durability or independently durable-ledger test. Temporary synthetic archives are removed by test cleanup; only counts are logged.

The new tagged Flutter E2E verifies the actual Go gate/epoch contracts, without fabricating API success: an install response is lost after commit; fixture-only restore fencing closes sync, revokes sessions, rotates the owner's epoch and retires writers; fresh sign-in uses the same UUID. A retry while closed returns **503** with unchanged pending version/body/epoch. Opening only that disposable fixture produces **410**, sets `blocked=1`, and preserves the request. After reopening SQLite and the secure-store boundary, Retry emits **zero install POSTs** and still requires review. This does not prove native secure storage or a complete review-resolution UX.

**Remaining gates:** all G0–G10 staging/operator checkboxes remain open. In particular, no live Resend domain/delivery, native Keychain/Keystore smoke, production-cost AC-7 latency/tolerance, real ingress/Alertmanager routing, provider retention/PITR/independent ledger custody, or real content publication was verified. Cartridge review resolution and minimal-ledger receipt-continuity limitations are explicit above. Sync/install rollout remains **closed**. No staging change, deployment, real content publication, commit or push was made; externally staged files were left untouched.

## 8. Independent ledger local evidence

Executed locally on **2026-11-15**, based on `5bee407` plus this recovery change. Private
evidence: `/tmp/veea-ledger-recovery-20261115` (temporary local files; attach sanitized results
to the release ticket separately). Go 1.26.2, local PostgreSQL 17, `pg_dump`/`pg_restore` 18.3.
No deployed service, shared-storage destination or real email provider was contacted.

| Check | Passed | Failed | Skipped | Evidence |
|---|---:|---:|---:|---|
| Full PostgreSQL + Mailpit Go suite, `-race` | **1,291** | **0** | **0** | `full-race.jsonl`; **483 top-level**, 470 unit and 821 integration tests/subtests. OpenAPI still 367 combinations, no violations, four pre-existing unexercised responses |
| Recovery package + admin CLI, `-race` | **23** | **0** | **0** | `focused-unit.jsonl`; overlapping subset of the full suite, not additional passes |
| Recovery-ledger PostgreSQL tests | **3** | **0** | **0** | Subset of `full-race.jsonl`: archive/gap, observed acceptance-lock wait, retained unfinished markers/concurrent publishers |
| Source-loss backup/restore drill, `-race` | **3** | **0** | **0** | `restore.jsonl`; one top-level plus two subtests, separately tagged and not included in 1,291 |
| Learner → real local Go/Mailpit Dart E2E | **8** | **0** | **0** | `flutter-go.jsonl`; excludes hidden loader/teardown events. Go harness **1/0/0** in `flutter-go-host.log`, separately tagged and race-enabled |

From `backend/`, the actual checks were:

```sh
make sqlc
make sqlc-verify
make check
make build
go vet -tags=integration,fluttere2e,restoredrill ./...
go test -race -count=1 -json ./internal/recoveryledger ./cmd/admin
VEEA_TEST_DATABASE_URL="$(scripts/test-postgres.sh url)" \
  VEEA_TEST_SMTP_ADDR=127.0.0.1:1025 VEEA_TEST_MAILPIT_API=http://127.0.0.1:8025 \
  go test -race -tags=integration -count=1 -json ./...
scripts/test-restore-drill.sh
VEEA_FLUTTER_E2E_REPORT=/tmp/veea-ledger-recovery-20261115/flutter-go.jsonl make test-flutter-go
```

SQL generation/verification, `make check`, build and tagged vet passed. After the retry-test
refinement, affected unit tests, check/build/vet and the restore drill were rerun and passed.
Shell syntax and both worktree/index whitespace checks passed. No Flutter production code or
HTTP contract changed; the existing Flutter E2E was run as a restore/account regression.
Migration version remains **15**; no migration or OpenAPI change was needed.

The drill now takes a real backup **before** accepting two deletions, completes one and leaves
one incomplete. An injected publication interruption leaves the old checkpoint insufficient;
recovery refuses it. Publication retry succeeds, then source cleanup **drops the original DB**
and the test verifies it is absent. A new CLI process with an unavailable source URL retrieves
the encrypted checkpoint from the separate local fixture and emits private recovery SQL.
The restored target refuses missing/behind proof and refuses finish before purge. After one
purge pass the restore session is lost; the store is reopened, the checkpoint recovered again,
and prepare/purge/finish/verify safely retried. Deleted accounts and owned data are absent,
survivor vocabulary/shared catalog remain, owner audit is minimized, epochs change, writers
are retired, old artifacts/mail/proofs are fenced and sync stays **false**. No reopening is
performed. Unit interruption tests cover both before and after atomic rename, plus tamper,
truncation, wrong source/key, stale generation/cutoff, old backup, key rotation and cancellation.

**Remaining G9 deployment dependency:** choose and provision independent storage and its tested
durability/serialization/retention/versioning/ACLs, dedicated key and source/receipt custody,
checkpoint scheduler, freshness failure routing and conservative incident cutoff procedure.
The local adapter proves recovery without the original database, **not** survival of a host/site
loss or installed operational coverage. Deletion `202` still precedes independent publication;
if the original is lost before the required interval is archived, access remains blocked until
authoritative missing history is recovered. This is not a zero-loss acceptance guarantee.
All staging/provider/device gates, the cartridge review-resolution UX and receipt-continuity
limit remain as recorded above. Sync remains closed. Deployment, staging, commits and pushes
remain Nin's work; no staging operation or index mutation was performed by this session.
