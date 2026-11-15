package ratelimit

import (
	"context"
	"errors"
	"fmt"
	"math"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/identity"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/db/sqlc"
)

// CooldownResult is the outcome of a claim.
type CooldownResult struct {
	// Granted is true when the caller may issue a challenge now.
	Granted bool
	// RetryAfter is the time left on the cooldown when it was not granted, for Retry-After.
	RetryAfter time.Duration
}

// RetryAfterSeconds is the Retry-After header value: whole seconds, rounded up, at least 1 for
// a denial, 0 when granted.
func (r CooldownResult) RetryAfterSeconds() int {
	if r.Granted {
		return 0
	}
	return max(1, int(math.Ceil(r.RetryAfter.Seconds())))
}

// Cooldown is the per (purpose, email) resend cooldown of TRD 7.2 step 1: at most one challenge
// per Seconds for one purpose and email, across all instances.
type Cooldown struct {
	// Seconds is the cooldown length. Zero means CooldownSeconds (60).
	Seconds int
	// Email derives the stored email digest.
	Email *identity.EmailHMAC
}

func (c Cooldown) seconds() int {
	if c.Seconds > 0 {
		return c.Seconds
	}
	return CooldownSeconds
}

// Claim tries to take the cooldown for purpose and email. It runs on tx, which must be the
// transaction that goes on to issue the challenge:
//
//   - Granted: the cooldown row is written inside tx. If tx commits, the claim stands. If tx
//     rolls back, the claim vanishes with it and the next request can claim at once, so a failed
//     issuance never burns the user's cooldown.
//   - Not granted: tx is left untouched and usable. The caller rolls back and answers 429 with
//     RetryAfter.
//
// Two transactions claiming the same new (purpose, email) at once: the second blocks on the row
// until the first ends. If the first commits, the second finds an active cooldown and is denied.
// If the first rolls back, the second inserts and is granted. Exactly one challenge is issued
// per cooldown period (TRD 7.2).
//
// The claim is made on every start request, whether or not the email has an account, so a 429
// reveals nothing about eligibility (AC-27).
//
// Timing uses the database now(), which inside a transaction is the transaction's start. The
// boundary is inclusive: a claim exactly Seconds after the last one is granted.
func (c Cooldown) Claim(ctx context.Context, tx pgx.Tx, purpose string, e identity.Email) (CooldownResult, error) {
	if purpose == "" {
		return CooldownResult{}, errors.New("ratelimit: cooldown purpose is required")
	}
	if c.Email == nil {
		return CooldownResult{}, errors.New("ratelimit: cooldown needs an email HMAC")
	}
	q := sqlc.New(tx)
	hmac := c.Email.Current(e)
	secs := float64(c.seconds())

	_, err := q.ClaimOTPCooldown(ctx, sqlc.ClaimOTPCooldownParams{Purpose: purpose, EmailHmac: hmac, CooldownSeconds: secs})
	if err == nil {
		return CooldownResult{Granted: true}, nil
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return CooldownResult{}, fmt.Errorf("ratelimit: claim cooldown: %w", err)
	}

	remaining, err := q.GetOTPCooldownRemaining(ctx, sqlc.GetOTPCooldownRemainingParams{
		Purpose: purpose, EmailHmac: hmac, CooldownSeconds: secs})
	switch {
	case errors.Is(err, pgx.ErrNoRows):
		// The row was cleaned up between the two statements. Ask for a short retry.
		return CooldownResult{RetryAfter: time.Second}, nil
	case err != nil:
		return CooldownResult{}, fmt.Errorf("ratelimit: read cooldown: %w", err)
	}
	// remaining is measured against this transaction's now(), its start time. A transaction that
	// started just before a concurrent winner, then waited for it on the row lock, sees the
	// winner's later last_issued_at and would compute slightly more than the cooldown. The real
	// time is already past the winner's claim (it committed before this read), so the cooldown
	// length is a correct upper bound.
	return CooldownResult{RetryAfter: time.Duration(min(remaining, secs) * float64(time.Second))}, nil
}
