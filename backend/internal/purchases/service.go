// Package purchases records only fresh Apple-verified, account-owned non-consumables.
package purchases

import (
	"context"
	"errors"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/appleiap"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/auth/session"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/identity/accounts"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/db"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/db/sqlc"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"
	"regexp"
	"time"
)

var ErrOwnership = errors.New("purchases: account ownership conflict")
var idPattern = regexp.MustCompile(`^[0-9]{1,64}$`)

func ValidTransactionID(id string) bool { return idPattern.MatchString(id) }

const MaxRetainedPurchases = 5

// Verifier is injected only by app wiring; production uses the authenticated Apple API.
type Verifier interface {
	Verify(context.Context, string) (appleiap.Transaction, error)
}
type Service struct {
	pool        *pgxpool.Pool
	tx          db.Tx
	verifier    Verifier
	environment string
}

func New(pool *pgxpool.Pool, verifier Verifier, environment string, retry func(string)) *Service {
	return &Service{pool: pool, tx: db.Tx{Pool: pool, OnRetry: retry}, verifier: verifier, environment: environment}
}
func (s *Service) Claim(ctx context.Context, p session.Principal, id string) error {
	_, err := s.VerifyAndClaim(ctx, p, id)
	return err
}
func (s *Service) VerifyAndClaim(ctx context.Context, p session.Principal, id string) (bool, error) {
	if s.verifier == nil {
		return false, appleiap.ErrUnavailable
	}
	if !ValidTransactionID(id) {
		return false, appleiap.ErrInvalid
	}
	// External I/O never runs while database locks are held.
	proof, err := s.verifier.Verify(ctx, id)
	if err != nil {
		return false, err
	}
	if proof.AccountToken != p.UserID {
		return false, ErrOwnership
	}
	if proof.Environment != s.environment || proof.ID != id || proof.OriginalID == "" || proof.SignedAt.IsZero() {
		return false, appleiap.ErrInvalid
	}
	revoked := false
	err = s.tx.Run(ctx, func(ctx context.Context, tx pgx.Tx) error {
		user, ok, err := accounts.LockForNoKeyUpdate(ctx, tx, p.UserID) // L3, before acting session L4a
		if err != nil {
			return err
		}
		if !ok || user.Status != accounts.StatusActive {
			return session.ErrUnauthorized
		}
		if _, ok, err := session.LockActing(ctx, tx, p.UserID, p.SessionID); err != nil {
			return err
		} else if !ok {
			return session.ErrUnauthorized
		}
		q := sqlc.New(tx)
		previous, err := q.LockAppleProPurchaseByOriginalID(ctx, sqlc.LockAppleProPurchaseByOriginalIDParams{Environment: proof.Environment, OriginalTransactionID: proof.OriginalID})
		if err != nil && !errors.Is(err, pgx.ErrNoRows) {
			return err
		}
		if err == nil && (previous.UserID != p.UserID || previous.AppAccountToken != p.UserID) {
			return ErrOwnership
		}
		record, err := q.UpsertAppleProPurchase(ctx, sqlc.UpsertAppleProPurchaseParams{
			OriginalTransactionID: proof.OriginalID, TransactionID: proof.ID, UserID: p.UserID, AppAccountToken: proof.AccountToken,
			ProductID: proof.ProductID, Environment: proof.Environment, PurchasedAt: proof.PurchasedAt,
			AppleSignedAt: proof.SignedAt, RevokedAt: proof.RevokedAt, RevocationReason: reasonValue(proof.RevocationReason),
		})
		if err != nil {
			return err
		}
		revoked = record.RevokedAt != nil
		// A refund is a successful reconciliation: return the updated effective plan,
		// including any independent manual grant, rather than rolling back revocation.
		return q.PruneAccountApplePurchases(ctx, p.UserID)
	})
	return revoked, err
}

// Reconcile refreshes old proofs before serving an owner plan. On Apple outages
// the HTTP request is unknown (503), never a fabricated Free downgrade. Other
// server consumers stop accepting unverified proofs after the 24-hour SQL lease.
func (s *Service) Reconcile(ctx context.Context, p session.Principal) error {
	rows, err := sqlc.New(s.pool).ListApplePurchasesForVerification(ctx, p.UserID)
	if err != nil {
		return err
	}
	if len(rows) > 0 && s.verifier == nil {
		return appleiap.ErrUnavailable
	}
	// One recently verified active proof is sufficient for aggregate Premium.
	// An obsolete proof from another Apple account must not block a fresh restore.
	for _, row := range rows {
		if row.Environment == s.environment && row.RevokedAt == nil && time.Since(row.VerifiedAt) < 5*time.Minute {
			return nil
		}
	}
	var verificationError error
	for _, row := range rows {
		if row.Environment != s.environment || (row.RevokedAt != nil && time.Since(row.VerifiedAt) < 5*time.Minute) {
			continue
		}
		revoked, err := s.VerifyAndClaim(ctx, p, row.TransactionID)
		if err != nil {
			if verificationError == nil {
				verificationError = err
			}
			continue
		}
		// One fresh active proof is sufficient; an obsolete Apple ID cannot block it.
		if !revoked {
			return nil
		}
	}
	if verificationError != nil {
		return verificationError
	}

	return nil
}

// CheckEnvironment refuses accidentally sharing sandbox purchase grants with a production API.
func (s *Service) CheckEnvironment(ctx context.Context) error {
	if s.verifier == nil {
		return nil
	}
	env, err := sqlc.New(s.pool).AppleIAPEnvironment(ctx)
	if err != nil {
		return err
	}
	if env != s.environment {
		return errors.New("purchases: database billing environment does not match verifier")
	}
	return nil
}

func reasonValue(reason *int32) pgtype.Int4 {
	if reason == nil {
		return pgtype.Int4{}
	}
	return pgtype.Int4{Int32: *reason, Valid: true}
}

func (s *Service) Available() bool { return s != nil && s.verifier != nil }
