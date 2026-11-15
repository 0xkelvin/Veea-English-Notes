package recoveryledger

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"syscall"
	"time"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/notify"
	"github.com/google/uuid"
)

const maxWireBytes = (MaxBytes+28)*4/3 + 4096

// FileStore is a POSIX filesystem adapter for the independently provisioned storage boundary.
// A directory on the database host/backup disk is a LOCAL FIXTURE, not disaster independence.
// Shared storage must supply tested flock/atomic rename/file+directory fsync semantics.
type FileStore struct {
	root   string
	source uuid.UUID
	keys   *notify.Keyring
	// Unit fault hooks exercise process interruption without weakening production behavior.
	afterTempSync func() error
	afterRename   func() error
}

func NewFileStore(root string, source uuid.UUID, keys *notify.Keyring) (*FileStore, error) {
	if root == "" || source == uuid.Nil || keys == nil {
		return nil, ErrInvalid
	}
	root, err := filepath.Abs(root)
	if err != nil {
		return nil, ErrInvalid
	}
	if err := os.Mkdir(root, 0700); err != nil && !errors.Is(err, os.ErrExist) {
		return nil, ErrInvalid
	}
	st, err := os.Lstat(root)
	if err != nil || !st.IsDir() || st.Mode()&os.ModeSymlink != 0 || st.Mode().Perm()&0077 != 0 {
		return nil, ErrInvalid
	}
	parent, err := os.Open(filepath.Dir(root))
	if err != nil {
		return nil, ErrInvalid
	}
	err = parent.Sync()
	_ = parent.Close()
	if err != nil {
		return nil, ErrInvalid
	}
	return &FileStore{root: root, source: source, keys: keys}, nil
}
func (s *FileStore) lock(ctx context.Context) (*os.File, error) {
	f, err := os.OpenFile(filepath.Join(s.root, ".lock"), os.O_CREATE|os.O_RDWR|syscall.O_NOFOLLOW, 0600)
	if err != nil {
		return nil, ErrInvalid
	}
	st, err := f.Stat()
	if err != nil || !st.Mode().IsRegular() || st.Mode().Perm()&0077 != 0 {
		f.Close()
		return nil, ErrInvalid
	}
	for {
		if err := ctx.Err(); err != nil {
			f.Close()
			return nil, err
		}
		err = syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
		if err == nil {
			return f, nil
		}
		if !errors.Is(err, syscall.EWOULDBLOCK) && !errors.Is(err, syscall.EAGAIN) {
			f.Close()
			return nil, ErrInvalid
		}
		select {
		case <-ctx.Done():
			f.Close()
			return nil, ctx.Err()
		case <-time.After(20 * time.Millisecond):
		}
	}
}
func unlock(f *os.File) { _ = syscall.Flock(int(f.Fd()), syscall.LOCK_UN); _ = f.Close() }

type wire struct {
	Format int    `json:"format"`
	KeyID  int16  `json:"key_id"`
	Sealed []byte `json:"sealed"`
}

func (s *FileStore) ad() []byte { return []byte("veea.deletion-recovery.v1:" + s.source.String()) }
func (s *FileStore) read() (Checkpoint, Receipt, error) {
	f, err := os.OpenFile(filepath.Join(s.root, "checkpoint.json"), os.O_RDONLY|syscall.O_NOFOLLOW, 0)
	if errors.Is(err, os.ErrNotExist) {
		return Checkpoint{}, Receipt{}, ErrMissing
	}
	if err != nil {
		return Checkpoint{}, Receipt{}, ErrInvalid
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil || !st.Mode().IsRegular() || st.Mode().Perm()&0077 != 0 || st.Size() > maxWireBytes {
		return Checkpoint{}, Receipt{}, ErrInvalid
	}
	raw, err := io.ReadAll(io.LimitReader(f, maxWireBytes+1))
	if err != nil || len(raw) > maxWireBytes {
		return Checkpoint{}, Receipt{}, ErrInvalid
	}
	var w wire
	if decode(raw, &w) != nil || w.Format != 1 {
		return Checkpoint{}, Receipt{}, ErrInvalid
	}
	plain, err := s.keys.OpenAD(w.KeyID, s.ad(), w.Sealed)
	if err != nil || len(plain) > MaxBytes {
		return Checkpoint{}, Receipt{}, ErrInvalid
	}
	defer clear(plain)
	var c Checkpoint
	if decode(plain, &c) != nil || validate(c) != nil || c.Source != s.source {
		return Checkpoint{}, Receipt{}, ErrInvalid
	}
	r, err := receipt(c)
	return c, r, err
}
func (s *FileStore) Read(ctx context.Context) (Checkpoint, Receipt, error) {
	f, err := s.lock(ctx)
	if err != nil {
		return Checkpoint{}, Receipt{}, err
	}
	defer unlock(f)
	c, r, err := s.read()
	if err == nil && ctx.Err() != nil {
		return Checkpoint{}, Receipt{}, ctx.Err()
	}
	return c, r, err
}
func (s *FileStore) Update(ctx context.Context, fn func(*Checkpoint) (Checkpoint, error)) (Receipt, error) {
	lock, err := s.lock(ctx)
	if err != nil {
		return Receipt{}, err
	}
	defer unlock(lock)
	prev, _, err := s.read()
	var old *Checkpoint
	if err == nil {
		old = &prev
	} else if !errors.Is(err, ErrMissing) {
		return Receipt{}, err
	}
	next, err := fn(old)
	if err != nil {
		return Receipt{}, err
	}
	if validate(next) != nil || next.Source != s.source {
		return Receipt{}, ErrInvalid
	}
	if old == nil && next.Generation != 1 || old != nil && (next.Generation != old.Generation+1 || !next.CoveredThrough.After(old.CoveredThrough)) {
		return Receipt{}, ErrGap
	}
	r, err := receipt(next)
	if err != nil {
		return Receipt{}, err
	}
	plain, err := json.Marshal(next)
	if err != nil || len(plain) > MaxBytes {
		return Receipt{}, ErrInvalid
	}
	defer clear(plain)
	sealed, key, err := s.keys.SealAD(s.ad(), plain)
	if err != nil {
		return Receipt{}, ErrInvalid
	}
	raw, err := json.Marshal(wire{1, key, sealed})
	if err != nil || len(raw) > maxWireBytes {
		return Receipt{}, ErrInvalid
	}
	if err := ctx.Err(); err != nil {
		return Receipt{}, err
	}
	if err := AtomicPrivateFile(s.root, "checkpoint.json", raw, true, s.afterTempSync, s.afterRename); err != nil {
		return Receipt{}, err
	}
	if err := ctx.Err(); err != nil {
		return Receipt{}, err
	}
	// Read back the authenticated content before acknowledging independently recoverable bytes.
	_, got, err := s.read()
	if err != nil || got.Digest != r.Digest {
		return Receipt{}, ErrInvalid
	}
	return r, nil
}

// WriteRestoreFile never overwrites a prior successful recovered file, so a stale/refused
// invocation cannot silently replace the operator's existing evidence.
func WriteRestoreFile(path string, raw []byte) error {
	st, err := os.Lstat(filepath.Dir(path))
	if path == "" || len(raw) > MaxBytes || err != nil || !st.IsDir() || st.Mode()&os.ModeSymlink != 0 || st.Mode().Perm()&0077 != 0 {
		return ErrInvalid
	}
	return AtomicPrivateFile(filepath.Dir(path), filepath.Base(path), raw, false, nil, nil)
}

// AtomicPrivateFile is shared by checkpoint publication and private recovery output. Only
// checkpoint publication replaces an old file. Before rename, failures leave old content;
// after rename an fsync failure is uncertain and must be retried, never acknowledged.
func AtomicPrivateFile(dir, name string, raw []byte, replace bool, afterSync, afterRename func() error) error {
	if filepath.Base(name) != name || name == "." || name == ".." {
		return ErrInvalid
	}
	f, err := os.CreateTemp(dir, ".ledger-tmp-*")
	if err != nil {
		return ErrInvalid
	}
	tmp := f.Name()
	defer os.Remove(tmp)
	defer f.Close()
	if err := f.Chmod(0600); err != nil {
		return ErrInvalid
	}
	if _, err := f.Write(raw); err != nil {
		return ErrInvalid
	}
	if err := f.Sync(); err != nil {
		return ErrInvalid
	}
	if err := f.Close(); err != nil {
		return ErrInvalid
	}
	if afterSync != nil {
		if err := afterSync(); err != nil {
			return err
		}
	}
	if replace {
		st, err := os.Lstat(filepath.Join(dir, name))
		if err == nil && (st.Mode()&os.ModeSymlink != 0 || !st.Mode().IsRegular()) {
			return ErrInvalid
		}
		if err != nil && !errors.Is(err, os.ErrNotExist) {
			return ErrInvalid
		}
		if err := os.Rename(tmp, filepath.Join(dir, name)); err != nil {
			return ErrInvalid
		}
	} else {
		// link is atomic and exclusive; a concurrent invocation cannot replace an existing file.
		if err := os.Link(tmp, filepath.Join(dir, name)); err != nil {
			return ErrInvalid
		}
	}
	if afterRename != nil {
		if err := afterRename(); err != nil {
			return err
		}
	}
	d, err := os.Open(dir)
	if err != nil {
		return ErrInvalid
	}
	defer d.Close()
	if err := d.Sync(); err != nil {
		return ErrInvalid
	}
	return nil
}
