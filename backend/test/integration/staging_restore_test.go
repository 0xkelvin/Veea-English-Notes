//go:build integration && restoredrill

package integration

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/audit"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/notify"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/db/sqlc"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/metrics"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/migrate"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/pgtest"
	"github.com/0xkelvin/Veea-English-Notes/backend/migrations"
	"github.com/google/uuid"
)

// TestStagingRestore_BackupAndDeletionReplay really dumps and restores PostgreSQL. It is
// separate from routine integration tests because it requires matching pg_dump/pg_restore.
// Both databases are pgtest-created and loopback-only. No deployed DB or rollout gate is used.
func TestStagingRestore_BackupAndDeletionReplay(t *testing.T) {
	for _, name := range []string{"pg_dump", "pg_restore"} {
		if _, err := exec.LookPath(name); err != nil {
			t.Fatalf("local prerequisite missing: %s", name)
		}
	}
	ctx := context.Background()
	e := newSignupEnv(t, nil)
	e.openSync(t)
	erased, pending, survivor := newUser(t, e.q), newUser(t, e.q), newUser(t, e.q)
	for _, u := range []uuid.UUID{erased.ID, pending.ID, survivor.ID} {
		user, err := e.q.GetUserByID(ctx, u)
		if err != nil {
			t.Fatal(err)
		}
		d := e.device(t, user, "snapshot-device")
		d.mustPush(t, mCreate(d.next(), uuid.New(), wordData("synthetic snapshot word")))
		e.publishPack(t, "restore_"+u.String(), "free", 1, uuid.New())
		wantStatus(t, d.installPack(t, "restore_"+u.String(), 1, d.packBasis(t)), 200)
	}
	// Snapshot contains live accounts, writers, words, watermarks, an export and unsent mail.
	_ = e.exportReady(t, survivor.Email, 0)
	keys, err := notify.NewKeyring(notify.Key{ID: 1, Key: outboxKey1})
	if err != nil {
		t.Fatal(err)
	}
	mailTx, err := e.d.Pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := notify.NewOutbox(keys).Enqueue(ctx, mailTx, notify.Message{Template: notify.TemplatePasswordChanged, To: survivor.Email, UserID: &survivor.ID, Payload: notify.Payload{DeviceName: "Synthetic device", OccurredAt: time.Now()}}); err != nil {
		_ = mailTx.Rollback(ctx)
		t.Fatal(err)
	}
	if err := mailTx.Commit(ctx); err != nil {
		t.Fatal(err)
	}
	if rowCount(t, e.d.Pool, `SELECT count(*) FROM email_outbox WHERE status='pending'`) == 0 || rowCount(t, e.d.Pool, `SELECT count(*) FROM account_export_chunks`) == 0 {
		t.Fatal("backup must contain pending mail and a live export artifact")
	}
	if err := audit.Record(ctx, e.d.Pool, audit.Event{Action: "auth.password.login", Outcome: audit.Success, ActorUserID: &erased.ID, TargetUserID: &erased.ID, UserAgent: "synthetic restored user agent", Metadata: map[string]string{"source": "synthetic_restore"}}); err != nil {
		t.Fatal(err)
	}
	oldAuditMax := rowCount(t, e.d.Pool, `SELECT max(id) FROM audit_events`)
	backup := filepath.Join(t.TempDir(), "synthetic.dump")
	cmd := exec.CommandContext(ctx, "pg_dump", "--format=custom", "--no-owner", "--no-privileges", "--file", backup, "--dbname", e.d.URL)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("local pg_dump failed: %v (%d diagnostic bytes)", err, len(out))
	}
	for _, email := range []string{erased.Email, pending.Email} {
		p, r := e.rightsStart(t, "delete", email)
		wantStatus(t, r, 202)
		wantStatus(t, e.rightsComplete(t, p), 202)
	}
	// Complete only one post-backup deletion; keep the other accepted/incomplete.
	mustExec(t, e.d.Pool, `UPDATE account_operations SET state='canceled' WHERE user_id=$1 AND action='delete'`, pending.ID)
	e.finishRightsJobs(t)
	mustExec(t, e.d.Pool, `UPDATE account_operations SET state='pending' WHERE user_id=$1 AND action='delete'`, pending.ID)
	if rowCount(t, e.d.Pool, `SELECT count(*) FROM deletion_ledger WHERE completed_at IS NOT NULL`) != 1 {
		t.Fatal("source must contain one completed and one incomplete deletion")
	}
	// Capture authoritative ledger separately from the older backup, without email or secrets.
	rows, err := e.d.Pool.Query(ctx, `SELECT operation_id,user_id,accepted_at,completed_at,retain_until FROM deletion_ledger`)
	if err != nil {
		t.Fatal(err)
	}
	type marker struct {
		op, user          uuid.UUID
		at                time.Time
		completed, retain *time.Time
	}
	var markers []marker
	for rows.Next() {
		var m marker
		if err := rows.Scan(&m.op, &m.user, &m.at, &m.completed, &m.retain); err != nil {
			t.Fatal(err)
		}
		markers = append(markers, m)
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	rows.Close()
	target := pgtest.NewEmpty(t)
	cmd = exec.CommandContext(ctx, "pg_restore", "--exit-on-error", "--no-owner", "--no-privileges", "--dbname", target.URL, backup)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("local pg_restore failed: %v (%d diagnostic bytes)", err, len(out))
	}
	if _, err := migrate.Up(ctx, target.URL, migrations.FS); err != nil {
		t.Fatal(err)
	}
	mustExec(t, target.Pool, `UPDATE learning_sync_control SET open=false,changed_at=clock_timestamp()`)
	clone := &signupEnv{d: target, q: sqlc.New(target.Pool), hmac: e.hmac, metrics: metrics.New()}
	conn, err := target.Pool.Acquire(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Release()
	execSQL := func(sql string) {
		t.Helper()
		if _, err := conn.Exec(ctx, sql); err != nil {
			t.Fatal(err)
		}
	}
	fileSQL := func(name string) string {
		t.Helper()
		b, err := os.ReadFile(filepath.Join("../../ops/restore", name))
		if err != nil {
			t.Fatal(err)
		}
		return string(b)
	}
	execSQL(`SET veea.restore_isolated='yes'; CREATE TEMP TABLE restore_deletions (LIKE deletion_ledger INCLUDING ALL)`)
	for _, m := range markers {
		if _, err := conn.Exec(ctx, `INSERT INTO restore_deletions VALUES($1,$2,$3,$4,$5)`, m.op, m.user, m.at, m.completed, m.retain); err != nil {
			t.Fatal(err)
		}
	}
	execSQL(fileSQL("prepare-isolated.sql"))
	// Before purge, finish must refuse; roll back the failed transaction before continuing.
	if _, err := conn.Exec(ctx, fileSQL("finish-isolated.sql")); err == nil {
		t.Fatal("finish accepted unpurged deletions")
	}
	execSQL("ROLLBACK")
	clone.finishRightsJobs(t)
	execSQL(fileSQL("finish-isolated.sql"))
	execSQL(fileSQL("verify-isolated.sql"))
	for _, id := range []uuid.UUID{erased.ID, pending.ID} {
		if rowCount(t, target.Pool, `SELECT count(*) FROM users WHERE id=$1`, id) != 0 {
			t.Fatal("deleted owner restored")
		}
	}
	if rowCount(t, target.Pool, `SELECT count(*) FROM audit_events WHERE (actor_user_id=$1 OR target_user_id=$1 OR actor_user_id=$2 OR target_user_id=$2) AND (email_hmac IS NOT NULL OR ip IS NOT NULL OR user_agent IS NOT NULL OR request_id IS NOT NULL OR metadata<>'{}') AND id <= $3`, erased.ID, pending.ID, oldAuditMax) != 0 {
		t.Fatal("restored deleted-owner audit was not minimized")
	}
	if rowCount(t, target.Pool, `SELECT count(*) FROM vocabulary_items WHERE user_id=$1`, survivor.ID) != 2 {
		t.Fatal("survivor data lost")
	}
	if rowCount(t, target.Pool, `SELECT count(*) FROM cartridge_versions`) != 3 {
		t.Fatal("shared content lost")
	}
	// Source and restored gate states are independent; the restored copy remains closed.
	if rowCount(t, target.Pool, `SELECT count(*) FROM learning_sync_control WHERE open`) != 0 {
		t.Fatal("restore opened sync")
	}
	info, err := os.Stat(backup)
	if err != nil || info.Size() == 0 {
		t.Fatal("empty dump")
	}
	t.Logf("real custom-format backup/restore; authoritative ledger completed=1 incomplete=1; both purged; survivor and shared catalog retained; epochs rotated; writers retired; artifacts/mail/proofs fenced; sync closed; dump bytes=%d", info.Size())
	// The backup is synthetic, temporary, never checked in or printed.
}
