# TRD 08 — Monitoring & Alerting

**Status:** v1.0. The rules are implemented and their behavior is verified locally with promtool (§6). Deployment wiring (Prometheus scrape, Alertmanager routing) is shared-infrastructure work (§8).
**Date:** 2026-11-15
**Audience:** Nin, backend engineers, and the operator on call.

## 1. Authority and inputs

- **Product Doc §10 (still [Proposed]):** operators can see delivery failures and other operational signals. This TRD delivers the four alerts below; the rest of §10 remains future work (§9).
- **TRD 01 §11.3:** Prometheus on the internal listener `VEEA_METRICS_ADDR` (`GET /metrics`), fixed label codes, counts after commit, `-1` for a failed gauge read. It said alerting is Phase 5, which is this TRD.
- **TRD 04 §6.2, §12.7:** active-store erasure within 24 hours of acceptance; release gate "alert on `account_deletion_oldest_pending_seconds` above 24 h".
- **TRD 06 §4, §12:** at least one active Super Admin after bootstrap; release gate "alert on `admin_active_super_admins < 1`".
- **TRD 07 §3.1:** the deployment topology (admin origin, public learner ingress). The metrics listener is neither; it is internal.
- **AGENTS.md:** only local disposable services in tests; metrics count after commit; fixed label values.

## 2. Metric inventory

These are the metrics actually exported by `cmd/api`, from `internal/platform/metrics/metrics.go` and `app.New` / `cmd/api/main.go`, checked by scraping the real registry (§6).

| Metric | Type | Labels | Present when |
|---|---|---|---|
| `auth_otp_started_total` | counter | `purpose`, `delivery` | after the first start |
| `auth_otp_verified_total` | counter | `purpose`, `result` | after the first redemption |
| `auth_signup_completed_total` | counter | `method` | after the first signup |
| `auth_password_login_total` | counter | `result` | after the first attempt |
| `auth_rate_limited_total` | counter | `rule` | after the first 429 |
| `auth_sessions_revoked_total` | counter | `reason` | after the first revocation |
| `auth_refresh_reuse_total` | counter | — | always (unlabeled) |
| `email_send_total` | counter | `template`, `result` (`sent`, `permanent`, `retryable`, `ambiguous`) | **always: every template × result at 0 from startup (new, §4.1)** |
| `email_outbox_stale_result_total` | counter | — | always |
| `email_outbox_pending` | gauge (query on scrape) | — | always; `-1` on read failure |
| `db_tx_retries_total` | counter | `reason` | after the first retry |
| `argon2_wait_seconds` | histogram | — | always |
| `account_lifecycle_accepted_total` | counter | `action` | after the first acceptance |
| `account_jobs_total` | counter | `job`, `result` | after the first job outcome |
| `account_deletion_oldest_pending_seconds` | gauge (query) | — | always; `0` when no purge is pending; `-1` on failure |
| `learning_sync_push_total`, `learning_sync_items_total`, `learning_sync_reset_total` | counters | see TRD 05 | after first use |
| `admin_actions_total` | counter | `action`, `result` | after the first admin request |
| `admin_active_super_admins` | gauge (query) | — | always; `-1` on failure |
| `admin_super_admin_bootstrapped` | gauge (query) | — | **always (new, §4.2)**: `1` after the first bootstrap, else `0`; `-1` on failure |
| `go_*`, `process_*` | runtime | — | always |

Prometheus adds `job` and `instance` to every series, and `up` per target. The database-backed gauges are the same on every API instance, because they read the shared database.

## 3. Stack and conventions

- **No monitoring stack exists in the repository.** There is no Prometheus, Alertmanager or Grafana configuration. The only deployment asset is the Rust `cloud/` docker-compose. The Go service already speaks the Prometheus exposition format, so the rules are a standard **Prometheus rule file**: [`backend/monitoring/prometheus/veea-alerts.yml`](../../backend/monitoring/prometheus/veea-alerts.yml). Any Prometheus-compatible ruler can load it unchanged (Prometheus, or a Mimir or Thanos ruler).
- **Scrape convention (deployment requirement):**
  - job name `veea-api`;
  - one target per API instance, scraping `VEEA_METRICS_ADDR` at `/metrics`;
  - scrape and rule-evaluation interval of 1 minute or shorter.

  The default `VEEA_METRICS_ADDR` is `127.0.0.1:9090`, loopback only, so a deployment must bind it to an internal address Prometheus can reach. It must never be exposed on the admin or learner ingress (TRD 07 §3.1). Every expression selects `job="veea-api"`, and a test enforces this.
- **Severity:** `critical` pages the on-call operator; `warning` opens a ticket for the next business day. Routing is Alertmanager configuration (§8).
- **Tooling:** `promtool` from the pinned `prom/prometheus:v2.49.1` image, or a local `promtool`, through `scripts/test-alert-rules.sh` (`make -C backend test-alerts`). It runs offline.

## 4. Service changes made for alerting

### 4.1 Email failure series exist from startup

A Prometheus counter series that first appears with value 1 shows no `increase()`: the first sample is the baseline. Without pre-created series, the first email failure after every restart would be invisible, and "no failures" would be a missing series rather than a 0.

`cmd/api` now calls `metrics.InitEmailSend(notify.TemplateNames())`, which creates every `email_send_total{template,result}` series at 0. `notify.TemplateNames()` lists every template. The email rules also fall back to 0 when the `sent` series or the whole metric is missing, so they cannot be silenced by an absent series either (tested, §6).

### 4.2 A durable bootstrap marker

`admin_active_super_admins == 0` is expected on a fresh deployment, before `bin/admin bootstrap-super-admin` runs. It is an incident only after bootstrap. Nothing durable recorded that bootstrap had happened: audit rows expire after 180 days, and the Super Admin rows themselves are what might be lost.

- **Migration `00013_rbac_bootstrap_marker.sql`** adds `rbac_bootstrap`: one row at most (`id = 1`, `first_bootstrapped_at`). It holds no account data and is not user-owned, so the purge and export inventory is unchanged. The migration backfills the marker when any Super Admin row exists or a bootstrap audit event is still retained, using the earliest bootstrap time.
- **Writes:** `admin.Bootstrap` writes it in the same transaction as the promotion, and so does any API promotion to `super_admin` (a backstop). Both use `ON CONFLICT DO NOTHING`, so the first time is kept.
- **Gauge:** `admin_super_admin_bootstrapped` reads it on each scrape: 1 after bootstrap, 0 before, `-1` if the read fails.

## 5. Rules and operator actions

All rules evaluate every minute. Thresholds are first-release defaults, to revisit after a month of real traffic.

| Alert | Severity | Expression (abridged) | Window and hold |
|---|---|---|---|
| `VeeaApiScrapeFailing` | critical | `up == 0` | for 5m |
| `VeeaApiScrapeTargetAbsent` | critical | `absent(up{job="veea-api"})` | for 10m |
| `VeeaApiMonitoringSeriesMissing` | warning | `up == 1` unless all 4 gauges are present | for 10m |
| `VeeaApiMonitoringReadFailed` | warning | any of the 4 gauges `< 0` | for 10m |
| `VeeaNoActiveSuperAdmin` | critical | `max(bootstrapped) == 1 and max(active Super Admins) == 0` | for 5m |
| `VeeaAccountPurgeSlow` | warning | `max(account_deletion_oldest_pending_seconds) > 7200` | for 15m |
| `VeeaAccountPurgeOverdue` | critical | `… > 86400` | for 5m |
| `VeeaEmailDeliveryFailureRatioHigh` | critical | (permanent + ambiguous) / all calls `> 0.25` over 30m, with at least 20 calls | 30m window, for 10m |
| `VeeaEmailDeliveryFailingLowVolume` | critical | at least 3 failures and 0 `sent` in 1h | 1h window, for 5m |
| `VeeaEmailOutboxBacklogGrowing` | warning | `email_outbox_pending >= 20` and `deriv(…[15m]) > 0` | for 15m |
| `VeeaEmailOutboxStalled` | critical | `min_over_time(pending[20m]) > 0` and 0 provider calls in 20m | for 10m |

**Aggregation.** The gauges are database-wide, so value rules use `max by (job)`: one alert per deployment, not one per instance. Counters use `sum by (job)` across instances. A `-1` sentinel never satisfies a value rule (`== 0`, `> threshold`, `>= 20`); it raises `VeeaApiMonitoringReadFailed` instead. One instance's `-1` cannot hide another instance's real value, because `max` ignores it whenever another instance reports a real value (tested).

### 5.1 Scrape failing or absent

`VeeaApiScrapeFailing` means a known target fails every scrape. `VeeaApiScrapeTargetAbsent` means no `up` series exists at all: discovery or configuration lost every target. While either fires, **every other rule is blind**, because the target's series go stale and value rules see nothing. That is why a missing scrape has its own alert and is never read as "all quiet".

First checks:

1. Is the API process running and healthy? Check the public `/healthz` and `/readyz` through the learner ingress.
2. Is `VEEA_METRICS_ADDR` bound to an address Prometheus can reach (not the loopback default)? Can it be reached from the Prometheus host (`curl http://<addr>/metrics`)?
3. Do the Prometheus target page and service discovery still list the instance with `job="veea-api"`?
4. Scrapes are capped at 2 concurrent and 5 s: a slow database can make scrapes time out, so also check database health.

### 5.2 Monitoring series missing or read failed

- **`VeeaApiMonitoringSeriesMissing`:** the scrape works, but one of `admin_active_super_admins`, `admin_super_admin_bootstrapped`, `account_deletion_oldest_pending_seconds` or `email_outbox_pending` is absent. The Super Admin, purge or outbox alerts built on it are silent. A missing series is not a healthy zero.
  - First check: is the instance running a binary older than this TRD? (Version 13 adds the bootstrap gauge, so run `bin/migrate up` and roll every instance.)
  - Is another process answering on the metrics port?
- **`VeeaApiMonitoringReadFailed`:** a gauge reports `-1`, meaning its query failed or exceeded its 1-second timeout.
  - First check: database connectivity and saturation (`db_tx_retries_total`, pool exhaustion), and the API logs for that instance.
  - After a deploy, also check that migration 13 has been applied: `rbac_bootstrap` must exist.

### 5.3 No active Super Admin

This fires only when bootstrap has happened (`admin_super_admin_bootstrapped == 1`) and no account is an active, verified Super Admin, for 5 minutes. The TRD 06 guard makes this impossible through the API, so it means a direct database change, or every Super Admin being suspended, deactivated or deleted outside the API.

First checks:

1. In the database (read-only): `SELECT id, status, email_verified_at FROM users WHERE role = 'super_admin'`. Are Super Admins suspended, deactivated, pending deletion or demoted? Check the TRD 06 audit history (`admin.role.change`, `admin.user.suspend` and direct-SQL evidence).
2. If someone should still be a Super Admin, recover with `bin/admin bootstrap-super-admin --mode break_glass --reason-code lost_access --ticket-ref <ticket>` on an existing active, verified account (TRD 06 §4.2). Then promote a second Super Admin through the console.
3. Before bootstrap the alert is silent by design. A deployment that never runs bootstrap therefore never pages; the release checklist (TRD 06 §12) covers that.

### 5.4 Account purge slow or overdue

`account_deletion_oldest_pending_seconds` is the age of the oldest accepted deletion still `pending`. It is 0 when none is pending, which is a healthy zero. Purges normally finish within minutes:

- **Slow** (more than 2 hours, held 15 minutes): a ticket.
- **Overdue** (more than 24 hours, held 5 minutes): the TRD 04 promise is broken, so it pages.

First checks:

1. Is the cleanup runner alive on some instance? The account job runs inside `cmd/api` (`account_jobs_total{job,result}`). A growing `result="error"` count shows a failing step.
2. API logs for the purge job: a failing batch, a permission error on `VEEA_MAINTENANCE_DATABASE_URL`, or a lock timeout.
3. The operation row: `SELECT id, accepted_at, purge_step FROM account_operations WHERE action = 'delete' AND state = 'pending' ORDER BY accepted_at`. A stuck `purge_step` points at the failing step (TRD 04 §6.2).
4. While pending, the account stays sealed and its email reserved (TRD 04). Never mark it completed by hand.

### 5.5 Email delivery failing

`email_send_total{result}` counts one sample per provider call. `permanent` and `ambiguous` are failures. `retryable` is a transient failure that is retried, so it counts as an attempt but not as a failure; the backlog rules catch retry storms.

- **Ratio rule (normal traffic):** more than 25% failures over 30 minutes with at least 20 calls, held 10 minutes.
- **Low-volume rule:** at least 3 failures and no success in an hour, held 5 minutes. This catches a quiet outage that the ratio rule's volume guard ignores. One failure in an hour fires nothing.

First checks:

1. The provider status page and API key: Resend `VEEA_RESEND_API_KEY`, or SMTP reachability for `VEEA_EMAIL_SENDER=smtp`, and the sending domain's verification (TRD 01 release checks).
2. Which templates fail: `sum by (template, result) (increase(email_send_total{job="veea-api"}[30m]))`.
3. API logs (component `outbox`) for the fixed failure class. Payloads and addresses are never logged.
4. Users can still sign in with a password. OTP-only accounts cannot sign in until delivery recovers.

### 5.6 Outbox backlog growing or stalled

`email_outbox_pending` counts rows with `status = 'pending'`: due now, or waiting at most 4 minutes for a retry.

- **Growing** (`>= 20` and rising over 15 minutes, held 15 minutes): messages arrive faster than they are sent. Codes expire after 10 minutes.
- **Stalled:** at least one message has stayed pending for 20 minutes while the provider was not called once, held 10 more minutes. The worker calls the provider at least every 4 minutes for any pending row (backoff 30 s, 1, 2 and 4 minutes, at most 5 calls). Silence therefore means no worker is running. This works at the lowest traffic: one stuck code is enough.

First checks:

1. Is any instance running the outbox worker (`cmd/api`), and is it leasing? Look for `email_outbox_stale_result_total` increases and worker errors in the logs.
2. If provider calls are happening but failing, follow §5.5.
3. Database health: the worker and the gauge share the API pool.
4. Expired and failed rows are terminalized by the reaper; they leave the backlog but are not separately metered (§9).

## 6. Tests

**Behavior with promtool:** `make -C backend test-alerts` runs `promtool check rules` and then `promtool test rules` on [`veea-alerts.test.yml`](../../backend/monitoring/prometheus/veea-alerts.test.yml). That file is generated by [`gen_tests.py`](../../backend/monitoring/prometheus/gen_tests.py) from readable scenarios, and expected annotations are read from the rule file. The script fails if the generated file is stale. It holds 21 scenarios and 74 checks on representative samples (one sample per minute, two instances where relevant):

| Scenario | Checks firing, recovery and silence |
|---|---|
| Healthy zeros, with traffic and with no traffic at all | none of the 11 alerts fire |
| Scrape fails 20 minutes, then recovers | pending at 2 minutes, firing after 5, cleared after recovery. Super Admin and missing-series rules stay silent while blind |
| No target at all | absent fires after 10 minutes with `job="veea-api"`; scrape-failing does not |
| Scraped but gauges missing | missing-series fires; the Super Admin rule does not treat absence as zero |
| `-1` outbox read | read-failed fires; outbox rules stay silent |
| Fresh deployment (not bootstrapped, 0 Super Admins) | silent |
| Bootstrap, then the last Super Admin is lost, then recovered | silent before bootstrap; pending, firing after 5 minutes, cleared |
| Two instances, one reads `-1` | no Super Admin alert; read-failed for that instance only |
| Unreadable bootstrap marker with 0 Super Admins | no Super Admin alert; read-failed |
| Purge age crossing 24 hours, then completed | overdue after 5 minutes, slow after 15, both clear at 0. A purge under 2 hours is quiet |
| 33% failures at high traffic, then failures stop | ratio fires after 10 minutes and clears; the low-volume rule stays silent |
| Low traffic: 1 failure per hour | silent |
| Low traffic: 3 failures, no success | low-volume fires and clears on a success; the ratio rule is silent (under 20 calls) |
| Same, with the `sent` series missing | still fires (fallback) |
| Backlog rising past 20, then a plateau | growing fires after 15 minutes and clears; stalled is silent while sending |
| Low traffic: one message pending, no provider calls | stalled fires (31 minutes from enqueue + 10 held) |
| One message retried every 4 minutes | not stalled |
| Stalled with `email_send_total` missing | still fires (fallback) |

**Mutation check.** Breaking the rules on purpose fails the suite in every case:

- raising the purge threshold;
- removing the bootstrap gating;
- removing the 20-call volume guard;
- removing either missing-series fallback.

**Rules tied to real metrics.** `backend/monitoring/rules_test.go` scrapes a registry wired like `cmd/api`. It fails if any expression names a metric the service does not export, matches a `result` value `email_send_total` never carries, or omits `job="veea-api"`.

**Gauges against PostgreSQL** (`test/integration/monitoring_test.go`, production router wiring):

- A fresh database exports all four gauges as healthy zeros (`bootstrapped 0`, `active 0`, `purge 0`, `pending 0`).
- After bootstrap: `1` and `1`. Break-glass keeps the first bootstrap time.
- Demoting every Super Admin by SQL gives `active 0` while the marker stays `1`.
- An accepted deletion aged 25 hours reports just over 86400, and returns to 0 after the purge.
- A missing marker table reads `-1`.
- An API promotion to `super_admin` writes the marker.
- The migration 12→13 backfill: marked with the first bootstrap time when bootstrapped, unmarked otherwise, a singleton check, and replay works.

**Unit:** zero-initialized `email_send_total` series and the bootstrap gauge values (`1`, `0`, `-1`); `notify.TemplateNames` covers every template.

Results are recorded in §10.

## 7. Explicit behavior at the edges

- **Bootstrap.** Before the first bootstrap, 0 Super Admins is silent: the marker is 0. After it, 0 pages within 5 minutes. A marker that cannot be read is never treated as "bootstrapped"; it raises the read-failed warning instead.
- **Low traffic.**
  - Ratio rules require 20 calls in their window, so a single failure never pages.
  - The low-volume rule needs 3 failures with no success in an hour.
  - The stalled-outbox rule needs only one message, because it measures absence of provider calls, not a rate.
  - Purge and Super Admin rules read database gauges on every scrape, so they do not depend on traffic.
- **Missing series.**
  - No target: the absent alert.
  - Failing target: the scrape-failing alert.
  - Scraped but a gauge missing: the missing-series alert.
  - A gauge read failure: the read-failed alert.
  - A missing series never satisfies a value rule, so it never looks like a healthy zero or like an incident.
  - The email rules fall back to 0 for missing counter series, and the email counters are pre-created at 0.

## 8. What was validated locally, and what needs shared infrastructure

| Item | Locally (2026-11-15) | Still to verify on shared infrastructure |
|---|---|---|
| Rule syntax and all 11 rules | `promtool check rules`: success | Load into the real Prometheus or ruler version; `promtool` here is v2.49.1, so confirm compatibility if the deployed version differs |
| Rule behavior (firing, recovery, silence) | 21 scenarios and 74 checks pass; mutations caught | Live evaluation against real series and intervals; confirm the scrape interval is 1 minute or shorter |
| Metric names and labels | Go test against the real registry | — |
| Database gauges, marker, migration 13 | PostgreSQL integration tests (§10) | Run `bin/migrate up` to 13 before rolling the binaries; check `admin_super_admin_bootstrapped` after bootstrap |
| Scrape target | Not configured in the repository | Bind `VEEA_METRICS_ADDR` to an internal address; job `veea-api`, one target per instance; keep `/metrics` off both ingresses |
| Alert delivery | Not configured | Alertmanager routes: `critical` pages, `warning` tickets. Fire a test alert end to end |
| Real failure drills | Simulated with samples only | Stop the outbox worker on staging (expect stalled); break the provider key (expect the email rules); hold a purge with a failing step (expect slow); remove a target (expect absent) |

## 9. Out of scope and follow-ups

- **Remaining Product Doc §10 signals:** sign-in failure spikes, OTP send volume and account-creation rate. The metrics exist (`auth_*`); no rules or dashboards yet.
- **Terminal outbox failures** (`failed` and `expired` rows from the reaper) are not metered as a counter. The email and backlog rules cover them indirectly. A counter would allow a precise "codes expired unsent" rule.
- **Dashboards, recording rules, and SLO burn-rate alerting.**
- **Learning sync:** it ships closed (TRD 05); add sync alerts when it opens.

## 10. Verification record — 2026-11-15

Run from `backend/`, against loopback-only disposable PostgreSQL and Mailpit. The migration version is now **13**.

| Check | Actual result |
|---|---|
| `make sqlc-verify` | Generated code reproducible |
| `make check` (gofmt, vet with and without the integration tag, unit tests) | Passed, including `go test ./monitoring` (rule names tied to the registry) |
| `make build` | Passed (`bin/api`, `bin/migrate`, `bin/admin`) |
| `make test-alerts` | `promtool check rules`: SUCCESS, 11 rules. `promtool test rules`: SUCCESS, 21 scenarios and 74 checks. Generated test file up to date |
| Mutation check | 5 deliberate rule breakages, all caught |
| Full race run, PostgreSQL + Mailpit (`go test -race -tags=integration -count=1 -json ./...`) | **1212 passed, 0 failed, 0 skipped** tests and subtests (451 top-level). 21 packages passed; 12 have no test files. Integration package: 774 passed. TRD 08 tests: 4 top-level passed (`TestMonitoring_GaugesBehindTheAlertRules`, `TestMonitoring_PromotionWritesTheMarker`, `TestMigrations_BootstrapMarkerBackfillFrom12`, `TestRulesReferenceOnlyExportedMetricsAndLabels`). Mailpit delivery ran and passed |
| OpenAPI runtime contract | 326 combinations, no violations; only the four pre-existing exceptions unexercised |
| Admin console against real Go (`make test-flutter-admin`) | Go test passed; Dart 6 ran, 6 passed, 0 skipped (bootstrap and promotion now also write the marker) |

**Validated locally:** all 11 rules for syntax, firing, recovery and silence on representative samples (§6), including bootstrap, low traffic and missing series; the gauges and marker against PostgreSQL; and the metric names against the real registry.

**Needs shared infrastructure** (§8): the scrape job and target wiring, Alertmanager routing, evaluation on live series at the deployed Prometheus version, and failure drills on staging.
