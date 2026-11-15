package otp

import (
	"context"
	"crypto/sha256"
	"encoding/binary"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/identity"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/db/sqlc"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"sort"
)

// LockAddresses is L0, always before cooldowns/challenges/users. Keys are stable across
// HMAC rotation, domain separated, sorted and never logged. Collisions only serialize work.
func LockAddresses(ctx context.Context, tx pgx.Tx, addresses ...string) error {
	keys := make([]int64, 0, len(addresses))
	for _, a := range addresses {
		h := sha256.Sum256([]byte("veea:lifecycle:address:" + a))
		keys = append(keys, int64(binary.BigEndian.Uint64(h[:8])))
	}
	sort.Slice(keys, func(i, j int) bool { return keys[i] < keys[j] })
	for i, k := range keys {
		if i > 0 && k == keys[i-1] {
			continue
		}
		if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock($1)`, k); err != nil {
			return err
		}
	}
	return nil
}

func (s *Service) checkSignupFence(ctx context.Context, tx pgx.Tx, ch sqlc.OtpChallenge) error {
	cutoff, err := sqlc.New(tx).LatestDeletionCutoff(ctx, s.emailHMAC.All(identity.Email{Normalized: ch.EmailNormalized}))
	if err != nil {
		return err
	}
	if !ch.CreatedAt.After(cutoff) {
		return ErrInvalidCode
	}
	return nil
}

func LockOwned(ctx context.Context, tx pgx.Tx, user uuid.UUID, batch int32) ([]uuid.UUID, error) {
	return sqlc.New(tx).LockOwnedOTPBatch(ctx, sqlc.LockOwnedOTPBatchParams{UserID: &user, BatchSize: batch})
}
func DeleteOwnedLocked(ctx context.Context, tx pgx.Tx, user uuid.UUID, ids []uuid.UUID) (int64, error) {
	return sqlc.New(tx).DeleteLockedOwnedOTP(ctx, sqlc.DeleteLockedOwnedOTPParams{UserID: &user, Ids: ids})
}

// LockDeletionProofs also pre-locks any old unbound signup proof for the reserved address.
// Invalidation is deferred until the flow has accepted both proof and current identity.
func LockDeletionProofs(ctx context.Context, tx pgx.Tx, email, token string) ([]uuid.UUID, error) {
	return sqlc.New(tx).LockDeletionProofs(ctx, sqlc.LockDeletionProofsParams{EmailNormalized: email, TokenHash: HashToken(token)})
}
func InvalidateSignup(ctx context.Context, tx pgx.Tx, ids []uuid.UUID) error {
	return sqlc.New(tx).InvalidateLockedSignupProofs(ctx, ids)
}
func CancelLockedSignupMail(ctx context.Context, tx pgx.Tx, ids []uuid.UUID) error {
	for _, id := range ids {
		if _, err := sqlc.New(tx).CancelPendingOutboxForChallenge(ctx, &id); err != nil {
			return err
		}
	}
	return nil
}
