# Architecture decision records

**Phase 3.1 status:** Evidence inventory only. No numbered ADRs have been created.
**Structure approval:** A dedicated `adr/` directory with separate numbered records is approved.
**Decision approval:** Remains in the original records linked below; this index creates no approvals.

Return to [backend documentation](../README.md) or the [content map](../content-map.md).

## Candidates requiring evidence review

These topics are candidates for later extraction, not assigned ADRs. Split independently
changeable decisions rather than treating each row as a mandatory single record. Preserve
the original identifier/date and distinguish later amendments from the initial choice.

| Candidate | Existing provenance | Implementation to compare | Extraction caution |
|---|---|---|---|
| Service shape and separate migration execution | [TRD 01 §2 and §14, R9](../../../docs/trd/01-email-authentication-account-foundation.md) | [Entrypoints](../../cmd), [composition](../../internal/app/app.go), [migration runner](../../internal/platform/migrate/migrate.go) | R9 contains retirement-era wording; preserve the original choice and amendment history separately. |
| Opaque sessions, refresh rotation, replay response and session cap | [TRD 01 §8 and §14, R1–R4/R11](../../../docs/trd/01-email-authentication-account-foundation.md), [TRD 02 §8](../../../docs/trd/02-session-management.md) | [Session package](../../internal/auth/session) | Retain the no-grace and lost-response consequences; do not generalize them to other writes. |
| Password proof/policy and unknown outcomes | [TRD 01 §5.4, §9 and §14, R6–R8/R10](../../../docs/trd/01-email-authentication-account-foundation.md) | [Password flows](../../internal/auth/password/password.go), [identity primitives](../../internal/identity) | Preserve the policy decision while identifying the actual filtered blocklist through its [provenance README](../../internal/identity/blocklist/README.md). |
| Transaction ordering and specific lock modes | [TRD 01 §7/§14 R13](../../../docs/trd/01-email-authentication-account-foundation.md), [TRD 03 §2/§4](../../../docs/trd/03-account-profile-email-change.md), [TRD 06 §4/§8](../../../docs/trd/06-rbac-user-administration-api.md) | [Transaction runner](../../internal/platform/db/tx.go), [account writers](../../internal/identity/accounts), [export snapshot](../../internal/lifecycle/export.go) | Carry forward amendments and the REPEATABLE READ export exception; avoid an unconditional isolation-level claim. |
| Email provider, encryption and bounded duplicate delivery | [TRD 01 §8/§14, R12/R14/R15](../../../docs/trd/01-email-authentication-account-foundation.md) | [Notify package](../../internal/notify), [local Compose](../../compose.yaml), [production Compose](../../compose.production.yaml) | R12 records Resend selection on 2026-11-14; preserve its different provenance from the 2026-11-13 approvals. Local Compose and runtime defaults differ. |
| Rights capabilities, retention and irreversible deletion | [TRD 04 §1.1/§11/§12](../../../docs/trd/04-account-lifecycle-data-rights.md) | [Rights handlers](../../internal/auth/httpapi/lifecycle.go), [lifecycle package](../../internal/lifecycle) | Approval applies to recorded decisions, not every earlier Proposed section or every deployment parameter. |
| Owner-scoped sync, conflicts, import and restore fencing | [TRD 05 §1.2, D1–D10](../../../docs/trd/05-learning-data-sync.md) | [Learning package](../../internal/learning), [sync migration](../../migrations/00011_learning_sync.sql) | Preserve decision IDs, client obligations and amendments to lifecycle behavior. |
| Staff authority and last-Super-Admin protection | [TRD 06 §2–§5](../../../docs/trd/06-rbac-user-administration-api.md) | [Policy](../../internal/admin/policy.go), [bootstrap](../../internal/admin/bootstrap.go), [guard](../../internal/identity/accounts/roles.go) | Keep the approved actor/action/target matrix distinct from implementation details. |
| Separate plans, grant authority and immutable cartridge delivery | [TRD 09 §1, E1–E5](../../../docs/trd/09-free-premium-entitlements.md), [TRD 10 §1–§2](../../../docs/trd/10-server-delivered-cartridges.md) | [Entitlements](../../internal/entitlements), [plan writer](../../internal/admin/plan.go), [cartridges](../../internal/learning/cartridges.go) | Keep the original plan-only scope and the later cartridge gating amendment; technical choices are not automatically approved product decisions. |
| Admin ingress and metrics exposure | [TRD 07 §3.1](../../../docs/trd/07-admin-console.md), [TRD 08 §3/§8](../../../docs/trd/08-monitoring-alerting.md) | [Production Compose](../../compose.production.yaml), [metrics](../../internal/platform/metrics) | Preserve Nin's recorded 2026-11-15 deployment decision; external ingress and alert routing still need verification. |
| Independent deletion-checkpoint coverage and custody | [Recovery runbook §1–§4](../../../docs/deletion-ledger-recovery.md), [TRD 04 §12.5a](../../../docs/trd/04-account-lifecycle-data-rights.md) | [Recovery implementation](../../internal/recoveryledger), [CLI](../../cmd/admin/ledger.go), [isolated restore SQL](../../ops/restore) | Source implementation is evidence, not a blanket approval of schedules or storage guarantees. Proposed deployment settings must remain Proposed. |

## Rules for later numbered ADRs

1. Identify a durable architectural choice with a clear scope, original provenance and
   implementation evidence. Do not create a record merely because a package exists.
2. Use the next available `NNNN-short-title.md` only when that extraction is reviewed.
   Numbering is not assigned by this candidate inventory.
3. Record context, alternatives, the decision, consequences, original IDs, recorded approver/date
   when present, superseding amendments and source/test links. If approval is absent, say so.
4. Separate **decision status** (Proposed, Approved, Superseded) from **implementation status**
   and **deployment readiness**. Do not mark an inferred choice Approved because code exists.
5. Link the relevant TRD requirements and acceptance criteria to the ADR; do not duplicate
   rationale or OpenAPI endpoint definitions in both places.
6. Retain original source sections until a reviewer verifies the extraction and incoming links.
   The [later-phase checklist](../content-map.md#later-phase-implementation-checklist) controls that migration.
