package learning

import (
	"context"
	"errors"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/db"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/db/sqlc"
)

// PurgeBatch removes one bounded batch of an owner's learning rows inside the TRD 04 purge
// transaction, which already holds the user at L3. Children go before their parents: words,
// then (after retiring every writer) mutation records, then the empty writers, then the head.
// It returns the rows removed; 0 means nothing is left. Every multi-row table is ON DELETE
// RESTRICT from users, so no cascade can bypass this bound: an erase with rows left fails.
func PurgeBatch(ctx context.Context, tx pgx.Tx, user uuid.UUID, batch int32) (int64, error) {
	q := sqlc.New(tx)
	if _, err := q.LockLearningHead(ctx, user); err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return 0, err
	}
	if n, err := q.PurgeVocabularyBatch(ctx, sqlc.PurgeVocabularyBatchParams{UserID: user, BatchSize: batch}); err != nil || n > 0 {
		return n, err
	}
	if err := q.RetireAllLearningWriters(ctx, user); err != nil {
		return 0, err
	}
	if n, err := q.PurgeLearningMutationsBatch(ctx, sqlc.PurgeLearningMutationsBatchParams{UserID: user, BatchSize: batch}); err != nil || n > 0 {
		return n, err
	}
	if n, err := q.PurgeEmptyLearningWritersBatch(ctx, sqlc.PurgeEmptyLearningWritersBatchParams{UserID: user, BatchSize: batch}); err != nil || n > 0 {
		return n, err
	}
	return q.DeleteLearningHead(ctx, user)
}

// HasRows reports whether any multi-row learning data of the owner remains (the purge's final check).
func HasRows(ctx context.Context, tx pgx.Tx, user uuid.UUID) (bool, error) {
	v, err := sqlc.New(tx).HasLearningRows(ctx, user)
	return v.Bool || !v.Valid, err // a NULL answer counts as rows left: fail closed
}

// Cleanup is the runner's learning_sync job: one bounded batch of each step, in order.
//  1. Compact 90-day tombstones of one owner, raising its horizon in the same transaction.
//  2. Delete deduplication records older than 30 days.
//  3. Delete mutation records of retired writers (retirement is logical and immediate).
//  4. Remove retired writers that have no records left.
//
// Every step commits independently, so an interrupted run resumes where it stopped.
func Cleanup(ctx context.Context, conn *pgxpool.Conn, batch int32) (int64, error) {
	q := sqlc.New(conn)
	var total int64
	owner, err := q.NextLearningCompactionOwner(ctx)
	switch {
	case errors.Is(err, pgx.ErrNoRows):
	case err != nil:
		return total, err
	default:
		err := (db.Tx{Pool: conn}).Run(ctx, func(ctx context.Context, tx pgx.Tx) error {
			tq := sqlc.New(tx)
			if _, err := tq.LockLearningHead(ctx, owner); err != nil {
				return err
			}
			revs, err := tq.CompactVocabularyTombstones(ctx, sqlc.CompactVocabularyTombstonesParams{UserID: owner, BatchSize: batch})
			if err != nil || len(revs) == 0 {
				return err
			}
			var h int64
			for _, r := range revs {
				if r != nil && *r > h {
					h = *r
				}
			}
			total += int64(len(revs))
			return tq.RaiseTombstoneHorizon(ctx, sqlc.RaiseTombstoneHorizonParams{UserID: owner, Horizon: h})
		})
		if err != nil {
			return total, err
		}
	}
	for _, step := range []func(context.Context, int32) (int64, error){
		q.DeleteExpiredLearningMutations, q.DeleteRetiredWriterMutations, q.DeleteEmptyRetiredWriters,
	} {
		n, err := step(ctx, batch)
		total += n
		if err != nil {
			return total, err
		}
	}
	return total, nil
}
