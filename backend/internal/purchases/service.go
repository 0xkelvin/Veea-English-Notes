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
	pool         *pgxpool.Pool
	tx           db.Tx
	verifier     Verifier
	environment  string
	allowSandbox bool
}

func New(pool *pgxpool.Pool, verifier Verifier, environment string, retry func(string)) *Service {
	return NewWithSandboxAcknowledgements(pool, verifier, environment, false, retry)
}

// NewWithSandboxAcknowledgements permits verified Sandbox acknowledgements on a
// Production API without inserting test proofs or granting any server Premium.
func NewWithSandboxAcknowledgements(pool *pgxpool.Pool, verifier Verifier, environment string, allowSandbox bool, retry func(string)) *Service {
	return &Service{pool: pool, tx: db.Tx{Pool: pool, OnRetry: retry}, verifier: verifier, environment: environment, allowSandbox: allowSandbox}
}
func (s *Service) Claim(ctx context.Context, p session.Principal, id string) error {
	_, err := s.VerifyAndClaim(ctx, p, id)
	return err
}

// Outcome separates Apple verification from a durable account purchase. Sandbox
// acknowledgements on Production are device-only; Environment is server-verified.
type Outcome struct {
	Revoked     bool
	Environment string
	Recorded    bool
}

func (s *Service) VerifyAndClaim(ctx context.Context, p session.Principal, id string) (bool, error) {
	outcome, err := s.VerifyAndClaimOutcome(ctx, p, id)
	return outcome.Revoked, err
}

func (s *Service) VerifyAndClaimOutcome(ctx context.Context, p session.Principal, id string) (Outcome, error) {
	return s.verifyAndClaimOutcome(ctx, p, id, "")
}

func (s *Service) verifyAndClaimOutcome(ctx context.Context, p session.Principal, id, expectedEnvironment string) (Outcome, error) {
	if s.verifier == nil {
		return Outcome{}, appleiap.ErrUnavailable
	}
	if !ValidTransactionID(id) {
		return Outcome{}, appleiap.ErrInvalid
	}
	// External I/O never runs while database locks are held.
	proof, err := s.verifier.Verify(ctx, id)
	if err != nil {
		return Outcome{}, err
	}
	if proof.AccountToken != p.UserID {
		return Outcome{}, ErrOwnership
	}
	if expectedEnvironment != "" && proof.Environment != expectedEnvironment {
		return Outcome{}, appleiap.ErrInvalid
	}
	sandboxAck := s.allowSandbox && s.environment == appleiap.EnvProduction && proof.Environment == appleiap.EnvSandbox
	if (proof.Environment != s.environment && !sandboxAck) || proof.ID != id || proof.OriginalID == "" || proof.SignedAt.IsZero() {
		return Outcome{}, appleiap.ErrInvalid
	}
	outcome := Outcome{Environment: proof.Environment, Revoked: proof.RevokedAt != nil}
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
		// Revalidate identity even when no purchase row is written. Client flags
		// never choose this path: only a freshly verified Apple Sandbox proof does.
		if sandboxAck {
			return nil
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
		outcome.Revoked = record.RevokedAt != nil
		outcome.Recorded = true
		// A refund is a successful reconciliation: return the updated effective plan,
		// including any independent manual grant, rather than rolling back revocation.
		return q.PruneAccountApplePurchases(ctx, p.UserID)
	})
	return outcome, err
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
		outcome, err := s.verifyAndClaimOutcome(ctx, p, row.TransactionID, row.Environment)
		if err != nil {
			if verificationError == nil {
				verificationError = err
			}
			continue
		}
		// One fresh active proof is sufficient; an obsolete Apple ID cannot block it.
		if !outcome.Revoked {
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
	if s.allowSandbox && s.environment != appleiap.EnvProduction {
		return errors.New("purchases: Sandbox acknowledgements require a Production database")
	}
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
