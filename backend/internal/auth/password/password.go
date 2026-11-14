// Package password implements Flows E, F and G of TRD 01: setting a first password while signed
// in, changing it, and resetting it by email (endpoints 7, 8 and 12 to 14; sections 5.3, 5.4 and
// 7.5).
//
// Every flow checks the new password's policy and runs Argon2id before any transaction. The
// mutation itself is one transaction in lock order: the challenge (L2, set and reset only), the
// account (L3), the acting session (L4a, set and change), the other sessions (L4b), then the
// outbox and audit rows (L5). Everything a flow changes commits together or not at all.
package password

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"unicode/utf8"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/audit"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/auth/otp"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/auth/session"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/identity"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/identity/accounts"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/notify"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/clientip"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/db"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/db/sqlc"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/ratelimit"
)

// Public outcomes (TRD 5.3). session.ErrUnauthorized is the 401 of set and change.
var (
	ErrPasswordAlreadySet     = errors.New("password_already_set")
	ErrPasswordNotSet         = errors.New("password_not_set")
	ErrInvalidCurrentPassword = errors.New("invalid_current_password")
)

// Session revocation reasons (TRD 6.5).
const (
	reasonSet    = "password_set"
	reasonChange = "password_change"
	reasonReset  = "password_reset"
)

// Audit failure reasons (TRD 11.1).
const (
	reasonAccountUnavailable = "account_unavailable"
	reasonSessionInvalid     = "session_invalid"
	reasonAlreadySet         = "password_already_set"
	reasonNotSet             = "password_not_set"
	reasonWrongCurrent       = "invalid_current_password"
	reasonStaleCurrent       = "stale_current_password"
)

// resetDevice names the "device" in the password_reset_done email: a reset is not tied to any
// session, so there is no device name to show.
const resetDevice = "Reset with an emailed code"

// Hasher is the part of identity.Hasher these flows need.
type Hasher interface {
	Hash(ctx context.Context, password string) (string, error)
	Verify(ctx context.Context, encoded, password string) (identity.VerifyResult, error)
}

// Config wires a Service.
type Config struct {
	Pool   *pgxpool.Pool
	OTP    *otp.Service
	Outbox *notify.Outbox
	Hasher Hasher
	Policy *identity.Policy
	// Rules supplies WrongCurrentPasswordUser. Nil means ratelimit.DefaultRules().
	Rules     *ratelimit.Rules
	Logger    *slog.Logger
	OnTxRetry func(sqlstate string)
}

// Service runs the password flows. It is safe for concurrent use.
type Service struct {
	pool    *pgxpool.Pool
	tx      db.Tx
	otp     *otp.Service
	outbox  *notify.Outbox
	hasher  Hasher
	policy  *identity.Policy
	limiter *ratelimit.Limiter
	rule    ratelimit.Rule
	log     *slog.Logger
}

// New validates cfg and returns a Service.
func New(cfg Config) (*Service, error) {
	if cfg.Pool == nil || cfg.OTP == nil || cfg.Outbox == nil || cfg.Hasher == nil || cfg.Policy == nil {
		return nil, errors.New("password: pool, OTP service, outbox, hasher and policy are required")
	}
	rules := ratelimit.DefaultRules()
	if cfg.Rules != nil {
		rules = *cfg.Rules
	}
	if err := rules.WrongCurrentPasswordUser.Validate(); err != nil {
		return nil, err
	}
	s := &Service{pool: cfg.Pool, otp: cfg.OTP, outbox: cfg.Outbox, hasher: cfg.Hasher, policy: cfg.Policy,
		limiter: ratelimit.NewLimiter(cfg.Pool), rule: rules.WrongCurrentPasswordUser, log: cfg.Logger}
	if s.log == nil {
		s.log = slog.New(slog.DiscardHandler)
	}
	s.tx = db.Tx{Pool: cfg.Pool, OnRetry: func(code string) {
		s.log.Warn("password: transaction retried", "sqlstate", code)
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

func (c Client) session() session.Client {
	return session.Client{IP: c.IP.Addr, UserAgent: c.UserAgent, RequestID: c.RequestID}
}

func (c Client) otp(purpose otp.Purpose, token, code string, p *session.Principal) otp.VerifyRequest {
	r := otp.VerifyRequest{Purpose: purpose, Token: token, Code: code, IP: c.IP, UserAgent: c.UserAgent, RequestID: c.RequestID}
	if p != nil {
		r.UserID, r.SessionID = &p.UserID, &p.SessionID
	}
	return r
}

// --- Flow E: first-password set --------------------------------------------------------------

// StartSet is endpoint 12: a set_password challenge bound to the caller's user and session, and
// the set_password_code email (R6). An account that already has a password gets
// ErrPasswordAlreadySet and nothing is issued.
//
// Errors: ErrPasswordAlreadySet, session.ErrUnauthorized, *ratelimit.Error, or an internal error.
func (s *Service) StartSet(ctx context.Context, p session.Principal, c Client) (otp.Acknowledgement, error) {
	u, ok, err := accounts.Get(ctx, s.pool, p.UserID)
	if err != nil {
		return otp.Acknowledgement{}, err
	}
	if !ok || !accounts.InGoodStanding(u) {
		return otp.Acknowledgement{}, session.ErrUnauthorized
	}
	if u.PasswordHash != nil {
		s.recordFailure(ctx, "auth.password.set.start", p, reasonAlreadySet, c)
		return otp.Acknowledgement{}, ErrPasswordAlreadySet
	}
	e := identity.Email{Display: u.Email, Normalized: u.EmailNormalized}
	ack, err := s.otp.Start(ctx, otp.StartRequest{
		Purpose: otp.PurposeSetPassword, Email: e, IP: c.IP, UserAgent: c.UserAgent, RequestID: c.RequestID,
		Check: func(ctx context.Context, tx pgx.Tx) (otp.Target, error) {
			// Re-read inside the start transaction: a password set meanwhile ends the start, and
			// the rollback releases the cooldown claim.
			cur, ok, err := accounts.Get(ctx, tx, p.UserID)
			switch {
			case err != nil:
				return otp.Target{}, err
			case !ok || !accounts.InGoodStanding(cur):
				return otp.Target{}, session.ErrUnauthorized
			case cur.PasswordHash != nil:
				return otp.Target{}, ErrPasswordAlreadySet
			}
			return otp.Target{Eligible: true, UserID: &cur.ID, SessionID: &p.SessionID, To: cur.Email}, nil
		},
	})
	if errors.Is(err, ErrPasswordAlreadySet) {
		// Set between the read above and the start transaction, which rolled back.
		s.recordFailure(ctx, "auth.password.set.start", p, reasonAlreadySet, c)
	}
	return ack, err
}

// Set is endpoint 13 (TRD 7.5 "Set (E)"). The policy is checked and the hash computed before
// the code is looked at, so a policy failure costs no attempt (AC-15). Then T-main: V bound to
// the caller's user and session (L2); the account locked and re-checked, password still unset
// (L3); the acting session locked and re-checked (L4a); the hash written; every other session
// revoked (L4b); password_added queued and the success event written (L5); the OTP core cancels
// the challenge's pending email; commit. A post-accept failure rolls everything back, the
// consumption included, and is recorded in T-fail.
//
// Errors: *identity.PolicyError, otp.ErrInvalidCode, otp.ErrAttemptsExceeded,
// session.ErrUnauthorized, ErrPasswordAlreadySet, *ratelimit.Error, identity.ErrBusy, or an
// internal error.
func (s *Service) Set(ctx context.Context, p session.Principal, token, code, newPassword string, c Client) error {
	u, ok, err := accounts.Get(ctx, s.pool, p.UserID)
	if err != nil {
		return err
	}
	if !ok {
		return session.ErrUnauthorized
	}
	req := c.otp(otp.PurposeSetPassword, token, code, &p)
	hash, err := s.prepare(ctx, newPassword, u.EmailNormalized, req)
	if err != nil {
		return err
	}
	req.Prechecked = true
	return s.otp.Verify(ctx, req, func(ctx context.Context, tx pgx.Tx, a otp.Accepted) error {
		// L3.
		locked, ok, err := accounts.LockForNoKeyUpdate(ctx, tx, p.UserID)
		if err != nil {
			return err
		}
		if !ok || !accounts.InGoodStanding(locked) {
			return otp.Rollback(reasonAccountUnavailable, session.ErrUnauthorized)
		}
		if locked.PasswordHash != nil {
			return otp.Rollback(reasonAlreadySet, ErrPasswordAlreadySet)
		}
		// L4a.
		acting, ok, err := session.LockActing(ctx, tx, p.UserID, p.SessionID)
		if err != nil {
			return err
		}
		if !ok {
			return otp.Rollback(reasonSessionInvalid, session.ErrUnauthorized)
		}
		return s.commitMutation(ctx, tx, mutation{
			user: locked, hash: hash, keep: &acting, revokeReason: reasonSet,
			template: notify.TemplatePasswordAdded, action: "auth.password.set", emailHMAC: a.EmailHMAC,
		}, c)
	})
}

// --- Flow F: change --------------------------------------------------------------------------

// Change is endpoint 14 (TRD 7.5 "Change (F)"). Outside any transaction: the new password's
// policy, the account must have a password (else ErrPasswordNotSet), the wrong-current-password
// limit (peek), then current_password is verified against the hash read now (H0) and the new
// one hashed. A wrong current password is audited and counted, never rolled back.
//
// Then one transaction: the account locked (L3), still active, with a password that is still H0
// (else ErrInvalidCurrentPassword, not counted: it changed concurrently); the acting session
// locked and re-checked (L4a); the new hash written; every other session revoked (L4b);
// password_changed queued and the success event written (L5); commit.
//
// There is no retry exception: a resend after a lost response is evaluated like any other
// request and normally gets ErrInvalidCurrentPassword, because the old password no longer
// matches (TRD 5.4). The acting session stays signed in either way.
//
// Errors: *identity.PolicyError, ErrPasswordNotSet, ErrInvalidCurrentPassword,
// session.ErrUnauthorized, *ratelimit.Error, identity.ErrBusy, or an internal error.
func (s *Service) Change(ctx context.Context, p session.Principal, current, newPassword string, c Client) error {
	u, ok, err := accounts.Get(ctx, s.pool, p.UserID)
	if err != nil {
		return err
	}
	if !ok {
		return session.ErrUnauthorized
	}
	normalized, err := s.policy.Validate(newPassword, u.EmailNormalized)
	if err != nil {
		return err
	}
	if u.PasswordHash == nil {
		s.recordFailure(ctx, "auth.password.change", p, reasonNotSet, c)
		return ErrPasswordNotSet
	}
	h0 := *u.PasswordHash
	limit := ratelimit.Check{Rule: s.rule, Subject: ratelimit.UserSubject(p.UserID)}
	d, err := s.limiter.Peek(ctx, limit)
	if err != nil {
		return err
	}
	if err := d.Err(); err != nil {
		return err
	}
	v, err := s.hasher.Verify(ctx, h0, current)
	if err != nil {
		return fmt.Errorf("password: verify current: %w", err)
	}
	if !v.Match {
		// Committed failure accounting (TRD 7.1 rules 3 and 6): the counter and the event are
		// autocommit statements.
		if _, err := s.limiter.Allow(ctx, limit); err != nil {
			return err
		}
		s.recordFailure(ctx, "auth.password.change", p, reasonWrongCurrent, c)
		return ErrInvalidCurrentPassword
	}
	hash, err := s.hasher.Hash(ctx, normalized)
	if err != nil {
		return err
	}

	var refusal error
	var reason string
	err = s.tx.Run(ctx, func(ctx context.Context, tx pgx.Tx) error {
		refusal, reason = nil, ""
		locked, ok, err := accounts.LockForNoKeyUpdate(ctx, tx, p.UserID) // L3
		if err != nil {
			return err
		}
		switch {
		case !ok || !accounts.InGoodStanding(locked):
			refusal, reason = session.ErrUnauthorized, reasonAccountUnavailable
		case locked.PasswordHash == nil:
			refusal, reason = ErrPasswordNotSet, reasonNotSet
		case *locked.PasswordHash != h0:
			refusal, reason = ErrInvalidCurrentPassword, reasonStaleCurrent
		}
		if refusal != nil {
			return refusal
		}
		acting, ok, err := session.LockActing(ctx, tx, p.UserID, p.SessionID) // L4a
		if err != nil {
			return err
		}
		if !ok {
			refusal, reason = session.ErrUnauthorized, reasonSessionInvalid
			return refusal
		}
		return s.commitMutation(ctx, tx, mutation{
			user: locked, hash: hash, keep: &acting, revokeReason: reasonChange,
			template: notify.TemplatePasswordChanged, action: "auth.password.change",
			emailHMAC: nil,
		}, c)
	})
	if refusal != nil && errors.Is(err, refusal) {
		// T-fail: the transaction rolled back; record why on its own (TRD 7.5).
		s.recordFailure(ctx, "auth.password.change", p, reason, c)
		return refusal
	}
	return err
}

// --- Flow G: reset ---------------------------------------------------------------------------

// StartReset is endpoint 7. The acknowledgement is the same for every email; only an account in
// good standing gets the reset_code email (AC-27).
func (s *Service) StartReset(ctx context.Context, rawEmail string, c Client) (otp.Acknowledgement, error) {
	e, err := identity.NormalizeEmail(rawEmail)
	if err != nil {
		return otp.Acknowledgement{}, err
	}
	return s.otp.Start(ctx, otp.StartRequest{
		Purpose: otp.PurposePasswordReset, Email: e, IP: c.IP, UserAgent: c.UserAgent, RequestID: c.RequestID,
		Check: func(ctx context.Context, tx pgx.Tx) (otp.Target, error) {
			u, exists, err := accounts.Find(ctx, tx, e)
			if err != nil || !exists || !accounts.InGoodStanding(u) {
				return otp.Target{}, err
			}
			return otp.Target{Eligible: true, UserID: &u.ID, To: u.Email}, nil
		},
	})
}

// CompleteReset is endpoint 8 (TRD 7.5 "Reset (G)"). The policy is checked and the hash
// computed before the code is looked at. Then T-main: V (L2); the challenge's account locked
// and re-checked (L3); the hash written, which also sets a first password on a passwordless
// account (R7); every session revoked (L4b); password_reset_done queued and the success event
// written (L5); commit. No session is issued. An account no longer in good standing rolls
// everything back and gets invalid_code.
//
// Errors: *identity.PolicyError, otp.ErrInvalidCode, otp.ErrAttemptsExceeded, *ratelimit.Error,
// identity.ErrBusy, or an internal error.
func (s *Service) CompleteReset(ctx context.Context, token, code, newPassword string, c Client) error {
	req := c.otp(otp.PurposePasswordReset, token, code, nil)
	// The contains_email rule needs the account's email, which only the challenge knows. An
	// unknown token is checked without it; V then rejects it.
	email, err := sqlc.New(s.pool).GetOTPChallengeEmailByTokenHash(ctx, otp.HashToken(token))
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return fmt.Errorf("password: read challenge email: %w", err)
	}
	hash, err := s.prepare(ctx, newPassword, email, req)
	if err != nil {
		return err
	}
	req.Prechecked = true
	return s.otp.Verify(ctx, req, func(ctx context.Context, tx pgx.Tx, a otp.Accepted) error {
		if a.UserID == nil {
			return errors.New("password: reset challenge without an account")
		}
		locked, ok, err := accounts.LockForNoKeyUpdate(ctx, tx, *a.UserID) // L3
		if err != nil {
			return err
		}
		if !ok || !accounts.InGoodStanding(locked) {
			return otp.Rollback(reasonAccountUnavailable, otp.ErrInvalidCode)
		}
		return s.commitMutation(ctx, tx, mutation{
			user: locked, hash: hash, revokeReason: reasonReset,
			template: notify.TemplatePasswordReset, action: "auth.password.reset.complete", emailHMAC: a.EmailHMAC,
		}, c)
	})
}

// --- shared steps ----------------------------------------------------------------------------

// prepare checks the policy, then the verify limits (so a limited request costs no Argon2id),
// then hashes the new password. All of it runs before any transaction (TRD 7.1 rule 4, 7.5).
func (s *Service) prepare(ctx context.Context, newPassword, normalizedEmail string, req otp.VerifyRequest) (string, error) {
	normalized, err := s.policy.Validate(newPassword, normalizedEmail)
	if err != nil {
		return "", err
	}
	if err := s.otp.CheckVerifyLimits(ctx, req); err != nil {
		return "", err
	}
	return s.hasher.Hash(ctx, normalized)
}

type mutation struct {
	user         sqlc.User
	hash         string
	keep         *sqlc.Session // the acting session (set, change); nil revokes all (reset)
	revokeReason string
	template     notify.Template
	action       string
	emailHMAC    []byte
}

// commitMutation writes the new hash on the locked account (L3 row already held), revokes
// sessions (L4b), then queues the notification and writes the success event (L5).
func (s *Service) commitMutation(ctx context.Context, tx pgx.Tx, m mutation, c Client) error {
	if err := accounts.SetPassword(ctx, tx, m.user.ID, m.hash); err != nil {
		return err
	}
	var revoked int64
	var err error
	device := resetDevice
	var sessionID *uuid.UUID
	if m.keep != nil {
		revoked, err = session.RevokeOthers(ctx, tx, m.user.ID, m.keep.ID, m.revokeReason, c.session())
		device, sessionID = m.keep.DeviceName, &m.keep.ID
	} else {
		revoked, err = session.RevokeAll(ctx, tx, m.user.ID, m.revokeReason, c.session())
	}
	if err != nil {
		return err
	}
	now, err := sqlc.New(tx).DatabaseNow(ctx)
	if err != nil {
		return fmt.Errorf("password: read database time: %w", err)
	}
	if _, err := s.outbox.Enqueue(ctx, tx, notify.Message{
		Template: m.template, To: m.user.Email, UserID: &m.user.ID,
		Payload: notify.Payload{DeviceName: notificationDevice(device), OccurredAt: now},
	}); err != nil {
		return err
	}
	return audit.Record(ctx, tx, audit.Event{Action: m.action, Outcome: audit.Success,
		ActorUserID: &m.user.ID, TargetUserID: &m.user.ID, SessionID: sessionID, EmailHMAC: m.emailHMAC,
		IP: c.IP.Addr, UserAgent: c.UserAgent, RequestID: c.RequestID,
		Metadata: map[string]string{"revoked_sessions": fmt.Sprint(revoked)}})
}

// notificationDevice keeps the device name within what a notification accepts: at most 64
// bytes. Session device names are limited to 64 characters, which can be more bytes, so a long
// non-ASCII name is cut at a character boundary rather than failing the whole mutation.
func notificationDevice(name string) string {
	name = strings.TrimSpace(name)
	for len(name) > 64 {
		_, size := utf8.DecodeLastRuneInString(name)
		name = name[:len(name)-size]
	}
	if strings.TrimSpace(name) == "" {
		return "Unknown device"
	}
	return name
}

// recordFailure writes a failure event in autocommit, outside any rolled-back transaction.
func (s *Service) recordFailure(ctx context.Context, action string, p session.Principal, reason string, c Client) {
	if err := audit.Record(ctx, s.pool, audit.Event{Action: action, Outcome: audit.Failure, Reason: reason,
		ActorUserID: &p.UserID, TargetUserID: &p.UserID, SessionID: &p.SessionID,
		IP: c.IP.Addr, UserAgent: c.UserAgent, RequestID: c.RequestID}); err != nil {
		s.log.Error("password: failure audit event not recorded", "action", action, "error", err)
	}
}
