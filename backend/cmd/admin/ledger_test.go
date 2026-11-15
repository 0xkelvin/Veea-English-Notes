package main

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/recoveryledger"
	"github.com/google/uuid"
)

func TestLedgerCLI_RecoveryNeverReadsDatabase(t *testing.T) {
	source := uuid.New()
	root := filepath.Join(t.TempDir(), "store")
	secret := "1:" + strings.Repeat("41", 32)
	keys, _ := recoveryledger.ParseKeys(secret)
	store, err := recoveryledger.NewFileStore(root, source, keys)
	if err != nil {
		t.Fatal(err)
	}
	at := time.Now().UTC()
	cp := recoveryledger.Checkpoint{Format: 1, Source: source, Generation: 1, CoveredThrough: at, BackupFloor: at.Add(-recoveryledger.BackupWindow), Records: []recoveryledger.Record{{OperationID: uuid.New(), UserID: uuid.New(), AcceptedAt: at.Add(-time.Minute)}}}
	if _, err := store.Update(context.Background(), func(*recoveryledger.Checkpoint) (recoveryledger.Checkpoint, error) { return cp, nil }); err != nil {
		t.Fatal(err)
	}
	outDir := filepath.Join(t.TempDir(), "private")
	if err := os.Mkdir(outDir, 0700); err != nil {
		t.Fatal(err)
	}
	outFile := filepath.Join(outDir, "recovered.sql")
	env := func(k string) string {
		if k == "VEEA_DATABASE_URL" {
			t.Fatal("recovery queried original database")
		}
		if k == "VEEA_RECOVERY_KEYS" {
			return secret
		}
		return ""
	}
	args := []string{"ledger", "recover", "--store", root, "--source", source.String(), "--backup-at", at.Add(-time.Hour).Format(time.RFC3339Nano), "--required-through", at.Format(time.RFC3339Nano), "--min-generation", "1", "--out", outFile}
	var out, stderr bytes.Buffer
	if code := run(context.Background(), args, env, &out, &stderr); code != 0 {
		t.Fatal("recovery failed", stderr.String())
	}
	var receipt recoveryledger.Receipt
	if json.Unmarshal(out.Bytes(), &receipt) != nil || receipt.Records != 1 {
		t.Fatal("missing receipt")
	}
	for _, unsafe := range []string{secret, cp.Records[0].UserID.String(), cp.Records[0].OperationID.String()} {
		if strings.Contains(out.String()+stderr.String(), unsafe) {
			t.Fatal("CLI printed private record or key")
		}
	}
	// Stale recovery refuses without emitting a file or printing secrets.
	args[len(args)-1] = filepath.Join(outDir, "must-not-exist.sql")
	for i, a := range args {
		if a == "--min-generation" {
			args[i+1] = "2"
		}
	}
	out.Reset()
	stderr.Reset()
	if run(context.Background(), args, env, &out, &stderr) != 1 || out.Len() != 0 {
		t.Fatal("stale checkpoint did not block")
	}
	if _, err := os.Stat(args[len(args)-1]); !os.IsNotExist(err) {
		t.Fatal("stale checkpoint emitted restore input")
	}
}
func TestLedgerCLI_RequirementsAreMandatory(t *testing.T) {
	for _, args := range [][]string{{"ledger"}, {"ledger", "unknown"}, {"ledger", "recover", "--store", "/tmp/unused", "--source", uuid.NewString()}, {"ledger", "archive", "--store", "/tmp/unused", "--source", "invalid"}} {
		var out, stderr bytes.Buffer
		if code := run(context.Background(), args, func(string) string { return "" }, &out, &stderr); code != 2 || out.Len() != 0 {
			t.Fatal("missing requirements accepted")
		}
	}
}
