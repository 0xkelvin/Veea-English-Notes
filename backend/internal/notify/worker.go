package notify

import (
	"context"
	"errors"
	"log/slog"
	"sync"
	"sync/atomic"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/db/sqlc"
)

// MaxSends is the send budget per row (TRD 8.3, R14). The database CHECK enforces it too.
const MaxSends = 5

// WorkerConfig holds the TRD 8.3 timings. Zero values take the approved defaults (R15).
type WorkerConfig struct {
	// Lease is how long a claim lasts. Default 2 minutes.
	Lease time.Duration
	// MinLeaseForSend is the lease that must remain to reserve a send. Default 45 s.
	MinLeaseForSend time.Duration
	// SendTimeout bounds one provider call. Default 30 s. It must be shorter than
	// MinLeaseForSend so the lease is still live when the call returns.
	SendTimeout time.Duration
	// BatchSize is the number of rows claimed per cycle. Default 20.
	BatchSize int
	// Concurrency is the number of rows processed at once within a batch. Default 4.
	Concurrency int
	// PollInterval is the pause between cycles. Default 1 s.
	PollInterval time.Duration
	// Backoff is the wait after a retryable result of send n (index n-1). Default 30 s, 1 min,
	// 2 min, 4 min. A send past the end of the list reuses its last value.
	Backoff []time.Duration
	// Logger receives row ids and outcome classes only. Default slog.Default().
	Logger *slog.Logger
	// OnSend, when set, is called after every provider call with the row's template and the
	// result: "sent", or the error class ("permanent", "retryable", "ambiguous"). It is the hook
	// for email_send_total (TRD 11.3).
	OnSend func(template, result string)
	// OnStale, when set, is called for every result write discarded because the lease was gone
	// (email_outbox_stale_result_total).
	OnStale func()
}

func (c WorkerConfig) withDefaults() WorkerConfig {
	if c.Lease == 0 {
		c.Lease = 2 * time.Minute
	}
	if c.MinLeaseForSend == 0 {
		c.MinLeaseForSend = 45 * time.Second
	}
	if c.SendTimeout == 0 {
		c.SendTimeout = 30 * time.Second
	}
	if c.BatchSize == 0 {
		c.BatchSize = 20
	}
	if c.Concurrency == 0 {
		c.Concurrency = 4
	}
	if c.PollInterval == 0 {
		c.PollInterval = time.Second
	}
	if len(c.Backoff) == 0 {
		c.Backoff = []time.Duration{30 * time.Second, time.Minute, 2 * time.Minute, 4 * time.Minute}
	}
	if c.Logger == nil {
		c.Logger = slog.Default()
	}
	return c
}

func (c WorkerConfig) validate() error {
	switch {
	case c.Lease <= 0 || c.MinLeaseForSend <= 0 || c.SendTimeout <= 0 || c.PollInterval <= 0:
		return errors.New("notify: worker durations must be positive")
	case c.SendTimeout >= c.MinLeaseForSend:
		return errors.New("notify: SendTimeout must be shorter than MinLeaseForSend, or a result could land after the lease ends")
	case c.BatchSize < 1 || c.Concurrency < 1:
		return errors.New("notify: BatchSize and Concurrency must be at least 1")
	}
	for _, b := range c.Backoff {
		if b < 0 {
			return errors.New("notify: backoff must not be negative")
		}
	}
	return nil
}

// Stats counts what one or more cycles did. StaleResults is the email_outbox_stale_result_total
// metric of TRD 11.3.
type Stats struct {
	Reaped       int64 // rows terminalized by the reaper
	Claimed      int64
	Sent         int64
	Retried      int64 // retryable or ambiguous results with budget left
	Failed       int64 // permanent, decrypt or render failures, and exhausted budgets
	Cancelled    int64 // linked challenge no longer open
	Released     int64 // skipped claims given back without spending budget
	StaleResults int64 // result writes that found the lease gone
}

func (s *Stats) add(o Stats) {
	atomic.AddInt64(&s.Reaped, o.Reaped)
	atomic.AddInt64(&s.Claimed, o.Claimed)
	atomic.AddInt64(&s.Sent, o.Sent)
	atomic.AddInt64(&s.Retried, o.Retried)
	atomic.AddInt64(&s.Failed, o.Failed)
	atomic.AddInt64(&s.Cancelled, o.Cancelled)
	atomic.AddInt64(&s.Released, o.Released)
	atomic.AddInt64(&s.StaleResults, o.StaleResults)
}

// Worker delivers outbox rows (TRD 8.3). Every database statement is a single autocommit
// statement on the pool, and no transaction or lock is held while the provider is called.
type Worker struct {
	q      *sqlc.Queries
	keys   *Keyring
	sender Sender
	cfg    WorkerConfig
	total  Stats
}

// NewWorker returns a worker on pool. The pool type makes it impossible to run the worker
// inside a caller's transaction.
func NewWorker(pool *pgxpool.Pool, keys *Keyring, sender Sender, cfg WorkerConfig) (*Worker, error) {
	if keys == nil || sender == nil {
		return nil, errors.New("notify: worker needs a keyring and a sender")
	}
	cfg = cfg.withDefaults()
	if err := cfg.validate(); err != nil {
		return nil, err
	}
	return &Worker{q: sqlc.New(pool), keys: keys, sender: sender, cfg: cfg}, nil
}

// Totals returns the counters accumulated since the worker started.
func (w *Worker) Totals() Stats {
	return Stats{
		Reaped: atomic.LoadInt64(&w.total.Reaped), Claimed: atomic.LoadInt64(&w.total.Claimed),
		Sent: atomic.LoadInt64(&w.total.Sent), Retried: atomic.LoadInt64(&w.total.Retried),
		Failed: atomic.LoadInt64(&w.total.Failed), Cancelled: atomic.LoadInt64(&w.total.Cancelled),
		Released: atomic.LoadInt64(&w.total.Released), StaleResults: atomic.LoadInt64(&w.total.StaleResults),
	}
}

// Run repeats RunOnce every PollInterval until ctx is cancelled. On cancellation, rows already
// reserved finish their send and record the result; claimed rows not yet reserved are released.
func (w *Worker) Run(ctx context.Context) error {
	t := time.NewTicker(w.cfg.PollInterval)
	defer t.Stop()
	for {
		if _, err := w.RunOnce(ctx); err != nil && ctx.Err() == nil {
			w.cfg.Logger.Error("outbox cycle failed", "error_class", errorClass(err))
		}
		select {
		case <-ctx.Done():
			return nil
		case <-t.C:
		}
	}
}

// RunOnce performs one cycle: reap, claim, then process each claimed row.
func (w *Worker) RunOnce(ctx context.Context) (Stats, error) {
	var s Stats
	// Database work that must finish even during shutdown uses a context without cancellation
	// but with a short timeout.
	dbctx := func() (context.Context, context.CancelFunc) {
		return context.WithTimeout(context.WithoutCancel(ctx), 10*time.Second)
	}

	if ctx.Err() != nil {
		return s, nil
	}
	reaped, err := w.q.ReapOutbox(ctx)
	if err != nil {
		return s, err
	}
	s.Reaped = reaped

	rows, err := w.q.ClaimOutboxBatch(ctx, sqlc.ClaimOutboxBatchParams{
		LeaseSeconds: w.cfg.Lease.Seconds(), BatchSize: int32(w.cfg.BatchSize)})
	if err != nil {
		w.total.add(s)
		return s, err
	}
	s.Claimed = int64(len(rows))

	var mu sync.Mutex
	sem := make(chan struct{}, w.cfg.Concurrency)
	var wg sync.WaitGroup
	for _, row := range rows {
		wg.Add(1)
		sem <- struct{}{}
		go func(row sqlc.EmailOutbox) {
			defer wg.Done()
			defer func() { <-sem }()
			r := w.process(ctx, dbctx, row)
			mu.Lock()
			s.add(r)
			mu.Unlock()
		}(row)
	}
	wg.Wait()
	w.total.add(s)
	return s, nil
}

// process handles one claimed row through steps 3 to 6 of TRD 8.3.
func (w *Worker) process(ctx context.Context, dbctx func() (context.Context, context.CancelFunc), row sqlc.EmailOutbox) Stats {
	var s Stats
	log := w.cfg.Logger.With("outbox_id", row.ID.String())
	lease := row.LeaseToken

	finish := func(status, code string) bool {
		c, cancel := dbctx()
		defer cancel()
		var le *string
		if code != "" {
			le = &code
		}
		n, err := w.q.FinishOutboxUnderLease(c, sqlc.FinishOutboxUnderLeaseParams{
			ID: row.ID, LeaseToken: lease, Status: status, LastError: le})
		if err != nil || n == 0 {
			s.StaleResults++
			w.stale()
			log.Warn("outbox result discarded: lease no longer held")
			return false
		}
		return true
	}
	release := func() {
		c, cancel := dbctx()
		defer cancel()
		if n, err := w.q.ReleaseOutboxLease(c, sqlc.ReleaseOutboxLeaseParams{ID: row.ID, LeaseToken: lease}); err == nil && n == 1 {
			s.Released++
		}
	}

	// Step 3a: a code email is only worth sending while its challenge is open.
	if row.ChallengeID != nil {
		open, err := w.challengeOpen(ctx, *row.ChallengeID)
		if err != nil {
			release()
			return s
		}
		if !open {
			if finish("cancelled", "challenge_closed") {
				s.Cancelled++
			}
			return s
		}
	}

	// Step 3b: decrypt and render in memory. Failures here are permanent for the row.
	email, code, ok := w.prepare(row)
	if !ok {
		if finish("failed", code) {
			s.Failed++
			log.Error("outbox payload unusable, row failed", "reason", code)
		}
		return s
	}
	defer scrub(&email)

	// Step 3c: shutting down before the reservation means the row goes back untouched.
	if ctx.Err() != nil {
		release()
		return s
	}

	// Step 4: durably reserve one send under a live lease with enough time left.
	rc, cancel := dbctx()
	sends, err := w.q.ReserveOutboxSend(rc, sqlc.ReserveOutboxSendParams{
		ID: row.ID, LeaseToken: lease, MinRemainingSeconds: w.cfg.MinLeaseForSend.Seconds()})
	cancel()
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			release() // too little lease left, budget used up meanwhile, or the claim was lost
		}
		return s
	}

	// Step 5: one provider call, outside any transaction, bounded by SendTimeout. A shutdown does
	// not cut it short: an interrupted send would only turn into an ambiguous result.
	sendCtx, cancelSend := context.WithTimeout(context.WithoutCancel(ctx), w.cfg.SendTimeout)
	providerID, sendErr := w.sender.Send(sendCtx, email)
	cancelSend()
	w.sent(row.Template, sendErr)

	// Step 6: record under the lease guard.
	if sendErr == nil {
		c, cancel := dbctx()
		defer cancel()
		n, err := w.q.FinishOutboxUnderLease(c, sqlc.FinishOutboxUnderLeaseParams{
			ID: row.ID, LeaseToken: lease, Status: "sent", ProviderMessageID: nonEmpty(safeProviderID(providerID))})
		if err != nil || n == 0 {
			s.StaleResults++
			w.stale()
			log.Warn("outbox result discarded: lease no longer held")
			return s
		}
		s.Sent++
		return s
	}

	class, reason := classify(sendErr)
	switch {
	case class == ClassPermanent:
		if finish("failed", lastError(class, reason)) {
			s.Failed++
		}
	case int(sends) >= MaxSends:
		if finish("failed", "send_budget_exhausted") {
			s.Failed++
		}
	default:
		c, cancel := dbctx()
		defer cancel()
		le := lastError(class, reason)
		n, err := w.q.RescheduleOutboxUnderLease(c, sqlc.RescheduleOutboxUnderLeaseParams{
			ID: row.ID, LeaseToken: lease, BackoffSeconds: w.backoff(int(sends)).Seconds(), LastError: &le})
		if err != nil || n == 0 {
			s.StaleResults++
			w.stale()
			log.Warn("outbox result discarded: lease no longer held")
			return s
		}
		s.Retried++
	}
	log.Info("outbox send failed", "class", string(class), "reason", reason, "send", sends)
	return s
}

func (w *Worker) challengeOpen(ctx context.Context, id uuid.UUID) (bool, error) {
	open, err := w.q.GetOutboxChallengeState(ctx, id)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, nil
	}
	return open, err
}

// prepare decrypts and renders a row. On failure it returns the reason code for last_error.
func (w *Worker) prepare(row sqlc.EmailOutbox) (Email, string, bool) {
	if row.PayloadKeyID == nil || row.PayloadCiphertext == nil {
		return Email{}, "decrypt_error", false
	}
	plain, err := w.keys.Open(row.ID, *row.PayloadKeyID, row.PayloadCiphertext)
	if err != nil {
		return Email{}, "decrypt_error", false
	}
	p, err := decodePayload(plain)
	clear(plain)
	if err != nil {
		return Email{}, "decrypt_error", false
	}
	rendered, err := Render(Template(row.Template), p)
	p = Payload{}
	if err != nil {
		return Email{}, "render_error", false
	}
	return Email{ID: row.ID, To: row.ToEmail, Subject: rendered.Subject, Text: rendered.Text, HTML: rendered.HTML}, "", true
}

func (w *Worker) backoff(sends int) time.Duration {
	if sends < 1 {
		sends = 1
	}
	if sends > len(w.cfg.Backoff) {
		return w.cfg.Backoff[len(w.cfg.Backoff)-1]
	}
	return w.cfg.Backoff[sends-1]
}

// scrub drops references to the decrypted bodies as soon as the send is done. Go strings are
// immutable, so this cannot wipe memory; it only shortens how long the plaintext stays reachable.
func scrub(e *Email) { *e = Email{} }

func nonEmpty(s string) *string {
	if s == "" {
		return nil
	}
	return &s
}

// safeProviderID bounds what a provider can write into provider_message_id.
func safeProviderID(s string) string {
	if len(s) > 200 {
		s = s[:200]
	}
	if hasControl(s) {
		return ""
	}
	return s
}

// errorClass reduces an error to a loggable class, never its text.
func errorClass(err error) string {
	switch {
	case errors.Is(err, context.Canceled):
		return "canceled"
	case errors.Is(err, context.DeadlineExceeded):
		return "timeout"
	default:
		return "database"
	}
}

func (w *Worker) stale() {
	if w.cfg.OnStale != nil {
		w.cfg.OnStale()
	}
}

func (w *Worker) sent(template string, err error) {
	if w.cfg.OnSend == nil {
		return
	}
	result := "sent"
	if err != nil {
		class, _ := classify(err)
		result = string(class)
	}
	w.cfg.OnSend(template, result)
}
