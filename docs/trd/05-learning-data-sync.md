# TRD 05 — Learning Data Sync

**Status:** v1.2. The backend is implemented and locally verified (§17): migration 00011, the six sync routes in `backend/api/openapi.yaml`, `backend/internal/learning/`, and the TRD 04 export and purge integration. Sync ships **closed** (`learning_sync_control.open = false`) and stays closed to users until the Flutter checks in §15.2 pass. Every product decision is recorded (D1–D10, §1.2), and Product Doc v0.3 §8 is aligned. This version also corrects the contracts listed in §17.2. The Flutter sync core and local §15.2 evidence are now recorded in [Flutter verification](05-flutter-verification.md); the Go identity/session/deletion client integration now has local end-to-end evidence there; rollout and device/deployment gates remain closed.
**Audience:** Nin, backend, Flutter and QA engineers.
**Scope:** The first server-side sync of learning data in the Go backend:
- ownership and offline retries;
- conflict resolution and deletion propagation;
- guest data, sign-out and account caches;
- database-restore handling;
- quotas;
- how vocabulary takes part in TRD 04 export, purge and restore fencing.

## 1. Authority and labels

Read alongside [AGENTS.md](../../AGENTS.md), the [User Management Product Doc v0.2](../product/user-management.md) (§1, §2, §8, Q-L2), [TRD 01](01-email-authentication-account-foundation.md) (§7.1 lock order, §11 audit and metrics), [TRD 02](02-session-management.md) and [TRD 04](04-account-lifecycle-data-rights.md).

Labels used in this document:
- **[Approved]**: decided in the Product Doc or an earlier TRD. The source is cited.
- **[Decided]**: one of D1–D10 in §1.2.
- **[Existing fact]**: what the code does today. The file is cited.
- **[Design]**: the technical detail that implements the decisions.

No product decision remains open; §16 lists implementation blockers.

### 1.1 Approved requirements

| Requirement | Source |
|---|---|
| The new backend is Go and PostgreSQL. The Rust backend is local-only, and its contracts, schema and migrations may be redesigned | Product Doc §1 **[Approved]** |
| Flutter is rebuilt after the backend; existing Flutter contracts do not constrain this design | Product Doc §1 **[Approved]** |
| One account has one stable `user_id`, independent of email and sign-in method | Product Doc §2 goal 1; TRD 04 §1 approved baseline |
| Learning data syncs per account with no cross-user leakage | Product Doc §2 goal 4 |
| Deletion is irreversible once accepted, purge targets 24 h, and the email is released only after purge. A later signup gets a new `user_id` and cannot recover or sync the deleted account's data | TRD 04 §1.1 **[Approved]** |
| Deactivation revokes every session. Deactivated and suspended owners keep their data. Rights proofs never grant learning-data writes | TRD 04 §1.1, §4.1 **[Approved]** |
| Export only the owner's product data that exists today. Downloads expire after 24 h and are invalidated when deletion is accepted | TRD 04 §1.1 **[Approved]** |
| Retention: backups/WAL 30 days, restoration ledger 90 days. The deletion ledger is replayed on restore before traffic | TRD 04 §1.1, §12.5 **[Approved]** |
| Every protected Go route uses `authenticated`; a changed route updates `backend/api/openapi.yaml` in the same change; metrics count after commit with fixed labels; a new user-owned table is purged, and exported if it is product data | AGENTS.md |
| Idempotency keys are authenticated first and scoped by user; there is no router-wide replay layer | AGENTS.md review rules (N1 precedent) |

### 1.2 Decisions (D1–D10, 2026-11-14) **[Decided]**

| ID | Decision | Where |
|---|---|---|
| **D1 — Scope** | V1 syncs vocabulary only. Review progress stays on the device until one canonical review model exists | §3 |
| **D2 — Conflicts** (answers Q-L2) | Changes to different fields merge. For the same field, the last server-accepted edit wins. Deletes beat stale edits. Restore is explicit. Client timestamps never decide | §6 |
| **D3 — Guest data and sign-out** | Sign-out opens the guest notebook and closes the account cache. Import consent is asked once per account and guest dataset; later imports are explicit. If an import exceeds capacity, the user chooses the words, and the excluded words stay on the device. A submitted import batch is rejected atomically if capacity changed before the server accepted it | §9.1–§9.4 |
| **D4 — Account isolation** | Account caches stay isolated. On confirmed account deletion, that account's cache and queue are cleared. Backups tagged with another `user_id` are rejected. There is no global deleted-item-ID denylist: word IDs and tombstones are scoped to the owning account | §4, §9.5, §9.6 |
| **D5 — Retention and old mutations** | Content-free tombstones are kept 90 days; deduplication records 30 days. A server-enforced rule stops an old mutation from being applied as new after its record expires, even with a fresh cursor, without using client timestamps | §5, §7 |
| **D6 — Database restore** | Rotate the sync epoch and require a full snapshot. Keep the old queue separate for user review; never replay it automatically or move it silently onto the new epoch. Apply the TRD 04 account-deletion ledger before sync reopens | §8.2 |
| **D7 — Limits and export** | 50,000 live words, 8 KiB per word and 64 MiB of content per account. Exports stay encrypted in PostgreSQL, with a verified serialized size bound | §10, §11 |
| **D8 — Field limits** | `word` 200, `meaning` 2,000, `pronunciation` 200, `source` 500, `examples` 20 × 500, `tags` 30 × 50, counted in Unicode code points. The 8 KiB serialized word limit is enforced separately. No control characters other than TAB and LF | §10.1 |
| **D9 — Sync registrations** | At most 20 writers per account. Adding the 21st retires the least recently used one, with deterministic tie-breaking. A retired writer's queue goes to manual review. Session revocation stays governed by TRD 02 | §5.2, §8.3 |
| **D10 — Review and confirmation** | Several rules on review and confirmation:<br>- After a database restore or a writer retirement, the device takes a new snapshot. Unresolved items are kept for explicit action or discard, one at a time, with no bulk replay. They are cleared on confirmed account deletion.<br>- On `capacity_changed`, the device refreshes capacity and requires confirmation before resubmitting.<br>- Words excluded from an import stay local until explicitly imported.<br>- Untagged legacy backups open in the guest notebook but are ineligible for account sync without established guest provenance.<br>- A sent edit is retried with its original writer, sequence and payload. After `mutation_expired` it is reconciled from the snapshot or reviewed, never automatically renumbered | §5.3, §8, §9.4, §9.6 |

### 1.3 Amendment to TRD 04

This pass also amends [TRD 04 §6.3](04-account-lifecycle-data-rights.md#63-old-devices-and-local-data). Its earlier proposal of a local-copy choice and a consented import into a newly created account is replaced by D4:
- clear the account's cache and queue on confirmed deletion;
- never import a deleted account's cache;
- reject backups tagged with another account.

The TRD 04 §12.5 restore runbook is extended by §8.2 below. [Product Doc v0.3](../product/user-management.md) §8 states the product rules and resolves Q-L2. This TRD holds the protocol.

## 2. Learning data that exists today **[Existing fact]**

The Go backend has no learning-data tables (migrations 00001–00010). TRD 04 export contains account and profile fields only.

### 2.1 Flutter device data

| Data | Where | Content | Synced today (Rust prototype) |
|---|---|---|---|
| Vocabulary entry | SQLite `words` ([`app_database.dart`](../../lib/data/local/app_database.dart), schema version 11) | Client UUID `id`, `word`, `meaning`, `pronunciation`, `part_of_speech`, `source`, `examples` and `tags` (JSON lists), capture `date`, `created_at`, `updated_at` (client clock), `is_deleted`, `is_dirty`, `synced_at`, derived search text | Content and tombstone |
| Gate review progress | `words.srs_stage`, `next_review_at`, `last_reviewed_at`, `last_gate_failed` | Per-word gate stage and schedule | No |
| SM-2 review state | `srs_reviews` | Interval, ease, next date, repetitions, lapses | No |
| Gate history and rounds | `gate_logs`, `gate_round_progress`, `gate_pending_answers`, `gate_word_rotation` | Completions and unfinished rounds per target app | No |
| Gate and learning settings | `gate_config` | Gated apps, pass duration, words per unlock, `auto_pronounce`, `daily_word_goal` (a boolean), practice pool | No |
| Account partitions | `account_workspaces`, `app_metadata.notebook_owner` | A JSON archive of each other account's tables, and the current owner | No |
| Reference data | `pronunciations`, bundled cartridges | Shared dictionary and content packs | Never |
| Other local state | SharedPreferences | Pet, friends, playlists, installed cartridges, widget/reminder/theme settings, sync cursor | No |

### 2.2 Gaps this design closes

The Rust prototype is in `cloud/` ([`word_repository_pg.rs`](../../cloud/src/infrastructure/persistence/postgres/word_repository_pg.rs)). Between it and today's Flutter client:
1. **Silent adoption.** On a device's first sign-in, `activateNotebook` adopts the guest notebook into the account without asking ([`sqlite_vocabulary_repository.dart`](../../lib/data/local/sqlite_vocabulary_repository.dart)).
2. **Client-clock winners.** Conflicts are decided by last write on the client's `updated_at`.
3. **Global IDs.** The globally unique primary key refuses an ID owned by another account, which reveals that it exists.
4. **Permanent tombstones.** Tombstones keep their full content forever.
5. **Two review models.** Progress lives in two local models (the gate stage and SM-2).
6. **Signed-out writes.** After sign-out the account notebook stays active, and edits made while signed out queue for that account.
7. **Rough retry detection.** Retries rely on comparing client timestamps.

## 3. V1 scope **[Decided: D1]**

| Data | V1 |
|---|---|
| Vocabulary items: content fields, capture day, deletion state | **Synced** |
| Review progress (gate stage, SM-2, gate history) | Device-local until one canonical review model exists |
| Learning preferences already in the TRD 03 profile (`daily_goal`, language, time zone) | Already synced by the profile |
| Gate rounds, gated apps, pass duration | Device-local permanently |
| Pet, friends, playlists, widget and theme settings | Device-local. Each needs its own owner, export and delete declaration before it can sync |
| Cartridge installations (TRD 10 amendment, 2026-11-15) | Owned word copies sync normally; server installation watermarks are owner-scoped, exported and purged. Bundled starter receipt and pending install requests are owner-scoped SQLite state |
| Pronunciations, cartridge content | Never: shared reference data |

**[Design]** Local review progress is keyed by the local item ID:
- An item arriving from another device starts with fresh local progress.
- A remote tombstone removes the item and its progress.
- An imported guest word keeps its progress on that device only.

The server never holds review progress, so export and purge do not cover it.

**TRD 10 amendment (2026-11-15).** Server cartridge install/update is a specialized atomic import using the same `admitImport`, `apply`, canonical size, lock order, head/feed and closed rollout gate. It has a durable per-owner/pack version watermark instead of a device writer sequence, and only creates entries first published after that watermark. It never replays or renumbers the existing writer queue. Explicit updates preserve edited/deleted entries even after tombstone compaction. Pending install requests retain their exact version/epoch across unknown outcomes; a restore blocks them for review. The 16-watermark export section is exactly bounded at 1,612 bytes; the worst-case full header is 14,700/16,384 bytes and the overall export bound stays 79,225,248 bytes. See [TRD 10](10-server-delivered-cartridges.md).

## 4. Ownership **[Decided: D4]**

- **Owner from the session only.** The owner is always the `user_id` of the authenticated principal. No body, path or cursor field names an owner.
- **Owner-scoped IDs and tombstones.** Every learning table is keyed by `(user_id, …)`, and a word's identity is `(user_id, id)`. A tombstone affects only its owner's item with that ID.
  - Another account may hold the same `id` (from a guest import, a re-registration or a coincidence) with no interaction at all.
  - An ID the owner does not have is absent, so a foreign ID reveals nothing (§2.2 gap 3).
  - There is no cross-account deleted-ID denylist. A purge removes the account's items and tombstones completely.
- **Every write rechecks the account and session.** Each write takes `users FOR KEY SHARE` and requires `status = 'active'`, then locks and rechecks the acting session. A non-active owner, or a revoked or expired session, is `401`. A TRD 04 `vop_` capability never reaches a learning route.
- **Signup creates the sync head.** The signup transaction creates the owner's sync head (§13). Re-registering with the same email creates a new `user_id`, and therefore a new head and epoch.

## 5. Revisions, writers and mutations **[Decided: D5]**

### 5.1 Per-owner revision feed

`learning_sync_heads` holds one row per owner with these fields:
- `epoch` (a random UUID);
- `revision`;
- `tombstone_horizon`;
- `live_words`;
- `content_bytes`.

Every write to an owner's learning rows locks this row first (push, writer registration, compaction, purge), assigns `head.revision + 1, +2, …`, and commits. Revisions are therefore gap-free and committed in order per owner. A cursor is opaque base64url `{epoch, revision}`.

### 5.2 Sync writers

A **writer** is one device's identity for writing to one account. **[Design]**
- `POST /v1/learning/sync/writers` creates a writer with a **server-generated** random `writer_id` and `last_seq = 0`, bound to the owner's current epoch. IDs are never reissued.
- The client stores `writer_id` in that account's cache partition and uses it for every push from that device to that account.
- **Cap (D9).** An owner has at most **20 writers**.
  - Registering when 20 exist retires exactly one: the writer with the oldest `last_used_at`. Ties go to the oldest `created_at`, then to the lowest `writer_id` in bytewise order.
  - The writer being created is never a candidate.
  - Retirement runs in the registration transaction under the head lock, so concurrent registrations are serialized and the count never exceeds 20.
- **What `last_used_at` means.** It is the database transaction time of the writer's registration, or of its latest push that returned `200`, including a push whose items were all duplicates. Pulls and state reads do not change it.
- **Writers and sessions are independent.**
  - Retiring a writer revokes no session.
  - Revoking or expiring a session leaves every writer in place. That covers TRD 02 revocation, the TRD 01 cap of 20 active sessions, logout and password changes.
  - A device signed in to the same account again keeps its writer.
  - Session revocation stays entirely governed by TRD 02.
- **Retirement is logical and immediate.** Retiring sets `retired_at`; from that commit on, every push from the writer is refused as a whole with `410 sync_reset_required` (`reason: writer_unknown`), and `GET …/state?writer_id=` reports it with `active: false` and its last `last_seq`. The cleanup job then deletes the writer's deduplication records in bounded, resumable batches, and only then removes the empty writer row. An epoch rotation (§8.2) retires every writer of the owner the same way.
- **No cascade bypasses the batches.** Records reference their writer `ON DELETE RESTRICT`, so a writer with records left cannot be deleted at all. The account purge uses the same order (§11.2).
- **After retirement** the device follows §8.3: a new snapshot, and its queue goes to manual review.

### 5.3 Mutation identity and sequence

A mutation is identified by `(writer_id, seq)`:

```
{ seq, op: create|update|delete|restore, entity_id, base_revision, changed_fields, data }
```

**Client rules (D10).** Every queued mutation is in exactly one of three states:

| State | Meaning | What the client may do |
|---|---|---|
| **Never sent** | Not yet in any transmitted request, so no `seq` has been assigned | Change, merge, rebase or drop it freely |
| **Sent, outcome unknown** | A request carrying it was transmitted (`seq` assigned and stored first) and no conclusive response arrived for that attempt: timeout, connection loss, or a `5xx`. **Once an attempt is unknown, the mutation stays in this state** until processing is resolved | **Retry it unchanged**: the same `writer_id`, the same `seq`, and the byte-identical mutation payload, even after pulling a fresh cursor or snapshot. A request-level refusal of a later retry (`400`, `409`, `410`, `413`, `429`, `503`) applies only to that retry; it says nothing about the earlier attempt, which may have been processed. Never change, renumber or move it to another writer |
| **Sent, outcome known** | A response settled it: a per-item result in a `200`, or a request-level refusal of an attempt with **no earlier unknown attempt** | Item result: done. Request-level refusal of a first, only attempt: the mutations return to **never sent**, and their `seq` values are released for renumbering. `410` with `epoch_changed` or `writer_unknown` sends the whole queue to the review set instead (§8.2, §8.3) |

**Resolving an unknown outcome.** Processing is resolved only by:
- a per-item result for that `seq` in a `200` push response (`duplicate`, a new outcome, `mutation_reused` or `mutation_expired`); or
- the authoritative writer high-water mark from `GET /v1/learning/sync/state?writer_id=`. `last_seq ≥ seq` **proves the mutation was processed, not that it applied**: it may have been rejected. The client then retries it unchanged to read its record (`duplicate` with `original_outcome`) or learns that the record expired (`mutation_expired`).

`last_seq < seq` read while an attempt could still be in flight proves nothing, so the client keeps retrying unchanged.

1. **Numbering.** A device numbers its writer's mutations contiguously (1, 2, 3, …) when it first puts them in an outgoing request. It stores the numbering before transmitting and keeps one request in flight per writer. A request with an unknown outcome is resolved, by unchanged retries, before any later mutation is sent.
2. **Atomic requests.** A request is processed atomically: it either commits every item outcome or none. So `last_seq` after an unknown-outcome request is either below its first `seq` or at least its last.
3. **`mutation_expired`.** The mutation was processed and its record has expired, so its outcome is gone. The client **never** gives that edit a new `seq` automatically. It reconciles from the snapshot: if the current server record already holds the edit's intended values, the edit is resolved. Otherwise the edit goes to the review set (§8.4), where only an explicit user action can create a new edit from it.
4. **No re-sending under a new identity.** A mutation that may have been processed is never re-sent under another writer or `seq`. Re-entering the same change takes a user action and is a new edit.

**Server rules,** evaluated under the head lock. `L` is the writer's `last_seq`:
1. A request's `seq` values must be strictly contiguous; otherwise `400 invalid_request`.
2. If the request's first `seq` is above `L + 1`, the response is `409 sequence_gap` and nothing is applied.
3. Each `seq ≤ L` is an already-processed mutation. It is **resolved first** (§5.4) and **never applied again**.
4. Only then is the new suffix (`seq > L`) admitted: for an import, capacity admission applies to that suffix alone (§9.4).
5. The suffix is processed in order. Every processed outcome (applied, merged, no-op or rejected) advances `last_seq`.
6. A request-level error (`400`, `409`, `410`, `413`, `429`, `503`, `5xx`) applies nothing and leaves `last_seq` unchanged.

Because numbering is contiguous and processing is in order, `last_seq` divides a writer's mutations exactly into processed and unprocessed. The server keeps `last_seq` for as long as the writer row exists, independently of the 30-day records.

### 5.4 Deduplication records and the expiry rule

For each processed mutation the server stores `(user_id, writer_id, seq) → request hash, outcome, code, result revision` in `learning_mutations` for **30 days**.

| Arriving `seq` | Record | Result |
|---|---|---|
| `≤ L` | present, same hash | `duplicate`: the original outcome plus the current canonical record. No new revision, write or metric |
| `≤ L` | present, different hash | `rejected` with `mutation_reused`; nothing applied |
| `≤ L` | **absent** (expired) | `rejected` with `mutation_expired`; nothing applied |
| `L + 1, …` | — | Processed by §5.6 and §6 |

**The server-enforced rule (D5):** a mutation at or below its writer's `last_seq` is never applied, whatever its `base_revision`, cursor or content. Its record decides only whether the caller gets the original outcome (`duplicate`), a reuse error, or `mutation_expired`.

A fresh cursor could change `base_revision`, but never `(writer_id, seq)`. A correct client does not even change `base_revision`: client rules keep a sent payload byte-identical. Server-generated writer IDs cannot be revived, and no client timestamp takes part.

The rule's limit: a client that deliberately re-authors old content as a new mutation creates a genuine new edit, and no server can tell it apart. Client rules 3 and 4 forbid doing so automatically, and the Flutter tests check it (§15).

**Concrete sequence.** Owner U has word X with `meaning = "a"` at revision 100. Device D has writer W with `last_seq = 41`; device E has writer V.

| Step | Request | Expected result |
|---|---|---|
| 1 | D, offline, edits X's meaning to "b" | Queued locally |
| 2 | D: `POST /v1/learning/sync/push {"epoch":E0,"writer_id":W,"kind":"sync","mutations":[{"seq":42,"op":"update","entity_id":X,"base_revision":100,"changed_fields":["meaning"],"data":{"meaning":"b"}}]}` | Server applies it at revision 101: `W.last_seq = 42`, record `(U,W,42)` stored. **The response is lost** |
| 3 | E pushes an update of X's meaning to "c" with `base_revision` 101 | Applied at revision 102 |
| 4 | Day 15: D resends step 2 unchanged | `results[0] = {seq:42, outcome:"duplicate", revision:101, record:{meaning:"c", revision:102}}`; nothing written |
| 5 | Day 31: the cleanup job deletes record `(U,W,42)` | `W.last_seq` stays 42 |
| 6 | D pulls with a fresh cursor (sees revision 102), then retries step 2's request **unchanged**: `seq` 42, `base_revision` 100, the same payload | `results[0] = {seq:42, outcome:"rejected", code:"mutation_expired"}`. X stays "c" at revision 102; no revision is allocated |
| 6′ | A faulty client instead rewrites the mutation with `base_revision: 102` and sends it as `seq` 42 | The same `mutation_expired`, with nothing applied: the server rule does not depend on the client keeping the payload |
| 7 | D reconciles from the snapshot (client rule 3). X's meaning is "c", not "b" | The edit goes to D's review set as "Your change to *meaning* ('b') was not applied; the current value is 'c'". It gets **no** new `seq` |
| 8 | The user chooses **Apply** for that review item | A new, never-sent mutation, assigned `seq` 43 when first sent, `base_revision` 102: applied at revision 103 by D2. It is a new edit made by an explicit user action, not a replay. Choosing **Discard** instead sends nothing |
| 9 | D sends `seq` 45 next, skipping 44 | `409 sequence_gap`; nothing applied |

### 5.5 Stale cursor and epoch rejection

These checks run before any mutation is evaluated:

| Condition | Response |
|---|---|
| Sync is closed (§8.2) | `503 sync_unavailable` with `Retry-After` |
| Malformed cursor or epoch | `400 invalid_request` |
| The push `epoch`, or the cursor's epoch, differs from the owner's current epoch | `410 sync_reset_required`, `reason: epoch_changed` |
| A push's writer is unknown, retired or belongs to another epoch | `410`, `reason: writer_unknown` |
| Cursor revision < `tombstone_horizon` | `410`, `reason: cursor_compacted` |
| Cursor revision > head revision | `410`, `reason: cursor_ahead` (defensive; a correct restore rotates the epoch) |

A `410` applies nothing. Its body carries the current `epoch`.

### 5.6 Per-item evaluation

These checks apply to mutations with `seq > L`. `(user_id, entity_id)` is looked up in the owner's rows only.

| Mutation | Owner's row | Result |
|---|---|---|
| `create` | absent | `applied`, if it fits the quota (§10); otherwise `rejected` with `quota_exceeded` |
| `create` | present (live or tombstone) | `rejected` with `id_in_use`. Lost-response creates are already caught by §5.4, so this only means a client ID collision |
| `update` or `delete` | live, `base_revision` ≤ head | Resolved by §6 |
| `update` | tombstone | `rejected` with `deleted_on_server`, returning the tombstone |
| `delete` | tombstone | `no_op` |
| `restore` | tombstone, `base_revision` ≥ the deletion revision | `applied` if it fits the quota, else `quota_exceeded`. A restore carries the full content |
| `restore` | tombstone, base below the deletion revision | `rejected` with `stale_base` |
| any | `base_revision` > head | `rejected` with `stale_base` |
| `update`, `delete` or `restore` | absent, `base_revision` < `tombstone_horizon` | `rejected` with `stale_base`: the item is never resurrected |
| `update`, `delete` or `restore` | absent otherwise | `rejected` with `unknown_item` |
| any | invalid data (§10.1) | `rejected` with `invalid_item` plus a `detail` |

**No-op detection.** An update whose `changed_fields` already equal the server values returns `no_op` and allocates no revision.

### 5.7 Pull

The client pushes before it pulls. `GET /v1/learning/sync/changes?cursor=` requires a feed cursor (`c1.…`). A page holds changes after the cursor in revision order, capped at **500 changes or 4 MiB of canonical item content**, whichever comes first, but always at least one change. The next cursor is the last revision returned.

A device with no cursor, or one told to reset, uses the snapshot protocol in §8.5. Feed cursors and snapshot page tokens are different formats: one is never accepted as the other (`400`).

Both reads run in one `REPEATABLE READ` read-only transaction. The rows returned and the head checked (epoch, horizon) therefore describe one moment, and a compaction is either fully visible or not visible at all.

## 6. Conflict resolution **[Decided: D2]**

- **The server's acceptance order decides.** `client_created_at` and the capture day are data only.
- **Field merge.** Each item stores `field_revisions`, the revision at which each field last changed. For every field in an update's `changed_fields`:
  - If the server field revision ≤ `base_revision`, the field is applied.
  - Otherwise the field changed elsewhere in the meantime. The incoming edit is now the last server-accepted edit, so it **wins**. The result is `merged`, with `conflicted_fields` naming the fields it overwrote.
  - Fields absent from `changed_fields` are never touched. `tags` and `examples` are each one whole-list field.
- **Deletes beat stale edits.** An update to a tombstone is `deleted_on_server`. A delete of a live item applies even when other edits arrived after its base.
- **Restore is explicit.** Only `restore`, with a base at or after the deletion, brings an item back, and it carries the full content. An update never revives.
- **No server-side content deduplication.** Duplicate hints stay a client feature (`WordIdentity.sameSense`).
- **Convergence.** Every result carries the canonical record, so devices that have pushed and pulled hold identical vocabulary.

## 7. Deletion propagation and tombstones **[Decided: D5]**

- **Content-free tombstones.** A delete clears every content field in the same transaction and keeps `(user_id, id, revision, deleted_revision, deleted_at)`. A database check enforces the empty content, and `content_bytes` becomes 0.
- **Kept 90 days** from `deleted_at`.
- **Compaction.** The cleanup runner compacts tombstones per owner in bounded batches, under the head lock. It raises `tombstone_horizon` to the highest compacted `deleted_revision`.
- **Account deletion** is the TRD 04 purge (§11.2), not a tombstone. Deactivation and suspension leave vocabulary unchanged.

## 8. Resets

### 8.1 Compacted cursor (same epoch)

On `cursor_compacted` the device was offline longer than the tombstone retention. Its writer and epoch are still valid. The queue is handled by state (§5.3):
1. **Snapshot.** Take a full snapshot and catch up from its boundary (§8.5). Then replace clean local records with the result, and delete clean local records absent from it, because their deletion was compacted.
2. **Sent edits with an unknown outcome come first.** They hold the lowest `seq` values. Retry them **unchanged** (same writer, same `seq`, byte-identical payload), with no rebase, even though the client now has a fresh snapshot and cursor. Results:
   - `duplicate`: the edit was applied earlier, and its original outcome is returned. Done.
   - a new item outcome (`applied`, `merged`, `no_op`, or `rejected` with `stale_base`, `deleted_on_server` and so on): it had never been processed and is processed now on its original base. A rejection is shown to the user like any other.
   - `mutation_expired`: it was processed and its record expired. Reconcile it from the snapshot (client rule 3). If the snapshot already holds the edit's intended values, it is resolved. Otherwise it goes to the review set (§8.4). It never gets a new `seq` automatically.
   - a request-level refusal of the retry (`429`, `503` and so on): it applies only to that retry. The edit stays sent with an unknown outcome and is retried unchanged later (§5.3).
3. **Never-sent edits come after.** They hold no `seq` yet, and may be rebased against the snapshot as below. They get their `seq` values, contiguously after the last one in use, only when first sent:

| Queued | Entity in snapshot | Rebased to |
|---|---|---|
| `create` | absent | The same create |
| `update` or `delete` | live | The same op, `base_revision` = snapshot revision |
| `update` | tombstone | Moved to the review set (§8.4), as "deleted on another device" |
| `delete` | tombstone | Dropped |
| `restore` | tombstone | Kept, `base_revision` = the tombstone's revision |
| `update` or `restore` | absent | Moved to the review set (§8.4). Re-creating the word there is a distinct user action |
| `delete` | absent | Dropped: the word is already gone |

4. **Push and store.** Push the never-sent mutations, then store the final cursor.

The distinction matters because a sent edit may already be on the server. Changing its payload or `seq` could make one change apply twice, or make an applied change look unapplied. A never-sent edit cannot be on the server, so rebasing it is safe.

### 8.2 Database restore **[Decided: D6]**

**Server runbook.** This extends TRD 04 §12.5. Every step completes before user traffic reaches sync:
1. Restore into an isolated instance and run `cmd/migrate up`.
2. Set `learning_sync_control.open = false`. Every sync route then returns `503 sync_unavailable`, even after the rest of the API reopens.
3. Apply the TRD 04 account-deletion ledger. Every ledger `user_id` is set to `pending_deletion` with its sessions revoked, and the purge job runs, including the vocabulary step (§11.2), until two checks pass:
   - `account_deletion_oldest_pending_seconds` is 0;
   - a verification query finds no `vocabulary_items`, `learning_sync_writers` or `learning_sync_heads` rows for any ledger `user_id`.
4. For every remaining head, set `epoch = gen_random_uuid()`. Retire every writer logically (`UPDATE learning_sync_writers SET retired_at = now() WHERE retired_at IS NULL`). The restored `last_seq` values are rewound and must not judge any device's queue; retirement makes every old writer's push `writer_unknown` at once. The cleanup job then deletes their records and rows in bounded batches (§5.2); it need not finish before reopening.
5. Delete restored export chunks and artifacts (TRD 04 step 4).
6. Only after the independent operator release decision may `learning_sync_control.open = true` be set. The current [staging preparation](../staging-verification.md) leaves it **false**.

**Client behavior on `epoch_changed` for its own account.** The account is the same `user_id` as the partition, so this is a restore:
1. Stop syncing for that account. Move the old queue, old `writer_id`, old cursor, and every local record that is dirty or differs from the server into that account's **review set**. That set is never sent.
2. Register a new writer, take a **new snapshot** with catch-up (§8.5), and replace the account cache with it.
3. Show the review set (§8.4). Nothing in it is replayed automatically or carried silently onto the new epoch.

A cursor from another account is never sent, because partitions are isolated. If it were, it would also get `epoch_changed`, and the account mismatch makes the client discard it.

### 8.3 Retired writer

On `writer_unknown` the epoch is unchanged. The writer was retired (§5.2) or never existed. Its `last_seq` is gone, so the client cannot tell processed from unprocessed. The client (D9, D10):
1. Moves the whole old queue (sent and never-sent) into the review set (§8.4).
2. Registers a new writer.
3. Takes a **new snapshot** with catch-up (§8.5) and replaces the account cache with it.
4. Shows the review set. Nothing from the old queue is sent under the new writer except through an explicit per-item action.

### 8.4 Review set **[Decided: D10]**

Each account cache has one review set, holding these unresolved items:
- the queue from before a restore (§8.2);
- a retired writer's queue (§8.3);
- local words that a restore snapshot lacks;
- `mutation_expired` edits that the snapshot does not reflect (§8.1).

Each item is shown next to the current server value. Actions are per item and **operation-specific**:

| Queued op | Word in the new snapshot | Action offered |
|---|---|---|
| `delete` | absent or tombstoned | None: **already resolved**, so it is removed from the review set without asking |
| `delete` | live | **Apply** sends a new `delete` (never sent, `base_revision` = the snapshot revision). It stays a delete |
| `update` | live | **Apply** sends a new `update` of the item's changed fields against the snapshot revision |
| `restore` | tombstoned | **Apply** sends a new `restore` with the tombstone's revision |
| `update` or `restore` | absent | No Apply. Only a **distinct** "Add again as a new word" action, which creates a new item with a new ID from the local content |
| `create`, or a local word the snapshot lacks | absent | Only "Add again as a new word" (a distinct action, new ID) |
| `create` | present | None: already resolved (the word exists) |

Every applied action is a new, never-sent mutation. It gets a `seq` under the current writer when first sent, and it is an ordinary new edit under D2 and the quota. **Discard** deletes the item and sends nothing.

Rules:
- There is **no bulk replay**: no "apply all" and no automatic application.
- Items stay until the user acts, the cache is removed, or deletion of the account is confirmed. Confirmed deletion clears the review set with the rest of the cache (§9.5).
- Review items never leave their account cache and are never imported into another account.

### 8.5 Snapshot and catch-up hand-off **[Design]**

`GET /v1/learning/sync/snapshot` pages the owner's live words as of a captured head revision H, in id order.
- **The first page captures H.**
- **Continuation is bound.** Every `next_page_token` (`s1.…`) binds the epoch, H and the last id returned. The epoch is a random value per account, so a token from another account (or from before a restore) is refused with `410 epoch_changed`.
- **Paging cannot lose writes.** A page returns only live words with `revision ≤ H`. A word created, changed or deleted after H therefore has a revision above H. It is excluded from later pages, and it reaches the client through the catch-up feed from H. That feed carries tombstones, so a word read on an early page and deleted later is removed during catch-up.
- **Every page carries `catch_up_cursor`,** the feed cursor for revision H.

The client:
1. **Stages** the pages without touching its current cache, until `next_page_token` is null.
2. **Catches up** with `GET …/changes?cursor=<catch_up_cursor>`, applying changes to the staged copy, until `has_more` is false. This happens **even when the first catch-up page is empty**: only then is the tail known.
3. **Replaces** the local cache with the staged copy, then keeps the last cursor.

**If compaction overtakes the boundary,** a tombstone with a revision above H may be compacted before the catch-up reads it, raising `tombstone_horizon` above H. Then the next snapshot page and the catch-up both answer `410 cursor_compacted`. The client discards the staged copy (its cache is untouched) and starts a new snapshot with a new H.

A cursor or token whose revision is above the head is `410 cursor_ahead`.

## 9. Local partitions, guest data and account caches

### 9.1 Partitions and sign-out **[Decided: D3]**

The rebuilt client keeps separate local partitions:
- **one guest partition,** with a random `guest_dataset_id`;
- **one cache per account,** keyed by `user_id`, holding its words, queue, cursor, writer and review set.

**Lifetime of the guest dataset ID.** It is created when the guest partition first holds a word. It stays the same until the user explicitly erases the guest notebook, or the app is reinstalled. Importing words out of it does not change it.

**Sign-out.** Sign-out **opens the guest notebook and closes the account cache**. A closed cache is neither shown nor editable, and its queue waits, unsent, until that account signs in again. Edits made while signed out go to the guest partition only. This closes §2.2 gap 6.

A cache is never merged into another cache, never relabeled as guest data, and never sent with another account's tokens.

### 9.2 Import consent **[Decided: D3]**

- **Eligible words.** Only guest words with established guest provenance (§9.6) can be imported or counted in the prompt. Legacy untagged words are shown in the guest notebook but never offered.
- **When the device asks.** On sign-in as account U, the device asks once if the guest partition holds eligible words and there is no stored decision for `(U, guest_dataset_id)`.
- **Recording the decision.** The device stores `imported` or `declined` with the time. U is not asked again for that dataset; another account signing in is asked separately.
- **Later imports.** Guest words added later, or a declined dataset, can be imported only through the explicit "Import guest words" action.
- **Online only.** An import needs a connection, because the device first pulls U's cache to show duplicates and capacity.

### 9.3 Choosing words and capacity **[Decided: D3]**

1. **Preview.** The client shows:
   - the guest words that are not duplicates of U's live words (same word and sense); duplicates are listed and excluded by default;
   - U's remaining capacity from `GET …/state`, as `word_limit − live_words` words and `content_byte_limit − content_bytes` bytes. Each word's size is its canonical size (§11.1), which the client computes with the same encoding.
2. **Selection.** If the candidates fit, the user may import all of them or choose some. If they do not fit, **the user chooses which words to import**, up to the shown capacity. Words not chosen stay in the guest partition on the device.
3. **Moving words.** A word moves into U's cache only when its `create` is applied. A per-item rejection (`invalid_item`, `id_in_use`) leaves it in the guest partition. For `id_in_use` the client may give the guest word a fresh UUID, and the user can include it in a later explicit import.

### 9.4 Atomic import batches **[Decided: D3]**

Each import request is `kind: "import"`, contains only `create` mutations (up to 200), and carries `capacity_basis: {live_words, content_bytes}`. The basis comes from the latest `state` or push response; a push response reports the new values after its commit.

Under the head lock, the server checks two things before applying anything:
- the basis equals the current head;
- the batch's valid creates fit both limits.

If either check fails, the whole request is `409 capacity_changed` with the current values. **Nothing is applied** and `last_seq` is unchanged. This is a conclusive request-level refusal, so the batch's mutations return to never sent (§5.3).

The client then (D10):
1. Refreshes capacity with `GET …/state`.
2. Shows the updated capacity. **It always asks the user to confirm before resubmitting**, even when the remaining selection still fits. If the selection no longer fits, the user first chooses again among the remaining selected words.
3. Resubmits only after confirmation, with the new basis and fresh `seq` values.

**Processed sequences come first.** Server rule 3 resolves an import's already-processed `seq` values before admitting capacity:
- An **entirely processed retry** returns `duplicate` results (or `mutation_expired`) even if the original import changed capacity and the basis is now stale.
- In a **mixed batch,** capacity admission applies only to the new suffix.
- A **capacity refusal** (`409 capacity_changed`, with `live_words`, `content_bytes` and the unchanged `last_seq`) applies nothing. It leaves that suffix and its `seq` values untouched, so they are unprocessed and may be re-chosen after confirmation. The processed prefix keeps its records; the client may retry it alone to read their results.

Batches already applied stay imported. Words excluded at any point, whether never chosen, deselected after `capacity_changed`, or not confirmed, stay in the guest partition until the user explicitly imports them later. Ordinary `kind: "sync"` pushes keep the per-item `quota_exceeded` behavior (§10.2).

### 9.5 Account caches and deletion **[Decided: D4]**

- **Signing into a different account** leaves other caches closed. V1 has no account-to-account copy.
- **What counts as confirmed deletion:**
  - this device received the accepted (`202`) deletion response;
  - or it read the TRD 04 receipt (`pending` or `completed`) with the saved capability.

  Acceptance is irreversible, so the client then clears that account's **entire** cache: words, queue, cursor, writer, review set, and its entries in guest import decisions. It keeps no local copy.
- **Unconfirmed deletion.** A device that cannot confirm (the account was deleted from another device) just sees `401`s. The cache stays closed like any other account's cache, with a settings action to remove it. It is never importable.
- **Re-registration.** A new account registered with the same email has a new `user_id`. It can never reach the old cache, which is either cleared or closed.

### 9.6 Backups and guest provenance **[Decided: D4, D10]**

Backups made by the rebuilt app's local backup feature (`BackupService`) record their source as `"source": {"kind": "account", "user_id": "…"}` or `{"kind": "guest"}`.

| Backup | Import |
|---|---|
| Tagged with the signed-in account's `user_id` | Into that account's cache, as an explicit import (§9.3 and §9.4) |
| Tagged with any other `user_id` (including while signed out, and a deleted account) | **Rejected:** "This backup belongs to another account" |
| Tagged guest by the rebuilt app | Into the guest partition. Each word keeps the provenance recorded in the file, and words recorded as `guest_created` can reach an account through import consent |
| Untagged (legacy backups, including every backup made before the rebuild) | **Opened in the guest notebook** with provenance `legacy_untagged`: viewable and editable on the device, but **ineligible for account sync** (D10). They are never offered for import |

**Guest provenance.** Every word in the guest partition records one of two values:
- `guest_created`: the word was created in the rebuilt app's guest notebook on this device, or arrived from a guest-tagged backup that recorded `guest_created` for it.
- `legacy_untagged`.

Only `guest_created` words are eligible for import into an account. Rules:
- Editing a `legacy_untagged` word does not change its provenance, and v1 offers no conversion.
- A learner who wants such a word in an account enters it again as a new word, which is a new item with a new ID.
- A guest-tagged backup records each word's provenance, so legacy words keep `legacy_untagged` through any number of backup round trips.

**Data already on a device.** When the rebuilt app first migrates the pre-rebuild local database, **every row is `legacy_untagged` unless positive guest provenance exists.** The pre-rebuild schema records no provenance, so in practice every migrated word is `legacy_untagged`. That includes:
- words in the unowned notebook that arrived through an untagged backup imported before the upgrade: nothing distinguishes them from words typed in;
- words of an account notebook whose `notebook_owner` marker was cleared at sign-out (the old `activateNotebook(null)` path): they look unowned but may belong to an account;
- words in a notebook owned by a pre-Go (Rust-era) account, which has no Go identity.

They open in the guest notebook and are never offered for import (D10).

A tag is a client rule, not a security boundary: the server cannot police a file the user has edited. Server-side isolation comes from §4, and nothing a user imports can touch another account's data.

## 10. Limits and quota **[Decided: D7]**

### 10.1 Limits

| Limit | Value | Enforced |
|---|---|---|
| Live words per account | **50,000**; tombstones do not count | `live_words` on the head row |
| Size of one word | **8 KiB** (8,192 bytes) of canonical content JSON, measured **after escaping** (§11.1). This is a separate check from the field limits: a word within every field limit (up to 14,400 code points, which can need far more than 8 KiB) is still refused when its serialized form exceeds 8 KiB | `invalid_item`, `detail: item_too_large` |
| Content per account | **64 MiB** (67,108,864 bytes): the sum of live words' canonical sizes | `content_bytes` on the head row |
| Field limits (D8), counted in **Unicode code points** (scalar values), not bytes, UTF-16 units or grapheme clusters | `word` 1–200 · `meaning` ≤ 2,000 · `pronunciation` ≤ 200 · `source` ≤ 500 · `examples` ≤ 20 entries of ≤ 500 each · `tags` ≤ 30 entries of ≤ 50 each | `invalid_item`, `detail: field_too_long` or `too_many_entries`, with `field` |
| Characters (D8) | Valid UTF-8 only (`detail: invalid_utf8`). No U+0000–U+001F except TAB (U+0009) and LF (U+000A) (`detail: control_character`). `part_of_speech` from the fixed list; capture day and `client_created_at` in years 0001–9999 | `invalid_item` with a `detail` |
| Push request | ≤ 200 mutations and ≤ 2 MiB of request body | `413 payload_too_large` |
| Pull page | ≤ 500 changes and ≤ 4 MiB of content | §5.7 |
| Active writers | 20 per owner | §5.2 |

**Validation order.** A word is checked in this order: UTF-8 validity, control characters, `part_of_speech` and dates, the field limits, then the serialized 8 KiB size. The first failure is reported. Clients apply the same rules before queuing, so an `invalid_item` result means a client bug or an edited backup.

**Counting.** Limits count code points, so a user-perceived character may count as more than one: an emoji with a skin-tone modifier is 2, an emoji family sequence is several, and a letter plus a combining accent is 2. Precomposed Vietnamese letters count 1. The client's character counter must use the same measure.

### 10.2 Quota behavior

- **Which mutations count.** `create` and `restore` raise `live_words` and `content_bytes`. An `update` changes `content_bytes` by the size difference. `delete` lowers both.
- **Sync pushes** (`kind: "sync"`) apply in request order after the head lock. A `create` or `restore` that would exceed either limit, or an `update` that would exceed the byte budget, is `rejected` with `quota_exceeded` (`limit: "words"` or `"bytes"`). Other items still apply, so a client that sends deletes first frees capacity within the same batch.
- **Words over the limit stay local until explicitly uploaded.** A word whose create got `quota_exceeded` stays in the account cache, marked "not backed up". It is not queued again automatically. When `state` shows capacity, the client offers "Back up now", and that explicit action queues a **new** create. The rejected mutation itself is never re-sent (client rule 4). Words excluded from an import likewise stay in the guest partition until explicitly imported (§9.4).
- **Imports** are atomic for capacity (§9.4).
- **Concurrent pushes from several devices** are serialized by the head lock, so the limits can never be exceeded.
- **Lowered limits.** If a later entitlement change lowers a limit, existing words are never deleted; only growth is refused. Phase 6 owns that.

## 11. TRD 04 integration **[Decided: D7]**

### 11.1 Export: format and verified size bound

**Canonical content encoding.** A word's content is the JSON object:

```
{"word":…,"meaning":…,"pronunciation":…,"part_of_speech":…,"source":…,"examples":[…],"tags":[…]}
```

The encoding is fixed:
- keys in that order;
- no whitespace;
- `null` for absent optional fields;
- strings escape only `"` → `\"`, `\` → `\\`, LF → `\n` and TAB → `\t`;
- every other character is written as its raw UTF-8 bytes. Other control characters are refused on input.

Server and client use this one encoder. `content_bytes` is the length of this encoding, so the 8 KiB and 64 MiB limits already include escaping. The export writes each word's content with **the same encoder** and asserts that the length equals the stored `content_bytes`, failing closed if it does not.

**Export layout** (schema version 2):
- **Header:** `{"schema_version":2,"snapshot_at":"…","snapshot_revision":N,"account":{…TRD 04 fields…},"vocabulary":[`
- **One element per live word:** `{"id":"<36>","revision":<≤19 digits>,"capture_day":"YYYY-MM-DD","client_created_at":"<24>","created_at":"<24>","updated_at":"<24>","content":<content>}`
- **Trailer:** `]}`

Formats: timestamps are UTC with milliseconds (`2006-01-02T15:04:05.000Z`, 24 characters), and the revision is a positive bigint.

**Excluded:** tombstones, deduplication records, writers, cursors and local review progress.

**Bound derivation:**

| Part | Bytes |
|---|---|
| Fixed envelope per word, excluding content: `{"id":"`+36+`",` = 45; `"revision":`+19+`,` = 31; `"capture_day":"`+10+`",` = 27; `"client_created_at":"`+24+`",` = 47; `"created_at":"`+24+`",` = 40; `"updated_at":"`+24+`",` = 40; `"content":` = 10; `}` = 1; separator `,` = 1 | **242** per word |
| Envelopes for 50,000 words | 12,100,000 |
| All content (the 64 MiB budget; reachable at 50,000 words, since 1,342 B average is below 8 KiB) | 67,108,864 |
| Header and trailer. The account fields are bounded by TRD 01/03 validation, and the generator **enforces** ≤ 16 KiB, failing closed | ≤ 16,384 |
| **Plaintext JSON P** (and the download body) | **≤ 79,225,248 bytes (75.56 MiB)** |

The generator also enforces the overall bound. If P would exceed it, for example on data written before a limit existed, the job fails closed with an error metric rather than publishing.

**Chunking and encryption.**
- **Chunks.** P is split into consecutive 1,048,576-byte plaintext chunks (the last may be shorter). That gives at most ⌈79,225,248 / 1,048,576⌉ = **76 chunks**, and at least 1.
- **Encoding byte.** Each chunk is sealed as `encoding byte ‖ body`:
  - `0x01` means the body is raw DEFLATE of the chunk, chosen **only when it is shorter** than the chunk;
  - otherwise `0x00` and the raw chunk.

  Compression can therefore never enlarge a chunk.
- **Sealing.** The body is sealed with the existing AES-GCM keyring (`nonce(12) ‖ ciphertext ‖ tag(16)`, 28 bytes of overhead). The associated data is `artifact_id ‖ seq (uint32, big-endian) ‖ final flag`; the current `Seal` binds only a row UUID, so this needs a keyring variant that accepts associated data.
- **Per-chunk bound:** ≤ 1 + 1,048,576 + 28 = **1,048,605 bytes**, enforced by a check on the row.
- **Total sealed payload:** ≤ P + 76 × 29 = **79,227,452 bytes**. This is a bound on the sealed chunk payloads (`octet_length(sealed)` summed). It **excludes** PostgreSQL row, tuple, TOAST and index overhead and the operation metadata, which are not claimed.
- **Memory.** Generation and download each process one chunk at a time. That is a design property; v1 does not measure memory.

Two claims from v0.2 are withdrawn because they could not be guaranteed: "gzip of the whole stream" and "≤ 77 chunks".

**As implemented and verified** (§17): `AppendCanonical` is the single encoder for the quota and the export, and `AppendExportRow` re-encodes each stored word and fails the job if the length differs from `content_bytes`. The generator enforces the header bound, the word count, the plaintext bound and the chunk count, and fails closed. A unit test pins every bound constant, the 241-byte envelope at maximal values, and the raw fallback, under which an incompressible full chunk seals to exactly 1,048,605 bytes. `TestLearningRights_ExportAndPurgeAtTheLimit` exports 50,000 words whose canonical content totals exactly 67,108,864 bytes, with escaped quotes, 19-digit revisions and year-9999 timestamps. It measured 79,209,289 plaintext bytes in 76 chunks, and the download decodes to all 50,000 words.

**Generation transaction.**
1. One `REPEATABLE READ` transaction reads the user, head and live items ordered by `(user_id, id)`, and writes the chunk rows.
2. It then locks the user `FOR NO KEY UPDATE` and the operation row, rechecks lifecycle and email revisions, and publishes: `state = ready`, `schema_version = 2`, `artifact_plain_bytes = P`.

Pushes are not blocked, since they take `KEY SHARE`, and they do not change the snapshot. A concurrent state change makes the final lock fail with `40001`, and the job retries. A generation that runs past 30 s is aborted and retried.

**Download** writes the TRD 04 audit event, then streams the chunks in order with `Content-Length: artifact_plain_bytes`. Each chunk is authenticated before its bytes are sent, and inflation is capped at 1,048,576 bytes per chunk. A failing chunk, or a missing final chunk, aborts the connection short of `Content-Length`.

**Expiry and cancellation** delete the chunk rows in the same transaction that ends the artifact: expiry after 24 h, cancellation at deletion acceptance, deactivation, reactivation or a revision change (TRD 04).

**Amended 2026-11-15 by [TRD 09](09-free-premium-entitlements.md) §7.** Export schema 3 adds a fixed-width `entitlements` section (plan and at most 50 retained grant periods, at most 7,812 bytes) inside the existing 16 KiB header budget. The worst-case schema-3 header measures 13,138 bytes, so `MaxExportPlainBytes` (79,225,248) and `MaxExportChunks` (76) are unchanged. Both plans keep the §10 limits.

### 11.2 Purge

The TRD 04 purge drains learning rows inside its final step (`purge_step` 2), before sessions, outbox and the erase. **`purge_step` keeps its 0..2 range;** the v1.1 widening is withdrawn.

Each checkpoint transaction takes TRD 04's locks (L0, owned L2, L2b, L3 `FOR UPDATE`), then the head (L4c), and removes **one bounded batch**, children before parents (`learning.PurgeBatch`):
1. live and tombstoned `vocabulary_items`;
2. once those are gone, every writer is retired, then `learning_mutations` are deleted;
3. then the now-empty writers;
4. then the head.

The final transaction checks that no learning rows remain (`learning.HasRows`) before `accounts.Erase`.

Every multi-row learning table references `users`, and records reference their writer, `ON DELETE RESTRICT`. An erase or writer delete with rows left therefore **fails instead of cascading**: no parent cascade can bypass the batch bound. The head is the only cascade, and it is exactly one row.

Export chunks reference their operation with `RESTRICT` too, and are deleted with every cancellation and expiry.

A failure leaves the account sealed and the job pending, and the rerun resumes from the last checkpoint. No sync write can land during purge: every session was revoked at acceptance, and §4 requires `active`. No deleted-ID record survives the purge (D4).

### 11.3 Restoration fencing

§8.2 is the vocabulary extension of TRD 04 §12.5. Ledger replay and purge come first, then epoch rotation, logical writer retirement and chunk removal, and only then is sync reopened. `learning_sync_control.open` makes "sync closed" server-enforced (`503`) rather than a runbook convention. The 90-day ledger exceeds the 30-day backups, so every restorable backup is covered.

## 12. API **[Implemented]**

All six routes use bearer authentication through `authenticated`. They return `503 sync_unavailable` (with `Retry-After`) while `learning_sync_control.open` is false, and take strict JSON with no query string unless stated. The normative contract is `backend/api/openapi.yaml` (version 1.4.0-trd05).

| Route | Request | Success |
|---|---|---|
| `GET /v1/learning/sync/state?writer_id=` (`writer_id` optional) | — | `200 {epoch, head_revision, tombstone_horizon, live_words, word_limit, content_bytes, content_byte_limit, writer: {writer_id, last_seq, active} \| null}` |
| `POST /v1/learning/sync/writers` | `{}` | `201 {writer_id, last_seq: 0, epoch}`; may retire the least recently used writer |
| `POST /v1/learning/sync/push` | `{epoch, writer_id, mutations: [{seq, op, entity_id, base_revision?, changed_fields?, data?}]}`; 1–200 mutations, ≤ 2 MiB | `200 {results: [{seq, entity_id, outcome, original_outcome?, code?, detail?, field?, limit?, conflicted_fields?, revision?, record}], head_revision, live_words, content_bytes, last_seq}` |
| `POST /v1/learning/sync/import` | `{epoch, writer_id, capacity_basis: {live_words, content_bytes}, mutations: [create…]}` | As push. The v1.1 `kind` field became this separate route, so every request field stays required |
| `GET /v1/learning/sync/changes?cursor=&limit=` | Feed cursor required (`c1.…`); `limit` 1–500 | `200 {epoch, changes: [VocabularyRecord], cursor, has_more}` |
| `GET /v1/learning/sync/snapshot?page_token=&limit=` | Page token optional (`s1.…`; absent starts a snapshot); `limit` 1–500 | `200 {epoch, snapshot_revision, items: [VocabularyRecord], next_page_token \| null, catch_up_cursor}` |

**Mutation shapes,** strictly by op:
- `create`: `{seq, op, entity_id, data}`
- `update`: `{seq, op, entity_id, base_revision, changed_fields, data}`, where `data` holds exactly the changed fields
- `delete`: `{seq, op, entity_id, base_revision}`
- `restore`: `{seq, op, entity_id, base_revision, data}`

A full `data` holds every content field plus `capture_day` and `client_created_at`. The deduplication hash is SHA-256 of the mutation object's exact bytes.

**Records.** `VocabularyRecord` is `{entity_id, revision, deleted, content | null, capture_day | null, client_created_at | null, updated_at}`. A duplicate result carries `original_outcome` and the original codes and revision.

**Request-level errors:**
- `400 invalid_request`
- `401 unauthorized`
- `409 sequence_gap`
- `409 capacity_changed` (import; body has `live_words`, `content_bytes`, `last_seq`)
- `410 sync_reset_required` (body has `reason` ∈ {`epoch_changed`, `writer_unknown`, `cursor_compacted`, `cursor_ahead`} and `epoch`)
- `413 payload_too_large`
- `415 unsupported_media_type`
- `429 rate_limited`
- `500 internal_error`
- `503 sync_unavailable`

**Item codes:** `invalid_item`, `mutation_reused`, `mutation_expired`, `stale_base`, `unknown_item`, `deleted_on_server`, `quota_exceeded` (with `limit`), `id_in_use`.

**`invalid_item` details:** `invalid_utf8`, `control_character`, `invalid_part_of_speech`, `invalid_date`, `field_empty` (a blank word, added in v1.2), `too_many_entries`, `field_too_long` (the last two name the `field`), `item_too_large`.

**Rate limits,** per session per minute: 60 pushes and imports (`learning_push`), 120 reads of state, changes and snapshot (`learning_pull`), 10 writer registrations (`learning_writer`).

**Observability.** Routine sync writes no audit rows, and content never enters audit or logs. Metrics are counted after commit, with fixed labels:
- `learning_sync_push_total{route,result}`;
- `learning_sync_items_total{op,outcome}`;
- `learning_sync_reset_total{reason}`.

## 13. Persistence (migration 00011) **[Implemented]**

**Tables:**
- **`learning_sync_control`:** a singleton, `open` default **false**.
- **`learning_sync_heads`:** one row per user, `ON DELETE CASCADE` (bounded: one row).
  - Created by an `AFTER INSERT` trigger on `users` in the same transaction, whichever path creates the account, and backfilled for existing users.
  - Checks bound `live_words` and `content_bytes`.
- **`learning_sync_writers`:** server-generated `writer_id`, `epoch`, `last_seq`, `last_used_at`, `retired_at`.
  - `users` FK is `RESTRICT`.
  - Indexes: a partial LRU index on active writers, and one on retired writers.
- **`learning_mutations`:** `(user_id, writer_id, seq)`, `request_hash`, `result jsonb` (fixed codes, field names and revisions only), `created_at`.
  - FK to its writer is `RESTRICT`; index on `created_at`.
- **`vocabulary_items`:** `(user_id, id)`; content columns with `text[]` examples and tags; `capture_day date`; `client_created_at`; `content_bytes` (canonical size); `revision`, `created_revision`, `field_revisions jsonb`, `deleted_at`, `deleted_revision`.
  - A check makes a row either live (content present, 1–8,192 bytes) or a tombstone (no content or dates, `content_bytes = 0`, empty `field_revisions`).
  - `users` FK is `RESTRICT`.
  - Indexes: `(user_id, revision)`, and partial on `deleted_at`.
- **`account_export_chunks`:** `(operation_id, seq 0..75)`, `final`, `key_id`, `sealed` (≤ 1,048,605 bytes). FK to `account_operations` is `RESTRICT`.

**Alterations:**
- `account_operations` gains `schema_version` and `artifact_plain_bytes`.
- The migration ends any `ready` version-1 artifact (`state = expired`), because the version-2 download path does not serve them.
- `artifact_ciphertext` stays and is not dropped in this release.

**Cleanup jobs.** The appended `learning_sync` runner job (advisory key `lockBase + 10`, batched) runs these in order:
1. tombstone compaction for one owner at a time, under the head lock, raising the horizon in the same transaction;
2. deduplication records older than 30 days;
3. retired writers' records;
4. empty retired writers.

Batch deletes use the established `ctid = ANY(ARRAY(… LIMIT n))` pattern with the predicate repeated on the outer side. Chunks are deleted with TRD 04 artifact expiry and every cancellation.

`backend/internal/learning/` owns these writes, apart from the purge and cleanup jobs it exports to `lifecycle` and `maintenance`.

## 14. Transactions and lock order **[Implemented]**

This adds **L4c, the learning sync head**, between L4b and L5 in the TRD 01 §7.1 order (with TRD 04's L0/L2b).

| Operation | Order |
|---|---|
| Push, import, writer registration (`db.Tx`, READ COMMITTED, whole-transaction retry) | Gate open check (autocommit) → rate limit (autocommit) → L3 `users FOR KEY SHARE`, requiring good standing → L4a `session.LockActing` (the acting session `FOR UPDATE`, not revoked or expired; v1.1 said `FOR SHARE`) → L4c head `FOR UPDATE` → writer row, record lookups, item reads and writes, record inserts, head and writer update. The head lock serializes every writer of one owner. No L5 writes |
| Signup | The `users` trigger inserts the head after the user row (L5) |
| Compaction | Per owner: L4c → bounded delete → horizon update, one transaction |
| Record expiry, writer cleanup | Bounded autocommit deletes; RESTRICT forbids removing a writer with records |
| Purge (TRD 04 step 2) | TRD 04 ordering (L0, owned L2, L2b) → L3 `FOR UPDATE` → L4c → one bounded batch |
| Export generation | `REPEATABLE READ`: reads and chunk inserts → L3 `FOR NO KEY UPDATE` → operation row → publish. A change since the snapshot fails with `40001`, and generation is retried up to three times |
| Changes, snapshot | One `REPEATABLE READ` read-only transaction, no locks |
| State | Single autocommit reads |

**Why this cannot deadlock or slip past deletion.** Deletion acceptance and deactivation take L3 `FOR NO KEY UPDATE`, which is compatible with `KEY SHARE`, then revoke sessions at L4b. That revocation waits for any push holding the acting session.
- If the push commits first, its data exists before the boundary and is purged later.
- If acceptance commits first, the push's L4a recheck finds the session revoked: `401`, nothing written.
- Acceptance never takes L4c, so neither side waits on a lock the other takes later.

Both orders are forced in `TestLearningRights_DeletionRacesPurgeAndReregistration`.

## 15. Acceptance tests

### 15.1 Server-side (implemented, PostgreSQL through the real router)

| Requirement | Tests (`backend/test/integration/learning*_test.go`, plus unit tests) |
|---|---|
| Closed by default, contract, errors, limits | `TestLearning_ClosedUntilOpened`, `TestLearning_ContractErrors`, `TestLearning_InternalErrors`, `TestLearning_RateLimits`. Together they cover every documented status and code of the six routes |
| Two offline devices, field merge, delete and restore rules, clocks | `TestLearningSync_TwoOfflineDevices` |
| Lost-response retries, refusals that apply only to the retry, `duplicate`, `mutation_reused`, expiry, a fresh cursor (unchanged and rewritten), high-water read, `sequence_gap` | `TestLearningSync_LostResponseAndExpiry` (the §5.4 sequence) |
| Concurrent identical requests; two sessions forced in both orders at the head lock; owners independent | `TestLearningSync_ConcurrentIdenticalAndConcurrentEdits` |
| Processed prefix before import admission; mixed batch; suffix untouched | `TestLearningSync_ImportCapacityAfterProcessedPrefix` |
| Quota at 50,000 words and 64 MiB, the 8,192/8,193 boundary including escaping, code points, characters, order, invalid UTF-8, the last slot | `TestLearningSync_QuotaAndValidationAtTheLimit`, unit tests in `internal/learning` |
| Snapshot hand-off under concurrent writes, empty tail, compaction past H, stale edits after compaction | `TestLearningSync_SnapshotCatchUpAndCompaction` |
| Writer cap, deterministic ties, concurrent registration, `last_used_at`, logical retirement, interrupted bounded cleanup, sessions independent | `TestLearningSync_WritersRetirementAndCleanup` |
| No unbounded cascade | `TestLearningSync_NoUnboundedCascade` |
| Restore runbook: gate, epoch rotation, writer retirement, rewound head | `TestLearningSync_RestoreRunbook` |
| Push vs deletion acceptance (both orders), stale device, interrupted purge, re-registration | `TestLearningRights_DeletionRacesPurgeAndReregistration` |
| Export v2 contents, canonical content, tombstones excluded, tampering, cancellation and expiry delete chunks | `TestLearningRights_ExportIncludesVocabularyAndFailsClosed`, `TestLearningRights_MultiChunkExportDetectsReorderAndTruncation`, `internal/lifecycle` `TestChunkEncodingNeverGrowsAndRoundTrips` |
| Export and purge at the limit | `TestLearningRights_ExportAndPurgeAtTheLimit` |
| Migration, schema, indexes | Existing schema and migration tests, extended to 00011 |

### 15.2 Flutter-only (not testable on the server; sync stays closed until these pass)

1. The three queue states:
   - a sent edit is retried with the same writer, `seq` and bytes (asserted by request hash);
   - a refusal after an unknown attempt never releases its `seq`;
   - `last_seq ≥ seq` triggers an unchanged retry to read the record.
2. `mutation_expired` is reconciled from the snapshot or goes to review, and is never renumbered.
3. Snapshot staging: catch-up runs to `has_more = false` (also when empty) before the cache is replaced, and `cursor_compacted` discards the staged copy.
4. Review actions are operation-specific (§8.4): a delete against an absent or tombstoned word resolves without asking, a delete against a live word stays a delete, re-creation is a distinct action, and there is no bulk replay. Review items are cleared on confirmed deletion.
5. Sign-out opens the guest notebook and closes the cache; its queue stays unsent.
6. Import consent:
   - asked once per `(account, guest_dataset_id)`; later imports are explicit;
   - an over-capacity import lets the user choose, and excluded words stay local;
   - `capacity_changed` refreshes capacity and asks for confirmation again.
7. Pre-rebuild migration marks every row `legacy_untagged` unless positive guest provenance exists. That includes an untagged backup imported before the upgrade, and a notebook whose owner marker was cleared at sign-out.
8. Backups: tagged with another `user_id` are refused; untagged ones open in the guest notebook only.
9. Words over quota stay local until "Back up now".
10. Confirmed deletion clears the cache, queue, cursor, writer, review set and import decisions.
11. The shared canonical encoder produces the same bytes and code-point counts in Dart and Go, against shared test vectors.

Local Flutter implementation and the 11-check result mapping are recorded in
[Flutter verification](05-flutter-verification.md). The local checks and Go identity/session/deletion end-to-end scenarios pass;
opening sync still requires the recorded device/deployment checks and operator decision.

## 16. Remaining implementation blockers

1. **The rebuilt Flutter client and §15.2.** The local SQLite/HTTP/widget checks now pass ([verification](05-flutter-verification.md)). Production Flutter auth/refresh/deletion adapters now use the Go contract and pass local Go/PostgreSQL/Mailpit end-to-end tests; real-device and deployment checks remain release gates. Sync stays closed (`learning_sync_control.open = false`); opening it is a deliberate operator action after those gates are met.
2. **Shared encoder vectors for Dart.** The Go encoder and its tests exist. The vectors (escaping, emoji, combining marks, the 8,192/8,193-byte boundary) still have to be exported to the Flutter test suite.
3. **Restore tooling and drill.** TRD 04 §12.5 and this section now have executable isolated SQL and a local synthetic pg_dump/pg_restore drill ([staging checklist](../staging-verification.md) §6–7). Hosted backup/PITR, disaster-time authoritative-ledger custody and operator cutover have not been drilled; they remain release gates.
4. **Release order.** Migration 00011 runs through `cmd/migrate` before the binaries. It ends any ready version-1 export and adds a trigger on `users`. Every instance must run the new binaries before sync opens.
5. **Not covered by a test.** A forced `40001` retry of a push is not exercised: the suite fails on any counted retry. The atomicity it relies on is the existing `db.Tx` behaviour, tested in TRD 01.

No product decision remains open.

## 17. Implementation and verification record — 2026-11-14

### 17.1 What was built

The backend portion, on `feat/go-email-auth-account-foundation`, without commits or pushes:
- **Migration `00011_learning_sync.sql`** (expand-only).
- **`backend/internal/learning/`:**
  - the canonical encoder and validation (`canon.go`);
  - strict mutation decoding, which detects invalid UTF-8 and lone surrogate escapes that `encoding/json` would replace silently (`decode.go`);
  - the service: gate, rate limits, writers, push and import, feed, snapshot (`service.go`);
  - the purge batch and cleanup job (`jobs.go`).
- **`internal/auth/httpapi/learning.go`:** the six routes, each wrapped with `authenticated`.
- **TRD 04 integration in `internal/lifecycle`:**
  - export schema version 2, built by a chunked `REPEATABLE READ` generator, with `SealAD`/`OpenAD` keyring methods binding artifact, chunk index and final flag (`export.go`);
  - a streaming download that aborts short of `Content-Length` on any authentication or length failure;
  - chunk deletion on every cancellation and expiry;
  - the learning purge in step 2, with a final emptiness check.
- **Supporting changes:**
  - `httpx` gains `DecodeJSONLimit`, `DecodeObject` and five problem codes;
  - `accounts` gains `LockForKeyShare`;
  - the maintenance runner gains the `learning_sync` job;
  - metrics gain three counters;
  - OpenAPI is updated to 1.4.0-trd05.

### 17.2 Contract corrections made while implementing

1. **Unknown outcomes are sticky.** A later request-level refusal applies only to that retry. Resolution is per-item results or the authoritative high-water check, which proves processing, not application (§5.3).
2. **Processed sequences are resolved before import capacity admission.** Admission applies to the new suffix only, and a refusal leaves the suffix untouched (§5.3 server rules, §9.4).
3. **Snapshot pagination is its own route and token format (`s1.`),** bound to the epoch, H and the last id. There is a defined catch-up hand-off and a recovery when compaction overtakes H (§5.7, §8.5). The feed cursor is now required on `changes`.
4. **Pre-rebuild rows are `legacy_untagged`** unless positive guest provenance exists. Words over quota stay local until an explicit upload (§9.6, §10.2).
5. **Review actions are operation-specific,** and re-creation is a distinct action (§8.4).
6. **Writer retirement is logical and immediate,** with bounded, resumable history deletion. Multi-row learning tables are `RESTRICT`, so no cascade can bypass the batches. The purge stays in `purge_step` 2, not a widened 0..3 (§5.2, §11.2, §13).
7. **The size bounds are labelled precisely.** 79,227,452 bytes is a sealed-payload bound, excluding PostgreSQL row and metadata overhead.
8. **Smaller API corrections:**
   - import is a separate route;
   - the writer state reports `active`;
   - a blank word is `field_empty`;
   - push takes the acting session with `session.LockActing` (`FOR UPDATE`).

### 17.3 Commands and results

All runs used loopback-only disposable services (`scripts/test-postgres.sh`, `scripts/test-mailpit.sh`), from `backend/`:

```sh
make sqlc && make sqlc-verify && make check && make build
VEEA_TEST_DATABASE_URL=postgres://postgres@127.0.0.1:54329/postgres \
VEEA_TEST_SMTP_ADDR=127.0.0.1:1025 VEEA_TEST_MAILPIT_API=http://127.0.0.1:8025 \
go test -race -tags=integration -count=1 -json ./...
```

All passed. The full race run passed **1,048 tests and subtests, with 0 failures and 0 skipped** (415 top-level): 425 unit and 623 integration. Eighteen packages passed; twelve have no test files.

Mailpit delivery ran. Contract coverage checked **260 operation/status/code combinations**, with no new exclusions: every documented response of the six sync routes was produced.

At the limit, under `-race`, the export was:
- 79,209,289 plaintext bytes (bound 79,225,248);
- 76 chunks;
- a largest sealed chunk of 608,405 bytes;
- 45,746,647 sealed-payload bytes (bound 79,227,452), compressed because the fixture text deflates.

The raw-fallback unit test separately confirms that an incompressible full chunk seals to exactly 1,048,605 bytes. The purge of those 50,000 words took 13 runner passes at batch 10,000, each pass removing at most one batch.
