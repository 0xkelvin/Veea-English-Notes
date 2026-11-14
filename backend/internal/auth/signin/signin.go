// Package signin implements Flows C and D of TRD 01: email OTP sign-in and password sign-in
// for existing accounts (endpoints 4 to 6, sections 7.3 and 7.4). It never creates an account.
//
// OTP sign-in is built on the OTP core (internal/auth/otp). Password sign-in runs Argon2id
// outside any transaction, then one short transaction that locks the account, re-checks it and
// issues the session.
package signin

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/audit"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/auth/otp"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/auth/session"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/identity"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/identity/accounts"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/clientip"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/db"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/db/sqlc"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/ratelimit"
)

// Public outcomes of password sign-in (TRD 5.3 endpoint 6).
var (
	// ErrInvalidCredentials is the one answer for an unknown email, a wrong password, a
	// passwordless account and a pending registration (AC-7).
	ErrInvalidCredentials = errors.New("invalid_credentials")
	// ErrAccountUnavailable is returned only after the password verified, for an account that
	// is not active (AC-9).
	ErrAccountUnavailable = errors.New("account_unavailable")
)

// Audit reasons (TRD 11.1).
const (
	reasonInvalidCredentials = "invalid_credentials"
	reasonAccountUnavailable = "account_unavailable"
	reasonPasswordChanged    = "password_changed_concurrently"
)

// Verifier is the part of identity.Hasher password sign-in needs. Tests wrap the real hasher to
// count Argon2id runs.
type Verifier interface {
	Verify(ctx context.Context, encoded, password string) (identity.VerifyResult, error)
	VerifyDummy(ctx context.Context, password string) error
	Hash(ctx context.Context, password string) (string, error)
}

// Config wires a Service.
type Config struct {
	Pool   *pgxpool.Pool
	OTP    *otp.Service
	Hasher Verifier
	// EmailHMAC keys the per-email failure counter and audit events.
	EmailHMAC *identity.EmailHMAC
	// Rules supplies the password-login limits. Nil means ratelimit.DefaultRules().
	Rules *ratelimit.Rules
	// Random is the source for session tokens. Nil means crypto/rand.
	Random    io.Reader
	Logger    *slog.Logger
	OnTxRetry func(sqlstate string)
}

// Service runs the sign-in use cases. It is safe for concurrent use.
type Service struct {
	pool      *pgxpool.Pool
	tx        db.Tx
	otp       *otp.Service
	hasher    Verifier
	emailHMAC *identity.EmailHMAC
	limiter   *ratelimit.Limiter
	rules     ratelimit.Rules
	random    io.Reader
	log       *slog.Logger
}

// New validates cfg and returns a Service.
func New(cfg Config) (*Service, error) {
	if cfg.Pool == nil || cfg.OTP == nil || cfg.Hasher == nil || cfg.EmailHMAC == nil {
		return nil, errors.New("signin: pool, OTP service, hasher and email HMAC are required")
	}
	rules := ratelimit.DefaultRules()
	if cfg.Rules != nil {
		rules = *cfg.Rules
	}
	if err := errors.Join(rules.PasswordLoginIP.Validate(), rules.PasswordLoginFailEmail.Validate()); err != nil {
		return nil, err
	}
	s := &Service{pool: cfg.Pool, otp: cfg.OTP, hasher: cfg.Hasher, emailHMAC: cfg.EmailHMAC,
		limiter: ratelimit.NewLimiter(cfg.Pool), rules: rules, random: cfg.Random, log: cfg.Logger}
	if s.log == nil {
		s.log = slog.New(slog.DiscardHandler)
	}
	s.tx = db.Tx{Pool: cfg.Pool, OnRetry: func(code string) {
		s.log.Warn("signin: transaction retried", "sqlstate", code)
		if cfg.OnTxRetry != nil {
			cfg.OnTxRetry(code)
		}
	}}
	return s, nil
}

// Client is what the HTTP layer knows about the caller.
type Client struct {
	IP        clientip.Result
	UserAgent string // sanitized
	RequestID string
}

// Result is a committed sign-in. Its tokens may be sent only because it is returned after the
// transaction committed.
type Result struct {
	Session session.Issued
	User    sqlc.User
}

// --- Flow C: email OTP sign-in ---------------------------------------------------------------

// StartOTP is endpoint 4. The acknowledgement is the same whether or not the email belongs to
// an account in good standing; only such an account gets the login_code email, sent to its
// stored address (AC-6, AC-27). Nothing is ever created for an unknown email.
//
// Errors: identity.ErrInvalidEmail, *ratelimit.Error, or an internal error.
func (s *Service) StartOTP(ctx context.Context, rawEmail string, c Client) (otp.Acknowledgement, error) {
	e, err := identity.NormalizeEmail(rawEmail)
	if err != nil {
		return otp.Acknowledgement{}, err
	}
	return s.otp.Start(ctx, otp.StartRequest{
		Purpose: otp.PurposeLogin, Email: e, IP: c.IP, UserAgent: c.UserAgent, RequestID: c.RequestID,
		Check: func(ctx context.Context, tx pgx.Tx) (otp.Target, error) {
			u, exists, err := accounts.Find(ctx, tx, e)
			if err != nil || !exists || !accounts.InGoodStanding(u) {
				return otp.Target{}, err // ineligible: delivery = 'none' (TRD 3.3, 4.4)
			}
			return otp.Target{Eligible: true, UserID: &u.ID, To: u.Email}, nil
		},
	})
}

// VerifyOTP is endpoint 5 (TRD 7.3). After the OTP core accepts the code, in the same
// transaction: L3 lock and re-check of the account, then the session (L4b cap, L5 insert) and
// the success audit event; the core cancels the pending email and commits. If the account left
// good standing meanwhile, everything rolls back (the code stays usable), a T-fail audit event
// records account_unavailable, and the caller gets invalid_code.
//
// Errors: session.ErrInvalidDevice, otp.ErrInvalidCode, otp.ErrAttemptsExceeded,
// *ratelimit.Error, or an internal error.
func (s *Service) VerifyOTP(ctx context.Context, token, code string, device session.Device, c Client) (Result, error) {
	if err := device.Validate(); err != nil {
		return Result{}, err
	}
	pending, err := session.NewPending(s.random) // before the transaction (TRD 7.1 rule 5)
	if err != nil {
		return Result{}, err
	}
	var res Result
	err = s.otp.Verify(ctx, otp.VerifyRequest{Purpose: otp.PurposeLogin, Token: token, Code: code,
		IP: c.IP, UserAgent: c.UserAgent, RequestID: c.RequestID},
		func(ctx context.Context, tx pgx.Tx, a otp.Accepted) error {
			res = Result{}
			if a.UserID == nil {
				return errors.New("signin: login challenge without an account")
			}
			// L3: lock and re-check the account the challenge was bound to.
			u, ok, err := accounts.LockForNoKeyUpdate(ctx, tx, *a.UserID)
			if err != nil {
				return err
			}
			if !ok || !accounts.InGoodStanding(u) {
				return otp.Rollback(reasonAccountUnavailable, otp.ErrInvalidCode)
			}
			issued, err := s.issue(ctx, tx, u, session.MethodOTP, device, "auth.otp.verify", a.EmailHMAC, pending, c)
			if err != nil {
				return err
			}
			res = Result{Session: issued, User: u}
			return nil
		})
	if err != nil {
		return Result{}, err
	}
	return res, nil
}

// --- Flow D: password sign-in ----------------------------------------------------------------

// PasswordLogin is endpoint 6 (TRD 7.4), in this order:
//
//  1. Limits, before any Argon2id work: the per-IP login limit is counted, and the per-email
//     failure limit is checked without counting. A lockout here applies to password sign-in
//     only; OTP sign-in and reset have their own limits.
//  2. Outside any transaction: read the account and run Argon2id against its hash, or against
//     the dummy hash when there is no account or no password, so every case costs the same.
//     A rehash, if the stored parameters are outdated, is also computed here.
//  3. Failure: count it against the email (autocommit) and write the failure audit event, then
//     ErrInvalidCredentials. These are never rolled back.
//  4. Success: one transaction. L3 lock; the stored hash must still be byte-equal to the one
//     that verified, else ErrInvalidCredentials and no session; the account must be active and
//     verified, else ErrAccountUnavailable; store the rehash (compare-and-set on the old hash);
//     issue the session (L4b, L5) and the success audit event; commit.
//
// Errors: identity.ErrInvalidEmail, session.ErrInvalidDevice, ErrInvalidCredentials,
// ErrAccountUnavailable, *ratelimit.Error, identity.ErrBusy, or an internal error.
func (s *Service) PasswordLogin(ctx context.Context, rawEmail, password string, device session.Device, c Client) (Result, error) {
	e, err := identity.NormalizeEmail(rawEmail)
	if err != nil {
		return Result{}, err
	}
	if err := device.Validate(); err != nil {
		return Result{}, err
	}
	if err := s.checkLoginLimits(ctx, e, c); err != nil {
		return Result{}, err
	}

	// Step 2, no transaction and no connection held during Argon2id (TRD 7.1 rule 4).
	u, exists, err := accounts.Find(ctx, s.pool, e)
	if err != nil {
		return Result{}, err
	}
	verified, rehash, err := s.verifyPassword(ctx, u, exists, password)
	if err != nil {
		return Result{}, err
	}
	if !verified {
		return Result{}, s.recordFailure(ctx, e, u, exists, c)
	}
	pending, err := session.NewPending(s.random)
	if err != nil {
		return Result{}, err
	}

	var res Result
	var refused error
	err = s.tx.Run(ctx, func(ctx context.Context, tx pgx.Tx) error {
		res, refused = Result{}, nil
		var err error
		res, refused, err = s.completeLogin(ctx, tx, e, u.ID, *u.PasswordHash, rehash, device, pending, c)
		return err
	})
	if err != nil {
		return Result{}, err
	}
	if refused != nil {
		return Result{}, refused
	}
	return res, nil
}

func (s *Service) checkLoginLimits(ctx context.Context, e identity.Email, c Client) error {
	d, err := s.limiter.Allow(ctx, ratelimit.Check{Rule: s.rules.PasswordLoginIP, Subject: ratelimit.IPSubject(c.IP)})
	if err != nil {
		return err
	}
	if err := d.Err(); err != nil {
		return err
	}
	p, err := s.limiter.Peek(ctx, ratelimit.Check{Rule: s.rules.PasswordLoginFailEmail, Subject: ratelimit.EmailSubject(s.emailHMAC, e)})
	if err != nil {
		return err
	}
	return p.Err()
}

// verifyPassword runs exactly one Argon2id: against the stored hash, or against the dummy hash
// when there is nothing to verify (AC-7). On a match with outdated parameters it also computes
// the replacement hash, still outside the transaction.
func (s *Service) verifyPassword(ctx context.Context, u sqlc.User, exists bool, password string) (bool, string, error) {
	if !exists || u.PasswordHash == nil {
		return false, "", s.hasher.VerifyDummy(ctx, password)
	}
	v, err := s.hasher.Verify(ctx, *u.PasswordHash, password)
	if err != nil {
		return false, "", fmt.Errorf("signin: verify: %w", err)
	}
	if !v.Match {
		return false, "", nil
	}
	if !v.NeedsRehash {
		return true, "", nil
	}
	rehash, err := s.hasher.Hash(ctx, password)
	if err != nil {
		return false, "", err
	}
	return true, rehash, nil
}

// recordFailure is the committed failure path (TRD 7.1 rule 3, 7.4 step 2): the per-email
// failure counter and the audit event are written in autocommit statements, so nothing can
// roll them back. It returns ErrInvalidCredentials, or an internal error if recording failed.
func (s *Service) recordFailure(ctx context.Context, e identity.Email, u sqlc.User, exists bool, c Client) error {
	if _, err := s.limiter.Allow(ctx, ratelimit.Check{Rule: s.rules.PasswordLoginFailEmail, Subject: ratelimit.EmailSubject(s.emailHMAC, e)}); err != nil {
		return err
	}
	ev := audit.Event{Action: "auth.password.login", Outcome: audit.Failure, Reason: reasonInvalidCredentials,
		EmailHMAC: s.emailHMAC.Current(e), IP: c.IP.Addr, UserAgent: c.UserAgent, RequestID: c.RequestID}
	if exists {
		ev.TargetUserID = &u.ID // an unknown email is recorded by its HMAC only (TRD 11.1)
	}
	if err := audit.Record(ctx, s.pool, ev); err != nil {
		return err
	}
	return ErrInvalidCredentials
}

// completeLogin is the success transaction. A refusal (second result) commits whatever audit
// event it wrote and is returned after the commit.
func (s *Service) completeLogin(ctx context.Context, tx pgx.Tx, e identity.Email, id uuid.UUID, verifiedHash, rehash string,
	device session.Device, pending session.Pending, c Client) (Result, error, error) {
	// L3, on the account whose hash verified.
	u, ok, err := accounts.LockForNoKeyUpdate(ctx, tx, id)
	if err != nil {
		return Result{}, nil, err
	}
	if !ok || u.PasswordHash == nil || *u.PasswordHash != verifiedHash {
		// A concurrent change or reset replaced the hash after it verified (TRD 7.4 step 3).
		return Result{}, ErrInvalidCredentials, s.recordInTx(ctx, tx, e, u, reasonPasswordChanged, c)
	}
	if !accounts.InGoodStanding(u) {
		return Result{}, ErrAccountUnavailable, s.recordInTx(ctx, tx, e, u, reasonAccountUnavailable, c)
	}
	if rehash != "" {
		// Same lock, no upgrade: the row is already held FOR NO KEY UPDATE.
		if _, err := accounts.ReplacePasswordHash(ctx, tx, u.ID, verifiedHash, rehash); err != nil {
			return Result{}, nil, err
		}
	}
	issued, err := s.issue(ctx, tx, u, session.MethodPassword, device, "auth.password.login", s.emailHMAC.Current(e), pending, c)
	if err != nil {
		return Result{}, nil, err
	}
	if rehash != "" {
		if u, _, err = accounts.Get(ctx, tx, u.ID); err != nil {
			return Result{}, nil, err
		}
	}
	return Result{Session: issued, User: u}, nil, nil
}

func (s *Service) recordInTx(ctx context.Context, tx pgx.Tx, e identity.Email, u sqlc.User, reason string, c Client) error {
	ev := audit.Event{Action: "auth.password.login", Outcome: audit.Failure, Reason: reason,
		EmailHMAC: s.emailHMAC.Current(e), IP: c.IP.Addr, UserAgent: c.UserAgent, RequestID: c.RequestID}
	if u.ID != uuid.Nil {
		ev.TargetUserID = &u.ID
	}
	return audit.Record(ctx, tx, ev)
}

// issue creates the session on an account the transaction holds at L3 and writes the success
// audit event.
func (s *Service) issue(ctx context.Context, tx pgx.Tx, u sqlc.User, method session.Method, device session.Device,
	action string, emailHMAC []byte, pending session.Pending, c Client) (session.Issued, error) {
	issued, err := session.Issue(ctx, tx, pending, session.Request{UserID: u.ID, Method: method, Device: device,
		UserAgent: c.UserAgent, IP: c.IP.Addr, RequestID: c.RequestID})
	if err != nil {
		return session.Issued{}, err
	}
	if err := audit.Record(ctx, tx, audit.Event{Action: action, Outcome: audit.Success,
		ActorUserID: &u.ID, TargetUserID: &u.ID, SessionID: &issued.SessionID, EmailHMAC: emailHMAC,
		IP: c.IP.Addr, UserAgent: c.UserAgent, RequestID: c.RequestID}); err != nil {
		return session.Issued{}, err
	}
	return issued, nil
}
