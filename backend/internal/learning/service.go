// Package learning implements TRD 05 vocabulary sync: server-issued writers, contiguous
// mutation sequences, field-level merge, content-free tombstones, a per-owner revision feed and
// snapshot pagination. Every owner-scoped write holds the owner's sync head (L4c).
package learning

import (
	"context"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/auth/session"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/identity/accounts"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/db"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/db/sqlc"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/httpx"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/metrics"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/ratelimit"
)

// Limits on writers and pages (TRD 05 §10.1).
const (
	MaxActiveWriters = 20
	MaxPageChanges   = 500
	MaxPageBytes     = 4 << 20
)

var (
	// ErrClosed is 503 sync_unavailable: learning_sync_control.open is false.
	ErrClosed = errors.New("learning: sync is closed")
	// ErrSequenceGap is 409 sequence_gap: the first new seq is above last_seq + 1.
	ErrSequenceGap = errors.New("learning: sequence gap")
)

// ResetError is 410 sync_reset_required.
type ResetError struct {
	Reason string // epoch_changed, writer_unknown, cursor_compacted, cursor_ahead
	Epoch  uuid.UUID
}

func (e *ResetError) Error() string { return "learning: reset required: " + e.Reason }

// CapacityError is 409 capacity_changed for an import whose new suffix does not fit the basis.
type CapacityError struct {
	LiveWords    int32
	ContentBytes int64
	LastSeq      int64
}

func (e *CapacityError) Error() string { return "learning: capacity changed" }

var (
	rulePush   = ratelimit.Rule{Name: "learning_push", Limit: 60, Window: time.Minute}
	rulePull   = ratelimit.Rule{Name: "learning_pull", Limit: 120, Window: time.Minute}
	ruleWriter = ratelimit.Rule{Name: "learning_writer", Limit: 10, Window: time.Minute}
)

// Service is the sync use case.
type Service struct {
	pool    *pgxpool.Pool
	tx      db.Tx
	limiter *ratelimit.Limiter
	metrics *metrics.Metrics
}

// New returns the service. onRetry observes transaction retries (metrics).
func New(pool *pgxpool.Pool, m *metrics.Metrics, onRetry func(string)) *Service {
	return &Service{pool: pool, tx: db.Tx{Pool: pool, OnRetry: onRetry}, limiter: ratelimit.NewLimiter(pool), metrics: m}
}

func (s *Service) admit(ctx context.Context, p session.Principal, rule ratelimit.Rule) error {
	open, err := sqlc.New(s.pool).LearningSyncOpen(ctx)
	if err != nil {
		return err
	}
	if !open {
		return ErrClosed
	}
	d, err := s.limiter.Allow(ctx, ratelimit.Check{Rule: rule, Subject: ratelimit.SessionSubject(p.SessionID)})
	if err != nil {
		return err
	}
	return d.Err()
}

func (s *Service) reset(reason string, epoch uuid.UUID) error {
	s.metrics.LearningReset(reason)
	return &ResetError{Reason: reason, Epoch: epoch}
}

// lockOwner takes L3 (users FOR KEY SHARE, account active), L4a (acting session) and L4c (head).
func lockOwner(ctx context.Context, tx pgx.Tx, p session.Principal) (sqlc.LearningSyncHead, error) {
	u, ok, err := accounts.LockForKeyShare(ctx, tx, p.UserID)
	if err != nil {
		return sqlc.LearningSyncHead{}, err
	}
	if !ok || !accounts.InGoodStanding(u) {
		return sqlc.LearningSyncHead{}, session.ErrUnauthorized
	}
	if _, ok, err := session.LockActing(ctx, tx, p.UserID, p.SessionID); err != nil {
		return sqlc.LearningSyncHead{}, err
	} else if !ok {
		return sqlc.LearningSyncHead{}, session.ErrUnauthorized
	}
	q := sqlc.New(tx)
	head, err := q.LockLearningHead(ctx, p.UserID)
	if errors.Is(err, pgx.ErrNoRows) { // every account has one; recreate defensively
		if err := q.EnsureLearningHead(ctx, p.UserID); err != nil {
			return sqlc.LearningSyncHead{}, err
		}
		head, err = q.LockLearningHead(ctx, p.UserID)
	}
	return head, err
}

// --- state and writers ------------------------------------------------------------------------

// WriterState is a writer's high-water mark. Active is false once it is retired; the row stays
// readable until its mutation history has been removed.
type WriterState struct {
	WriterID uuid.UUID `json:"writer_id"`
	LastSeq  int64     `json:"last_seq"`
	Active   bool      `json:"active"`
}

// State is GET /v1/learning/sync/state.
type State struct {
	Epoch            uuid.UUID    `json:"epoch"`
	HeadRevision     int64        `json:"head_revision"`
	TombstoneHorizon int64        `json:"tombstone_horizon"`
	LiveWords        int32        `json:"live_words"`
	WordLimit        int32        `json:"word_limit"`
	ContentBytes     int64        `json:"content_bytes"`
	ContentByteLimit int64        `json:"content_byte_limit"`
	Writer           *WriterState `json:"writer"`
}

// State reads the owner's head and, when asked, one of its writers. A writer of another owner
// or an unknown id is reported as null.
func (s *Service) State(ctx context.Context, p session.Principal, writer *uuid.UUID) (State, error) {
	if err := s.admit(ctx, p, rulePull); err != nil {
		return State{}, err
	}
	q := sqlc.New(s.pool)
	head, err := s.head(ctx, q, p.UserID)
	if err != nil {
		return State{}, err
	}
	out := State{Epoch: head.Epoch, HeadRevision: head.Revision, TombstoneHorizon: head.TombstoneHorizon,
		LiveWords: head.LiveWords, WordLimit: MaxLiveWords, ContentBytes: head.ContentBytes, ContentByteLimit: MaxContentBytes}
	if writer != nil {
		w, err := q.GetLearningWriter(ctx, sqlc.GetLearningWriterParams{UserID: p.UserID, WriterID: *writer})
		switch {
		case errors.Is(err, pgx.ErrNoRows):
		case err != nil:
			return State{}, err
		default:
			out.Writer = &WriterState{WriterID: w.WriterID, LastSeq: w.LastSeq, Active: w.RetiredAt == nil && w.Epoch == head.Epoch}
		}
	}
	return out, nil
}

func (s *Service) head(ctx context.Context, q *sqlc.Queries, user uuid.UUID) (sqlc.LearningSyncHead, error) {
	head, err := q.GetLearningHead(ctx, user)
	if errors.Is(err, pgx.ErrNoRows) {
		if err := q.EnsureLearningHead(ctx, user); err != nil {
			return head, err
		}
		head, err = q.GetLearningHead(ctx, user)
	}
	return head, err
}

// Registered is POST /v1/learning/sync/writers.
type Registered struct {
	WriterID uuid.UUID `json:"writer_id"`
	LastSeq  int64     `json:"last_seq"`
	Epoch    uuid.UUID `json:"epoch"`
}

// RegisterWriter issues a new server-generated writer. With 20 active writers it first retires
// the least recently used one (D9), in the same transaction under the head lock.
func (s *Service) RegisterWriter(ctx context.Context, p session.Principal) (Registered, error) {
	if err := s.admit(ctx, p, ruleWriter); err != nil {
		return Registered{}, err
	}
	var out Registered
	err := s.tx.Run(ctx, func(ctx context.Context, tx pgx.Tx) error {
		head, err := lockOwner(ctx, tx, p)
		if err != nil {
			return err
		}
		q := sqlc.New(tx)
		n, err := q.CountActiveLearningWriters(ctx, p.UserID)
		if err != nil {
			return err
		}
		for ; n >= MaxActiveWriters; n-- {
			if _, err := q.RetireLeastRecentLearningWriter(ctx, p.UserID); err != nil {
				return err
			}
		}
		w, err := q.InsertLearningWriter(ctx, sqlc.InsertLearningWriterParams{UserID: p.UserID, WriterID: uuid.New(), Epoch: head.Epoch})
		if err != nil {
			return err
		}
		out = Registered{WriterID: w.WriterID, LastSeq: 0, Epoch: head.Epoch}
		return nil
	})
	return out, err
}

// --- records ------------------------------------------------------------------------------------

// RecordContent is a live word's content in API responses.
type RecordContent struct {
	Word          string   `json:"word"`
	Meaning       string   `json:"meaning"`
	Pronunciation *string  `json:"pronunciation"`
	PartOfSpeech  *string  `json:"part_of_speech"`
	Source        *string  `json:"source"`
	Examples      []string `json:"examples"`
	Tags          []string `json:"tags"`
}

// Record is the canonical server state of one word. A tombstone has no content or dates.
type Record struct {
	EntityID        uuid.UUID      `json:"entity_id"`
	Revision        int64          `json:"revision"`
	Deleted         bool           `json:"deleted"`
	Content         *RecordContent `json:"content"`
	CaptureDay      *string        `json:"capture_day"`
	ClientCreatedAt *time.Time     `json:"client_created_at"`
	UpdatedAt       time.Time      `json:"updated_at"`
}

func recordOf(r sqlc.VocabularyItem) *Record {
	out := &Record{EntityID: r.ID, Revision: r.Revision, Deleted: r.DeletedAt != nil, UpdatedAt: r.UpdatedAt.UTC()}
	if r.DeletedAt == nil {
		c := itemOf(r)
		out.Content = &RecordContent{Word: c.Word, Meaning: c.Meaning, Pronunciation: c.Pronunciation, PartOfSpeech: c.PartOfSpeech,
			Source: c.Source, Examples: c.Examples, Tags: c.Tags}
		day := c.CaptureDay.Format("2006-01-02")
		created := c.ClientCreatedAt.UTC()
		out.CaptureDay, out.ClientCreatedAt = &day, &created
	}
	return out
}

func itemOf(r sqlc.VocabularyItem) Item {
	it := Item{Content: Content{Pronunciation: r.Pronunciation, PartOfSpeech: r.PartOfSpeech, Source: r.Source,
		Examples: nonNil(r.Examples), Tags: nonNil(r.Tags)}}
	if r.Word != nil {
		it.Word = *r.Word
	}
	if r.Meaning != nil {
		it.Meaning = *r.Meaning
	}
	if r.CaptureDay != nil {
		it.CaptureDay = *r.CaptureDay
	}
	if r.ClientCreatedAt != nil {
		it.ClientCreatedAt = *r.ClientCreatedAt
	}
	return it
}

func nonNil(l []string) []string {
	if l == nil {
		return []string{}
	}
	return l
}

// --- push ---------------------------------------------------------------------------------------

// Basis is an import's capacity_basis.
type Basis struct {
	LiveWords    int64 `json:"live_words"`
	ContentBytes int64 `json:"content_bytes"`
}

// PushInput is one push (Import nil) or import request.
type PushInput struct {
	Epoch     uuid.UUID
	WriterID  uuid.UUID
	Import    *Basis
	Mutations []Mutation
}

// Result is one mutation's result. A duplicate carries its original outcome and codes.
type Result struct {
	Seq              int64     `json:"seq"`
	EntityID         uuid.UUID `json:"entity_id"`
	Outcome          string    `json:"outcome"`
	OriginalOutcome  string    `json:"original_outcome,omitempty"`
	Code             string    `json:"code,omitempty"`
	Detail           string    `json:"detail,omitempty"`
	Field            string    `json:"field,omitempty"`
	Limit            string    `json:"limit,omitempty"`
	ConflictedFields []string  `json:"conflicted_fields,omitempty"`
	Revision         *int64    `json:"revision,omitempty"`
	Record           *Record   `json:"record"`
}

// stored is the deduplication record's result: fixed codes, field names and revisions only.
type stored struct {
	Outcome          string   `json:"outcome"`
	Code             string   `json:"code,omitempty"`
	Detail           string   `json:"detail,omitempty"`
	Field            string   `json:"field,omitempty"`
	Limit            string   `json:"limit,omitempty"`
	ConflictedFields []string `json:"conflicted_fields,omitempty"`
	Revision         *int64   `json:"revision,omitempty"`
}

// PushOutput is the 200 body.
type PushOutput struct {
	Results      []Result `json:"results"`
	HeadRevision int64    `json:"head_revision"`
	LiveWords    int32    `json:"live_words"`
	ContentBytes int64    `json:"content_bytes"`
	LastSeq      int64    `json:"last_seq"`
}

type counters struct {
	revision     int64
	liveWords    int32
	contentBytes int64
}

// Push applies a push or import (TRD 05 §5). Under the head lock it checks the epoch and writer,
// resolves every already-processed seq (duplicate, mutation_reused or mutation_expired) without
// applying it, and only then admits the new suffix: for an import, capacity admission applies to
// that suffix alone, and a refusal leaves the suffix and its seq values untouched.
func (s *Service) Push(ctx context.Context, p session.Principal, in PushInput) (PushOutput, error) {
	if err := s.admit(ctx, p, rulePush); err != nil {
		return PushOutput{}, err
	}
	route := "push"
	if in.Import != nil {
		route = "import"
		for _, m := range in.Mutations {
			if m.Op != OpCreate {
				return PushOutput{}, httpx.ErrBadRequest
			}
		}
	}
	var out PushOutput
	var applied []Result
	err := s.tx.Run(ctx, func(ctx context.Context, tx pgx.Tx) error {
		out, applied = PushOutput{}, nil
		head, err := lockOwner(ctx, tx, p)
		if err != nil {
			return err
		}
		if head.Epoch != in.Epoch {
			return s.reset("epoch_changed", head.Epoch)
		}
		q := sqlc.New(tx)
		w, err := q.GetLearningWriter(ctx, sqlc.GetLearningWriterParams{UserID: p.UserID, WriterID: in.WriterID})
		if errors.Is(err, pgx.ErrNoRows) || (err == nil && (w.RetiredAt != nil || w.Epoch != head.Epoch)) {
			return s.reset("writer_unknown", head.Epoch)
		}
		if err != nil {
			return err
		}
		first, last := in.Mutations[0].Seq, in.Mutations[len(in.Mutations)-1].Seq
		if first > w.LastSeq+1 {
			return ErrSequenceGap
		}
		// 1. Already-processed seq values: never applied again.
		var prefix []Mutation
		suffix := in.Mutations
		if first <= w.LastSeq {
			cut := int(min(last, w.LastSeq) - first + 1)
			prefix, suffix = in.Mutations[:cut], in.Mutations[cut:]
			recs, err := q.ListLearningMutations(ctx, sqlc.ListLearningMutationsParams{UserID: p.UserID, WriterID: in.WriterID,
				FirstSeq: first, LastSeq: prefix[len(prefix)-1].Seq})
			if err != nil {
				return err
			}
			bySeq := map[int64]sqlc.LearningMutation{}
			for _, r := range recs {
				bySeq[r.Seq] = r
			}
			for _, m := range prefix {
				r, err := resolveProcessed(ctx, q, p.UserID, m, bySeq)
				if err != nil {
					return err
				}
				out.Results = append(out.Results, r)
			}
		}
		// 2. Capacity admission for an import's new suffix only.
		c := counters{revision: head.Revision, liveWords: head.LiveWords, contentBytes: head.ContentBytes}
		if in.Import != nil && len(suffix) > 0 {
			if err := admitImport(ctx, q, p.UserID, *in.Import, c, suffix, w.LastSeq); err != nil {
				return err
			}
		}
		// 3. The new suffix, in order.
		for _, m := range suffix {
			r, err := s.apply(ctx, q, p.UserID, head, &c, m)
			if err != nil {
				return err
			}
			body, err := json.Marshal(stored{Outcome: r.Outcome, Code: r.Code, Detail: r.Detail, Field: r.Field, Limit: r.Limit,
				ConflictedFields: r.ConflictedFields, Revision: r.Revision})
			if err != nil {
				return err
			}
			if err := q.InsertLearningMutation(ctx, sqlc.InsertLearningMutationParams{UserID: p.UserID, WriterID: in.WriterID,
				Seq: m.Seq, RequestHash: m.Hash[:], Result: body}); err != nil {
				return err
			}
			out.Results = append(out.Results, r)
			applied = append(applied, r)
		}
		if len(suffix) > 0 {
			if err := q.UpdateLearningHead(ctx, sqlc.UpdateLearningHeadParams{UserID: p.UserID, Revision: c.revision,
				LiveWords: c.liveWords, ContentBytes: c.contentBytes}); err != nil {
				return err
			}
		}
		lastSeq := max(w.LastSeq, last)
		if err := q.AdvanceLearningWriter(ctx, sqlc.AdvanceLearningWriterParams{UserID: p.UserID, WriterID: in.WriterID, LastSeq: lastSeq}); err != nil {
			return err
		}
		out.HeadRevision, out.LiveWords, out.ContentBytes, out.LastSeq = c.revision, c.liveWords, c.contentBytes, lastSeq
		return nil
	})
	var reset *ResetError
	var capacity *CapacityError
	switch {
	case err == nil:
		s.metrics.LearningPush(route, "ok")
		for _, r := range applied {
			s.metrics.LearningItem(opOf(in.Mutations, r.Seq), r.Outcome)
		}
	case errors.As(err, &reset):
		s.metrics.LearningPush(route, "reset")
	case errors.As(err, &capacity):
		s.metrics.LearningPush(route, "capacity_changed")
	case errors.Is(err, ErrSequenceGap):
		s.metrics.LearningPush(route, "sequence_gap")
	}
	return out, err
}

func opOf(ms []Mutation, seq int64) string {
	for _, m := range ms {
		if m.Seq == seq {
			return m.Op
		}
	}
	return "other"
}

// resolveProcessed answers a seq at or below last_seq from its record: the high-water mark
// proves the mutation was processed, not that it applied; the record says how, while it exists.
func resolveProcessed(ctx context.Context, q *sqlc.Queries, user uuid.UUID, m Mutation, bySeq map[int64]sqlc.LearningMutation) (Result, error) {
	r := Result{Seq: m.Seq, EntityID: m.EntityID}
	rec, ok := bySeq[m.Seq]
	switch {
	case !ok:
		r.Outcome, r.Code = "rejected", "mutation_expired"
	case string(rec.RequestHash) != string(m.Hash[:]):
		r.Outcome, r.Code = "rejected", "mutation_reused"
	default:
		var st stored
		if err := json.Unmarshal(rec.Result, &st); err != nil {
			return r, fmt.Errorf("learning: stored result: %w", err)
		}
		r.Outcome, r.OriginalOutcome = "duplicate", st.Outcome
		r.Code, r.Detail, r.Field, r.Limit, r.ConflictedFields, r.Revision = st.Code, st.Detail, st.Field, st.Limit, st.ConflictedFields, st.Revision
	}
	row, err := q.GetVocabularyItem(ctx, sqlc.GetVocabularyItemParams{UserID: user, ID: m.EntityID})
	switch {
	case errors.Is(err, pgx.ErrNoRows):
	case err != nil:
		return r, err
	default:
		r.Record = recordOf(row)
	}
	return r, nil
}

// admitImport refuses the whole import (CapacityError, nothing applied) when the basis differs
// from the head or the suffix's valid creates do not fit both limits.
func admitImport(ctx context.Context, q *sqlc.Queries, user uuid.UUID, b Basis, c counters, suffix []Mutation, lastSeq int64) error {
	refuse := &CapacityError{LiveWords: c.liveWords, ContentBytes: c.contentBytes, LastSeq: lastSeq}
	if b.LiveWords != int64(c.liveWords) || b.ContentBytes != c.contentBytes {
		return refuse
	}
	words, size := int64(c.liveWords), c.contentBytes
	for _, m := range suffix {
		if m.Invalid != nil || m.Item.Validate(m.BadDate) != nil {
			continue
		}
		if _, err := q.GetVocabularyItem(ctx, sqlc.GetVocabularyItemParams{UserID: user, ID: m.EntityID}); err == nil {
			continue // id_in_use, not counted
		} else if !errors.Is(err, pgx.ErrNoRows) {
			return err
		}
		words++
		size += int64(CanonicalSize(m.Item.Content))
	}
	if words > MaxLiveWords || size > MaxContentBytes {
		return refuse
	}
	return nil
}

func rejected(m Mutation, code string) Result {
	return Result{Seq: m.Seq, EntityID: m.EntityID, Outcome: "rejected", Code: code}
}

func invalid(m Mutation, inv *Invalid) Result {
	r := rejected(m, "invalid_item")
	r.Detail, r.Field = inv.Detail, inv.Field
	return r
}

func quota(m Mutation, limit string) Result {
	r := rejected(m, "quota_exceeded")
	r.Limit = limit
	return r
}

func withRecord(r Result, row *sqlc.VocabularyItem) Result {
	if row != nil {
		r.Record = recordOf(*row)
	}
	return r
}

// apply evaluates one new mutation (TRD 05 §5.6, §6) and writes its effect.
func (s *Service) apply(ctx context.Context, q *sqlc.Queries, user uuid.UUID, head sqlc.LearningSyncHead, c *counters, m Mutation) (Result, error) {
	cur, err := q.GetVocabularyItem(ctx, sqlc.GetVocabularyItemParams{UserID: user, ID: m.EntityID})
	found := err == nil
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return Result{}, err
	}
	var row *sqlc.VocabularyItem
	if found {
		row = &cur
	}
	if m.Op != OpCreate && *m.Base > head.Revision {
		return withRecord(rejected(m, "stale_base"), row), nil
	}
	if !found && m.Op != OpCreate {
		if *m.Base < head.TombstoneHorizon {
			return rejected(m, "stale_base"), nil
		}
		return rejected(m, "unknown_item"), nil
	}
	tomb := found && cur.DeletedAt != nil
	switch m.Op {
	case OpCreate:
		if found {
			return withRecord(rejected(m, "id_in_use"), row), nil
		}
		return s.writeLive(ctx, q, user, c, m, nil, *m.Item, nil)
	case OpDelete:
		if tomb {
			return withRecord(Result{Seq: m.Seq, EntityID: m.EntityID, Outcome: "no_op"}, row), nil
		}
		c.revision++
		if err := q.TombstoneVocabularyItem(ctx, sqlc.TombstoneVocabularyItemParams{UserID: user, ID: m.EntityID, Revision: c.revision}); err != nil {
			return Result{}, err
		}
		c.liveWords--
		c.contentBytes -= int64(cur.ContentBytes)
		return s.after(ctx, q, user, m, "applied", nil)
	case OpRestore:
		if !tomb {
			return withRecord(Result{Seq: m.Seq, EntityID: m.EntityID, Outcome: "no_op"}, row), nil
		}
		if *m.Base < *cur.DeletedRevision {
			return withRecord(rejected(m, "stale_base"), row), nil
		}
		return s.writeLive(ctx, q, user, c, m, row, *m.Item, nil)
	case OpUpdate:
		if tomb {
			return withRecord(rejected(m, "deleted_on_server"), row), nil
		}
		next := itemOf(cur)
		for f, v := range m.Patch {
			setField(&next, f, v)
		}
		return s.writeLive(ctx, q, user, c, m, row, next, m.Changed)
	}
	return Result{}, errors.New("learning: unknown op")
}

// writeLive validates and writes a live item: a create (row nil), a restore (changed nil) or an
// update of the changed fields, with quota and field-level merge.
func (s *Service) writeLive(ctx context.Context, q *sqlc.Queries, user uuid.UUID, c *counters, m Mutation, row *sqlc.VocabularyItem, next Item, changed []string) (Result, error) {
	inv := m.Invalid
	if inv == nil {
		inv = next.Validate(m.BadDate)
	}
	if inv != nil {
		return withRecord(invalid(m, inv), row), nil
	}
	size := int64(CanonicalSize(next.Content))
	revs := map[string]int64{}
	var conflicted []string
	if m.Op == OpUpdate {
		if err := json.Unmarshal(row.FieldRevisions, &revs); err != nil {
			return Result{}, fmt.Errorf("learning: field revisions: %w", err)
		}
		prev := itemOf(*row)
		var differs []string
		for _, f := range changed {
			if !sameField(prev, next, f) {
				differs = append(differs, f)
				if revs[f] > *m.Base {
					conflicted = append(conflicted, f)
				}
			}
		}
		if len(differs) == 0 {
			return withRecord(Result{Seq: m.Seq, EntityID: m.EntityID, Outcome: "no_op"}, row), nil
		}
		if c.contentBytes-int64(row.ContentBytes)+size > MaxContentBytes {
			return withRecord(quota(m, "bytes"), row), nil
		}
		changed = differs
	} else {
		if int64(c.liveWords)+1 > MaxLiveWords {
			return withRecord(quota(m, "words"), row), nil
		}
		if c.contentBytes+size > MaxContentBytes {
			return withRecord(quota(m, "bytes"), row), nil
		}
		changed = editable
	}
	c.revision++
	for _, f := range changed {
		revs[f] = c.revision
	}
	frs, err := json.Marshal(revs)
	if err != nil {
		return Result{}, err
	}
	day, created := next.CaptureDay, next.ClientCreatedAt.UTC()
	if m.Op == OpUpdate {
		created = row.ClientCreatedAt.UTC()
	}
	word, meaning := next.Word, next.Meaning
	examples, tags := nonNil(next.Examples), nonNil(next.Tags)
	if row == nil {
		err = q.InsertVocabularyItem(ctx, sqlc.InsertVocabularyItemParams{UserID: user, ID: m.EntityID, Word: &word, Meaning: &meaning,
			Pronunciation: next.Pronunciation, PartOfSpeech: next.PartOfSpeech, Source: next.Source, Examples: examples, Tags: tags,
			CaptureDay: &day, ClientCreatedAt: &created, ContentBytes: int32(size), Revision: c.revision, FieldRevisions: frs})
	} else {
		err = q.UpdateVocabularyItem(ctx, sqlc.UpdateVocabularyItemParams{UserID: user, ID: m.EntityID, Word: &word, Meaning: &meaning,
			Pronunciation: next.Pronunciation, PartOfSpeech: next.PartOfSpeech, Source: next.Source, Examples: examples, Tags: tags,
			CaptureDay: &day, ClientCreatedAt: &created, ContentBytes: int32(size), Revision: c.revision, FieldRevisions: frs})
	}
	if err != nil {
		return Result{}, err
	}
	if m.Op == OpUpdate {
		c.contentBytes += size - int64(row.ContentBytes)
	} else {
		c.liveWords++
		c.contentBytes += size
	}
	outcome := "applied"
	if len(conflicted) > 0 {
		outcome = "merged"
	}
	return s.after(ctx, q, user, m, outcome, conflicted)
}

func (s *Service) after(ctx context.Context, q *sqlc.Queries, user uuid.UUID, m Mutation, outcome string, conflicted []string) (Result, error) {
	row, err := q.GetVocabularyItem(ctx, sqlc.GetVocabularyItemParams{UserID: user, ID: m.EntityID})
	if err != nil {
		return Result{}, err
	}
	rev := row.Revision
	return Result{Seq: m.Seq, EntityID: m.EntityID, Outcome: outcome, ConflictedFields: conflicted, Revision: &rev, Record: recordOf(row)}, nil
}

func setField(it *Item, f string, v any) {
	if f == "capture_day" {
		it.CaptureDay = v.(time.Time)
		return
	}
	assign(it, f, v)
}

func sameField(a, b Item, f string) bool {
	eq := func(x, y *string) bool { return (x == nil && y == nil) || (x != nil && y != nil && *x == *y) }
	switch f {
	case "word":
		return a.Word == b.Word
	case "meaning":
		return a.Meaning == b.Meaning
	case "pronunciation":
		return eq(a.Pronunciation, b.Pronunciation)
	case "part_of_speech":
		return eq(a.PartOfSpeech, b.PartOfSpeech)
	case "source":
		return eq(a.Source, b.Source)
	case "examples":
		return slices.Equal(a.Examples, b.Examples)
	case "tags":
		return slices.Equal(a.Tags, b.Tags)
	case "capture_day":
		return a.CaptureDay.Equal(b.CaptureDay)
	}
	return false
}

// --- feed and snapshot ----------------------------------------------------------------------------

// Cursor and page-token formats differ by prefix, so one is never accepted as the other.
const (
	cursorPrefix = "c1."
	tokenPrefix  = "s1."
)

// FeedCursor encodes a feed position {epoch, revision}.
func FeedCursor(epoch uuid.UUID, revision int64) string {
	b := make([]byte, 24)
	copy(b, epoch[:])
	binary.BigEndian.PutUint64(b[16:], uint64(revision))
	return cursorPrefix + base64.RawURLEncoding.EncodeToString(b)
}

func parseCursor(s string) (uuid.UUID, int64, bool) {
	if len(s) < len(cursorPrefix) || s[:len(cursorPrefix)] != cursorPrefix {
		return uuid.Nil, 0, false
	}
	b, err := base64.RawURLEncoding.DecodeString(s[len(cursorPrefix):])
	if err != nil || len(b) != 24 {
		return uuid.Nil, 0, false
	}
	rev := int64(binary.BigEndian.Uint64(b[16:]))
	return uuid.UUID(b[:16]), rev, rev >= 0
}

func pageToken(epoch uuid.UUID, h int64, after uuid.UUID) string {
	b := make([]byte, 40)
	copy(b, epoch[:])
	binary.BigEndian.PutUint64(b[16:], uint64(h))
	copy(b[24:], after[:])
	return tokenPrefix + base64.RawURLEncoding.EncodeToString(b)
}

func parseToken(s string) (uuid.UUID, int64, uuid.UUID, bool) {
	if len(s) < len(tokenPrefix) || s[:len(tokenPrefix)] != tokenPrefix {
		return uuid.Nil, 0, uuid.Nil, false
	}
	b, err := base64.RawURLEncoding.DecodeString(s[len(tokenPrefix):])
	if err != nil || len(b) != 40 {
		return uuid.Nil, 0, uuid.Nil, false
	}
	h := int64(binary.BigEndian.Uint64(b[16:]))
	return uuid.UUID(b[:16]), h, uuid.UUID(b[24:]), h >= 0
}

// readOnly runs fn in one REPEATABLE READ read-only transaction, so the rows read and the head
// (epoch, horizon) checked describe the same moment: a compaction is either fully visible or not.
func (s *Service) readOnly(ctx context.Context, fn func(q *sqlc.Queries) error) error {
	tx, err := s.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead, AccessMode: pgx.ReadOnly})
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback(context.WithoutCancel(ctx)) }()
	if err := fn(sqlc.New(tx)); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// Changes is GET /v1/learning/sync/changes.
type Changes struct {
	Epoch   uuid.UUID `json:"epoch"`
	Changes []*Record `json:"changes"`
	Cursor  string    `json:"cursor"`
	HasMore bool      `json:"has_more"`
}

func pageRows(rows []sqlc.VocabularyItem, limit int) ([]sqlc.VocabularyItem, bool) {
	var bytes int64
	for i, r := range rows {
		if i == limit {
			return rows[:i], true
		}
		bytes += int64(r.ContentBytes)
		if i > 0 && bytes > MaxPageBytes {
			return rows[:i], true
		}
	}
	return rows, false
}

// Changes returns the owner's changes after a feed cursor, in revision order.
func (s *Service) Changes(ctx context.Context, p session.Principal, cursor string, limit int) (Changes, error) {
	epoch, after, ok := parseCursor(cursor)
	if !ok || limit < 1 || limit > MaxPageChanges {
		return Changes{}, httpx.ErrBadRequest
	}
	if err := s.admit(ctx, p, rulePull); err != nil {
		return Changes{}, err
	}
	var out Changes
	err := s.readOnly(ctx, func(q *sqlc.Queries) error {
		rows, err := q.VocabularyChanges(ctx, sqlc.VocabularyChangesParams{UserID: p.UserID, AfterRevision: after, MaxRows: int32(limit + 1)})
		if err != nil {
			return err
		}
		head, err := q.GetLearningHead(ctx, p.UserID)
		if err != nil {
			return err
		}
		switch {
		case epoch != head.Epoch:
			return s.reset("epoch_changed", head.Epoch)
		case after > head.Revision:
			return s.reset("cursor_ahead", head.Epoch)
		case after < head.TombstoneHorizon:
			return s.reset("cursor_compacted", head.Epoch)
		}
		page, more := pageRows(rows, limit)
		out = Changes{Epoch: head.Epoch, Changes: make([]*Record, 0, len(page)), Cursor: FeedCursor(head.Epoch, after), HasMore: more}
		for _, r := range page {
			out.Changes = append(out.Changes, recordOf(r))
		}
		if len(page) > 0 {
			out.Cursor = FeedCursor(head.Epoch, page[len(page)-1].Revision)
		}
		return nil
	})
	return out, err
}

// Snapshot is GET /v1/learning/sync/snapshot.
type Snapshot struct {
	Epoch            uuid.UUID `json:"epoch"`
	SnapshotRevision int64     `json:"snapshot_revision"`
	Items            []*Record `json:"items"`
	NextPageToken    *string   `json:"next_page_token"`
	CatchUpCursor    string    `json:"catch_up_cursor"`
}

// Snapshot pages the live items as of a captured head revision H, in id order. The first page
// captures H; every page token binds the epoch, H and the last id. A word changed after H is
// excluded here and reaches the client by catching up from catch_up_cursor (revision H).
func (s *Service) Snapshot(ctx context.Context, p session.Principal, token string, limit int) (Snapshot, error) {
	var epoch, after uuid.UUID
	var h int64
	if token != "" {
		var ok bool
		if epoch, h, after, ok = parseToken(token); !ok {
			return Snapshot{}, httpx.ErrBadRequest
		}
	}
	if limit < 1 || limit > MaxPageChanges {
		return Snapshot{}, httpx.ErrBadRequest
	}
	if err := s.admit(ctx, p, rulePull); err != nil {
		return Snapshot{}, err
	}
	var out Snapshot
	err := s.readOnly(ctx, func(q *sqlc.Queries) error {
		head, err := q.GetLearningHead(ctx, p.UserID)
		if err != nil {
			return err
		}
		if token == "" {
			epoch, h = head.Epoch, head.Revision
		}
		switch {
		case epoch != head.Epoch:
			return s.reset("epoch_changed", head.Epoch)
		case h > head.Revision:
			return s.reset("cursor_ahead", head.Epoch)
		case h < head.TombstoneHorizon:
			return s.reset("cursor_compacted", head.Epoch)
		}
		rows, err := q.VocabularySnapshotPage(ctx, sqlc.VocabularySnapshotPageParams{UserID: p.UserID, SnapshotRevision: h, AfterID: after, MaxRows: int32(limit + 1)})
		if err != nil {
			return err
		}
		page, more := pageRows(rows, limit)
		out = Snapshot{Epoch: epoch, SnapshotRevision: h, Items: make([]*Record, 0, len(page)), CatchUpCursor: FeedCursor(epoch, h)}
		for _, r := range page {
			out.Items = append(out.Items, recordOf(r))
		}
		if more {
			t := pageToken(epoch, h, page[len(page)-1].ID)
			out.NextPageToken = &t
		}
		return nil
	})
	return out, err
}
