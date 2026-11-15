// Package recoveryledger implements operator-only independent deletion checkpoints. It never
// changes account acceptance, opens ingress/sync, or treats an old checkpoint as a final cutoff.
package recoveryledger

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/csv"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/notify"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/db/sqlc"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

const MaxRecords = 1_000_000
const MaxBytes = 256 << 20
const BackupWindow = 30 * 24 * time.Hour

var ErrInvalid = errors.New("recovery ledger: invalid or unavailable checkpoint")
var ErrBehind = errors.New("recovery ledger: coverage is behind the required cutoff; keep restored access closed")
var ErrGap = errors.New("recovery ledger: source gap or rewind; keep restored access closed")
var ErrMissing = errors.New("recovery ledger: checkpoint missing; keep restored access closed")

// Record contains only the existing minimized restoration-ledger columns.
type Record struct {
	OperationID uuid.UUID  `json:"operation_id"`
	UserID      uuid.UUID  `json:"user_id"`
	AcceptedAt  time.Time  `json:"accepted_at"`
	CompletedAt *time.Time `json:"completed_at"`
	RetainUntil *time.Time `json:"retain_until"`
}

// Checkpoint is encrypted as one authenticated document. Source is provisioned independently
// of the DB being restored; Generation and cutoff receipts belong in the operator's custody.
type Checkpoint struct {
	Format         int       `json:"format"`
	Source         uuid.UUID `json:"source"`
	Generation     int64     `json:"generation"`
	CoveredThrough time.Time `json:"covered_through"`
	BackupFloor    time.Time `json:"backup_floor"`
	Records        []Record  `json:"records"`
}

// Receipt is safe to print: no user identifiers, keys or records.
type Receipt struct {
	Generation     int64     `json:"generation"`
	CoveredThrough time.Time `json:"covered_through"`
	BackupFloor    time.Time `json:"backup_floor"`
	Records        int       `json:"records"`
	Digest         string    `json:"digest"`
}

// Store is the independently durable boundary. Update serializes the read/snapshot/publish
// cycle; the callback has no external side effects. Errors must not acknowledge publication.
// The supplied FileStore is a local POSIX adapter, not a provisioned shared-storage service.
type Store interface {
	Read(context.Context) (Checkpoint, Receipt, error)
	Update(context.Context, func(*Checkpoint) (Checkpoint, error)) (Receipt, error)
}

// ParseKeys uses a dedicated recovery secret, current key first: id:64-hex[,previous...].
// It must never reuse the database/outbox key. Errors never quote key material.
func ParseKeys(raw string) (*notify.Keyring, error) {
	var keys []notify.Key
	for _, entry := range strings.Split(raw, ",") {
		id, value, ok := strings.Cut(entry, ":")
		n, err := strconv.ParseInt(id, 10, 16)
		b, berr := hex.DecodeString(value)
		if !ok || err != nil || berr != nil || n <= 0 || len(b) != 32 {
			return nil, ErrInvalid
		}
		keys = append(keys, notify.Key{ID: int16(n), Key: b})
	}
	k, err := notify.NewKeyring(keys...)
	if err != nil {
		return nil, ErrInvalid
	}
	return k, nil
}

// Archive reads an exact fenced snapshot from the authoritative PRIMARY only. A prior
// unexpired marker missing from that source is a rewind/gap; never archive a restored DB to
// manufacture coverage for a missing disaster interval. No external I/O runs in a db.Tx retry.
func Archive(ctx context.Context, pool *pgxpool.Pool, store Store, source uuid.UUID, initialize bool) (Receipt, error) {
	if source == uuid.Nil {
		return Receipt{}, ErrInvalid
	}
	return store.Update(ctx, func(previous *Checkpoint) (Checkpoint, error) {
		if previous == nil && !initialize {
			return Checkpoint{}, ErrMissing
		}
		tx, err := pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
		if err != nil {
			return Checkpoint{}, ErrInvalid
		}
		defer tx.Rollback(context.WithoutCancel(ctx)) // read-only rollback releases the fence on every exit
		if _, err := tx.Exec(ctx, `SET LOCAL lock_timeout='5s'; SET LOCAL statement_timeout='30s'; SET LOCAL idle_in_transaction_session_timeout='60s'`); err != nil {
			return Checkpoint{}, ErrInvalid
		}
		q := sqlc.New(tx)
		if err := q.LockRecoveryLedger(ctx); err != nil {
			return Checkpoint{}, ErrInvalid
		}
		at, err := q.WallClock(ctx)
		if err != nil {
			return Checkpoint{}, ErrInvalid
		}
		rows, err := q.ListRecoveryLedger(ctx, at)
		if err != nil || len(rows) > MaxRecords {
			return Checkpoint{}, ErrInvalid
		}
		next := Checkpoint{Format: 1, Source: source, Generation: 1, CoveredThrough: at.UTC(), BackupFloor: at.UTC().Add(-BackupWindow), Records: make([]Record, 0, len(rows))}
		for _, r := range rows {
			next.Records = append(next.Records, Record{r.OperationID, r.UserID, r.AcceptedAt.UTC(), r.CompletedAt, r.RetainUntil})
		}
		if previous != nil {
			if previous.Source != source || !next.CoveredThrough.After(previous.CoveredThrough) || previous.Generation == int64(^uint64(0)>>1) {
				return Checkpoint{}, ErrGap
			}
			next.Generation = previous.Generation + 1
			byID := map[uuid.UUID]Record{}
			for _, r := range next.Records {
				byID[r.UserID] = r
			}
			for _, old := range previous.Records {
				if old.CompletedAt != nil && old.RetainUntil != nil && !old.RetainUntil.After(next.CoveredThrough) {
					continue
				}
				r, ok := byID[old.UserID]
				if !ok || r.OperationID != old.OperationID || !r.AcceptedAt.Equal(old.AcceptedAt) ||
					(old.CompletedAt != nil && (r.CompletedAt == nil || r.CompletedAt.Before(*old.CompletedAt))) {
					return Checkpoint{}, ErrGap
				}
			}
		}
		if err := validate(next); err != nil {
			return Checkpoint{}, err
		}
		// Release the table fence before durable storage I/O. The checkpoint covers only 'at',
		// not deletions committed after that instant or while publication is in progress.
		if err := tx.Commit(ctx); err != nil {
			return Checkpoint{}, ErrInvalid
		}
		return next, nil
	})
}

func validate(c Checkpoint) error {
	if c.Format != 1 || c.Source == uuid.Nil || c.Generation < 1 || c.CoveredThrough.IsZero() || !c.BackupFloor.Equal(c.CoveredThrough.Add(-BackupWindow)) || len(c.Records) > MaxRecords {
		return ErrInvalid
	}
	users, ops := map[uuid.UUID]bool{}, map[uuid.UUID]bool{}
	for _, r := range c.Records {
		if r.UserID == uuid.Nil || r.OperationID == uuid.Nil || users[r.UserID] || ops[r.OperationID] || r.AcceptedAt.IsZero() || r.AcceptedAt.After(c.CoveredThrough) ||
			((r.CompletedAt == nil) != (r.RetainUntil == nil)) ||
			(r.CompletedAt != nil && (r.CompletedAt.Before(r.AcceptedAt) || r.CompletedAt.After(c.CoveredThrough) || r.RetainUntil.Before(r.CompletedAt.Add(90*24*time.Hour)))) {
			return ErrInvalid
		}
		users[r.UserID], ops[r.OperationID] = true, true
	}
	return nil
}
func receipt(c Checkpoint) (Receipt, error) {
	b, err := json.Marshal(c)
	if err != nil || len(b) > MaxBytes {
		return Receipt{}, ErrInvalid
	}
	digest := sha256.Sum256(b)
	return Receipt{c.Generation, c.CoveredThrough, c.BackupFloor, len(c.Records), hex.EncodeToString(digest[:])}, nil
}
func decode(raw []byte, dst any) error {
	d := json.NewDecoder(bytes.NewReader(raw))
	d.DisallowUnknownFields()
	if err := d.Decode(dst); err != nil {
		return ErrInvalid
	}
	if err := d.Decode(new(any)); !errors.Is(err, io.EOF) {
		return ErrInvalid
	}
	return nil
}

// Requirement is the independently recorded recovery boundary. Never derive RequiredThrough
// or MinGeneration from the checkpoint being checked. Missing requirements fail closed.
type Requirement struct {
	Source          uuid.UUID
	BackupAt        time.Time
	RequiredThrough time.Time
	MinGeneration   int64
}

func validRequirement(req Requirement) bool {
	return req.Source != uuid.Nil && !req.BackupAt.IsZero() && !req.RequiredThrough.IsZero() && req.MinGeneration >= 1 && !req.BackupAt.After(req.RequiredThrough)
}

// Recover has no source-database connection. Only a complete authenticated checkpoint meeting
// every operator requirement can produce a ledger/proof for the existing isolated restore SQL.
func Recover(ctx context.Context, store Store, req Requirement) (Checkpoint, Receipt, error) {
	if !validRequirement(req) {
		return Checkpoint{}, Receipt{}, ErrInvalid
	}
	c, r, err := store.Read(ctx)
	if err != nil {
		return Checkpoint{}, Receipt{}, err
	}
	if c.Source != req.Source {
		return Checkpoint{}, Receipt{}, ErrInvalid
	}
	if c.Generation < req.MinGeneration || c.CoveredThrough.Before(req.RequiredThrough) {
		return Checkpoint{}, Receipt{}, ErrBehind
	}
	if req.BackupAt.Before(c.BackupFloor) {
		return Checkpoint{}, Receipt{}, ErrBehind
	}
	return c, r, nil
}

// RestoreSQL is private operator input, containing only typed UUIDs/timestamps. Encryption
// keys and capabilities never appear. The coverage proof is checked again by all restore SQL.
func RestoreSQL(c Checkpoint, r Receipt, req Requirement) ([]byte, error) {
	if err := validate(c); err != nil || !validRequirement(req) {
		return nil, ErrInvalid
	}
	actual, err := receipt(c)
	if err != nil || actual.Digest != r.Digest || actual.Generation != r.Generation || actual.Records != r.Records || !actual.CoveredThrough.Equal(r.CoveredThrough) || !actual.BackupFloor.Equal(r.BackupFloor) || c.Source != req.Source || c.Generation < req.MinGeneration || c.CoveredThrough.Before(req.RequiredThrough) || req.BackupAt.Before(c.BackupFloor) || req.BackupAt.After(req.RequiredThrough) {
		return nil, ErrBehind
	}
	var b bytes.Buffer
	fmt.Fprintln(&b, `\set ON_ERROR_STOP on`)
	fmt.Fprintln(&b, `CREATE TEMP TABLE restore_recovery_proof (source_id uuid NOT NULL, generation bigint NOT NULL, covered_through timestamptz NOT NULL, backup_at timestamptz NOT NULL, required_through timestamptz NOT NULL, backup_floor timestamptz NOT NULL, min_generation bigint NOT NULL, record_count bigint NOT NULL, checkpoint_digest text NOT NULL);`)
	// All interpolated values originate from UUID/int/time/digest types, never free-form input.
	fmt.Fprintf(&b, "INSERT INTO restore_recovery_proof VALUES ('%s',%d,'%s','%s','%s','%s',%d,%d,'%s');\n", c.Source, c.Generation, c.CoveredThrough.Format(time.RFC3339Nano), req.BackupAt.UTC().Format(time.RFC3339Nano), req.RequiredThrough.UTC().Format(time.RFC3339Nano), c.BackupFloor.Format(time.RFC3339Nano), req.MinGeneration, len(c.Records), r.Digest)
	fmt.Fprintln(&b, `CREATE TEMP TABLE restore_deletions (LIKE deletion_ledger INCLUDING ALL);`)
	fmt.Fprintln(&b, `COPY restore_deletions FROM STDIN WITH (FORMAT csv);`)
	w := csv.NewWriter(&b)
	records := slices.Clone(c.Records)
	slices.SortFunc(records, func(a, b Record) int { return bytes.Compare(a.UserID[:], b.UserID[:]) })
	for _, row := range records {
		completed, retain := "", ""
		if row.CompletedAt != nil {
			completed = row.CompletedAt.UTC().Format(time.RFC3339Nano)
			retain = row.RetainUntil.UTC().Format(time.RFC3339Nano)
		}
		if err := w.Write([]string{row.OperationID.String(), row.UserID.String(), row.AcceptedAt.UTC().Format(time.RFC3339Nano), completed, retain}); err != nil {
			return nil, ErrInvalid
		}
	}
	w.Flush()
	if w.Error() != nil {
		return nil, ErrInvalid
	}
	fmt.Fprintln(&b, `\.`)
	return b.Bytes(), nil
}
