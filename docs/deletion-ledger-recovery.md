# Independent deletion-ledger recovery

Operator workflow for TRD 04 §12.5a and TRD 05 §8.2. Nin owns deployment and cutover.
These commands never open ingress or `learning_sync_control`. The API contract and schema
remain unchanged (migration **00015**). Use the candidate API, CLI and restore SQL together.

## 1. Acceptance, coverage and the stop boundary

Deletion `202` acknowledges the existing atomic PostgreSQL transaction: the account is sealed,
sessions revoked and a minimal `deletion_ledger` marker committed. It does **not** acknowledge
independent storage. That deletion becomes independently recoverable only after a checkpoint
containing its marker is published durably, authenticated on read-back and acknowledged by
`admin ledger archive` in the independent destination. There is an interval between these events.
This implementation is asynchronous checkpointing, not a zero-loss acceptance protocol.

An archive fences `deletion_ledger` with a short SHARE table lock. It waits for preceding
writers, records database `clock_timestamp()` after acquiring the lock, and reads every retained
completed or incomplete marker. New ledger writes wait until that read transaction ends. The
transaction is released **before** external publication; coverage stops at its recorded time,
not at command completion. Lock wait is bounded to 5 seconds, each statement to 30 seconds,
and the command uses a 60-second context. Filesystem calls depend on the destination and may
not be interruptible; cancellation never acknowledges publication. A busy or failing archive
must be retried and alerted, not waived.

The encrypted checkpoint contains format/version, an independently assigned source UUID,
generation, `covered_through`, a 30-day backup floor, and the minimal marker rows:
`operation_id`, `user_id`, `accepted_at`, `completed_at`, `retain_until`. No mailbox, token,
receipt capability, OTP, outbox payload or product data is included. Standard output is only a
receipt: generation, cutoff, backup floor, record count and SHA-256 digest of the checkpoint's
plaintext representation. Preserve this receipt in the independent operator record.

Recovery requires **all** of the following, established outside the checkpoint being tested:

| Requirement | Source of truth |
|---|---|
| `--source` | Provisioning record mapping the UUID to the authoritative primary and backup lineage |
| `--backup-at` | Conservative earliest database point included in the backup/PITR, from the backup manifest; for a logical dump use its start, not finish time |
| `--required-through` | Incident/cutover record covering the last instant an acceptance could have committed, including known clock uncertainty |
| `--min-generation` | Independently retained latest acknowledged archive receipt/monotonic generation record; never lower it to make a restored checkpoint pass |

For a planned cutover, stop and fence **all source writers**, record the cutoff in the source
database clock domain, then run a final archive and verify coverage through that cutoff. For
unplanned loss, establish a conservative incident bound in the same clock domain, using
independent infrastructure evidence. An unknown cutoff or unknown lineage is a stop condition.
Do not set the requirement equal to the available archive's time to conceal a gap.

Missing/corrupt/wrong-key/wrong-source checkpoints, insufficient generation or cutoff, and
backups older than the checkpoint's 30-day floor all fail closed. Publication also refuses
an unexpired previously archived marker missing or rewound in the source. This detects source
rewind; it does not establish provenance for an arbitrarily chosen database. Always archive
the authoritative primary, **never the restored target**.

If the source is gone and the archive is behind, keep public/admin access, sign-in, workers
and sync closed. Retrieve a newer independently retained checkpoint, or recover authoritative
replica/WAL evidence into an isolated source under an approved incident procedure and archive
it with verified lineage and coverage. If that evidence is unavailable, the restore remains
blocked. An old CSV, a zero-row ledger in the backup, or an operator override is not coverage.

## 2. Provision independent custody (deployment prerequisite)

The repository supplies a **POSIX filesystem adapter**, used with a separate local directory
in synthetic tests. No shared-storage destination, scheduler or secret manager is selected or
provisioned. A directory on the database host or its backup disk is not a separate disaster
failure domain. Production requires an approved independently durable mount, or a future Store
adapter with equivalent serialization, authenticated read-back and durable publication guarantees.

Before deployment record:

1. Destination, owner, failure domain, access policy, durability, version/rollback recovery and
   retention controls. The POSIX adapter requires tested exclusive `flock`, atomic rename and
   file **and directory** `fsync`; do not assume every network mount provides them.
2. One random source UUID held outside the database, mapped to this primary and backup lineage.
   Do not change it during restore or create a new archive to bypass missing history.
3. A dedicated 256-bit recovery encryption key in independent secret custody, exported privately
   as `VEEA_RECOVERY_KEYS=id:64hex[,previous_id:64hex...]` (current first). Do not reuse outbox,
   OTP or database keys. Keep required old key versions until all retained checkpoints can be
   recovered. The key IDs are safe evidence; their values are not.
4. An operator job using `VEEA_DATABASE_URL` for the authoritative primary, permission to SELECT
   and SHARE-lock `deletion_ledger`, and a private writable store directory. No user/audit mutation
   grants are required. The store directory is mode 0700; checkpoint/lock/output files are 0600.
   Parent directories must exist and be trusted. The command rejects a symlink as its final
   store path, checkpoint or lock file; avoid symlinked/untrusted parent paths too.
5. Schedule and freshness/exit-code monitoring, independent receipt retention, incident cutoff
   procedure and on-call owner. A suggested initial cadence is every **5 minutes**, plus a final
   fenced capture for planned cutover. This is a proposed deployment setting, not a configured
   job or a zero-loss RPO. A missed run, unacknowledged publication, unknown generation or stale
   cutoff must alert outside the database being protected. No TRD 08 alert scope is expanded here.

One-time initialization, from `backend/`, with the approved environment loaded privately:

```sh
set -eu
umask 077
# VEEA_LEDGER_STORE: independent private directory, parent already provisioned
# VEEA_LEDGER_SOURCE: UUID from independent provisioning record
# VEEA_RECOVERY_KEYS and VEEA_DATABASE_URL: private secret injection, never shell tracing
bin/admin ledger archive --store "$VEEA_LEDGER_STORE" \
  --source "$VEEA_LEDGER_SOURCE" --initialize
```

Retain the successful JSON receipt in the independent job/audit record with operator, source,
candidate digest and ticket. Normal scheduled/final runs use the same command **without**
`--initialize`. A missing file then refuses publication. Do not use initialization to reset a
lost archive. Concurrent publishers serialize through the store lock and advance generation.
Checkpoint records are bounded to 1,000,000 and plaintext to 256 MiB; a limit breach refuses
publication and requires operational remediation, never truncation.

Completed markers are retained at least 90 days after completion; unfinished markers never
expire. Each new full checkpoint excludes only completed expired markers. Keep the latest
checkpoint even when its unfinished markers are old: do not apply a blind object TTL that
discards them. Historical versions and their keys need a documented purge policy covering
the ≤30-day backup window and incident needs; indefinite version retention is not implied.

Publication writes a private temporary file, fsyncs it, atomically replaces the checkpoint,
fsyncs the directory and authenticates read-back. Before rename, interruption preserves the
previous checkpoint. After rename, a complete new checkpoint may be visible despite an error
or lost receipt. Retry against the same store/source, retain the verified next receipt, and
never assume a failed command acknowledged coverage. Stale temporary files from process death
are private and ignored; remove them only with publishers stopped under the incident procedure.

## 3. Recover without the original database

Use a recovery host that can access the independent store and key custody, even with the
original database unavailable. `recover` and `status` do not read `VEEA_DATABASE_URL` or connect
to a source database. Load the four requirements above from independent records; do not derive
them from this store's current file. From `backend/`:

```sh
set -eu
umask 077
# Create once; use a trusted private parent and a new output name for each recovery.
mkdir -m 700 ./private-recovery
bin/admin ledger status --store "$VEEA_LEDGER_STORE" --source "$VEEA_LEDGER_SOURCE" \
  --backup-at "$VEEA_RECOVERY_BACKUP_AT" --required-through "$VEEA_RECOVERY_REQUIRED_THROUGH" \
  --min-generation "$VEEA_RECOVERY_MIN_GENERATION"
bin/admin ledger recover --store "$VEEA_LEDGER_STORE" --source "$VEEA_LEDGER_SOURCE" \
  --backup-at "$VEEA_RECOVERY_BACKUP_AT" --required-through "$VEEA_RECOVERY_REQUIRED_THROUGH" \
  --min-generation "$VEEA_RECOVERY_MIN_GENERATION" --out ./private-recovery/recovered.sql
```

Times are RFC3339 UTC (fractional seconds accepted). Only exit 0 plus a matching receipt is
success. Recovery never overwrites an existing output file; on retry use a new private name.
The output contains private UUID markers and coverage proof, not credentials. Transfer it only
through the approved encrypted restricted channel. Record digest/count/generation/cutoff and
secret **version IDs**, not its contents, in release evidence. Remove plaintext after the drill
or incident according to the approved evidence policy.

Continue [staging checklist §6](staging-verification.md#6-isolated-restore-sequence-for-g9-nin):
restore the backup in isolation, migrate, close sync and load `recovered.sql` into the same
kept-open private `psql` session used by prepare/finish/verify. The CLI authenticates the
checkpoint; SQL checks presence, count and coverage consistency again. These checks do not
cryptographically authenticate arbitrary hand-written temporary tables; trusted operator
custody of CLI output and network isolation remain mandatory. Do not bypass the CLI with CSV.

Run prepare, the ordinary checkpointed purge, then finish and verify. Finish refuses remaining
deletions; it rotates survivor epochs and retires writers. Verification requires no deleted
owner, no restored active credentials/exports/pending mail, changed surviving epochs and a
closed sync gate. Interruption keeps the environment closed. After session loss, recover the
same verified checkpoint again, reload into a new session and repeat preparation/purge; it is
safe to retry, although preparation resets purge progress and a new epoch baseline.

Only a separate Nin cutover decision after **all** checks can reopen access. A minimal ledger
does not restore post-backup receipt capabilities; their continuity remains a recorded limit.

## 4. Synthetic evidence and production boundary

`backend/scripts/test-restore-drill.sh` takes a real logical backup, accepts two later deletions
(one finished, one incomplete), interrupts checkpoint publication, refuses the stale checkpoint,
retries publication, then **drops the source database**. A fresh recovery CLI runs with an
unavailable source URL and recovers from the encrypted independent local fixture. It restores
the backup, refuses missing/behind proofs and premature finish, interrupts purge, reconnects,
recovers again and completes ordinary purge plus epoch rotation and verification. It checks
deleted account/product rows absent and survivor data intact while keeping sync closed.

Unit tests also interrupt both sides of rename and test corruption, key rotation, private
paths, cancellation and monotonic requirements. PostgreSQL tests verify that the fence waits
for acceptance commit, missing archived markers stop publication, and concurrent checkpoints
serialize without dropping unfinished markers. Exact commands/counts are recorded in
[staging verification §8](staging-verification.md#8-independent-ledger-local-evidence).

This proves source-database independence using synthetic data and a local adapter. It does
not prove shared-storage durability, independent host/site survival, an installed schedule,
freshness alert routing, PITR availability or secret-custody recovery. Those are explicit G9
deployment gates; the full staging/provider restore drill remains Nin's work.
