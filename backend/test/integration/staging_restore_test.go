//go:build integration && restoredrill

package integration

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/audit"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/notify"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/db/sqlc"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/metrics"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/migrate"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/pgtest"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/recoveryledger"
	"github.com/0xkelvin/Veea-English-Notes/backend/migrations"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
)

// TestStagingRestore_BackupAndDeletionReplay really dumps and restores PostgreSQL. It is
// separate from routine integration tests because it requires matching pg_dump/pg_restore.
// Both databases are pgtest-created and loopback-only. No deployed DB or rollout gate is used.
func TestStagingRestore_BackupAndDeletionReplay(t *testing.T) {
	for _, name := range []string{"pg_dump", "pg_restore", "go"} {
		if _, err := exec.LookPath(name); err != nil {
			t.Fatalf("local prerequisite missing: %s", name)
		}
	}
	ctx := context.Background()
	sourceID := uuid.New()
	keyText := "1:" + strings.Repeat("41", 32) // dedicated throwaway recovery key, not an outbox key
	keys, err := recoveryledger.ParseKeys(keyText)
	if err != nil {
		t.Fatal(err)
	}
	storeDir := filepath.Join(t.TempDir(), "independent-store")
	store, err := recoveryledger.NewFileStore(storeDir, sourceID, keys)
	if err != nil {
		t.Fatal(err)
	}
	backup := filepath.Join(t.TempDir(), "synthetic.dump")
	var originalName string
	var erasedID, pendingID, survivorID uuid.UUID
	var backupAt, requiredThrough time.Time
	var oldAuditMax int
	if !t.Run("publish_post_backup_checkpoint_then_lose_original", func(t *testing.T) {
		e := newSignupEnv(t, nil)
		originalName = e.d.Name
		e.openSync(t)
		if _, err := recoveryledger.Archive(ctx, e.d.Pool, store, sourceID, true); err != nil {
			t.Fatal(err)
		}
		erased, pending, survivor := newUser(t, e.q), newUser(t, e.q), newUser(t, e.q)
		erasedID, pendingID, survivorID = erased.ID, pending.ID, survivor.ID
		for _, u := range []uuid.UUID{erasedID, pendingID, survivorID} {
			user, err := e.q.GetUserByID(ctx, u)
			if err != nil {
				t.Fatal(err)
			}
			d := e.device(t, user, "snapshot-device")
			d.mustPush(t, mCreate(d.next(), uuid.New(), wordData("synthetic snapshot word")))
			pack := "restore_" + u.String()
			e.publishPack(t, pack, "free", 1, uuid.New())
			wantStatus(t, d.installPack(t, pack, 1, d.packBasis(t)), 200)
		}
		_ = e.exportReady(t, survivor.Email, 0)
		mailKeys, err := notify.NewKeyring(notify.Key{ID: 1, Key: outboxKey1})
		if err != nil {
			t.Fatal(err)
		}
		tx, err := e.d.Pool.Begin(ctx)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := notify.NewOutbox(mailKeys).Enqueue(ctx, tx, notify.Message{Template: notify.TemplatePasswordChanged, To: survivor.Email, UserID: &survivorID, Payload: notify.Payload{DeviceName: "Synthetic device", OccurredAt: time.Now()}}); err != nil {
			_ = tx.Rollback(ctx)
			t.Fatal(err)
		}
		if err := tx.Commit(ctx); err != nil {
			t.Fatal(err)
		}
		if rowCount(t, e.d.Pool, `SELECT count(*) FROM email_outbox WHERE status='pending'`) == 0 || rowCount(t, e.d.Pool, `SELECT count(*) FROM account_export_chunks`) == 0 {
			t.Fatal("backup must contain pending mail and export chunks")
		}
		if err := audit.Record(ctx, e.d.Pool, audit.Event{Action: "auth.password.login", Outcome: audit.Success, ActorUserID: &erasedID, TargetUserID: &erasedID, UserAgent: "synthetic restored user agent", Metadata: map[string]string{"source": "synthetic_restore"}}); err != nil {
			t.Fatal(err)
		}
		oldAuditMax = rowCount(t, e.d.Pool, `SELECT max(id) FROM audit_events`)
		backupAt = e.dbNow(t)
		cmd := exec.CommandContext(ctx, "pg_dump", "--format=custom", "--no-owner", "--no-privileges", "--file", backup, "--dbname", e.d.URL)
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("local pg_dump failed: %v (%d diagnostic bytes)", err, len(out))
		}
		for _, email := range []string{erased.Email, pending.Email} {
			p, r := e.rightsStart(t, "delete", email)
			wantStatus(t, r, 202)
			wantStatus(t, e.rightsComplete(t, p), 202)
		}
		mustExec(t, e.d.Pool, `UPDATE account_operations SET state='canceled' WHERE user_id=$1 AND action='delete'`, pendingID)
		e.finishRightsJobs(t)
		mustExec(t, e.d.Pool, `UPDATE account_operations SET state='pending' WHERE user_id=$1 AND action='delete'`, pendingID)
		if rowCount(t, e.d.Pool, `SELECT count(*) FROM deletion_ledger WHERE completed_at IS NOT NULL`) != 1 {
			t.Fatal("source needs one completed and one incomplete marker")
		}
		requiredThrough = e.dbNow(t) // independent incident boundary, BEFORE archive publication
		req := recoveryledger.Requirement{Source: sourceID, BackupAt: backupAt, RequiredThrough: requiredThrough, MinGeneration: 2}
		if _, err := recoveryledger.Archive(ctx, e.d.Pool, &interruptedRecoveryStore{Store: store}, sourceID, false); err == nil {
			t.Fatal("archive interruption ignored")
		}
		if _, _, err := recoveryledger.Recover(ctx, store, req); !errors.Is(err, recoveryledger.ErrBehind) {
			t.Fatal("stale checkpoint accepted", err)
		}
		receipt, err := recoveryledger.Archive(ctx, e.d.Pool, store, sourceID, false)
		if err != nil || receipt.Generation != 2 || receipt.Records != 2 {
			t.Fatal("archive retry failed", err)
		}
		// pgtest cleanup first checks source hygiene, then drops the original DB on subtest exit.
	}) {
		return
	}
	admin, err := pgxpool.New(ctx, os.Getenv(pgtest.EnvURL))
	if err != nil {
		t.Fatal(err)
	}
	var originalExists bool
	err = admin.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM pg_database WHERE datname=$1)`, originalName).Scan(&originalExists)
	admin.Close()
	if err != nil || originalExists {
		t.Fatal("original database must be gone before recovery")
	}
	t.Run("recover_independently_and_retry_interrupted_restore", func(t *testing.T) {
		req := recoveryledger.Requirement{Source: sourceID, BackupAt: backupAt, RequiredThrough: requiredThrough, MinGeneration: 2}
		outDir := filepath.Join(t.TempDir(), "private")
		if err := os.Mkdir(outDir, 0700); err != nil {
			t.Fatal(err)
		}
		recoveredFile := filepath.Join(outDir, "independent-recovery.sql")
		recoveryCmd := exec.CommandContext(ctx, "go", "run", "./cmd/admin", "ledger", "recover", "--store", storeDir, "--source", sourceID.String(), "--backup-at", backupAt.Format(time.RFC3339Nano), "--required-through", requiredThrough.Format(time.RFC3339Nano), "--min-generation", "2", "--out", recoveredFile)
		recoveryCmd.Dir = "../.."
		recoveryCmd.Env = append(os.Environ(), "VEEA_RECOVERY_KEYS="+keyText, "VEEA_DATABASE_URL=postgres://127.0.0.1:1/unavailable")
		if out, err := recoveryCmd.CombinedOutput(); err != nil {
			t.Fatalf("independent CLI recovery failed: %v (%d diagnostic bytes)", err, len(out))
		}
		recoverySQL, err := os.ReadFile(recoveredFile)
		if err != nil {
			t.Fatal(err)
		}
		target := pgtest.NewEmpty(t)
		cmd := exec.CommandContext(ctx, "pg_restore", "--exit-on-error", "--no-owner", "--no-privileges", "--dbname", target.URL, backup)
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("local pg_restore failed: %v (%d diagnostic bytes)", err, len(out))
		}
		if _, err := migrate.Up(ctx, target.URL, migrations.FS); err != nil {
			t.Fatal(err)
		}
		mustExec(t, target.Pool, `UPDATE learning_sync_control SET open=false,changed_at=clock_timestamp()`)
		clone := &signupEnv{d: target, q: sqlc.New(target.Pool), hmac: testEmailHMAC(t), metrics: metrics.New(), logs: &syncBuffer{}, fake: &notify.FakeSender{}}
		conn, err := target.Pool.Acquire(ctx)
		if err != nil {
			t.Fatal(err)
		}
		defer func() { conn.Release() }()
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
		execSQL(`SET veea.restore_isolated='yes'`)
		// Neither a raw ledger nor an unproved coverage interval may authorize restore preparation.
		if _, err := conn.Exec(ctx, fileSQL("prepare-isolated.sql")); err == nil {
			t.Fatal("missing independent proof accepted")
		}
		execSQL("ROLLBACK")
		loadRecoveredSQL(t, conn, recoverySQL)
		execSQL(`UPDATE restore_recovery_proof SET covered_through=required_through-interval '1 second'`)
		if _, err := conn.Exec(ctx, fileSQL("prepare-isolated.sql")); err == nil {
			t.Fatal("stale proof accepted")
		}
		execSQL("ROLLBACK")
		cp, rr, err := recoveryledger.Recover(ctx, store, req)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := conn.Exec(ctx, `UPDATE restore_recovery_proof SET covered_through=$1`, cp.CoveredThrough); err != nil {
			t.Fatal(err)
		}
		execSQL(fileSQL("prepare-isolated.sql"))
		if _, err := conn.Exec(ctx, fileSQL("finish-isolated.sql")); err == nil {
			t.Fatal("unpurged deletions accepted")
		}
		execSQL("ROLLBACK")
		noErrors(t, clone.rightsRunner(t).RunOnce(ctx))
		if rowCount(t, target.Pool, `SELECT count(*) FROM account_operations WHERE action='delete' AND state='pending'`) == 0 {
			t.Fatal("purge finished before interruption")
		}
		_ = conn.Conn().Close(ctx)
		conn.Release()
		conn, err = target.Pool.Acquire(ctx)
		if err != nil {
			t.Fatal(err)
		}
		execSQL(`SET veea.restore_isolated='yes'`)
		// Reopen independent storage after the interruption; no in-memory marker set is
		// needed to recover the new restore session.
		reopenedStore, err := recoveryledger.NewFileStore(storeDir, sourceID, keys)
		if err != nil {
			t.Fatal(err)
		}
		cp, rr, err = recoveryledger.Recover(ctx, reopenedStore, req)
		if err != nil {
			t.Fatal(err)
		}
		raw, err := recoveryledger.RestoreSQL(cp, rr, req)
		if err != nil {
			t.Fatal(err)
		}
		loadRecoveredSQL(t, conn, raw)
		execSQL(fileSQL("prepare-isolated.sql"))
		clone.finishRightsJobs(t)
		execSQL(fileSQL("finish-isolated.sql"))
		execSQL(fileSQL("verify-isolated.sql"))
		for _, id := range []uuid.UUID{erasedID, pendingID} {
			if rowCount(t, target.Pool, `SELECT count(*) FROM users WHERE id=$1`, id) != 0 {
				t.Fatal("deleted account restored")
			}
		}
		if rowCount(t, target.Pool, `SELECT count(*) FROM audit_events WHERE (actor_user_id=$1 OR target_user_id=$1 OR actor_user_id=$2 OR target_user_id=$2) AND (email_hmac IS NOT NULL OR ip IS NOT NULL OR user_agent IS NOT NULL OR request_id IS NOT NULL OR metadata<>'{}') AND id <= $3`, erasedID, pendingID, oldAuditMax) != 0 {
			t.Fatal("restored audit not minimized")
		}
		if rowCount(t, target.Pool, `SELECT count(*) FROM vocabulary_items WHERE user_id=$1`, survivorID) != 2 || rowCount(t, target.Pool, `SELECT count(*) FROM cartridge_versions`) != 3 {
			t.Fatal("survivor/shared content lost")
		}
		if rowCount(t, target.Pool, `SELECT count(*) FROM learning_sync_control WHERE open`) != 0 {
			t.Fatal("restore opened sync")
		}
		clone.assertNoSecrets(t)
		info, err := os.Stat(backup)
		if err != nil || info.Size() == 0 {
			t.Fatal("empty backup")
		}
		t.Logf("original database absent; independent encrypted CLI recovery; interrupted archive/purge retried; completed=1 incomplete=1 deletions purged; survivor/catalog retained; epochs changed, writers retired; artifacts/mail/proofs fenced; sync closed; dump bytes=%d", info.Size())
	})
}

// Interruption after snapshot capture but before durable publication must not certify coverage.
type interruptedRecoveryStore struct{ recoveryledger.Store }

func (s *interruptedRecoveryStore) Update(ctx context.Context, fn func(*recoveryledger.Checkpoint) (recoveryledger.Checkpoint, error)) (recoveryledger.Receipt, error) {
	return s.Store.Update(ctx, func(old *recoveryledger.Checkpoint) (recoveryledger.Checkpoint, error) {
		c, err := fn(old)
		if err != nil {
			return c, err
		}
		return c, errors.New("synthetic archive interruption")
	})
}

// Load the exact private SQL generated for psql, using the same PostgreSQL COPY protocol.
func loadRecoveredSQL(t *testing.T, conn *pgxpool.Conn, raw []byte) {
	t.Helper()
	prefix, body, ok := strings.Cut(string(raw), "COPY restore_deletions FROM STDIN WITH (FORMAT csv);\n")
	if !ok || !strings.HasSuffix(body, "\\.\n") {
		t.Fatal("malformed recovery SQL")
	}
	prefix = strings.TrimPrefix(prefix, "\\set ON_ERROR_STOP on\n")
	if _, err := conn.Exec(context.Background(), prefix); err != nil {
		t.Fatal(err)
	}
	body = strings.TrimSuffix(body, "\\.\n")
	if _, err := conn.Conn().PgConn().CopyFrom(context.Background(), strings.NewReader(body), "COPY restore_deletions FROM STDIN WITH (FORMAT csv)"); err != nil {
		t.Fatal(err)
	}
}
