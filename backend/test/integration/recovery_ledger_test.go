//go:build integration

package integration

import (
	"context"
	"errors"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/recoveryledger"
	"github.com/google/uuid"
)

func recoveryStore(t *testing.T) (*recoveryledger.FileStore, uuid.UUID) {
	t.Helper()
	keys, err := recoveryledger.ParseKeys("1:" + strings.Repeat("41", 32))
	if err != nil {
		t.Fatal(err)
	}
	source := uuid.New()
	store, err := recoveryledger.NewFileStore(filepath.Join(t.TempDir(), "store"), source, keys)
	if err != nil {
		t.Fatal(err)
	}
	return store, source
}
func TestRecoveryLedger_ArchiveAndSourceGap(t *testing.T) {
	ctx := context.Background()
	e := newSignupEnv(t, nil)
	store, source := recoveryStore(t)
	if _, err := recoveryledger.Archive(ctx, e.d.Pool, store, source, false); !errors.Is(err, recoveryledger.ErrMissing) {
		t.Fatal("missing store silently initialized", err)
	}
	first, err := recoveryledger.Archive(ctx, e.d.Pool, store, source, true)
	if err != nil || first.Records != 0 || first.Generation != 1 {
		t.Fatal(err)
	}
	user := newUser(t, e.q)
	proof, r := e.rightsStart(t, "delete", user.Email)
	wantStatus(t, r, 202)
	wantStatus(t, e.rightsComplete(t, proof), 202)
	required := e.dbNow(t)
	second, err := recoveryledger.Archive(ctx, e.d.Pool, store, source, false)
	if err != nil || second.Records != 1 || second.Generation != 2 {
		t.Fatal(err)
	}
	req := recoveryledger.Requirement{Source: source, BackupAt: first.CoveredThrough, RequiredThrough: required, MinGeneration: 2}
	cp, _, err := recoveryledger.Recover(ctx, store, req)
	if err != nil || cp.Records[0].UserID != user.ID {
		t.Fatal("accepted deletion not recoverable", err)
	}
	mustExec(t, e.d.Pool, `DELETE FROM deletion_ledger WHERE user_id=$1`, user.ID) // synthetic rewind/corruption
	if _, err := recoveryledger.Archive(ctx, e.d.Pool, store, source, false); !errors.Is(err, recoveryledger.ErrGap) {
		t.Fatal("missing live marker was overwritten", err)
	}
	_, latest, err := store.Read(ctx)
	if err != nil || latest.Digest != second.Digest || latest.Generation != 2 {
		t.Fatal("gap advanced checkpoint", err)
	}
}
func TestRecoveryLedger_FenceWaitsForAcceptanceCommit(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	e := newSignupEnv(t, nil)
	store, source := recoveryStore(t)
	u := newUser(t, e.q)
	tx, err := e.d.Pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(context.Background())
	op := uuid.New()
	if _, err := tx.Exec(ctx, `INSERT INTO deletion_ledger(operation_id,user_id,accepted_at) VALUES($1,$2,clock_timestamp())`, op, u.ID); err != nil {
		t.Fatal(err)
	}
	result := make(chan error, 1)
	go func() { _, err := recoveryledger.Archive(ctx, e.d.Pool, store, source, true); result <- err }()
	// Observe the actual table-lock wait rather than hoping for a wall-clock race ordering.
	for {
		var waiting bool
		if err := e.d.Pool.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM pg_locks WHERE database=(SELECT oid FROM pg_database WHERE datname=current_database()) AND relation='deletion_ledger'::regclass AND mode='ShareLock' AND NOT granted)`).Scan(&waiting); err != nil {
			t.Fatal(err)
		}
		if waiting {
			break
		}
		select {
		case err := <-result:
			t.Fatal("checkpoint bypassed uncommitted acceptance", err)
		case <-ctx.Done():
			t.Fatal(ctx.Err())
		case <-time.After(5 * time.Millisecond):
		}
	}
	if err := tx.Commit(ctx); err != nil {
		t.Fatal(err)
	}
	if err := <-result; err != nil {
		t.Fatal(err)
	}
	cp, _, err := store.Read(ctx)
	if err != nil || len(cp.Records) != 1 || cp.Records[0].OperationID != op || cp.CoveredThrough.Before(cp.Records[0].AcceptedAt) {
		t.Fatal("in-flight committed deletion not covered", err)
	}
}
func TestRecoveryLedger_RetentionAndConcurrentWriters(t *testing.T) {
	ctx := context.Background()
	e := newSignupEnv(t, nil)
	store, source := recoveryStore(t)
	now := e.dbNow(t)
	// Minimized markers have no owner FK, so these are independent synthetic historical rows.
	mustExec(t, e.d.Pool, `INSERT INTO deletion_ledger VALUES($1,$2,$3,$4,$5)`, uuid.New(), uuid.New(), now.Add(-200*24*time.Hour), now.Add(-91*24*time.Hour), now.Add(-24*time.Hour))
	unfinished := uuid.New()
	mustExec(t, e.d.Pool, `INSERT INTO deletion_ledger VALUES($1,$2,$3,NULL,NULL)`, uuid.New(), unfinished, now.Add(-200*24*time.Hour))
	r, err := recoveryledger.Archive(ctx, e.d.Pool, store, source, true)
	if err != nil || r.Records != 1 {
		t.Fatal("unfinished/retention selection", err)
	}
	errs := make(chan error, 3)
	for range 3 {
		go func() { _, err := recoveryledger.Archive(ctx, e.d.Pool, store, source, false); errs <- err }()
	}
	for range 3 {
		if err := <-errs; err != nil {
			t.Fatal(err)
		}
	}
	cp, r, err := store.Read(ctx)
	if err != nil || r.Generation != 4 || r.Records != 1 || cp.Records[0].UserID != unfinished {
		t.Fatal("concurrent publication lost state", err)
	}
}
