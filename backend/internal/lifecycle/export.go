package lifecycle

import (
	"bytes"
	"compress/flate"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strconv"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/audit"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/identity/accounts"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/learning"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/notify"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/db/sqlc"
)

// DefaultExportTimeout bounds one export generation (TRD 05 §11.1); a slower one is retried.
const DefaultExportTimeout = 30 * time.Second

// Chunk encodings: the first byte of each sealed plaintext.
const (
	encodingRaw     = 0x00
	encodingDeflate = 0x01
)

// SetExportTimeout changes the generation bound (tests at the export limit under -race).
func (s *Service) SetExportTimeout(d time.Duration) { s.exportTimeout = d }

func (s *Service) generationTimeout() time.Duration {
	if s.exportTimeout > 0 {
		return s.exportTimeout
	}
	return DefaultExportTimeout
}

func retryable(err error) bool {
	var pg *pgconn.PgError
	return errors.As(err, &pg) && (pg.Code == "40001" || pg.Code == "40P01")
}

// runExport generates one pending export (schema version 2). The snapshot is one REPEATABLE
// READ transaction: it reads the user, head and live words, writes the sealed chunks, then
// locks the user and the operation and publishes. A state change after the snapshot fails the
// final lock with 40001 and the generation is retried; nothing partial is ever published.
func (s *Service) runExport(ctx context.Context, conn *pgxpool.Conn, id uuid.UUID) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, s.generationTimeout())
	defer cancel()
	for attempt := 0; ; attempt++ {
		result, err := s.exportOnce(ctx, conn, id)
		if err == nil || attempt == 2 || !retryable(err) {
			return result, err
		}
	}
}

func (s *Service) exportOnce(ctx context.Context, conn *pgxpool.Conn, id uuid.UUID) (string, error) {
	tx, err := conn.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead})
	if err != nil {
		return "", err
	}
	defer func() { _ = tx.Rollback(context.WithoutCancel(ctx)) }()
	q := sqlc.New(tx)
	op, err := q.ReadAccountOperation(ctx, id)
	if err != nil {
		return "", err
	}
	if op.State != "pending" || op.Action != "export" || op.UserID == nil {
		return "", nil
	}
	u, ok, err := accounts.Get(ctx, tx, *op.UserID)
	if err != nil {
		return "", err
	}
	if !ok || !eligible("export", u) || u.EmailRevision != op.EmailRevision || u.LifecycleRevision != op.LifecycleRevision {
		n, err := q.CancelAccountOperation(ctx, op.ID)
		if err != nil || n == 0 {
			return "", err
		}
		if err := audit.Record(ctx, tx, evidence(sessionClient(), op.UserID, "account.export.cancel", map[string]string{"operation_id": id.String()})); err != nil {
			return "", err
		}
		return "canceled", tx.Commit(ctx)
	}
	head, err := q.GetLearningHead(ctx, u.ID)
	if err != nil {
		return "", err
	}
	snapshotAt, err := q.WallClock(ctx)
	if err != nil {
		return "", err
	}
	header, err := exportHeader(snapshotAt, head.Revision, u)
	if err != nil {
		return "", err
	}
	if len(header)+len(exportTrailer) > learning.MaxHeaderBytes {
		return "", errors.New("rights: export header over its bound")
	}
	w := &chunkWriter{ctx: ctx, q: q, keys: s.keys, op: id, artifact: op.ArtifactID}
	w.buf = append(w.buf, header...)
	after, words := uuid.Nil, 0
	for {
		rows, err := q.ExportVocabularyPage(ctx, sqlc.ExportVocabularyPageParams{UserID: u.ID, AfterID: after, MaxRows: 1000})
		if err != nil {
			return "", err
		}
		for _, r := range rows {
			if words > 0 {
				w.buf = append(w.buf, ',')
			}
			if w.buf, err = learning.AppendExportRow(w.buf, r); err != nil {
				return "", err
			}
			words++
			if err := w.flush(); err != nil {
				return "", err
			}
		}
		if len(rows) < 1000 {
			break
		}
		after = rows[len(rows)-1].ID
	}
	w.buf = append(w.buf, exportTrailer...)
	if err := w.close(); err != nil {
		return "", err
	}
	if words > learning.MaxLiveWords || w.total > learning.MaxExportPlainBytes {
		return "", fmt.Errorf("rights: export of %d words, %d bytes exceeds its bound", words, w.total)
	}
	// Publish: L3, then the operation row, then the state change.
	if _, ok, err := accounts.LockForNoKeyUpdate(ctx, tx, u.ID); err != nil || !ok {
		if err == nil {
			err = errors.New("rights: export owner vanished")
		}
		return "", err
	}
	current, err := q.LockAccountOperation(ctx, id)
	if err != nil {
		return "", err
	}
	if current.State != "pending" {
		return "", nil // canceled meanwhile; the chunks roll back with this transaction
	}
	key := w.keyID
	if n, err := q.PublishAccountExport(ctx, sqlc.PublishAccountExportParams{ID: id, ArtifactPlainBytes: &w.total, ArtifactKeyID: &key}); err != nil || n != 1 {
		if err == nil {
			err = errors.New("rights: export not published")
		}
		return "", err
	}
	if err := audit.Record(ctx, tx, evidence(sessionClient(), op.UserID, "account.export.ready", map[string]string{"operation_id": id.String()})); err != nil {
		return "", err
	}
	return "ready", tx.Commit(ctx)
}

const exportTrailer = "]}"

func exportHeader(snapshotAt time.Time, revision int64, u sqlc.User) ([]byte, error) {
	account, err := json.Marshal(struct {
		ID          uuid.UUID  `json:"user_id"`
		Email       string     `json:"email"`
		VerifiedAt  *time.Time `json:"email_verified_at"`
		CreatedAt   time.Time  `json:"created_at"`
		DisplayName *string    `json:"display_name"`
		Language    string     `json:"preferred_language"`
		TimeZone    string     `json:"time_zone"`
		DailyGoal   int32      `json:"daily_goal"`
	}{u.ID, u.Email, u.EmailVerifiedAt, u.CreatedAt, u.DisplayName, u.PreferredLanguage, u.TimeZone, u.DailyGoal})
	if err != nil {
		return nil, errors.New("rights: encode export header")
	}
	h := []byte(`{"schema_version":2,"snapshot_at":"`)
	h = snapshotAt.UTC().AppendFormat(h, learning.ExportTime)
	h = append(h, `","snapshot_revision":`...)
	h = strconv.AppendInt(h, revision, 10)
	h = append(h, `,"account":`...)
	h = append(h, account...)
	return append(h, `,"vocabulary":[`...), nil
}

// chunkWriter seals the export plaintext into 1 MiB chunks as it grows. A chunk is emitted only
// when more bytes follow it, so the last one is always the one marked final.
type chunkWriter struct {
	ctx      context.Context
	q        *sqlc.Queries
	keys     *notify.Keyring
	op       uuid.UUID
	artifact uuid.UUID
	buf      []byte
	seq      int32
	total    int64
	keyID    int16
}

func (w *chunkWriter) flush() error {
	for len(w.buf) > learning.ExportChunkBytes {
		if err := w.emit(w.buf[:learning.ExportChunkBytes], false); err != nil {
			return err
		}
		w.buf = append(w.buf[:0], w.buf[learning.ExportChunkBytes:]...)
	}
	return nil
}

func (w *chunkWriter) close() error {
	if err := w.flush(); err != nil {
		return err
	}
	return w.emit(w.buf, true)
}

func chunkAD(artifact uuid.UUID, seq int32, final bool) []byte {
	ad := make([]byte, 21)
	copy(ad, artifact[:])
	binary.BigEndian.PutUint32(ad[16:], uint32(seq))
	if final {
		ad[20] = 1
	}
	return ad
}

// emit seals one chunk: an encoding byte, then the raw chunk, or its DEFLATE form only when
// that is strictly shorter, so compression can never enlarge a chunk.
func (w *chunkWriter) emit(chunk []byte, final bool) error {
	if w.seq >= learning.MaxExportChunks {
		return errors.New("rights: export exceeds its chunk bound")
	}
	body, err := encodeChunk(chunk)
	if err != nil {
		return err
	}
	sealed, key, err := w.keys.SealAD(chunkAD(w.artifact, w.seq, final), body)
	if err != nil {
		return err
	}
	if len(sealed) > learning.MaxSealedChunkBytes {
		return errors.New("rights: sealed chunk over its bound")
	}
	if err := w.q.InsertExportChunk(w.ctx, sqlc.InsertExportChunkParams{OperationID: w.op, Seq: w.seq, Final: final, KeyID: key, Sealed: sealed}); err != nil {
		return err
	}
	w.seq++
	w.total += int64(len(chunk))
	w.keyID = key
	return nil
}

// encodeChunk is the sealed plaintext of one chunk: an encoding byte, then the raw chunk, or its
// DEFLATE form only when that is strictly shorter. It is never longer than 1 + len(chunk).
func encodeChunk(chunk []byte) ([]byte, error) {
	var z bytes.Buffer
	z.WriteByte(encodingDeflate)
	fw, err := flate.NewWriter(&z, flate.BestSpeed)
	if err != nil {
		return nil, err
	}
	if _, err := fw.Write(chunk); err != nil {
		return nil, err
	}
	if err := fw.Close(); err != nil {
		return nil, err
	}
	if z.Len()-1 < len(chunk) {
		return z.Bytes(), nil
	}
	return append([]byte{encodingRaw}, chunk...), nil
}

// Artifact is an authorized, audited download of a published version-2 export.
type Artifact struct {
	Operation uuid.UUID
	ID        uuid.UUID
	Size      int64
}

// StreamArtifact writes the plaintext export chunk by chunk, authenticating each before any of
// its bytes are written. A missing, reordered, substituted or truncated chunk is an error, and
// the caller aborts the response short of its Content-Length.
func (s *Service) StreamArtifact(ctx context.Context, a Artifact, w io.Writer) error {
	q := sqlc.New(s.pool)
	var written int64
	for seq := int32(0); seq < learning.MaxExportChunks; seq++ {
		c, err := q.GetExportChunk(ctx, sqlc.GetExportChunkParams{OperationID: a.Operation, Seq: seq})
		if err != nil {
			return fmt.Errorf("rights: export chunk %d: %w", seq, err)
		}
		body, err := s.keys.OpenAD(c.KeyID, chunkAD(a.ID, seq, c.Final), c.Sealed)
		if err != nil {
			return fmt.Errorf("rights: export chunk %d: %w", seq, err)
		}
		plain, err := decodeChunk(body)
		if err != nil {
			return err
		}
		if !c.Final && len(plain) != learning.ExportChunkBytes {
			return errors.New("rights: short non-final export chunk")
		}
		if _, err := w.Write(plain); err != nil {
			return err
		}
		written += int64(len(plain))
		if c.Final {
			if written != a.Size {
				return errors.New("rights: export length mismatch")
			}
			return nil
		}
	}
	return errors.New("rights: export has no final chunk")
}

func decodeChunk(body []byte) ([]byte, error) {
	if len(body) == 0 {
		return nil, errors.New("rights: empty export chunk")
	}
	switch body[0] {
	case encodingRaw:
		if len(body)-1 > learning.ExportChunkBytes {
			return nil, errors.New("rights: export chunk over 1 MiB")
		}
		return body[1:], nil
	case encodingDeflate:
		plain, err := io.ReadAll(io.LimitReader(flate.NewReader(bytes.NewReader(body[1:])), learning.ExportChunkBytes+1))
		if err != nil {
			return nil, fmt.Errorf("rights: inflate export chunk: %w", err)
		}
		if len(plain) > learning.ExportChunkBytes {
			return nil, errors.New("rights: export chunk inflates over 1 MiB")
		}
		return plain, nil
	}
	return nil, errors.New("rights: unknown export chunk encoding")
}
