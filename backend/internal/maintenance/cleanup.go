// Package maintenance runs the cleanup jobs of TRD 01 §6.10 inside the API process.
//
// Each job runs every Interval under its own session-level advisory lock, so only one instance
// runs it at a time. The lock is taken with pg_try_advisory_lock on one dedicated connection and
// every statement of the job runs on that same connection, so the job holds the lock from its
// first batch to its last. Release is verified: pg_advisory_unlock must report that this session
// held the lock. If the release fails or reports otherwise (or the job failed or was cancelled
// in a way that may have broken the connection), the connection is taken out of the pool and
// closed, which drops any session lock with it. A lock can therefore never leak into the pool.
//
// Every query uses the database clock. Deletes are bounded batches of BatchSize rows, at most
// MaxBatches per job and run, so one run is bounded even after a long outage; the next run
// continues where it stopped.
package maintenance

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/db/sqlc"
)

// Defaults (TRD 6.10).
const (
	DefaultInterval   = 5 * time.Minute
	DefaultBatchSize  = 1000
	DefaultMaxBatches = 100
	releaseTimeout    = 5 * time.Second
)

// lockBase is the first advisory lock key of the cleanup jobs ("VEEACL" in hex). Each job adds
// its index. It does not collide with the test harness key ("VEEATEST") or goose's own lock.
const lockBase int64 = 0x5645_4541_434c_0000

// Job is one cleanup task.
type Job struct {
	Name    string
	LockKey int64
	// Batched jobs repeat while a batch comes back full. Unbatched ones run one statement.
	Batched bool
	run     func(ctx context.Context, q *sqlc.Queries, batch int32) (int64, error)
}

// Jobs is the TRD 6.10 table, in the order they run. Pending password hashes are scrubbed
// before old challenges are deleted, and old sessions go before consumed refresh tokens so the
// cascade does most of that work.
func Jobs() []Job {
	jobs := []Job{
		{Name: "otp_pending_password_hash", run: func(ctx context.Context, q *sqlc.Queries, _ int32) (int64, error) {
			return q.ClearExpiredPendingPasswordHashes(ctx) // AC-26: no hash outlives its challenge
		}},
		{Name: "otp_challenges", Batched: true, run: func(ctx context.Context, q *sqlc.Queries, b int32) (int64, error) {
			return q.DeleteExpiredOTPChallenges(ctx, b) // 24 h after expiry; cascades to outbox rows
		}},
		{Name: "otp_cooldowns", Batched: true, run: func(ctx context.Context, q *sqlc.Queries, b int32) (int64, error) {
			return q.DeleteStaleOTPCooldowns(ctx, b) // last issued more than 24 h ago
		}},
		{Name: "email_outbox_reap", run: func(ctx context.Context, q *sqlc.Queries, _ int32) (int64, error) {
			return q.ReapOutbox(ctx) // backstop for the worker's reaper (TRD 8.3)
		}},
		{Name: "email_outbox_finished", Batched: true, run: func(ctx context.Context, q *sqlc.Queries, b int32) (int64, error) {
			return q.DeleteFinishedOutbox(ctx, b) // terminal rows, 7 days after finished_at
		}},
		{Name: "sessions", Batched: true, run: func(ctx context.Context, q *sqlc.Queries, b int32) (int64, error) {
			return q.DeleteStaleSessions(ctx, b) // 30 days after revocation or absolute expiry
		}},
		{Name: "refresh_tokens_consumed", Batched: true, run: func(ctx context.Context, q *sqlc.Queries, b int32) (int64, error) {
			return q.DeleteExpiredConsumedRefreshTokens(ctx, b) // retain_until passed (lookup enforces it anyway)
		}},
		{Name: "rate_limit_counters", Batched: true, run: func(ctx context.Context, q *sqlc.Queries, b int32) (int64, error) {
			return q.DeleteOldRateLimitCounters(ctx, b) // windows older than 48 h
		}},
		// Append to keep existing advisory-lock keys stable across rolling deployments.
		{Name: "email_changes", Batched: true, run: func(ctx context.Context, q *sqlc.Queries, b int32) (int64, error) {
			return q.DeleteExpiredEmailChanges(ctx, b)
		}},
		// audit_events are not deleted in Phase 1 (Q-L3).
	}
	for i := range jobs {
		jobs[i].LockKey = lockBase + int64(i)
	}
	return jobs
}

// Result is one job's outcome in one run.
type Result struct {
	Job string
	// Ran is false when another session held the job's lock, so this run skipped it.
	Ran      bool
	Rows     int64
	Batches  int
	Duration time.Duration
	Err      error
}

// Config wires a Runner.
type Config struct {
	Pool       *pgxpool.Pool
	Interval   time.Duration // zero means DefaultInterval
	BatchSize  int32         // zero means DefaultBatchSize
	MaxBatches int           // zero means DefaultMaxBatches
	Logger     *slog.Logger
	// OnResult, when set, is called with every job result (metrics, tests).
	OnResult func(Result)
}

// Runner runs the jobs. It is safe for concurrent use; concurrent runs, in one process or many,
// are serialized per job by the advisory locks.
type Runner struct {
	cfg  Config
	jobs []Job
}

// New validates cfg and returns a Runner for Jobs().
func New(cfg Config) (*Runner, error) {
	if cfg.Pool == nil {
		return nil, errors.New("maintenance: a pool is required")
	}
	if cfg.Interval == 0 {
		cfg.Interval = DefaultInterval
	}
	if cfg.BatchSize == 0 {
		cfg.BatchSize = DefaultBatchSize
	}
	if cfg.MaxBatches == 0 {
		cfg.MaxBatches = DefaultMaxBatches
	}
	if cfg.Interval < 0 || cfg.BatchSize < 1 || cfg.MaxBatches < 1 {
		return nil, errors.New("maintenance: interval, batch size and max batches must be positive")
	}
	if cfg.Logger == nil {
		cfg.Logger = slog.New(slog.DiscardHandler)
	}
	return &Runner{cfg: cfg, jobs: Jobs()}, nil
}

// Run runs every job once at start and then every Interval until ctx is cancelled. A job in
// progress at cancellation is interrupted and its lock released.
func (r *Runner) Run(ctx context.Context) error {
	t := time.NewTicker(r.cfg.Interval)
	defer t.Stop()
	for {
		r.RunOnce(ctx)
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-t.C:
		}
	}
}

// RunOnce runs every job once, in order, and returns their results.
func (r *Runner) RunOnce(ctx context.Context) []Result {
	results := make([]Result, 0, len(r.jobs))
	for _, j := range r.jobs {
		if ctx.Err() != nil {
			break
		}
		res := r.runJob(ctx, j)
		switch {
		case res.Err != nil:
			r.cfg.Logger.Error("cleanup job failed", "job", j.Name, "rows", res.Rows, "error", res.Err)
		case res.Ran && res.Rows > 0:
			r.cfg.Logger.Info("cleanup job done", "job", j.Name, "rows", res.Rows, "batches", res.Batches)
		}
		if r.cfg.OnResult != nil {
			r.cfg.OnResult(res)
		}
		results = append(results, res)
	}
	return results
}

func (r *Runner) runJob(ctx context.Context, j Job) (res Result) {
	start := time.Now()
	res.Job = j.Name
	defer func() { res.Duration = time.Since(start) }()

	conn, err := r.cfg.Pool.Acquire(ctx)
	if err != nil {
		res.Err = fmt.Errorf("acquire connection: %w", err)
		return res
	}
	q := sqlc.New(conn)
	got, err := q.TryCleanupAdvisoryLock(ctx, j.LockKey)
	if err != nil {
		res.Err = fmt.Errorf("try lock: %w", err)
		discard(conn)
		return res
	}
	if !got {
		conn.Release() // another session runs this job right now
		return res
	}
	res.Ran = true

	// The lock is held by this connection's session; every batch runs on it.
	for res.Batches < r.cfg.MaxBatches {
		n, err := j.run(ctx, q, r.cfg.BatchSize)
		res.Batches++
		res.Rows += n
		if err != nil {
			res.Err = fmt.Errorf("batch %d: %w", res.Batches, err)
			break
		}
		if !j.Batched || n < int64(r.cfg.BatchSize) {
			break
		}
	}

	// Release on a context that survives cancellation, and verify this session held the lock.
	rctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), releaseTimeout)
	defer cancel()
	released, err := q.ReleaseCleanupAdvisoryLock(rctx, j.LockKey)
	switch {
	case err != nil:
		res.Err = errors.Join(res.Err, fmt.Errorf("release lock: %w", err))
		discard(conn)
	case !released:
		res.Err = errors.Join(res.Err, errors.New("advisory lock was not held at release"))
		discard(conn)
	case res.Err != nil:
		discard(conn) // the connection may be in a bad state after a failed statement
	default:
		conn.Release()
	}
	return res
}

// discard takes the connection out of the pool and closes it, which ends its session and with
// it every session-level advisory lock it may still hold.
func discard(c *pgxpool.Conn) {
	ctx, cancel := context.WithTimeout(context.Background(), releaseTimeout)
	defer cancel()
	_ = c.Hijack().Close(ctx)
}
