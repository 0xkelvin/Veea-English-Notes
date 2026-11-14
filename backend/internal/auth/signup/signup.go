// Package signup implements Flows A and B of TRD 01: signup by email OTP and by email +
// password, both completed by verifying the emailed code (endpoints 1 to 3, sections 4, 5.3
// and 7.2 to 7.3).
//
// It is built on the OTP core (internal/auth/otp), which owns the challenge, cooldown, rate
// limits, outbox email and audit of start and code validation. Signup adds the eligibility rule
// (no account for the email), the password policy and hash for Flow B, and the steps after a
// valid code: create the verified account and its first session in the same transaction.
package signup

import (
	"context"
	"errors"
	"fmt"
	"io"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/audit"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/auth/otp"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/auth/session"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/identity"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/identity/accounts"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/clientip"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/db/sqlc"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/ratelimit"
)

// ErrSignupUnavailable is the 409 of TRD 5.3 endpoint 3: the code was valid but the email
// gained an account after the attempt started. The challenge stays consumed and nothing else
// changes.
var ErrSignupUnavailable = errors.New("signup_unavailable")

// PasswordHasher is the part of identity.Hasher signup needs. Tests wrap the real hasher to
// observe when hashing happens.
type PasswordHasher interface {
	Hash(ctx context.Context, password string) (string, error)
}

// Config wires a Service.
type Config struct {
	Pool   *pgxpool.Pool
	OTP    *otp.Service
	Hasher PasswordHasher
	Policy *identity.Policy
	// Rules supplies PasswordSignupStartIP. Nil means ratelimit.DefaultRules().
	Rules *ratelimit.Rules
	// Random is the source for session tokens. Nil means crypto/rand.
	Random io.Reader
}

// Service runs the signup use cases. It is safe for concurrent use.
type Service struct {
	otp     *otp.Service
	hasher  PasswordHasher
	policy  *identity.Policy
	limiter *ratelimit.Limiter
	rule    ratelimit.Rule
	random  io.Reader
}

// New validates cfg and returns a Service.
func New(cfg Config) (*Service, error) {
	if cfg.Pool == nil || cfg.OTP == nil || cfg.Hasher == nil || cfg.Policy == nil {
		return nil, errors.New("signup: pool, OTP service, hasher and policy are required")
	}
	rules := ratelimit.DefaultRules()
	if cfg.Rules != nil {
		rules = *cfg.Rules
	}
	if err := rules.PasswordSignupStartIP.Validate(); err != nil {
		return nil, err
	}
	return &Service{otp: cfg.OTP, hasher: cfg.Hasher, policy: cfg.Policy,
		limiter: ratelimit.NewLimiter(cfg.Pool), rule: rules.PasswordSignupStartIP, random: cfg.Random}, nil
}

// Client is what the HTTP layer knows about the caller.
type Client struct {
	IP        clientip.Result
	UserAgent string // sanitized
	RequestID string
}

// StartOTP is endpoint 1 (Flow A). The acknowledgement is the same whether or not the email
// already has an account; only an eligible request queues the signup_code email (AC-27).
//
// Errors: identity.ErrInvalidEmail, *otp.RateLimitedError, or an internal error.
func (s *Service) StartOTP(ctx context.Context, rawEmail string, c Client) (otp.Acknowledgement, error) {
	e, err := identity.NormalizeEmail(rawEmail)
	if err != nil {
		return otp.Acknowledgement{}, err
	}
	return s.otp.Start(ctx, otp.StartRequest{
		Purpose: otp.PurposeSignup, SignupMethod: otp.SignupOTP, Email: e, Check: eligibility(e, ""),
		IP: c.IP, UserAgent: c.UserAgent, RequestID: c.RequestID,
	})
}

// StartPassword is endpoint 2 (Flow B), in the order TRD 5.3 sets:
//
//  1. Validate the email and the password policy. A violation is returned before anything else
//     happens, so the response cannot depend on eligibility.
//  2. Count the per-IP password-signup limit, before any Argon2id work (TRD 10).
//  3. Hash the password outside any transaction, eligible or not, for equal timing (TRD 9.2).
//  4. Run the OTP start. An eligible request binds the hash to its new challenge; an ineligible
//     one discards it (TRD 4.4).
//
// Errors: identity.ErrInvalidEmail, *identity.PolicyError, identity.ErrInvalidPasswordEncoding,
// *otp.RateLimitedError, identity.ErrBusy, or an internal error.
func (s *Service) StartPassword(ctx context.Context, rawEmail, password string, c Client) (otp.Acknowledgement, error) {
	e, err := identity.NormalizeEmail(rawEmail)
	if err != nil {
		return otp.Acknowledgement{}, err
	}
	normalized, err := s.policy.Validate(password, e.Normalized)
	if err != nil {
		return otp.Acknowledgement{}, err
	}
	d, err := s.limiter.Allow(ctx, ratelimit.Check{Rule: s.rule, Subject: ratelimit.IPSubject(c.IP)})
	if err != nil {
		return otp.Acknowledgement{}, err
	}
	if !d.Allowed {
		return otp.Acknowledgement{}, &otp.RateLimitedError{Rule: d.Rule.Name, RetryAfter: d.RetryAfterSeconds()}
	}
	hash, err := s.hasher.Hash(ctx, normalized)
	if err != nil {
		return otp.Acknowledgement{}, err
	}
	return s.otp.Start(ctx, otp.StartRequest{
		Purpose: otp.PurposeSignup, SignupMethod: otp.SignupPassword, Email: e, Check: eligibility(e, hash),
		IP: c.IP, UserAgent: c.UserAgent, RequestID: c.RequestID,
	})
}

// eligibility is TRD 3.3 for signup: eligible when no account exists for the email. The pending
// hash is offered either way; the OTP core stores it only on an eligible challenge.
func eligibility(e identity.Email, pendingHash string) otp.Eligibility {
	return func(ctx context.Context, tx pgx.Tx) (otp.Target, error) {
		_, exists, err := accounts.Find(ctx, tx, e)
		if err != nil {
			return otp.Target{}, err
		}
		return otp.Target{Eligible: !exists, PendingPasswordHash: pendingHash}, nil
	}
}

// Result is a completed signup. Its tokens may be sent only because Verify returns it after the
// transaction committed.
type Result struct {
	Session session.Issued
	User    sqlc.User
}

// Verify is endpoint 3 (TRD 7.3). After the OTP core accepts the code, in the same transaction
// and in lock order:
//
//   - L3: insert the account with a verified email and the pending password hash (or none),
//     waiting on the unique index if another attempt for the email is in flight;
//   - L4b and L5: issue the first session and write auth.signup.verify;
//   - L5: the OTP core cancels the challenge's pending email and commits.
//
// If the account already exists, nothing about it is read or changed and no session is
// issued: the consumption commits with an account_exists failure audit event, and Verify
// returns ErrSignupUnavailable. Any other failure rolls everything back, consumption included.
//
// Errors: session.ErrInvalidDevice, otp.ErrInvalidCode, otp.ErrAttemptsExceeded,
// ErrSignupUnavailable, *otp.RateLimitedError, or an internal error.
func (s *Service) Verify(ctx context.Context, token, code string, device session.Device, c Client) (Result, error) {
	if err := device.Validate(); err != nil {
		return Result{}, err
	}
	// Generated before the transaction (TRD 7.1 rule 5).
	pending, err := session.NewPending(s.random)
	if err != nil {
		return Result{}, err
	}
	userID, err := uuid.NewV7()
	if err != nil {
		return Result{}, errors.New("signup: generate user id")
	}

	var res Result
	err = s.otp.Verify(ctx, otp.VerifyRequest{
		Purpose: otp.PurposeSignup, Token: token, Code: code,
		IP: c.IP, UserAgent: c.UserAgent, RequestID: c.RequestID,
	}, func(ctx context.Context, tx pgx.Tx, a otp.Accepted) error {
		res = Result{}
		r, err := s.complete(ctx, tx, a, userID, pending, device, c)
		res = r
		return err
	})
	if err != nil {
		return Result{}, err
	}
	return res, nil
}

// complete runs the signup steps after the code was accepted, inside T-main.
func (s *Service) complete(ctx context.Context, tx pgx.Tx, a otp.Accepted, userID uuid.UUID,
	pending session.Pending, device session.Device, c Client) (Result, error) {
	method := session.MethodSignupOTP
	if a.SignupMethod == otp.SignupPassword {
		if a.PendingPasswordHash == "" {
			return Result{}, errors.New("signup: password signup challenge without a pending hash")
		}
		method = session.MethodSignupPassword
	}
	now, err := sqlc.New(tx).DatabaseNow(ctx)
	if err != nil {
		return Result{}, fmt.Errorf("signup: read database time: %w", err)
	}

	// L3: the new account.
	user, created, err := accounts.CreateVerified(ctx, tx, accounts.NewVerified{
		ID: userID, Email: a.Email, PasswordHash: a.PendingPasswordHash, VerifiedAt: now})
	if err != nil {
		return Result{}, err
	}
	if !created {
		return Result{}, otp.CommitFailure("account_exists", ErrSignupUnavailable)
	}

	// L4b, L5: the first session, then the success audit event.
	issued, err := session.Issue(ctx, tx, pending, session.Request{
		UserID: user.ID, Method: method, Device: device, UserAgent: c.UserAgent, IP: c.IP.Addr, RequestID: c.RequestID})
	if err != nil {
		return Result{}, err
	}
	if err := audit.Record(ctx, tx, audit.Event{
		Action: "auth.signup.verify", Outcome: audit.Success, ActorUserID: &user.ID, TargetUserID: &user.ID,
		SessionID: &issued.SessionID, EmailHMAC: a.EmailHMAC, IP: c.IP.Addr, UserAgent: c.UserAgent,
		RequestID: c.RequestID, Metadata: map[string]string{"method": string(a.SignupMethod)},
	}); err != nil {
		return Result{}, err
	}
	return Result{Session: issued, User: user}, nil
}
