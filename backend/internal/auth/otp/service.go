// Package otp is the reusable OTP challenge core of TRD 01 sections 4 and 7.2 to 7.3: issuing
// a challenge (start) and redeeming its code (procedure V), with the transaction boundaries,
// lock order, cooldown, rate limits, outbox email and audit events those sections define.
//
// The flows built on it (signup, OTP sign-in, password reset, first-password set) supply only
// what differs between them: an eligibility check for start, and the steps that follow a
// successful redemption, which run in the same transaction as the consumption.
//
// Secrets: the code exists in plaintext only in memory and inside the encrypted outbox payload.
// The challenge row stores HMAC(VEEA_OTP_KEY, id || code) and SHA-256 of the token. Neither the
// code nor the token is ever logged, put in an error, or written to an audit event.
//
// Time: expiry, cooldown and supersession all use the database clock (the transaction's now()),
// like the rate limiter and the outbox, so application clocks never matter.
package otp

import (
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/netip"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/audit"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/identity"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/notify"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/clientip"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/db"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/db/sqlc"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/metrics"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/ratelimit"
)

// Fixed parameters (TRD 4.2).
const (
	Lifetime    = 10 * time.Minute
	MaxAttempts = 5
)

// Rule names reported in RateLimitedError for limits that are not ratelimit.Rules.
const (
	RuleCooldown = "otp_start_cooldown"
)

// Config wires a Service.
type Config struct {
	Pool      *pgxpool.Pool
	Codes     *CodeKeys           // VEEA_OTP_KEY
	EmailHMAC *identity.EmailHMAC // VEEA_EMAIL_HMAC_KEY
	Outbox    *notify.Outbox      // VEEA_OUTBOX_KEY
	// Rules overrides the TRD 10 limits. Nil means ratelimit.DefaultRules().
	Rules *ratelimit.Rules
	// CooldownSeconds overrides the 60 s resend cooldown. Zero means ratelimit.CooldownSeconds.
	CooldownSeconds int
	// Random is the source for tokens and codes. Nil means crypto/rand. Tests inject a
	// deterministic source to know the code of a delivery = 'none' challenge (TRD 12.3). Start
	// reads the 32 token bytes first, then 4 bytes per code candidate.
	Random io.Reader
	Logger *slog.Logger
	// OnTxRetry is called before a transaction is retried after a deadlock or serialization
	// failure. With the TRD 7.1 lock order this never happens; tests assert it.
	OnTxRetry func(sqlstate string)
	// Metrics, when set, receives the TRD 11.3 OTP counters. Nil disables them.
	Metrics *metrics.Metrics
}

// Service issues and redeems OTP challenges. It is safe for concurrent use.
type Service struct {
	pool      *pgxpool.Pool
	tx        db.Tx
	codes     *CodeKeys
	emailHMAC *identity.EmailHMAC
	outbox    *notify.Outbox
	limiter   *ratelimit.Limiter
	rules     ratelimit.Rules
	cooldown  ratelimit.Cooldown
	random    io.Reader
	log       *slog.Logger
	metrics   *metrics.Metrics
}

// NewService validates cfg and returns a Service.
func NewService(cfg Config) (*Service, error) {
	if cfg.Pool == nil || cfg.Codes == nil || cfg.EmailHMAC == nil || cfg.Outbox == nil {
		return nil, errors.New("otp: pool, code keys, email HMAC and outbox are required")
	}
	rules := ratelimit.DefaultRules()
	if cfg.Rules != nil {
		rules = *cfg.Rules
	}
	if err := rules.Validate(); err != nil {
		return nil, err
	}
	if cfg.CooldownSeconds < 0 {
		return nil, errors.New("otp: cooldown must not be negative")
	}
	s := &Service{
		pool: cfg.Pool, codes: cfg.Codes, emailHMAC: cfg.EmailHMAC, outbox: cfg.Outbox,
		limiter: ratelimit.NewLimiter(cfg.Pool), rules: rules,
		cooldown: ratelimit.Cooldown{Seconds: cfg.CooldownSeconds, Email: cfg.EmailHMAC},
		random:   cfg.Random, log: cfg.Logger, metrics: cfg.Metrics,
	}
	if s.random == nil {
		s.random = rand.Reader
	}
	if s.log == nil {
		s.log = slog.New(slog.DiscardHandler)
	}
	s.tx = db.Tx{Pool: cfg.Pool, OnRetry: func(code string) {
		s.log.Warn("otp: transaction retried", "sqlstate", code)
		if cfg.OnTxRetry != nil {
			cfg.OnTxRetry(code)
		}
	}}
	return s, nil
}

// cooldownError is the 429 of an active cooldown. The cooldown is per purpose and email, so the
// purpose scopes its audit record.
func (s *Service) cooldownError(purpose Purpose, e identity.Email, retryAfter int) error {
	return &RateLimitedError{Rule: RuleCooldown, RetryAfter: retryAfter, Scope: string(purpose),
		Window: time.Duration(s.cooldownSeconds()) * time.Second, Subject: ratelimit.EmailSubject(s.emailHMAC, e)}
}

func (s *Service) cooldownSeconds() int {
	if s.cooldown.Seconds > 0 {
		return s.cooldown.Seconds
	}
	return ratelimit.CooldownSeconds
}

// --- Start -----------------------------------------------------------------------------------

// Eligibility decides, inside the start transaction and after the cooldown claim, whether the
// request is eligible (TRD 3.3, 7.2 step 3). It reads users without a lock and must not write.
// An error rolls back the whole start, the cooldown claim included.
type Eligibility func(ctx context.Context, tx pgx.Tx) (Target, error)

// Target is the result of an Eligibility check.
type Target struct {
	Eligible bool
	// UserID binds a login, password_reset or set_password challenge to its account.
	UserID *uuid.UUID
	// SessionID binds a set_password challenge to the caller's session.
	SessionID *uuid.UUID
	// PendingPasswordHash is the argon2id hash of a password signup, stored on the challenge
	// until it is redeemed or ends (TRD 4.1).
	PendingPasswordHash string
	// To is the recipient. Empty means the address as entered (StartRequest.Email.Display).
	To            string
	EmailRevision int64
}

// StartRequest is one OTP start.
type StartRequest struct {
	Purpose      Purpose
	SignupMethod SignupMethod // signup only
	Email        identity.Email
	Check        Eligibility
	IP           clientip.Result
	UserAgent    string
	RequestID    string
}

// Acknowledgement is the 202 body (TRD 5.2). It is the same shape whether or not the request
// was eligible.
type Acknowledgement struct {
	ChallengeToken string
	ExpiresAt      time.Time
	ResendAfter    time.Time
	// delivery is "code" or "none", for metrics only. It is never part of a response.
	delivery string
}

// Start issues a challenge (TRD 7.2).
//
// Before the transaction, the hourly and daily per-email limits and the per-IP limit are counted
// in autocommit statements. Then one transaction, in lock order L1 → L2 → L5:
//
//  1. claim the (purpose, email) cooldown;
//  2. run the eligibility check;
//  3. supersede the open challenge for (purpose, email);
//  4. insert the new challenge, with delivery 'code' or 'none';
//  5. cancel the superseded challenge's pending email, then, if eligible, enqueue the new code;
//  6. write the audit event and commit.
//
// All of it commits or none of it does: a failure anywhere leaves no challenge, no email and no
// cooldown claim. An ineligible request takes exactly the same path and returns the same
// Acknowledgement, but its challenge is inert and no email is queued (TRD 4.4).
//
// Errors: *RateLimitedError for a limit or an active cooldown, otherwise an internal error.
func (s *Service) Start(ctx context.Context, req StartRequest) (Acknowledgement, error) {
	if req.Purpose == PurposeEmailCurrent || req.Purpose == PurposeEmailNew {
		return Acknowledgement{}, errors.New("otp: email change requires pair start")
	}
	info, err := req.Purpose.info()
	if err != nil {
		return Acknowledgement{}, err
	}
	if err := req.validate(); err != nil {
		return Acknowledgement{}, err
	}
	if err := s.checkStartLimits(ctx, req); err != nil {
		return Acknowledgement{}, err
	}
	p, err := s.newStartPlan(info, req)
	if err != nil {
		return Acknowledgement{}, err
	}
	var ack Acknowledgement
	err = s.tx.Run(ctx, func(ctx context.Context, tx pgx.Tx) error {
		var err error
		ack, err = s.issue(ctx, tx, p)
		return err
	})
	if err != nil {
		return Acknowledgement{}, err
	}
	s.metrics.OTPStarted(string(req.Purpose), ack.delivery) // after the commit
	return ack, nil
}

// checkStartLimits counts the start in the per-email and per-IP limits, in autocommit
// statements before the transaction (TRD 7.1 rule 6, 7.2).
func (s *Service) checkStartLimits(ctx context.Context, req StartRequest) error {
	email := ratelimit.EmailSubject(s.emailHMAC, req.Email)
	d, err := s.limiter.Allow(ctx,
		ratelimit.Check{Rule: s.rules.StartEmailHourly, Subject: email},
		ratelimit.Check{Rule: s.rules.StartEmailDaily, Subject: email},
		ratelimit.Check{Rule: s.rules.StartIP, Subject: ratelimit.IPSubject(req.IP)},
	)
	if err != nil {
		return err
	}
	if !d.Allowed {
		return d.Err()
	}
	return nil
}

// startPlan is one start with its secrets, generated before the transaction (TRD 7.1 rule 5).
// A retried transaction reuses them, which is safe because the failed attempt committed nothing.
type startPlan struct {
	info      purposeInfo
	req       StartRequest
	id        uuid.UUID
	token     string
	tokenHash []byte
	code      string
	emailHMAC []byte
}

func (s *Service) newStartPlan(info purposeInfo, req StartRequest) (startPlan, error) {
	token, tokenHash, err := newToken(s.random)
	if err != nil {
		return startPlan{}, err
	}
	code, err := newCode(s.random)
	if err != nil {
		return startPlan{}, err
	}
	id, err := uuid.NewV7()
	if err != nil {
		return startPlan{}, errors.New("otp: generate challenge id")
	}
	return startPlan{info: info, req: req, id: id, token: token, tokenHash: tokenHash, code: code,
		emailHMAC: s.emailHMAC.Current(req.Email)}, nil
}

// issue is the start transaction, in lock order L1 → L2 → L5.
func (s *Service) issue(ctx context.Context, tx pgx.Tx, p startPlan) (Acknowledgement, error) {
	q := sqlc.New(tx)

	// L1: the cooldown claim runs whatever the eligibility, so a 429 reveals nothing (step 1).
	claim, err := s.cooldown.Claim(ctx, tx, string(p.req.Purpose), p.req.Email)
	if err != nil {
		return Acknowledgement{}, err
	}
	if !claim.Granted {
		return Acknowledgement{}, s.cooldownError(p.req.Purpose, p.req.Email, claim.RetryAfterSeconds())
	}
	now, err := q.DatabaseNow(ctx)
	if err != nil {
		return Acknowledgement{}, fmt.Errorf("otp: read database time: %w", err)
	}

	// Step 3: eligibility, unlocked reads only.
	target, err := p.req.Check(ctx, tx)
	if err != nil {
		return Acknowledgement{}, err
	}
	if target, err = bindTarget(p.info, p.req, target); err != nil {
		return Acknowledgement{}, err
	}

	// L2: supersede, then insert (steps 4 and 5).
	expires := now.Add(Lifetime)
	superseded, err := s.replaceChallenge(ctx, q, p, target, expires)
	if err != nil {
		return Acknowledgement{}, err
	}

	// L5: every outbox write comes after the challenge writes (step 4's cancel, step 6), then
	// the audit event (step 7).
	if err := s.queueEmails(ctx, tx, p, target, superseded, expires); err != nil {
		return Acknowledgement{}, err
	}
	if err := s.recordStart(ctx, tx, p, target); err != nil {
		return Acknowledgement{}, err
	}
	return Acknowledgement{ChallengeToken: p.token, ExpiresAt: expires,
		ResendAfter: now.Add(time.Duration(s.cooldownSeconds()) * time.Second), delivery: delivery(target)}, nil
}

// replaceChallenge supersedes the open challenge for (purpose, email) and inserts the new one.
// It returns the ids of the superseded challenges.
func (s *Service) replaceChallenge(ctx context.Context, q *sqlc.Queries, p startPlan, t Target, expires time.Time) ([]uuid.UUID, error) {
	superseded, err := q.SupersedeOpenOTPChallenges(ctx, sqlc.SupersedeOpenOTPChallengesParams{
		Purpose: string(p.req.Purpose), EmailNormalized: p.req.Email.Normalized})
	if err != nil {
		return nil, fmt.Errorf("otp: supersede: %w", err)
	}
	row := sqlc.InsertOTPChallengeParams{
		ID: p.id, TokenHash: p.tokenHash, Purpose: string(p.req.Purpose),
		Email: p.req.Email.Display, EmailNormalized: p.req.Email.Normalized,
		UserID: t.UserID, SessionID: t.SessionID,
		CodeHash: s.codes.Hash(p.id, p.code), Delivery: delivery(t), MaxAttempts: MaxAttempts,
		ExpiresAt: expires, RequestIp: addrPtr(p.req.IP.Addr),
		EmailRevision: t.EmailRevision,
	}
	if p.req.Purpose == PurposeSignup {
		row.SignupMethod = ptr(string(p.req.SignupMethod))
	}
	if t.PendingPasswordHash != "" {
		row.PendingPasswordHash = ptr(t.PendingPasswordHash)
	}
	if _, err := q.InsertOTPChallenge(ctx, row); err != nil {
		if isUniqueViolation(err, "otp_challenges_one_open") {
			// The backstop index (TRD 7.2 step 5). Unreachable after the cooldown claim.
			return nil, s.cooldownError(p.req.Purpose, p.req.Email, s.cooldownSeconds())
		}
		return nil, fmt.Errorf("otp: insert challenge: %w", err)
	}
	return superseded, nil
}

// queueEmails cancels the superseded challenges' pending emails and, only for an eligible
// request, enqueues the new code (TRD 7.2 steps 4 and 6).
func (s *Service) queueEmails(ctx context.Context, tx pgx.Tx, p startPlan, t Target, superseded []uuid.UUID, expires time.Time) error {
	for _, old := range superseded {
		if _, err := s.outbox.CancelForChallenge(ctx, tx, old); err != nil {
			return err
		}
	}
	if !t.Eligible {
		return nil
	}
	_, err := s.outbox.Enqueue(ctx, tx, notify.Message{
		Template: p.info.template, To: t.To, UserID: t.UserID,
		ChallengeID: &p.id, NotAfter: &expires, Payload: notify.Payload{Code: p.code},
	})
	return err
}

func (s *Service) recordStart(ctx context.Context, tx pgx.Tx, p startPlan, t Target) error {
	meta := map[string]string{"delivery": delivery(t)}
	if p.req.Purpose == PurposeSignup {
		meta["method"] = string(p.req.SignupMethod)
	}
	return audit.Record(ctx, tx, audit.Event{
		Action: p.info.startAction, Outcome: audit.Success,
		ActorUserID: actor(p.info, t.UserID), TargetUserID: t.UserID, SessionID: t.SessionID,
		EmailHMAC: p.emailHMAC, IP: p.req.IP.Addr, UserAgent: p.req.UserAgent, RequestID: p.req.RequestID,
		Metadata: meta,
	})
}

func delivery(t Target) string {
	if t.Eligible {
		return "code"
	}
	return "none"
}

func (r StartRequest) validate() error {
	if r.Email.Normalized == "" || r.Email.Display == "" {
		return errors.New("otp: start needs a normalized email")
	}
	if r.Check == nil {
		return errors.New("otp: start needs an eligibility check")
	}
	switch {
	case r.Purpose == PurposeSignup && r.SignupMethod != SignupOTP && r.SignupMethod != SignupPassword:
		return errors.New("otp: signup needs method otp or password")
	case r.Purpose != PurposeSignup && r.SignupMethod != "":
		return errors.New("otp: only signup has a method")
	}
	return nil
}

// bindTarget checks a Target against its purpose and strips everything from an ineligible one:
// a delivery = 'none' challenge is never bound to an account, a session or a credential, and
// a password signup's hash is discarded (TRD 4.4).
func bindTarget(info purposeInfo, req StartRequest, t Target) (Target, error) {
	if !t.Eligible {
		return Target{}, nil
	}
	switch {
	case info.needsUser && t.UserID == nil:
		return Target{}, errors.New("otp: an eligible challenge for this purpose needs the account")
	case !info.needsUser && t.UserID != nil:
		return Target{}, errors.New("otp: a signup challenge is not bound to an account")
	case info.callerBound != (t.SessionID != nil):
		return Target{}, errors.New("otp: invalid caller binding for purpose")
	case (req.SignupMethod == SignupPassword) != (t.PendingPasswordHash != ""):
		return Target{}, errors.New("otp: a pending password hash belongs to, and is required by, password signup")
	}
	if t.To == "" {
		t.To = req.Email.Display
	}
	return t, nil
}

// --- Verify ----------------------------------------------------------------------------------

// VerifyRequest is one redemption.
type VerifyRequest struct {
	Purpose Purpose
	Token   string
	Code    string
	// UserID and SessionID are the authenticated caller. Required for set_password, which is
	// bound to both (TRD 4.3); must be nil for every other purpose.
	UserID    *uuid.UUID
	SessionID *uuid.UUID
	IP        clientip.Result
	UserAgent string
	RequestID string
	// Prechecked means the caller already ran CheckVerifyLimits for this request, for example
	// before an Argon2id run it must not spend on a limited request. Verify then skips them, so
	// the per-IP counter moves once per request.
	Prechecked bool
}

// Accepted describes a challenge that procedure V just consumed. It is handed to the flow's
// AfterAccept callback, inside the same transaction.
type Accepted struct {
	ChallengeID  uuid.UUID
	Purpose      Purpose
	SignupMethod SignupMethod
	Email        identity.Email // as stored on the challenge
	EmailHMAC    []byte
	UserID       *uuid.UUID // login, password_reset, set_password
	SessionID    *uuid.UUID // set_password
	// PendingPasswordHash is the password signup hash. It has already been cleared from the row
	// and exists only here, in memory (TRD 7.3 step 5).
	PendingPasswordHash string
	EmailRevision       int64
}

// AfterAccept runs a flow's steps after V accepted the code, in the same transaction and in
// lock order L3 → L4 → L5 (TRD 7.3, 7.5). It ends the redemption by returning:
//
//   - nil: the pending email of the challenge is cancelled and everything commits. The callback
//     writes its own success audit event.
//   - CommitFailure(reason, err): the consumption stands and commits with a failure audit event;
//     Verify returns err.
//   - Rollback(reason, err): everything rolls back, the challenge is usable again, and a failure
//     audit event is written in its own transaction; Verify returns err.
//   - any other error: everything rolls back and Verify returns it.
type AfterAccept func(ctx context.Context, tx pgx.Tx, a Accepted) error

// outcome carries what one T-main attempt decided out of the transaction closure.
type outcome struct {
	reject   error // ErrInvalidCode or ErrAttemptsExceeded, committed with its audit event
	counted  bool  // the rejection counts toward the per-email failure limit (step C)
	email    *identity.Email
	hmac     []byte
	target   *uuid.UUID
	flowFail *flowFailure // CommitFailure: committed
}

// Verify redeems a code (TRD 7.3) with these boundaries:
//
//   - Limits, before any transaction: the per-IP verify limit is counted, and the per-email
//     verify-failure limit is checked without counting (P). Either gives *RateLimitedError and
//     opens no transaction.
//   - T-main: procedure V on the challenge row (L2 only), then then's steps, then commit.
//     A rejection commits the attempt increment and its failure audit event before returning,
//     so failures can never be rolled back (TRD 7.1 rule 3).
//   - T-fail: only after then asked for Rollback, a short transaction with the failure audit.
//   - C: after a counted rejection committed, the per-email failure counter is incremented.
//
// The returned error is nil on success, ErrInvalidCode or ErrAttemptsExceeded for a rejection,
// *RateLimitedError, the error a flow passed to CommitFailure or Rollback, or an internal error.
func (s *Service) Verify(ctx context.Context, req VerifyRequest, then AfterAccept) error {
	if req.Purpose == PurposeEmailCurrent || req.Purpose == PurposeEmailNew {
		return errors.New("otp: email change requires pair verification")
	}
	info, err := req.Purpose.info()
	if err != nil {
		return err
	}
	if then == nil {
		return errors.New("otp: verify needs the flow's after-accept steps")
	}
	hasCaller, fullCaller := req.UserID != nil || req.SessionID != nil, req.UserID != nil && req.SessionID != nil
	if (info.callerBound && !fullCaller) || (!info.callerBound && hasCaller) {
		return errors.New("otp: set_password verification needs the caller's user and session, other purposes none")
	}
	tokenHash := HashToken(req.Token)
	if !req.Prechecked {
		if err := s.checkVerifyLimits(ctx, req, tokenHash); err != nil {
			s.metrics.OTPVerified(string(req.Purpose), limitResult(err))
			return err
		}
	}

	var out outcome
	err = s.tx.Run(ctx, func(ctx context.Context, tx pgx.Tx) error {
		out = outcome{}
		return s.redeem(ctx, tx, info, req, tokenHash, then, &out)
	})
	return s.settle(ctx, info, req, &out, err)
}

// CheckVerifyLimits runs Verify's pre-transaction limits on their own: the per-IP verify limit
// (counted) and the per-email failure limit P (peeked). Call it before expensive work, then pass
// Prechecked to Verify. Errors: *RateLimitedError or an internal error.
func (s *Service) CheckVerifyLimits(ctx context.Context, req VerifyRequest) error {
	err := s.checkVerifyLimits(ctx, req, HashToken(req.Token))
	if err != nil {
		// Counted here, because Verify skips its own check for a Prechecked request.
		s.metrics.OTPVerified(string(req.Purpose), limitResult(err))
	}
	return err
}

// checkVerifyLimits runs before any transaction: the per-IP verify limit is counted, then P
// reads the challenge's email without a lock and peeks at its failure counter (TRD 7.3, 10).
func (s *Service) checkVerifyLimits(ctx context.Context, req VerifyRequest, tokenHash []byte) error {
	d, err := s.limiter.Allow(ctx, ratelimit.Check{Rule: s.rules.VerifyIP, Subject: ratelimit.IPSubject(req.IP)})
	if err != nil {
		return err
	}
	if !d.Allowed {
		return d.Err()
	}
	normalized, err := sqlc.New(s.pool).GetOTPChallengeEmailByTokenHash(ctx, tokenHash)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil // unknown token: no email to limit; V rejects it without counting
	}
	if err != nil {
		return fmt.Errorf("otp: verify pre-check: %w", err)
	}
	pd, err := s.limiter.Peek(ctx, ratelimit.Check{Rule: s.rules.VerifyFailEmail,
		Subject: ratelimit.EmailSubject(s.emailHMAC, identity.Email{Normalized: normalized})})
	if err != nil {
		return err
	}
	if !pd.Allowed {
		return pd.Err()
	}
	return nil
}

// settle turns the result of T-main into Verify's result, running T-fail or C where needed.
func (s *Service) settle(ctx context.Context, info purposeInfo, req VerifyRequest, out *outcome, err error) error {
	result := s.decide(ctx, info, req, out, err)
	s.metrics.OTPVerified(string(req.Purpose), verifyResult(out, err, result))
	return result
}

// verifyResult is the auth_otp_verified_total result label: success, invalid_code,
// attempts_exceeded, rejected (the code was right but the flow refused, for example the account
// is gone or no longer active), or error.
// A transaction error is classified first: outcome fields set inside a closure whose commit
// then failed describe work that rolled back, and must not be counted as results.
func verifyResult(out *outcome, txErr, result error) string {
	var ff *flowFailure
	switch {
	case txErr != nil && errors.As(txErr, &ff):
		return "rejected" // the flow asked for Rollback; T-fail recorded it
	case txErr != nil:
		return "error"
	case result == nil:
		return "success"
	case out.reject != nil && errors.Is(out.reject, ErrAttemptsExceeded):
		return "attempts_exceeded"
	case out.reject != nil:
		return "invalid_code"
	case out.flowFail != nil:
		return "rejected"
	}
	return "error"
}

// limitResult labels a refusal by the verify limits: rate_limited, or error for a database
// failure while checking them.
func limitResult(err error) string {
	var limited *RateLimitedError
	if errors.As(err, &limited) {
		return "rate_limited"
	}
	return "error"
}

func (s *Service) decide(ctx context.Context, info purposeInfo, req VerifyRequest, out *outcome, err error) error {
	var ff *flowFailure
	switch {
	case err != nil && errors.As(err, &ff) && !ff.commit:
		// T-fail: T-main rolled back (consumption undone); record the failure on its own.
		terr := s.tx.Run(ctx, func(ctx context.Context, tx pgx.Tx) error {
			return audit.Record(ctx, tx, s.failureEvent(info, req, out, ff.reason))
		})
		if terr != nil {
			s.log.Error("otp: failure audit event not recorded", "action", info.verifyAction, "error", terr)
		}
		return ff.err
	case err != nil:
		return err
	case out.reject != nil:
		if out.counted && out.email != nil {
			s.countFailure(ctx, *out.email)
		}
		return out.reject
	case out.flowFail != nil:
		return out.flowFail.err
	}
	return nil
}

// countFailure is C: after the attempt committed, count it against the email in autocommit.
// A failure here is logged; the rejection still stands.
func (s *Service) countFailure(ctx context.Context, e identity.Email) {
	_, err := s.limiter.Allow(ctx, ratelimit.Check{Rule: s.rules.VerifyFailEmail, Subject: ratelimit.EmailSubject(s.emailHMAC, e)})
	if err != nil {
		s.log.Error("otp: verify failure counter not recorded", "error", err)
	}
}

// redeem is T-main: procedure V, then the flow.
func (s *Service) redeem(ctx context.Context, tx pgx.Tx, info purposeInfo, req VerifyRequest,
	tokenHash []byte, then AfterAccept, out *outcome) error {
	q := sqlc.New(tx)
	now, err := q.DatabaseNow(ctx)
	if err != nil {
		return fmt.Errorf("otp: read database time: %w", err)
	}

	// V1, L2: lock the challenge by token.
	ch, err := q.LockOTPChallengeByTokenHash(ctx, tokenHash)
	if errors.Is(err, pgx.ErrNoRows) {
		return s.reject(ctx, tx, info, req, out, ErrInvalidCode, false)
	}
	if err != nil {
		return fmt.Errorf("otp: lock challenge: %w", err)
	}
	email := identity.Email{Display: ch.Email, Normalized: ch.EmailNormalized}
	out.email, out.hmac, out.target = &email, s.emailHMAC.Current(email), ch.UserID

	// V2 (unusable) and V3 (exhausted): not counted.
	if reason := unusable(info, ch, req, now); reason != nil {
		return s.reject(ctx, tx, info, req, out, reason, false)
	}
	// V4: always run the constant-time compare; a delivery = 'none' challenge can never pass,
	// whatever the code (TRD 4.4).
	match := s.codes.Match(ch.ID, req.Code, ch.CodeHash)
	if !match || ch.Delivery != "code" {
		if err := updateLocked(q.IncrementOTPChallengeAttempts(ctx, ch.ID)); err != nil {
			return fmt.Errorf("otp: count attempt: %w", err)
		}
		return s.reject(ctx, tx, info, req, out, ErrInvalidCode, true)
	}
	// V5: accept. The pending password hash leaves the row here and lives on only in memory.
	if err := updateLocked(q.ConsumeOTPChallenge(ctx, ch.ID)); err != nil {
		return fmt.Errorf("otp: consume challenge: %w", err)
	}
	return s.runFlow(ctx, tx, info, req, accepted(ch, req, out), then, out)
}

// unusable returns the rejection for a challenge that cannot be redeemed at all: wrong purpose,
// wrong caller binding, consumed, superseded, expired on the database clock (V2, invalid_code)
// or out of attempts (V3, code_attempts_exceeded). Nil means V continues to the compare.
func unusable(info purposeInfo, ch sqlc.OtpChallenge, req VerifyRequest, now time.Time) error {
	if Purpose(ch.Purpose) != req.Purpose || !bindingMatches(info, ch, req) ||
		ch.ConsumedAt != nil || ch.SupersededAt != nil || !ch.ExpiresAt.After(now) {
		return ErrInvalidCode
	}
	if ch.Attempts >= ch.MaxAttempts {
		return ErrAttemptsExceeded
	}
	return nil
}

func accepted(ch sqlc.OtpChallenge, req VerifyRequest, out *outcome) Accepted {
	a := Accepted{
		ChallengeID: ch.ID, Purpose: req.Purpose, Email: *out.email, EmailHMAC: out.hmac,
		UserID: ch.UserID, SessionID: ch.SessionID,
		EmailRevision: ch.EmailRevision,
	}
	if ch.SignupMethod != nil {
		a.SignupMethod = SignupMethod(*ch.SignupMethod)
	}
	if ch.PendingPasswordHash != nil {
		a.PendingPasswordHash = *ch.PendingPasswordHash
	}
	return a
}

// runFlow runs the flow's L3, L4 and L5 steps after V accepted, then cancels the challenge's
// pending email as the last L5 write, after every lock the flow took (TRD 7.3).
func (s *Service) runFlow(ctx context.Context, tx pgx.Tx, info purposeInfo, req VerifyRequest,
	a Accepted, then AfterAccept, out *outcome) error {
	ferr := then(ctx, tx, a)
	var ff *flowFailure
	if ferr != nil && !(errors.As(ferr, &ff) && ff.commit) {
		return ferr // roll back; settle writes T-fail for Rollback
	}
	if _, err := s.outbox.CancelForChallenge(ctx, tx, a.ChallengeID); err != nil {
		return err
	}
	if ff != nil {
		if err := audit.Record(ctx, tx, s.failureEvent(info, req, out, ff.reason)); err != nil {
			return err
		}
		out.flowFail = ff
	}
	return nil
}

// reject records a V rejection inside T-main. Returning nil commits the attempt increment (if
// any) together with the failure audit event (TRD 7.3, "On a V rejection").
func (s *Service) reject(ctx context.Context, tx pgx.Tx, info purposeInfo, req VerifyRequest,
	out *outcome, reason error, counted bool) error {
	auditReason := ReasonInvalidCode
	if errors.Is(reason, ErrAttemptsExceeded) {
		auditReason = ReasonAttemptsExceeded
	}
	if err := audit.Record(ctx, tx, s.failureEvent(info, req, out, auditReason)); err != nil {
		return err
	}
	out.reject, out.counted = reason, counted
	return nil
}

func (s *Service) failureEvent(info purposeInfo, req VerifyRequest, out *outcome, reason string) audit.Event {
	return audit.Event{
		Action: info.verifyAction, Outcome: audit.Failure, Reason: reason,
		ActorUserID: req.UserID, TargetUserID: out.target, SessionID: req.SessionID,
		EmailHMAC: out.hmac, IP: req.IP.Addr, UserAgent: req.UserAgent, RequestID: req.RequestID,
	}
}

// bindingMatches applies the caller binding of set_password (TRD 4.3, 7.3 step 2).
func bindingMatches(info purposeInfo, ch sqlc.OtpChallenge, req VerifyRequest) bool {
	if !info.callerBound {
		return true
	}
	return ch.UserID != nil && ch.SessionID != nil && *ch.UserID == *req.UserID && *ch.SessionID == *req.SessionID
}

// --- helpers ---------------------------------------------------------------------------------

// actor is the acting user: only set_password is started by a signed-in user.
func actor(info purposeInfo, user *uuid.UUID) *uuid.UUID {
	if info.callerBound {
		return user
	}
	return nil
}

// updateLocked checks that an UPDATE of the row this transaction holds changed exactly that row.
func updateLocked(n int64, err error) error {
	if err != nil {
		return err
	}
	if n != 1 {
		return errors.New("locked challenge not updated")
	}
	return nil
}

func isUniqueViolation(err error, constraint string) bool {
	var pgErr *pgconn.PgError
	return errors.As(err, &pgErr) && pgErr.Code == "23505" && pgErr.ConstraintName == constraint
}

func addrPtr(a netip.Addr) *netip.Addr {
	if !a.IsValid() {
		return nil
	}
	return &a
}

func ptr[T any](v T) *T { return &v }
