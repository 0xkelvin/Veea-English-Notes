# Documentation inventory and content map

**Phase:** 3.1 — prepared for review.
**Structure approval:** The task approves the six core guides, four consolidated feature TRDs
and a dedicated ADR directory. It does not approve replacement prose, new requirements,
new technical decisions or deployment readiness.
**Inventory baseline:** 2026-11-17; source snapshot `05f66c4` on the current `main` branch.
The snapshot identifies the inspected source, not the authority for a requirement or decision.

Return to the [documentation index](README.md) or [ADR inventory](adr/README.md).

## Scope and classification

This is a migration plan, not a consolidation. No source document has been moved, rewritten,
archived or deleted. Every existing TRD is included, including the frontend-owned TRD 07
and the dated Flutter verification record. Relevant backend, product, rollout and recovery
sections are also mapped. Frontend-only documents remain outside the backend migration.

| Classification | Meaning in this plan |
|---|---|
| Keep | Retain the current owner/location or an irreplaceable requirement/provenance record; link from the future guide. |
| Move | In a later reviewed phase, transfer the identified material to one destination with source traceability. |
| Merge | In a later reviewed phase, reconcile related sections into one maintained home, preserving distinct requirements and exceptions. |
| Archive | Preserve dated context/evidence at the existing source path for now. Exclude it from undated implementation authority. This label does not archive a file in Phase 3.1. |
| Delete Later | Candidate duplicate prose only. Remove nothing until content parity, unique semantics, source history and incoming links have been reviewed. |

All destination paths below are relative to `backend/docs/` unless explicitly named otherwise.
Planned paths are code spans, not broken links or claims that pages already exist. Planned
section names are editorial destinations, not newly approved requirements. Secondary
destinations receive links or their own distinct concern, not another editable copy.

Every mapped source's title/preamble and every level-two heading are inventoried. Child
headings, tables, examples, footnotes and appendices inherit that mapping unless an explicit
split follows. Archive rows retain the complete original evidence, not just its summary.

## Source audit checkpoints

The following comparisons were made against the current implementation. They establish
what later writers must verify; they are not new runtime test results.

| Topic | Source evidence | Documentation implication |
|---|---|---|
| Runtime and API ownership | [API entrypoint](../cmd/api/main.go), [composition](../internal/app/app.go), [routes](../internal/auth/httpapi/httpapi.go), [admin routes](../internal/auth/httpapi/admin.go), [OpenAPI](../api/openapi.yaml) | Three binaries (`api`, `migrate`, `admin`); 50 operations across 49 OpenAPI paths. Retain the contract as the endpoint-definition source. |
| Database and generated code | [Migrations](../migrations), [migration README](../migrations/README.md), [SQLC](../sqlc.yaml), [queries](../internal/platform/db/queries) | 15 migrations and 13 query-domain files. The migration README omits 00010/00011 and lists later entries out of order; the backend README names only the original query domains. Record the discrepancy; do not silently copy the incomplete inventories. |
| Isolation and lock exceptions | [Transaction runner](../internal/platform/db/tx.go), [export snapshot](../internal/lifecycle/export.go), [account writers](../internal/identity/accounts) | General READ COMMITTED transactions have retry rules; export uses REPEATABLE READ. Preserve flow-specific lock modes, hash-before-transaction rules and lock ordering. |
| Configuration versus Compose | [Runtime configuration](../internal/platform/config/config.go), [local Compose](../compose.yaml), [env generator](../scripts/compose-env.sh), [production Compose](../compose.production.yaml) | Runtime defaults to SMTP; checked-in local Compose selects Resend. Key generation does not supply the From/API-key settings. Do not turn historical Mailpit smoke results into claims about current Compose behavior. |
| Password policy provenance | [Policy](../internal/identity/password_policy.go), [blocklist README](../internal/identity/blocklist/README.md) | Preserve the original policy decision while linking the actual filtered 5,329-entry blocklist provenance; do not repeat the historical approximately-100k estimate as the implemented count. |
| Test scope | [Makefile](../Makefile), [Resend worker integration test](../internal/notify/resend_integration_test.go), [database harness](../internal/platform/pgtest/pgtest.go), [contract tests](../api/openapi_test.go) | `make test-integration` targets `test/integration`; all integration-tagged packages include additional notify tests. Missing local test configuration can cause skips. Test presence, historical results and current execution are different evidence. |
| Rollout and capability boundaries | [Sync admission](../internal/learning/service.go), [cartridges](../internal/learning/cartridges.go), [plans](../internal/entitlements/entitlements.go), [gate migration](../migrations/00011_learning_sync.sql) | Sync and install code is implemented but ships closed. Catalog/content and install checks differ. Plans are not roles; both plans keep the same sync limits. |
| Operational and recovery boundary | [Maintenance](../internal/maintenance/cleanup.go), [checkpoint implementation](../internal/recoveryledger), [recovery CLI](../cmd/admin/ledger.go), [production grants](../ops/production/grants.sql) | In-process jobs and a local checkpoint adapter exist; independent storage, scheduling and deployment evidence are separate. Describe actual grants rather than assume narrow per-table permissions. |
| Absent compatibility API | [Mounted routes](../internal/auth/httpapi/httpapi.go), [OpenAPI](../api/openapi.yaml), [rollout boundary](../../docs/account-feedback-rollout.md) | Go has no retired phone/feedback API implementation. Preserve the documented compatibility limitation; do not invent a replacement feature. |

## TRD section inventory

### TRD 01 — Authentication foundation

Source: [docs/trd/01-email-authentication-account-foundation.md](../../docs/trd/01-email-authentication-account-foundation.md). All child subsections inherit their parent mapping unless split below.

| Source section | Classification | Future destination | Preservation requirement |
|---|---|---|---|
| Title, status, date, audience and preamble | Keep | Existing source; carry provenance into its reviewed destination | Preserve the original labels, approver/date and amendments. This inventory grants no new approval. |
| 0. How to read this TRD | Merge | Documentation index and `trd/identity-and-access.md` | Retain labels and source authority; distinguish decisions from implementation and release evidence. |
| 1. Scope | Merge | `trd/identity-and-access.md` | Preserve scope, exclusions and all approved flows; retain deferred items as deferred. |
| 2. Architecture | Move | `architecture.md` | Describe real module dependencies, standard HTTP wiring and the three binaries; keep original rationale through ADR references. |
| 3. Identity model | Merge | `trd/identity-and-access.md` | Preserve stable UUID identity, normalization, eligibility and account standing rules. |
| 4. OTP challenges and signup binding | Merge | `trd/identity-and-access.md` | Preserve challenge binding, inert starts, purpose restrictions, expiry and supersession rules. |
| 5. API contract | Merge | `api.md` and `trd/identity-and-access.md` | Keep protocol conventions and unique flow/retry semantics; use OpenAPI for wire definitions. See subsection splits. |
| 6. PostgreSQL schema | Merge | `database.md` and `operations.md` | Reconcile schema inventory with all current migrations; cleanup procedures have one operations home. |
| 7. Transaction rules | Merge | `database.md` with flow references from `trd/identity-and-access.md` | Preserve lock order/modes, transaction boundaries, failed-proof commits and flow-specific exceptions. |
| 8. Sessions, tokens and email | Merge | `trd/identity-and-access.md` and `operations.md` | Separate session protocol from email delivery/encryption operations; retain all retry and retention consequences. |
| 9. Password handling | Merge | `trd/identity-and-access.md` | Preserve password policy and Argon2 resource limits; link colocated blocklist provenance rather than copy it. |
| 10. Rate limits | Merge | `trd/identity-and-access.md` | Preserve rule/subject/window semantics and committed denial behavior; database clock and cooldown boundaries remain explicit. |
| 11. Audit, logging and metrics | Merge | `operations.md` with acceptance references from `trd/identity-and-access.md` | Keep audit producer/test matrix, log hygiene and metric semantics distinct from deployed monitoring. |
| 12. Testing | Merge | `development.md` and `trd/identity-and-access.md`; release checks in `operations.md` | Retain every AC identifier and concurrency/retry case. Dated results remain evidence at the original source. |
| 13. Configuration | Move | `development.md` | One environment reference derived from the loader, CLI and Compose; preserve key formats and rotation constraints. |
| 14. Decisions | Move | `adr/` (candidate extraction only) | Retain R1–R15, recorded statuses/dates, alternatives and costs; keep provider selection provenance distinct. |
| 15. Delivery plan | Archive | Existing source path (retained) | Preserve tickets and original sequence as delivery history; do not present it as a current branch/PR-based authority. |

Subsection splits for [docs/trd/01-email-authentication-account-foundation.md](../../docs/trd/01-email-authentication-account-foundation.md):

| Source subsection | Classification | Future destination | Preservation requirement |
|---|---|---|---|
| Version-change notes before §0 | Archive | Existing source path (retained) | Preserve amendments and the order of policy changes; link relevant provenance from later ADRs. |
| §5.1 conventions | Move | `api.md` | Retain JSON/error/request-ID/no-store rules and the separate authentication schemes. |
| §5.2 shared shapes and §5.3 endpoint definitions | Delete Later | OpenAPI remains canonical; `api.md` links it | Only duplicate wire-definition prose is a deletion candidate after parity review. Preserve unique requirements, error meanings, examples needed for acceptance and links to §5.4. |
| §5.4 retry and lost-response outcomes (AC-25) | Merge | `trd/identity-and-access.md` | Preserve operation-specific uncertainty and retry outcomes; never replace these with a generic idempotency claim. |
| §6.10 cleanup jobs and §7.8 outbox worker | Move | `operations.md` | Retain schedule, bounded batches, lock ownership, lease/send/result ordering and cancellation behavior. |
| §7.1 lock order/modes and §7.2–§7.7 flow transactions | Merge | `database.md` and `trd/identity-and-access.md` | Database guide owns the shared lock table; identity TRD keeps per-flow proof/commit semantics and references the shared rule. |
| §8.1 and §8.4–§8.7 sessions/rotation/retention/cap/revocation | Merge | `trd/identity-and-access.md` | Keep opaque-token trust, no grace, replay scope, exact retention and session cap consequences. |
| §8.2 payload protection and §8.3 email delivery | Move | `operations.md` | Preserve key rotation, encryption binding, duplicate-send budget, ambiguous outcomes and provider readiness limits. |
| §11.1 audit actions (AC-24) | Merge | `trd/identity-and-access.md`; shared audit mechanics in `operations.md` | Keep action-to-producer-to-test rows, including later feature amendments; do not collapse the matrix to a checklist item. |
| §11.2 log hygiene and §11.3 metrics | Move | `operations.md` | Retain allowlists, redaction constraints, fixed label values and transaction-sensitive metric rules. |
| §12.1 harness | Move | `development.md` | Distinguish unit, integration, notify integration, client harness and restore-drill scopes and skip conditions. |
| §12.2 acceptance matrix and §12.3 additional tests | Merge | `trd/identity-and-access.md` | Carry every AC ID and technical test requirement, including race, rollback, ownership and lost-response cases. |
| §12.4 verification before release | Merge | `operations.md` | Preserve provider/device/restore/ingress gates and links to shared staging acceptance; local tests cannot close external gates. |

### TRD 02 — Session management

Source: [docs/trd/02-session-management.md](../../docs/trd/02-session-management.md). All child subsections inherit their parent mapping unless split below.

| Source section | Classification | Future destination | Preservation requirement |
|---|---|---|---|
| Title, status, date, audience and preamble | Keep | Existing source; carry provenance into its reviewed destination | Preserve the original labels, approver/date and amendments. This inventory grants no new approval. |
| 1. Authority and scope | Merge | `trd/identity-and-access.md` | Retain scope and original authority; keep bearer/lock decisions traceable. |
| 2. Existing model and identity | Merge | `trd/identity-and-access.md` | Preserve live/listable criteria, current-session identity and device metadata limits. |
| 3. HTTP contract | Merge | `trd/identity-and-access.md` with `api.md` | Keep ownership/error semantics; reference OpenAPI instead of copying response schemas. |
| 4. Revocation and transaction design | Merge | `trd/identity-and-access.md` and `database.md` | Keep ownership locks, revocation reasons and current-session restrictions; reference shared lock order. |
| 5. Defined concurrent outcomes | Merge | `trd/identity-and-access.md` | Retain both-order race outcomes and replay/lost-response behavior. |
| 6. Audit and observability | Move | `operations.md` with feature audit references from `trd/identity-and-access.md` | Retain revocation audit and metric meanings. |
| 7. Router-level PostgreSQL verification | Merge | `trd/identity-and-access.md` acceptance mapping; `development.md` harness instructions | Preserve router-level concurrency, authorization, rollback and rate-limit cases. |
| 8. Decision record | Move | `adr/` (candidate extraction only) | Preserve the original session-management decision record and its approval provenance. |
| 9. Implementation and verification evidence | Archive | Existing source path (retained) | Keep dated implementation/results separate from the maintained acceptance matrix. |

### TRD 03 — Profile and email change

Source: [docs/trd/03-account-profile-email-change.md](../../docs/trd/03-account-profile-email-change.md). All child subsections inherit their parent mapping unless split below.

| Source section | Classification | Future destination | Preservation requirement |
|---|---|---|---|
| Title, status, date, audience and preamble | Keep | Existing source; carry provenance into its reviewed destination | Preserve the original labels, approver/date and amendments. This inventory grants no new approval. |
| 1. Authority and approved decisions | Merge | `trd/identity-and-access.md` and `adr/` (candidate extraction only) | Retain named decisions, exact scope and provenance; new prose does not reapprove earlier proposals. |
| 2. Required OTP-core changes — specified before shared-code edits | Merge | `trd/identity-and-access.md` and `database.md` | Preserve paired-proof core ownership, address locks and shared OTP constraints. |
| 3. Profile contract | Merge | `trd/identity-and-access.md` with `api.md` | Preserve profile validation, revision conflicts and ownership; OpenAPI owns shapes. |
| 4. Email API and semantics | Merge | `trd/identity-and-access.md` | Preserve paired proof, same-UUID cutover, uniqueness races, revocation and lost-response semantics. |
| 5. Schema, messages and audit | Merge | `database.md` and `operations.md` with `trd/identity-and-access.md` audit requirements | Retain migration, template and audit obligations without duplicate schema definitions. |
| 6. Acceptance and verification | Merge | `trd/identity-and-access.md` acceptance mapping | Keep all proof, race, profile conflict, rollback and session effect cases. |
| 7. Conflicts resolved from the draft | Archive | Existing source path (retained); reviewed decisions linked from ADRs | Preserve draft resolution history; do not promote every discarded alternative into an active requirement. |
| 8. Implementation and verification record — 2026-11-14 | Archive | Existing source path (retained) | Preserve dates and recorded results; carry source/test references into the maintained acceptance mapping. |

### TRD 04 — Account lifecycle

Source: [docs/trd/04-account-lifecycle-data-rights.md](../../docs/trd/04-account-lifecycle-data-rights.md). All child subsections inherit their parent mapping unless split below.

| Source section | Classification | Future destination | Preservation requirement |
|---|---|---|---|
| Title, status, date, audience and preamble | Keep | Existing source; carry provenance into its reviewed destination | Preserve the original labels, approver/date and amendments. This inventory grants no new approval. |
| 1. Authority, scope and decision status | Keep | Existing source path (retained); authority references in `trd/account-lifecycle.md` | Retain the baseline and Proposed/Approved distinction. |
| 1.1 Approved decisions and implementation choices — 2026-11-14 | Move | `adr/` (candidate extraction only) with requirements in `trd/account-lifecycle.md` | Preserve the 2026-11-14 approval and all superseding implementation choices. |
| 2. Current Go behavior and data inventory | Archive | Existing source path (retained) | Preserve the inspected pre-feature inventory; describe the current schema separately in the database guide. |
| 3. Proposed state model, actors and access | Merge | `trd/account-lifecycle.md` | Reconcile original proposed state rules with §1.1/§12; retain rejected/inactive-state access boundaries. |
| 4. Proposed proof and capability protocol | Merge | `trd/account-lifecycle.md` | Preserve action-scoped Rights capabilities, mailbox proof, operation binding and lost-response recovery. |
| 5. Proposed export flow and contents | Merge | `trd/account-lifecycle.md` | Preserve export scope, eligibility, snapshot, expiry and invalidation requirements; include later amendments. |
| 6. Proposed deletion flow, receipt and old devices | Merge | `trd/account-lifecycle.md` | Retain acceptance versus completion, bounded purge, email release, old-device handling and receipt constraints. |
| 7. Proposed erasure and retention policy | Merge | `operations.md` with requirements in `trd/account-lifecycle.md` | Preserve approved retention values, minimization and infrastructure/provider caveats. |
| 8. Proposed API, persistence and transaction design | Merge | `trd/account-lifecycle.md` and `database.md`; `api.md` references OpenAPI | Keep proof/transaction design and owned-table responsibilities; separate duplicated wire definitions. |
| 9. Proposed audit and operational evidence | Merge | `operations.md` and `trd/account-lifecycle.md` | Retain audit events and which operational evidence is still required. |
| 10. Proposed acceptance tests and verification limits | Merge | `trd/account-lifecycle.md` acceptance mapping | Preserve every acceptance, security, concurrency and verification-limit case. |
| 11. Decisions Nin must approve before implementation | Move | `adr/` (candidate extraction only) | Preserve the original question/decision history and link §1.1/§12 resolutions; do not treat historical questions as newly unresolved. |
| 12. Implementation and verification record — 2026-11-14 | Archive | Existing source path (retained); active requirements split below | Keep dated evidence; explicitly extract active retention/recovery/provider/release obligations before any later retirement. |

Subsection splits for [docs/trd/04-account-lifecycle-data-rights.md](../../docs/trd/04-account-lifecycle-data-rights.md):

| Source subsection | Classification | Future destination | Preservation requirement |
|---|---|---|---|
| §8.1 duplicated wire definitions | Delete Later | OpenAPI; `trd/account-lifecycle.md` keeps protocol requirements | Only after comparison, preserve capability scope and distinct acceptance/status/download semantics; no source deletion in this phase. |
| §8.2 persistence/OTP and §8.3 lock order | Merge | `database.md` with `trd/account-lifecycle.md` | Preserve OTP-core-only proof writes, address fence order, acting-session checks and purge/export participation. |
| §12.1 implementation and §12.3 resolved findings | Merge | `trd/account-lifecycle.md` source/test mapping; original evidence retained | Distinguish behavioral corrections from dated execution claims; preserve rollback, receipt and size-bound safeguards. |
| §12.2 commands/results | Archive | Existing source path (retained); reusable command instructions in `development.md` | Keep exact run/date context without treating historical totals as new verification. |
| §12.3a entitlement amendment | Merge | `trd/account-lifecycle.md` and `trd/content-and-entitlements.md` | Preserve export schema 3, plan inclusion, grant retention/bounds and exclusion of staff/ticket metadata. |
| §12.4 application retention versus deployment | Merge | `operations.md` | Keep enforced database behavior distinct from backup/WAL, log and provider obligations. |
| §12.5 restore-time deletion replay and §12.5a independent checkpoints | Move | `recovery.md` | Preserve the stop boundary, ordered procedure, independent coverage requirements and source/backup lineage. |
| §12.6 provider retention | Move | `operations.md` | Retain unverified provider obligations; code and local tests do not certify provider retention. |
| §12.7 release gates | Merge | `operations.md` | Retain all open gates and links to the shared staging checklist. |

### TRD 05 — Learning sync

Source: [docs/trd/05-learning-data-sync.md](../../docs/trd/05-learning-data-sync.md). All child subsections inherit their parent mapping unless split below.

| Source section | Classification | Future destination | Preservation requirement |
|---|---|---|---|
| Title, status, date, audience and preamble | Keep | Existing source; carry provenance into its reviewed destination | Preserve the original labels, approver/date and amendments. This inventory grants no new approval. |
| 1. Authority and labels | Keep | Existing source path (retained); requirements in `trd/learning-sync.md` and provenance in ADRs | Retain approved requirements and D1–D10; preserve amendments to lifecycle and product requirements. |
| 2. Learning data baseline before this implementation | Archive | Existing source path (retained) | Retain pre-implementation device/prototype inventory; do not present it as current Go behavior. |
| 3. V1 scope **[Decided: D1]** | Merge | `trd/learning-sync.md` | Preserve v1 vocabulary-only scope, explicit local-only exclusions and cartridge amendments. |
| 4. Ownership **[Decided: D4]** | Merge | `trd/learning-sync.md` | Keep authenticated ownership, owner-scoped IDs/tombstones and no cross-account adoption. |
| 5. Revisions, writers and mutations **[Decided: D5]** | Merge | `trd/learning-sync.md` | Retain writer, epoch, sequence, expiry/deduplication and partial-prefix processing semantics. |
| 6. Conflict resolution **[Decided: D2]** | Merge | `trd/learning-sync.md` | Retain server-accepted conflict rules and per-field behavior. |
| 7. Deletion propagation and tombstones **[Decided: D5]** | Merge | `trd/learning-sync.md` | Keep deletion precedence, compaction and content-free tombstone retention. |
| 8. Resets | Merge | `trd/learning-sync.md`; restoration procedure in `recovery.md` | Keep reset reasons, review behavior and snapshot/catch-up contract; link to one restore procedure. |
| 9. Local partitions, guest data and account caches | Merge | `trd/learning-sync.md` client obligations; detailed client evidence stays in its source | Preserve consent, exclusions, account isolation, backup provenance and legacy-untagged safety; do not copy Flutter implementation into Go guides. |
| 10. Limits and quota **[Decided: D7]** | Merge | `trd/learning-sync.md` | Keep exact limits, validation/counting rules and capacity-change outcomes. |
| 11. TRD 04 integration **[Decided: D7]** | Merge | `trd/account-lifecycle.md` with protocol obligations in `trd/learning-sync.md` | Preserve export encoding/bounds, bounded purge and restoration fencing; link shared owned-data rules. |
| 12. API **[Implemented]** | Merge | `trd/learning-sync.md`; `api.md` references OpenAPI | Retain sync semantics and error meanings without another endpoint/schema catalog. |
| 13. Persistence (migration 00011) **[Implemented]** | Move | `database.md` with ownership references in `trd/learning-sync.md` | Reconcile migration 00011 with later schema changes; preserve RESTRICT and owner-head obligations. |
| 14. Transactions and lock order **[Implemented]** | Move | `database.md` with flow-specific references in `trd/learning-sync.md` | Keep the account/session/head lock order and transaction boundaries. |
| 15. Acceptance tests | Merge | `trd/learning-sync.md` acceptance mapping; `development.md` execution scopes | Preserve server and Flutter acceptance IDs; backend tests cannot certify device behavior. |
| 16. Remaining implementation blockers | Merge | `trd/learning-sync.md` and `operations.md` | Reconcile each recorded blocker with later closeout/source evidence; retain unresolved release gates. |
| 17. Implementation and verification record — 2026-11-14 | Archive | Existing source path (retained); active contract corrections split below | Preserve the dated implementation record, test totals and limitations. |

Subsection splits for [docs/trd/05-learning-data-sync.md](../../docs/trd/05-learning-data-sync.md):

| Source subsection | Classification | Future destination | Preservation requirement |
|---|---|---|---|
| §1.2 D1–D10 and §1.3 lifecycle amendment | Move | `adr/` (candidate extraction only); requirements remain in `trd/learning-sync.md`/`trd/account-lifecycle.md` | Retain exact decision IDs and product authority; do not duplicate decision rationale in the TRD. |
| §8.2 database restore and §11.3 restoration fencing | Merge | `recovery.md` procedure; `trd/learning-sync.md` epoch/protocol requirements | Preserve deletion replay before access, epoch rotation, old-queue separation and the prohibition on automatic replay. |
| §11.1 export and §11.2 purge | Merge | `trd/account-lifecycle.md`; `trd/learning-sync.md` canonical encoding and ownership requirements | Preserve amendments from TRD 09/10 and all serialized-size bounds; one owner for overall export/purge requirements. |
| §15.1 server and §15.2 Flutter acceptance cases | Merge | `trd/learning-sync.md` acceptance mapping | Keep every numbered item and its source/test/evidence/release status; no silent removal of client-only gates. |
| §17.1 implementation source references and §17.2 contract corrections | Merge | `trd/learning-sync.md` source/test mapping and `api.md` | Carry current corrections into the future guide; retain original dated evidence in place. |
| §17.3 commands/results | Archive | Existing source path (retained); reusable harness instructions in `development.md` | Preserve run context and local-only limitations; do not reuse historical passing totals. |

### TRD 06 — RBAC administration

Source: [docs/trd/06-rbac-user-administration-api.md](../../docs/trd/06-rbac-user-administration-api.md). All child subsections inherit their parent mapping unless split below.

| Source section | Classification | Future destination | Preservation requirement |
|---|---|---|---|
| Title, status, date, audience and preamble | Keep | Existing source; carry provenance into its reviewed destination | Preserve the original labels, approver/date and amendments. This inventory grants no new approval. |
| 0. How to read this TRD | Keep | Existing source path (retained); documentation labels in index | Preserve the original authority and status vocabulary. |
| 1. Authority, baseline and scope | Merge | `trd/identity-and-access.md` | Keep scope, baseline caveats and approved upstream inputs. |
| 2. Approved decisions (Nin, 2026-11-15) | Move | `adr/` (candidate extraction only) | Retain named approver/date and D1–D4 provenance. |
| 3. Actor–action–target matrix (approved, D1) | Merge | `trd/identity-and-access.md` | Preserve the full actor/action/target matrix; do not replace it with a generic staff check. |
| 4. Super Admin provisioning and protection (approved, D2 and D3) | Merge | `trd/identity-and-access.md`; CLI procedure in `operations.md` and lock mechanics in `database.md` | Keep first bootstrap, break-glass, last-Super-Admin guard and owner-flow amendments. |
| 5. When changes take effect (approved, D4) | Merge | `trd/identity-and-access.md` | Retain next-request role effects, session revalidation and suspension semantics. |
| 6. API contract | Merge | `trd/identity-and-access.md` with `api.md` | Retain visibility, allowed actions, pagination, refusal/retry meanings and ticket/reason rules; OpenAPI owns wire definitions. |
| 7. Persistence: migration 00012 | Move | `database.md` | Keep migration 00012 and revision/suspension consistency constraints. |
| 8. Transactions and lock order | Move | `database.md` with authorization revalidation requirements in `trd/identity-and-access.md` | Preserve sorted actor/target locking, acting session and guard ordering. |
| 9. Audit, logging and metrics | Merge | `operations.md` with audit producer mapping in `trd/identity-and-access.md` | Keep events and fixed metrics; later plan/history requirements stay explicit. |
| 9b. Plan management (TRD 09, added 2026-11-15) | Merge | `trd/content-and-entitlements.md`; authority references in `trd/identity-and-access.md` | Keep plan-change policy, self-management refusal and role/plan separation. |
| 9a. Per-account audit history (added 2026-11-15) | Merge | `trd/identity-and-access.md` | Retain the explicit audit-history field allowlist, visibility, cursor tie-breaker and retention behavior. |
| 10. Code map | Move | `architecture.md` with source/test links in `trd/identity-and-access.md` | Update path references from current code when writing; preserve behavioral evidence. |
| 11. Router-level PostgreSQL tests | Merge | `trd/identity-and-access.md` acceptance mapping; `development.md` harness instructions | Keep matrix, rollback, stale-role/status, race and last-Super-Admin cases. |
| 12. Release gates | Merge | `operations.md` | Preserve ingress/network, bootstrap and release acceptance gates. |
| 13. Implementation and verification record — 2026-11-15 | Archive | Existing source path (retained); active history requirements already mapped | Keep dated verification and audit-history addendum; do not replace current acceptance mapping with totals. |

### TRD 07 — Frontend-owned admin console

Source: [docs/trd/07-admin-console.md](../../docs/trd/07-admin-console.md). All child subsections inherit their parent mapping unless split below.

| Source section | Classification | Future destination | Preservation requirement |
|---|---|---|---|
| Title, status, date, audience and preamble | Keep | Existing source; carry provenance into its reviewed destination | Preserve the original labels, approver/date and amendments. This inventory grants no new approval. |
| 1. Authority and inputs | Keep | Existing source path (retained) | Frontend-owned scope/authority; link from the backend index. |
| 2. Location and stack | Keep | Existing source path (retained) | Do not migrate frontend stack, credential storage or UI implementation into Go guides. |
| 3. Deployment | Merge | `operations.md` backend ingress obligations; frontend setup remains here | Retain approved same-origin/operator-network/public-edge requirements and original provenance. |
| 4. Sign-in and session | Keep | Existing source path (retained); `trd/identity-and-access.md` owns backend session contract | Keep UI flow here; link the canonical backend behavior rather than duplicate it. |
| 5. The first operator workflow | Keep | Existing source path (retained) | Frontend operator workflow remains owned by the console document. |
| 5b. Plans (TRD 09, 2026-11-15) | Keep | Existing source path (retained); `trd/content-and-entitlements.md` owns backend entitlement requirements | Keep plan UI here; preserve the cross-product acceptance link. |
| 5a. Audit history tab (added 2026-11-15) | Keep | Existing source path (retained); `trd/identity-and-access.md` owns backend audit visibility | Keep audit tab/UI here; no widening of the backend field allowlist. |
| 6. Refusals and messages | Keep | Existing source path (retained); backend refusal semantics in `trd/identity-and-access.md`/`api.md` | Preserve the UI mapping for every server refusal without moving UI content. |
| 7. Permission changes while the console is open | Keep | Existing source path (retained); backend revalidation contract in `trd/identity-and-access.md` | Keep console state behavior and backend trust boundary distinct. |
| 8. API and deployment gaps (recorded, not blocking) | Keep | Existing source path (retained); backend/deployment gaps referenced by `operations.md` | Do not interpret a recorded nonblocking gap as an implemented capability. |
| 9. Code map | Keep | Existing source path (retained) | Frontend code map remains colocated with its owner. |
| 10. Verification — 2026-11-15 | Archive | Existing source path (retained); harness links in `development.md` | Retain dated frontend/real-Go verification and remaining deployment limits. |
| 11. Decision record | Keep | Existing source path (retained); relevant backend candidates in ADR inventory | Retain the frontend decision record; only extract backend architectural choices with scoped provenance. |

Subsection splits for [docs/trd/07-admin-console.md](../../docs/trd/07-admin-console.md):

| Source subsection | Classification | Future destination | Preservation requirement |
|---|---|---|---|
| §3.1 deployment decision (Nin, 2026-11-15) | Merge | `operations.md` and evidence-backed ADR candidate | Preserve approved ingress constraints; implementation and edge verification remain separate. |
| §3.2 local development | Keep | Existing source path (retained); `development.md` links the Go integration harness | Preserve frontend commands here and avoid a second maintained console setup guide. |
| §10.1 Premium plan UI verification | Archive | Existing source path (retained) | Preserve dated integration evidence, without treating it as production acceptance. |

### TRD 08 — Monitoring and alerting

Source: [docs/trd/08-monitoring-alerting.md](../../docs/trd/08-monitoring-alerting.md). All child subsections inherit their parent mapping unless split below.

| Source section | Classification | Future destination | Preservation requirement |
|---|---|---|---|
| Title, status, date, audience and preamble | Keep | Existing source; carry provenance into its reviewed destination | Preserve the original labels, approver/date and amendments. This inventory grants no new approval. |
| 1. Authority and inputs | Keep | Existing source path (retained); authority references in `operations.md` | Retain input/decision provenance. |
| 2. Metric inventory | Move | `operations.md` | Reconcile with the actual registry; retain metric names, labels and gauge sentinel meanings. |
| 3. Stack and conventions | Move | `operations.md` | Keep scrape assumptions and separation between implemented rules and provisioned monitoring. |
| 4. Service changes made for alerting | Move | `architecture.md` and `operations.md` | Preserve startup series and durable bootstrap marker responsibilities. |
| 5. Rules and operator actions | Move | `operations.md` | Keep all eleven alert rules, thresholds, aggregation, operator actions and ownership. |
| 6. Tests | Move | `development.md`; alert acceptance in `operations.md` | Preserve promtool fixture/scenario evidence and registry linkage; do not edit generated scenarios by hand. |
| 7. Explicit behavior at the edges | Move | `operations.md` | Keep missing-series/read-failure/bootstrap/low-volume edge behavior and tested limitations. |
| 8. What was validated locally, and what needs shared infrastructure | Move | `operations.md` | Preserve local versus shared-infrastructure evidence and explicit external verification work. |
| 9. Out of scope and follow-ups | Keep | Existing source path (retained); future scope tracked by `operations.md` | Keep unimplemented signals/dashboards/follow-ups labeled as such. |
| 10. Verification record — 2026-11-15 | Archive | Existing source path (retained) | Preserve dates, versions and recorded local results; do not imply deployed alert routing. |

### TRD 09 — Entitlements

Source: [docs/trd/09-free-premium-entitlements.md](../../docs/trd/09-free-premium-entitlements.md). All child subsections inherit their parent mapping unless split below.

| Source section | Classification | Future destination | Preservation requirement |
|---|---|---|---|
| Title, status, date, audience and preamble | Keep | Existing source; carry provenance into its reviewed destination | Preserve the original labels, approver/date and amendments. This inventory grants no new approval. |
| 1. Decisions (Nin, 2026-11-15) | Move | `adr/` (candidate extraction only); requirements in `trd/content-and-entitlements.md` | Retain E1–E5, approver/date and the later cartridge amendment. |
| 2. Capabilities by plan | Merge | `trd/content-and-entitlements.md` | Preserve plan-independent data rights/sync and the first gated cartridge capability. |
| 3. Model | Merge | `trd/content-and-entitlements.md` | Retain role/plan separation, effective-plan semantics and expiry behavior. |
| 4. Storage: migration `00014_entitlements.sql` | Move | `database.md`; feature constraints in `trd/content-and-entitlements.md` | Keep migration 00014, retained history bounds and database function ownership. |
| 5. Checks and effects | Merge | `trd/content-and-entitlements.md` | Preserve database-time checks, no data/session/role side effects and stale revision behavior. |
| 6. API (OpenAPI `1.7.0-trd09`) | Merge | `trd/content-and-entitlements.md` with `api.md` | Keep grant authority, audit and retry semantics; reference OpenAPI definitions. |
| 7. Owner export (schema 3) and its bound | Merge | `trd/account-lifecycle.md` with section ownership in `trd/content-and-entitlements.md` | Preserve schema 3, bounded plan/grant export, and staff/ticket exclusion. |
| 8. Contracts preserved | Merge | `trd/content-and-entitlements.md` | Keep every unchanged-account/data-rights/sync guarantee. |
| 9. Tests | Merge | `trd/content-and-entitlements.md` acceptance mapping; `development.md` test scopes | Preserve expiry boundaries, concurrency, authority, isolation, audit/export and retention cases. |
| 10. Contract changes and open points | Merge | `trd/content-and-entitlements.md` | Resolve historical open points only with recorded decisions or source evidence; retain genuinely open questions. |
| 11. Verification record — 2026-11-15 | Archive | Existing source path (retained) | Preserve local verification date/results and limitations. |

### TRD 10 — Cartridges

Source: [docs/trd/10-server-delivered-cartridges.md](../../docs/trd/10-server-delivered-cartridges.md). All child subsections inherit their parent mapping unless split below.

| Source section | Classification | Future destination | Preservation requirement |
|---|---|---|---|
| Title, status, date, audience and preamble | Keep | Existing source; carry provenance into its reviewed destination | Preserve the original labels, approver/date and amendments. This inventory grants no new approval. |
| 1. Approved decisions | Move | `adr/` (candidate extraction only); requirements in `trd/content-and-entitlements.md` | Preserve approval/date, scope and content-classification decisions. |
| 2. Technical choices | Merge | `trd/content-and-entitlements.md`; schema detail in `database.md` | Separate approved requirements from technical choices; retain stability, immutability and cumulative-version invariants. |
| 3. HTTP contract | Merge | `trd/content-and-entitlements.md` with `api.md` | Keep capability/refusal/retry semantics; OpenAPI owns endpoint and payload definitions. |
| 4. Flutter installation and local state | Merge | `trd/content-and-entitlements.md` and `trd/learning-sync.md` client obligations; existing UI detail retained | Preserve exact version/epoch across uncertainty, account scoping, review/discard/retry and offline/downgrade guarantees. |
| 5. Export, purge and size | Merge | `trd/account-lifecycle.md` with `trd/content-and-entitlements.md` section bounds and `database.md` ownership rules | Preserve installation watermark export/purge and the complete serialized-size derivation. |
| 6. Verification requirements | Merge | `trd/content-and-entitlements.md` acceptance mapping | Keep publication, plan expiry, concurrency, quota, retry, isolation, export and purge requirements. |
| 7. Operator publishing | Move | `operations.md` | Keep audited CLI publication, input/ticket validation and operator authority. |
| 8. Rollout dependencies | Merge | `operations.md` with feature gates in `trd/learning-sync.md`/`trd/content-and-entitlements.md` | Keep synthetic fixtures versus approved real content, device/deployment dependencies and the closed install gate. |
| 9. Implementation and verification record | Archive | Existing source path (retained) | Preserve local verification and outstanding real content/device/deployment limits. |

### TRD 05 companion — Flutter verification evidence

Source: [docs/trd/05-flutter-verification.md](../../docs/trd/05-flutter-verification.md). All child subsections inherit their parent mapping unless split below.

| Source section | Classification | Future destination | Preservation requirement |
|---|---|---|---|
| Title, status, date, audience and preamble | Keep | Existing source; carry provenance into its reviewed destination | Preserve the original labels, approver/date and amendments. This inventory grants no new approval. |
| Takeover inventory | Archive | Existing source path (retained) | Preserve takeover/index history as dated context; never use a branch as current behavioral authority. |
| Completed behavior | Archive | Existing source path (retained); contract obligations referenced from `trd/learning-sync.md` | Keep dated completed-behavior evidence; source must verify current implementation. |
| Commands and actual results | Archive | Existing source path (retained); reusable instructions linked from `development.md` | Keep exact commands/results and local-only boundaries. |
| §15.2 result mapping | Keep | Existing source path (retained); acceptance links in `trd/learning-sync.md` | Retain every §15.2 item-to-evidence mapping and unresolved external check. |
| Flutter → Go integration closeout — 2026-11-15 | Archive | Existing source path (retained); current client obligations referenced by `trd/identity-and-access.md`/`trd/learning-sync.md` | Preserve Go integration closeout, storage/receipt/retry constraints, commands and remaining release gates. |

## Supporting documentation section inventory

Backend-specific rules and current procedures move only after the later checklist passes.
Product and frontend records retain their owners; future backend pages link their requirements
and evidence rather than copying their whole documents.

### Backend README

Source: [backend/README.md](../../backend/README.md). All child subsections inherit their parent mapping unless split below.

| Source section | Classification | Future destination | Preservation requirement |
|---|---|---|---|
| Title, status, date, audience and preamble | Keep | Existing source; carry provenance into its reviewed destination | Preserve the original labels, approver/date and amendments. This inventory grants no new approval. |
| Layout | Move | `architecture.md`; concise links remain in backend README | Preserve all three binaries and real package boundaries; refresh outdated comments from implementation. |
| Configuration | Move | `development.md` | Separate runtime defaults, Compose overrides, CLI/test inputs, key formats and required fields. |
| Endpoints | Delete Later | OpenAPI; `api.md` contains usage conventions | Only remove duplicated endpoint-definition prose after unique behavior/retry/security statements have a mapped home and parity is checked. |
| Commands | Merge | `development.md`; short common-command entry retained | Preserve invocation directory, toolchain prerequisites and command scope. |
| Local Docker Compose | Move | `development.md` | Preserve project/env selection, actual Resend wiring, loopback ports and volume/key persistence; retain historical SMTP evidence separately. |
| Production Docker (Resend, no Mailpit) | Move | `operations.md` | Preserve migration/grants/API startup ordering, network boundaries, role/grant realities and no-wipe behavior. |
| Schema and queries | Move | `database.md` | Correct the complete migration/query inventory against source; retain SQLC reproducibility and editing rules. |
| Email | Move | `operations.md`; local sender setup in `development.md` | Preserve payload encryption, worker outcomes, duplicate delivery and live-provider verification boundaries. |
| Integration tests | Move | `development.md` | Preserve safe local database harness, tags, skip conditions and suite-scope distinctions. |
| Session management (TRD 02) | Merge | `trd/identity-and-access.md`; operational instructions in `development.md` | Keep ownership/revocation behavior while removing future duplicate implementation descriptions. |
| Account profile and email change (TRD 03) | Merge | `trd/identity-and-access.md`; nested test/alert/publication material split below | Preserve email cutover semantics and distinct client harnesses, alert tests and cartridge CLI instructions. |

Subsection splits for [backend/README.md](../../backend/README.md):

| Source subsection | Classification | Future destination | Preservation requirement |
|---|---|---|---|
| Introduction, staging/recovery links and design authority | Keep | `backend/README.md`; links to index/core pages | Retain a useful landing page; source/approval/deployment authority must remain distinct. |
| Local Compose historical smoke/result paragraphs | Archive | Existing source path (retained) | Preserve the stated SMTP setup and execution date; do not promote them into current Resend startup evidence. |
| Flutter → Go local end-to-end checks | Move | `development.md` | Preserve local-only harness prerequisites, tags and rollout boundary; link dated evidence rather than copy it. |
| Admin console → Go local end-to-end checks | Move | `development.md` | Keep same-origin/staff contract coverage; console UI remains frontend-owned. |
| Alert rules | Move | `development.md` command reference; `operations.md` behavior | Keep registry/promtool checks distinct from installed monitoring/routing. |
| Cartridge publishing | Move | `operations.md` | Preserve input/ticket validation, audit evidence and operator-only access. |

### Independent deletion-ledger recovery

Source: [docs/deletion-ledger-recovery.md](../../docs/deletion-ledger-recovery.md). All child subsections inherit their parent mapping unless split below.

| Source section | Classification | Future destination | Preservation requirement |
|---|---|---|---|
| Title, status, date, audience and preamble | Keep | Existing source; carry provenance into its reviewed destination | Preserve the original labels, approver/date and amendments. This inventory grants no new approval. |
| 1. Acceptance, coverage and the stop boundary | Move | `recovery.md` | Preserve DB acceptance versus independent publication, coverage monotonicity, source lineage, stop conditions and all cutoff requirements. |
| 2. Provision independent custody (deployment prerequisite) | Move | `recovery.md` | Preserve independent key/source custody, filesystem guarantees, initialization restrictions, schedule proposals and alert responsibilities. |
| 3. Recover without the original database | Move | `recovery.md` | Preserve recover/status independence from the source DB, all flags, isolated restore order, refusal conditions and private artifact handling. |
| 4. Synthetic evidence and production boundary | Archive | Existing source path (retained); limitations explicitly retained in `recovery.md` | Keep synthetic evidence dated; preserve adapter versus provisioned infrastructure and receipt-continuity limitations. |

### Shared staging verification

Source: [docs/staging-verification.md](../../docs/staging-verification.md). All child subsections inherit their parent mapping unless split below.

| Source section | Classification | Future destination | Preservation requirement |
|---|---|---|---|
| Title, status, date, audience and preamble | Keep | Existing source; carry provenance into its reviewed destination | Preserve the original labels, approver/date and amendments. This inventory grants no new approval. |
| 1. Run locally first | Merge | `development.md` commands; shared release checklist retained | Keep safe local-only prerequisites, private evidence handling and suite scopes. |
| 2. Ordered staging checklist (Nin executes) | Keep | Existing source path (retained); backend procedures referenced from `operations.md` | Preserve gate IDs/order, required evidence and responsible operator; do not split away cross-product acceptance. |
| 3. Physical-device checklist for G4 | Keep | Existing source path (retained) | Physical-device checks stay frontend/release-owned; backend docs link rather than claim them complete. |
| 4. Read-only ingress probes for G6 (Nin) | Merge | `operations.md` procedure; shared gate reference retained | Preserve edge-versus-upstream evidence, network restrictions and metrics isolation. |
| 5. Controlled alert drills for G7 (Nin) | Merge | `operations.md` procedure; shared gate reference retained | Preserve controlled alert drills and routing verification without claiming provisioning. |
| 6. Isolated restore sequence for G9 (Nin) | Merge | `recovery.md` procedure; shared ordered gate reference retained | Preserve isolated restore, deletion replay, coverage validation, epoch rotation and closed-gate checks in one procedural home. |
| 7. Initial staging-preparation local evidence (historical) | Archive | Existing source path (retained) | Preserve historical local evidence and its limitations. |
| 8. Independent ledger local evidence | Archive | Existing source path (retained) | Preserve independent ledger local evidence; it does not establish deployed custody/freshness. |
| 9. Cartridge restore-review local evidence | Archive | Existing source path (retained); feature acceptance links in `trd/content-and-entitlements.md`/`trd/learning-sync.md` | Keep cartridge restore/restart evidence dated and separated from release acceptance. |

### Dated staging acceptance attempt

Source: [docs/staging-acceptance-2026-11-15.md](../../docs/staging-acceptance-2026-11-15.md). All child subsections inherit their parent mapping unless split below.

| Source section | Classification | Future destination | Preservation requirement |
|---|---|---|---|
| Title, status, date, audience and preamble | Keep | Existing source; carry provenance into its reviewed destination | Preserve the original labels, approver/date and amendments. This inventory grants no new approval. |
| 1. Candidate identity and build eligibility | Archive | Existing source path (retained) | Retain attempted candidate identity, access boundary and blocked prerequisites. |
| 2. Independent-ledger drill — executed first | Archive | Existing source path (retained) | Retain independent-ledger drill identity, scope and evidence limits. |
| 3. Staging acceptance results | Archive | Existing source path (retained) | Preserve the actual blocked/unverified staging result; do not relabel it as accepted. |
| 4. Independent local checks completed despite staging blockers | Archive | Existing source path (retained) | Keep local results separate from staging/provider/device acceptance. |
| 5. Handoff and invariant | Archive | Existing source path (retained) | Retain the handoff, unresolved responsibilities and closed-gate invariant. |

### Account and feedback rollout boundary

Source: [docs/account-feedback-rollout.md](../../docs/account-feedback-rollout.md). All child subsections inherit their parent mapping unless split below.

| Source section | Classification | Future destination | Preservation requirement |
|---|---|---|---|
| Title, status, date, audience and preamble | Keep | Existing source; carry provenance into its reviewed destination | Preserve the original labels, approver/date and amendments. This inventory grants no new approval. |
| Accounts and local data | Keep | Existing source path (retained); backend contracts linked from `trd/identity-and-access.md`/`trd/learning-sync.md` | Preserve client ownership/cache/import constraints, compatibility limitations and no silent data adoption. |
| Local development and verification | Merge | `development.md`; client rollout page retains navigation | One backend setup/harness reference; preserve current email selection and local-only verification. |
| Feedback | Keep | Existing source path (retained) | Keep the explicit absence of Go feedback routes and local outbox boundary; no approved replacement implementation is inferred. |
| Sync and cartridge release gates | Keep | Existing source path (retained); authoritative backend gate requirements in `operations.md`/`trd/learning-sync.md`/`trd/content-and-entitlements.md` | Preserve client installation review and real-content classification obligations without claiming release approval. |
| Remaining external checks | Keep | Existing source path (retained) and shared staging checklist | Retain external checks and operator responsibilities; link backend procedures when written. |

### Product requirements and approval provenance

Source: [docs/product/user-management.md](../../docs/product/user-management.md). All child subsections inherit their parent mapping unless split below.

| Source section | Classification | Future destination | Preservation requirement |
|---|---|---|---|
| Title, status, date, audience and preamble | Keep | Existing source; carry provenance into its reviewed destination | Preserve the original labels, approver/date and amendments. This inventory grants no new approval. |
| How to read this document | Keep | Existing source path (retained) | Product labels remain product authority; technical docs must not invent approvals. |
| 1. Context and constraints | Keep | Existing source path (retained); architecture links `architecture.md` | Keep product scope and approved service constraints with their provenance. |
| 2. Goals and non-goals | Keep | Existing source path (retained); feature TRDs reference requirements | Preserve product goals/exclusions rather than duplicating them as new decisions. |
| 3. Roadmap | Keep | Existing source path (retained) | Roadmap status drift needs a later evidence-backed reconciliation, not silent promotion of proposals. |
| 4. Personas and roles | Keep | Existing source path (retained); permission implementation in `trd/identity-and-access.md` | Retain personas/role requirements and distinguish role policy from implementation. |
| 5. Phase 1 — Email authentication & account foundation | Keep | Existing source path (retained); technical requirements in `trd/identity-and-access.md` | Preserve all approved flows and AC identifiers; reference instead of reapproving. |
| 6. Account status and data lifecycle (Phase 2 outline) | Keep | Existing source path (retained); implementation/approval amendments linked from `trd/account-lifecycle.md` | Retain original proposals and later decisions without flattening status. |
| 7. Profile and device management (Phase 2 outline) | Keep | Existing source path (retained); technical requirements in `trd/identity-and-access.md` | Preserve profile/device scope and deferred history. |
| 8. Learning data sync (Phase 3 outline) | Keep | Existing source path (retained); technical protocol in `trd/learning-sync.md` | Preserve D1–D10 product lineage and vocabulary-only scope. |
| 9. RBAC and user administration (Phase 4) | Keep | Existing source path (retained); technical policy in `trd/identity-and-access.md` | Preserve matrix approval and actor/target authority. |
| 10. Audit and monitoring (Phase 5 outline) | Keep | Existing source path (retained); implementation and deployment split in `operations.md` | Original monitoring proposals do not imply dashboards or deployment exist. |
| 11. Free / Premium entitlements (Phase 6) | Keep | Existing source path (retained); technical requirements in `trd/content-and-entitlements.md` | Preserve E1–E5 and cartridge amendments; payment remains deferred. |
| 12. Questions | Keep | Existing source path (retained) | Carry unresolved questions with exact status; a proposal in this inventory is not an answer. |
| 13. Phase 1 acceptance criteria | Keep | Existing source path (retained); test/requirement links from `trd/identity-and-access.md` | Preserve all AC IDs and amendments. |
| 14. Delivery sequence | Archive | Existing source path (retained) | Keep the original delivery sequence as context; do not use it as current implementation authority. |

### Historical product discovery

Source: [docs/product/product-discovery.md](../../docs/product/product-discovery.md). All child subsections inherit their parent mapping unless split below.

| Source section | Classification | Future destination | Preservation requirement |
|---|---|---|---|
| Title, status, date, audience and preamble | Keep | Existing source; carry provenance into its reviewed destination | Preserve the original labels, approver/date and amendments. This inventory grants no new approval. |
| 1. Product Overview | Archive | Existing source path (retained) | Preserve this whole section, child sections, dates, assumptions and evidence limits. Future backend pages link relevant provenance only; do not copy historical product/client claims as current Go behavior. |
| 2. Existing Features | Archive | Existing source path (retained) | Preserve this whole section, child sections, dates, assumptions and evidence limits. Future backend pages link relevant provenance only; do not copy historical product/client claims as current Go behavior. |
| 3. User Journeys | Archive | Existing source path (retained) | Preserve this whole section, child sections, dates, assumptions and evidence limits. Future backend pages link relevant provenance only; do not copy historical product/client claims as current Go behavior. |
| 4. Current Technical Architecture | Archive | Existing source path (retained) | Preserve this whole section, child sections, dates, assumptions and evidence limits. Future backend pages link relevant provenance only; do not copy historical product/client claims as current Go behavior. |
| 5. Current Monetization Capability | Archive | Existing source path (retained) | Preserve this whole section, child sections, dates, assumptions and evidence limits. Future backend pages link relevant provenance only; do not copy historical product/client claims as current Go behavior. |
| 6. AI Cost Centers | Archive | Existing source path (retained) | Preserve this whole section, child sections, dates, assumptions and evidence limits. Future backend pages link relevant provenance only; do not copy historical product/client claims as current Go behavior. |
| 7. Monetization Opportunities | Archive | Existing source path (retained) | Preserve this whole section, child sections, dates, assumptions and evidence limits. Future backend pages link relevant provenance only; do not copy historical product/client claims as current Go behavior. |
| 8. Product Gaps | Archive | Existing source path (retained) | Preserve this whole section, child sections, dates, assumptions and evidence limits. Future backend pages link relevant provenance only; do not copy historical product/client claims as current Go behavior. |
| Appendix: Quick-Reference File Map | Archive | Existing source path (retained) | Preserve this whole section, child sections, dates, assumptions and evidence limits. Future backend pages link relevant provenance only; do not copy historical product/client claims as current Go behavior. |

### Historical implementation handoff

Source: [docs/nin-handoff.md](../../docs/nin-handoff.md). All child subsections inherit their parent mapping unless split below.

| Source section | Classification | Future destination | Preservation requirement |
|---|---|---|---|
| Title, status, date, audience and preamble | Keep | Existing source; carry provenance into its reviewed destination | Preserve the original labels, approver/date and amendments. This inventory grants no new approval. |
| Included | Archive | Existing source path (retained) | Preserve this whole section, child sections, dates, assumptions and evidence limits. Future backend pages link relevant provenance only; do not copy historical product/client claims as current Go behavior. |
| Apple configuration to confirm with Nin | Archive | Existing source path (retained) | Preserve this whole section, child sections, dates, assumptions and evidence limits. Future backend pages link relevant provenance only; do not copy historical product/client claims as current Go behavior. |
| Current backend handoff | Archive | Existing source path (retained) | Preserve this whole section, child sections, dates, assumptions and evidence limits. Future backend pages link relevant provenance only; do not copy historical product/client claims as current Go behavior. |
| Validation | Archive | Existing source path (retained) | Preserve this whole section, child sections, dates, assumptions and evidence limits. Future backend pages link relevant provenance only; do not copy historical product/client claims as current Go behavior. |

### Historical first-launch QA

Source: [docs/first-launch-qa.md](../../docs/first-launch-qa.md). All child subsections inherit their parent mapping unless split below.

| Source section | Classification | Future destination | Preservation requirement |
|---|---|---|---|
| Title, status, date, audience and preamble | Keep | Existing source; carry provenance into its reviewed destination | Preserve the original labels, approver/date and amendments. This inventory grants no new approval. |
| Scope and review | Archive | Existing source path (retained) | Preserve this whole section, child sections, dates, assumptions and evidence limits. Future backend pages link relevant provenance only; do not copy historical product/client claims as current Go behavior. |
| Executed checks | Archive | Existing source path (retained) | Preserve this whole section, child sections, dates, assumptions and evidence limits. Future backend pages link relevant provenance only; do not copy historical product/client claims as current Go behavior. |
| Required external validation | Archive | Existing source path (retained) | Preserve this whole section, child sections, dates, assumptions and evidence limits. Future backend pages link relevant provenance only; do not copy historical product/client claims as current Go behavior. |
| Five-minute candidate added after the range preference | Archive | Existing source path (retained) | Preserve this whole section, child sections, dates, assumptions and evidence limits. Future backend pages link relevant provenance only; do not copy historical product/client claims as current Go behavior. |
| Per-app management follow-up — 11 November 2026 | Archive | Existing source path (retained) | Preserve this whole section, child sections, dates, assumptions and evidence limits. Future backend pages link relevant provenance only; do not copy historical product/client claims as current Go behavior. |
| Settings App locks overview — 11 November 2026 | Archive | Existing source path (retained) | Preserve this whole section, child sections, dates, assumptions and evidence limits. Future backend pages link relevant provenance only; do not copy historical product/client claims as current Go behavior. |
| Aggregate switch and unlock-sheet correction — 11 November 2026 | Archive | Existing source path (retained) | Preserve this whole section, child sections, dates, assumptions and evidence limits. Future backend pages link relevant provenance only; do not copy historical product/client claims as current Go behavior. |

### Historical monetization proposal

Source: [MONETIZATION_SEQUENCE.md](../../MONETIZATION_SEQUENCE.md). All child subsections inherit their parent mapping unless split below.

| Source section | Classification | Future destination | Preservation requirement |
|---|---|---|---|
| Title, status, date, audience and preamble | Keep | Existing source; carry provenance into its reviewed destination | Preserve the original labels, approver/date and amendments. This inventory grants no new approval. |
| Thesis | Archive | Existing source path (retained) | Preserve this whole section, child sections, dates, assumptions and evidence limits. Future backend pages link relevant provenance only; do not copy historical product/client claims as current Go behavior. |
| Assets (verified in-tree) | Archive | Existing source path (retained) | Preserve this whole section, child sections, dates, assumptions and evidence limits. Future backend pages link relevant provenance only; do not copy historical product/client claims as current Go behavior. |
| Liabilities (verified in-tree) | Archive | Existing source path (retained) | Preserve this whole section, child sections, dates, assumptions and evidence limits. Future backend pages link relevant provenance only; do not copy historical product/client claims as current Go behavior. |
| Phase 0 — Stop the bleeding | Archive | Existing source path (retained) | Preserve this whole section, child sections, dates, assumptions and evidence limits. Future backend pages link relevant provenance only; do not copy historical product/client claims as current Go behavior. |
| Phase 1 — Ship it free | Archive | Existing source path (retained) | Preserve this whole section, child sections, dates, assumptions and evidence limits. Future backend pages link relevant provenance only; do not copy historical product/client claims as current Go behavior. |
| Phase 2 — Charge before building | Archive | Existing source path (retained) | Preserve this whole section, child sections, dates, assumptions and evidence limits. Future backend pages link relevant provenance only; do not copy historical product/client claims as current Go behavior. |
| Phase 3 — Build what the data chose | Archive | Existing source path (retained) | Preserve this whole section, child sections, dates, assumptions and evidence limits. Future backend pages link relevant provenance only; do not copy historical product/client claims as current Go behavior. |
| Phase 4 — Hardware | Archive | Existing source path (retained) | Preserve this whole section, child sections, dates, assumptions and evidence limits. Future backend pages link relevant provenance only; do not copy historical product/client claims as current Go behavior. |
| Why hardware is Phase 4 and not Phase 1 | Archive | Existing source path (retained) | Preserve this whole section, child sections, dates, assumptions and evidence limits. Future backend pages link relevant provenance only; do not copy historical product/client claims as current Go behavior. |
| Open questions for the reviewer | Archive | Existing source path (retained) | Preserve this whole section, child sections, dates, assumptions and evidence limits. Future backend pages link relevant provenance only; do not copy historical product/client claims as current Go behavior. |

### Colocated references, root navigation and frontend exclusions

| Source and important sections | Classification | Future destination | Preservation requirement |
|---|---|---|---|
| [Migration README](../migrations/README.md): introduction, inventory table, Rules | Merge | `database.md`; retain a short colocated pointer later | Keep up-only/no-applied-edits rules, separate migration step and SQLC coupling. Inventory must include 00010/00011 and current ordering. No table is changed in Phase 3.1. |
| [Blocklist README](../internal/identity/blocklist/README.md): Source, Processing, Behavior and limits, Regenerating | Keep | Existing colocated README; references from identity TRD/development guide | Retain pinned source/hash/licence, filtering, significant spaces, exact matching and regeneration rules; do not duplicate the dataset or provenance. |
| [Root README](../../README.md): local backend, production Docker, backend tests, optional accounts/feedback | Merge | Short root navigation to `backend/README.md` and future guides | Preserve the app overview and offline boundary. Move backend procedure ownership later, without editing unrelated Flutter/native instructions. |
| [AGENTS.md](../../AGENTS.md): Go backend module rules, staging readiness, Go commands, review rules and data hygiene | Keep | Existing engineering instructions; links to future guides | Preserve authentication exceptions, OTP-only challenge writes, lock order, ownership, export/purge, audit/metric, local-only and secret-handling invariants. Do not replace instructions with unsupported summaries. |
| [Native protection](../../docs/first-launch-native-protection.md), [app-gate specification](../../docs/APP_GATE_FLUTTER_SPEC.md), [Shortcut setup](../../docs/guided-shortcut-setup.md), [universal Shortcut candidate](../../docs/universal-shortcut-candidate.md) | Keep | Existing frontend/native documents | Outside the Go documentation migration. Keep all sections with their current owners and status; do not move device evidence into backend readiness claims. |

## Information-loss risks and review controls

| Risk | Required later review control |
|---|---|
| Status flattening | Carry original Proposed/Approved/Decided markers, dates and amendments. Record implementation evidence and deployment readiness in separate fields. |
| Lost provenance | Keep original R/AC/D/E identifiers and named approver/date when recorded. The ADR index lists candidates, not new approvals. Preserve preamble/version-change history and resolution sections. |
| Lost security exceptions | Check owner/session/rights trust boundaries, hash-before-transaction, address locks, Super Admin guard, paired email cutover, READ COMMITTED versus export REPEATABLE READ, no-grace refresh and committed proof failures explicitly. |
| Lost acceptance coverage | Maintain a source requirement/AC → destination requirement → source/test → dated evidence/gate mapping. Never replace detailed cases with passing totals. |
| Export/purge drift | Reconcile TRD 04, 05, 09 and 10 together: schema version, canonical encoder, chunk/integrity checks, exact size bounds, plan/grant and watermark sections, restrictive foreign keys and bounded purge. |
| Audit data widening | Preserve the explicit history field allowlist, visibility policy and `(occurred_at, id)` tie-breaker. Export must continue to exclude staff/ticket/internal metadata. |
| Unsafe recovery simplification | Preserve every stop/refusal condition, independent cutoff/source/generation requirement, custody obligation, restore ordering and receipt limitation. Database acceptance is not independent publication. |
| Client contract loss | Keep import consent, legacy provenance, account partitions, unknown version/epoch requests and manual review obligations traceable without rewriting frontend documentation. |
| Misleading readiness | Keep sync/install closed, synthetic content classification explicit, and local tests distinct from signed-device/provider/ingress/monitoring/storage evidence. |
| Duplicate authorities | OpenAPI owns wire definitions; migrations/queries own schema; each procedure/decision gets one maintained home. Duplicate prose is Delete Later only after unique semantics and links are accounted for. |
| Historical evidence damage | Archive classification retains existing records and their actual success/failure/blocked state. Do not update old totals, remove limitations or treat old branches/PRs as authority. |
| Broken incoming links | Inventory callers/anchors before later movement. Keep reviewed source pointers and verify Git Markdown and Confluence navigation before deleting duplicate bodies. |

## Later-phase implementation checklist

These are sequencing steps, not new numbered phase approvals. Stop after the current Phase 3.1 review.

### Phase 3.1 review gate

- [x] Inventory all existing TRDs and important supporting sections, including preambles and inherited child content.
- [x] Record verified source checkpoints and unresolved discrepancies without changing existing documents.
- [x] Create navigation and a dedicated ADR inventory without creating future guide/TRD placeholders or numbered decisions.
- [x] Add minimal backend README navigation; leave its existing content intact.
- [x] Validate local links/anchors, section coverage, original-source preservation and documentation-only change scope; run whitespace checks before handoff.
- [ ] Obtain review of this map, destinations, frontend exclusions and preservation controls before rewriting anything.

### Core guides after review

- [ ] Establish maintainers/reviewers; confirm Git Markdown authoring and Confluence mirror ownership.
- [ ] Write architecture from the three binaries, composition, actual dependencies and worker lifecycle.
- [ ] Write development/configuration/testing guidance from loader, Makefile, Compose and build tags; resolve the documented SMTP/Resend discrepancy through an explicit decision if behavior is to change.
- [ ] Write the database guide with all 15 migrations, all query domains, generated-code rules, complete lock order and flow-specific isolation/mode exceptions.
- [ ] Write the API usage guide with authentication/error/retry conventions and references to OpenAPI; do not reproduce endpoint/payload definitions.
- [ ] Write operations with actual grants, startup order, jobs, retention, metric/alert behavior and unverified deployment prerequisites.
- [ ] Transfer recovery procedures as one reviewed unit, including all coverage/custody/refusal conditions and synthetic-evidence limitations.

### Feature TRDs and ADRs after review

- [ ] Create a requirement/AC/provenance traceability ledger from each mapped source section before merging it.
- [ ] Consolidate identity/access while retaining profile/email, sessions, authorization matrix, audit allowlist, bootstrap, concurrency and retry cases.
- [ ] Consolidate lifecycle with every learning/entitlement/cartridge export and purge amendment; recheck size bounds and retention distinctions.
- [ ] Consolidate learning sync while preserving all D1–D10 requirements, client-only acceptance obligations and closed rollout gates.
- [ ] Consolidate content/entitlements while preserving E1–E5, immutable/additive content, exact uncertain requests, grant authority and real-content gates.
- [ ] Review ADR candidates; create separate numbered records only for justified choices with original IDs/approver/date, alternatives, consequences and evidence.
- [ ] Link TRDs to those ADRs for rationale rather than duplicating decisions; leave absent approval explicit.

### Parity, navigation and publication after review

- [ ] Compare every requirement, AC, security rule, table/example/footnote and amendment with its destination; obtain feature-owner review.
- [ ] Preserve dated evidence and original records; review historical Archive candidates without changing their observed results.
- [ ] Verify every source section/anchor and incoming link, including product, frontend, scripts and operator references.
- [ ] Replace obsolete editable bodies with reviewed pointers only after parity; consider Delete Later entries individually, never as blanket source-file deletion.
- [ ] Validate local Markdown links/anchors and `git diff --check`; ensure only the approved documentation scope changed.
- [ ] Publish the approved Markdown hierarchy to Confluence with source links and mirror metadata; verify anchors/attachments without creating a second editable authority.
- [ ] Record documentation approval, implementation evidence and deployment readiness separately; do not close staging/device/provider gates through a documentation change.

## Phase 3.1 verification boundary

Only documentation navigation and inventory are changed in this phase. Link/section coverage,
source preservation, change scope and whitespace are validated before handoff. Builds, tests,
services, migrations, production settings and database/volume operations are outside this
phase and are not represented as newly passed verification. Existing TRDs and runbooks
remain untouched and continue to carry their original provenance and limitations.
