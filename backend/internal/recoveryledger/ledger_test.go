package recoveryledger

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
)

func fixture(t *testing.T) (*FileStore, Checkpoint, Requirement) {
	t.Helper()
	keys, err := ParseKeys("1:" + strings.Repeat("41", 32))
	if err != nil {
		t.Fatal(err)
	}
	source := uuid.New()
	s, err := NewFileStore(filepath.Join(t.TempDir(), "store"), source, keys)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC()
	c := Checkpoint{Format: 1, Source: source, Generation: 1, CoveredThrough: now, BackupFloor: now.Add(-BackupWindow), Records: []Record{{OperationID: uuid.New(), UserID: uuid.New(), AcceptedAt: now.Add(-time.Hour)}}}
	return s, c, Requirement{source, now.Add(-2 * time.Hour), now.Add(-time.Minute), 1}
}
func put(t *testing.T, s *FileStore, c Checkpoint) Receipt {
	t.Helper()
	r, err := s.Update(context.Background(), func(*Checkpoint) (Checkpoint, error) { return c, nil })
	if err != nil {
		t.Fatal(err)
	}
	return r
}
func TestIndependentCheckpoint_RoundTripAndProof(t *testing.T) {
	s, c, req := fixture(t)
	put(t, s, c)
	recovered, r, err := Recover(context.Background(), s, req)
	if err != nil {
		t.Fatal(err)
	}
	sql, err := RestoreSQL(recovered, r, req)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(sql, []byte("restore_recovery_proof")) || !bytes.Contains(sql, []byte(c.Records[0].UserID.String())) {
		t.Fatal("missing private recovery input")
	}
	outDir := filepath.Join(t.TempDir(), "private")
	if err := os.Mkdir(outDir, 0700); err != nil {
		t.Fatal(err)
	}
	out := filepath.Join(outDir, "recovered.sql")
	if err := WriteRestoreFile(out, sql); err != nil {
		t.Fatal(err)
	}
	if err := WriteRestoreFile(out, []byte("replacement")); err == nil {
		t.Fatal("overwrote prior recovery evidence")
	}
	raw, err := os.ReadFile(filepath.Join(s.root, "checkpoint.json"))
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(raw, []byte(c.Records[0].UserID.String())) || bytes.Contains(raw, []byte("accepted_at")) {
		t.Fatal("checkpoint records not encrypted")
	}
	st, _ := os.Stat(out)
	if st.Mode().Perm() != 0600 {
		t.Fatal("plaintext output not private")
	}
}
func TestIndependentCheckpoint_Refusals(t *testing.T) {
	for _, name := range []string{"missing", "truncated", "tampered", "wrong_key", "wrong_source", "behind", "old_generation", "backup_too_old", "missing_requirement", "duplicate_marker"} {
		t.Run(name, func(t *testing.T) {
			s, c, req := fixture(t)
			if name != "missing" {
				put(t, s, c)
			}
			switch name {
			case "truncated":
				os.WriteFile(filepath.Join(s.root, "checkpoint.json"), []byte("{"), 0600)
			case "tampered":
				raw, _ := os.ReadFile(filepath.Join(s.root, "checkpoint.json"))
				raw[len(raw)/2] ^= 1
				os.WriteFile(filepath.Join(s.root, "checkpoint.json"), raw, 0600)
			case "wrong_key":
				s.keys, _ = ParseKeys("1:" + strings.Repeat("42", 32))
			case "wrong_source":
				req.Source = uuid.New()
			case "behind":
				req.RequiredThrough = c.CoveredThrough.Add(time.Second)
			case "old_generation":
				req.MinGeneration = 2
			case "backup_too_old":
				req.BackupAt = c.BackupFloor.Add(-time.Second)
			case "missing_requirement":
				req.MinGeneration = 0
			case "duplicate_marker":
				c.Generation = 2
				c.CoveredThrough = c.CoveredThrough.Add(time.Second)
				c.BackupFloor = c.CoveredThrough.Add(-BackupWindow)
				c.Records = append(c.Records, c.Records[0])
				if _, err := s.Update(context.Background(), func(*Checkpoint) (Checkpoint, error) { return c, nil }); err == nil {
					t.Fatal("duplicate accepted")
				}
				return
			}
			if _, _, err := Recover(context.Background(), s, req); err == nil {
				t.Fatal("unsafe recovery accepted")
			}
		})
	}
}
func TestIndependentCheckpoint_InterruptedPublicationAndRetry(t *testing.T) {
	for _, stage := range []string{"before_rename", "after_rename"} {
		t.Run(stage, func(t *testing.T) {
			s, c, req := fixture(t)
			put(t, s, c)
			c.Generation = 2
			c.CoveredThrough = c.CoveredThrough.Add(time.Second)
			c.BackupFloor = c.CoveredThrough.Add(-BackupWindow)
			interrupted := errors.New("synthetic interruption")
			if stage == "before_rename" {
				s.afterTempSync = func() error { return interrupted }
			} else {
				s.afterRename = func() error { return interrupted }
			}
			if _, err := s.Update(context.Background(), func(*Checkpoint) (Checkpoint, error) { return c, nil }); !errors.Is(err, interrupted) {
				t.Fatal("fault not observed")
			}
			s.afterTempSync, s.afterRename = nil, nil
			got, _, err := s.Read(context.Background())
			if err != nil {
				t.Fatal(err)
			}
			if stage == "before_rename" && got.Generation != 1 {
				t.Fatal("partial write replaced committed checkpoint")
			}
			// A rename acknowledged only in memory may be visible; retry never duplicates records.
			c.Generation = got.Generation + 1
			c.CoveredThrough = got.CoveredThrough.Add(time.Second)
			c.BackupFloor = c.CoveredThrough.Add(-BackupWindow)
			put(t, s, c)
			req.MinGeneration = c.Generation
			recovered, _, err := Recover(context.Background(), s, req)
			if err != nil || len(recovered.Records) != 1 {
				t.Fatal("retry failed", err)
			}
		})
	}
}
func TestIndependentCheckpoint_KeyRotationAndLockCancellation(t *testing.T) {
	s, c, req := fixture(t)
	put(t, s, c)
	s.keys, _ = ParseKeys("2:" + strings.Repeat("42", 32) + ",1:" + strings.Repeat("41", 32))
	if _, _, err := Recover(context.Background(), s, req); err != nil {
		t.Fatal(err)
	}
	held, err := s.lock(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	defer unlock(held)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Millisecond)
	defer cancel()
	if _, _, err := s.Read(ctx); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatal("lock ignored cancellation")
	}
}
func TestIndependentCheckpoint_PrivatePathsAndKeyValidation(t *testing.T) {
	s, c, _ := fixture(t)
	for _, raw := range []string{"", "secret-value", "1:bad", "0:" + strings.Repeat("41", 32), "1:" + strings.Repeat("41", 32) + ",1:" + strings.Repeat("42", 32)} {
		if _, err := ParseKeys(raw); err == nil || strings.Contains(err.Error(), "secret-value") {
			t.Fatal("unsafe key parsing")
		}
	}
	target := filepath.Join(t.TempDir(), "outside")
	os.WriteFile(target, []byte("untouched"), 0600)
	if err := os.Symlink(target, filepath.Join(s.root, "checkpoint.json")); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Update(context.Background(), func(*Checkpoint) (Checkpoint, error) { return c, nil }); err == nil {
		t.Fatal("followed checkpoint symlink")
	}
	raw, _ := os.ReadFile(target)
	if string(raw) != "untouched" {
		t.Fatal("changed symlink target")
	}
}
