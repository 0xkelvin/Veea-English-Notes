# Backend documentation

**Phase:** 3.1 — inventory, content mapping and navigation, prepared for review.
**Structure:** Approved by the Phase 3.1 task; the destination pages below are not yet written.
**Content status:** This index and its mapping are review material, not approval of a new design.
**Implementation and deployment:** Source evidence and release acceptance are separate from documentation approval.

Git Markdown is the maintained source of truth; Confluence mirrors the same content.
Until a later migration is reviewed, the existing documents remain at their current paths.
Use the implementation and OpenAPI to verify behavior, the original decision records to
establish approval, and the staging checklist to assess deployment readiness. A branch,
PR, historical test count or document status alone does not establish current behavior.

## Start here

- [Current backend README](../README.md): setup, configuration, commands and implementation notes.
- [Section-level content map and later-phase checklist](content-map.md): all existing TRDs,
  important supporting sections, planned destinations and preservation requirements.
- [ADR inventory and extraction rules](adr/README.md): evidence required before creating a numbered ADR.
- [OpenAPI](../api/openapi.yaml): the HTTP contract; future guides will link to it rather than duplicate endpoint definitions.
- [Staging verification](../../docs/staging-verification.md): shared release gates, including the closed sync/install gate.
- [Current recovery runbook](../../docs/deletion-ledger-recovery.md): independent custody, coverage requirements and isolated restoration.

## Core navigation

Paths in the Destination column are planned names, deliberately not links to missing files.
All six core pages are **Planned — not created in Phase 3.1**.

| Destination | Purpose | Current sources |
|---|---|---|
| `architecture.md` | Entrypoints, package boundaries, startup/shutdown and dependency flows | [Backend layout](../README.md#layout), [TRD 01 architecture](../../docs/trd/01-email-authentication-account-foundation.md#2-architecture), [composition](../internal/app/app.go) |
| `development.md` | Local workflows, configuration, generated code, test scopes and troubleshooting | [Backend development guide](../README.md), [Makefile](../Makefile), [configuration loader](../internal/platform/config/config.go), [scripts](../scripts) |
| `api.md` | Authentication schemes, errors, decoding and retry conventions; references to OpenAPI | [OpenAPI](../api/openapi.yaml), [HTTP handlers](../internal/auth/httpapi), [HTTP infrastructure](../internal/platform/httpx/server.go) |
| `database.md` | Complete migration inventory, SQLC, ownership, transactions and lock rules | [Migration README](../migrations/README.md), [migrations](../migrations), [SQLC configuration](../sqlc.yaml), [transaction runner](../internal/platform/db/tx.go) |
| `operations.md` | Deployment sequence, jobs, email, metrics/alerts, retention and release boundaries | [Backend operations](../README.md#production-docker-resend-no-mailpit), [TRD 08](../../docs/trd/08-monitoring-alerting.md), [staging checklist](../../docs/staging-verification.md) |
| `recovery.md` | Independent deletion checkpoints, custody, recovery commands and refusal conditions | [Recovery runbook](../../docs/deletion-ledger-recovery.md), [TRD 04](../../docs/trd/04-account-lifecycle-data-rights.md), [restore SQL](../ops/restore), [recovery implementation](../internal/recoveryledger) |

## Feature TRD navigation

All four consolidated TRDs are **Planned — not created in Phase 3.1**. Their requirements,
acceptance criteria and security rules must remain traceable to the source sections in the map.

| Destination | Existing feature documents | Boundary to preserve |
|---|---|---|
| `trd/identity-and-access.md` | [TRD 01](../../docs/trd/01-email-authentication-account-foundation.md), [TRD 02](../../docs/trd/02-session-management.md), [TRD 03](../../docs/trd/03-account-profile-email-change.md), [TRD 06](../../docs/trd/06-rbac-user-administration-api.md) | Signup/sign-in, passwords, sessions, profile/email, staff policy, audit visibility and acceptance mappings |
| `trd/account-lifecycle.md` | [TRD 04](../../docs/trd/04-account-lifecycle-data-rights.md), lifecycle amendments in [TRD 05](../../docs/trd/05-learning-data-sync.md), [TRD 09](../../docs/trd/09-free-premium-entitlements.md) and [TRD 10](../../docs/trd/10-server-delivered-cartridges.md) | Scoped rights proofs, export, deletion receipts, bounded purge and retained-data obligations |
| `trd/learning-sync.md` | [TRD 05](../../docs/trd/05-learning-data-sync.md), [client verification evidence](../../docs/trd/05-flutter-verification.md), relevant [TRD 10](../../docs/trd/10-server-delivered-cartridges.md) constraints | Ownership, writers/sequences, epochs, conflicts, quotas, import consent and client obligations |
| `trd/content-and-entitlements.md` | [TRD 09](../../docs/trd/09-free-premium-entitlements.md), [TRD 10](../../docs/trd/10-server-delivered-cartridges.md), [TRD 06 plan administration](../../docs/trd/06-rbac-user-administration-api.md#9b-plan-management-trd-09-added-2026-11-15) | Role/plan separation, immutable content, additive installs/updates, publication and export/purge bounds |

The [admin-console TRD](../../docs/trd/07-admin-console.md) remains frontend-owned.
Backend permission, ingress and integration-test obligations are mapped without copying its UI specification.

## Decision navigation

[The dedicated ADR directory](adr/README.md) exists for inventory and navigation only.
No numbered ADR has been created, no existing decision has been rewritten, and no new
approval has been inferred. Later feature TRDs will link to justified numbered ADRs for
decision rationale, retaining requirements and acceptance criteria in the TRDs.

## Status and maintenance rules

- **Documentation approval:** the structure is approved; Phase 3.1 content is awaiting review.
  Later pages and changes to requirements need their own review.
- **Proposed / Approved:** preserve the original decision's status, identifier, named approver
  and recorded date. Implemented code is evidence of behavior, not evidence of approval.
- **Implemented / Partial / Planned / Legacy Compatibility:** classify features against source
  and tests; record test presence separately from a dated successful execution.
- **Deployment readiness:** record gates and external prerequisites explicitly. Implemented
  sync/install code does not open the gate, and a local checkpoint adapter does not establish
  independent storage, scheduling or freshness monitoring.
- Keep one editable home for each procedure or decision. Historical records remain dated
  evidence. Do not turn source snapshots, old branches or PRs into behavioral authority.
- Preserve source-to-destination links before considering any **Delete Later** entry in the map.
  No existing document is moved, archived or deleted by Phase 3.1.
