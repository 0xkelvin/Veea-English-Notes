package db

import (
	"context"
	"errors"
	"math/rand/v2"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

// SQLSTATE codes that make a whole transaction safe to retry (TRD 7.1 rule 7).
const (
	SQLStateDeadlock      = "40P01"
	SQLStateSerialization = "40001"
)

// DefaultTxRetries is how many times a transaction is retried after a deadlock or
// serialization failure (TRD 7.1 rule 7).
const DefaultTxRetries = 3

// Tx runs use-case transactions at READ COMMITTED (TRD 7.1 rule 1).
type Tx struct {
	Pool *pgxpool.Pool
	// Retries is the number of retries after a deadlock or serialization failure. Zero means
	// DefaultTxRetries; a negative value disables retries.
	Retries int
	// OnRetry, when set, is called with the SQLSTATE before each retry. With the lock order of
	// TRD 7.1 a retry should never happen, so callers count or log it (db_tx_retries_total).
	OnRetry func(sqlstate string)
}

// Run runs fn in a transaction and commits when fn returns nil. Any error from fn rolls the
// transaction back and is returned unchanged.
//
// A deadlock or serialization failure, from fn or from the commit, retries the whole transaction
// with a short jittered backoff. That is safe because nothing committed. fn must therefore keep
// no state between attempts that it does not reset at its start, and must not have effects
// outside the transaction.
func (t Tx) Run(ctx context.Context, fn func(ctx context.Context, tx pgx.Tx) error) error {
	retries := t.Retries
	if retries == 0 {
		retries = DefaultTxRetries
	}
	for attempt := 0; ; attempt++ {
		err := t.once(ctx, fn)
		code, retryable := retryableState(err)
		if !retryable || attempt >= retries {
			return err
		}
		if t.OnRetry != nil {
			t.OnRetry(code)
		}
		backoff := time.Duration(attempt+1) * (10*time.Millisecond + rand.N(20*time.Millisecond))
		select {
		case <-ctx.Done():
			return err
		case <-time.After(backoff):
		}
	}
}

func (t Tx) once(ctx context.Context, fn func(ctx context.Context, tx pgx.Tx) error) error {
	tx, err := t.Pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
	if err != nil {
		return err
	}
	if err := fn(ctx, tx); err != nil {
		// Rollback uses a fresh context so a cancelled request still releases its locks.
		_ = tx.Rollback(context.WithoutCancel(ctx))
		return err
	}
	return tx.Commit(ctx)
}

func retryableState(err error) (string, bool) {
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) && (pgErr.Code == SQLStateDeadlock || pgErr.Code == SQLStateSerialization) {
		return pgErr.Code, true
	}
	return "", false
}
