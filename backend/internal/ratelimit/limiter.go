package ratelimit

import (
	"context"
	"errors"
	"fmt"
	"math"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/identity"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/clientip"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/db/sqlc"
)

// Subject is who a limit applies to. Build one with the constructors below: they are the only
// way to get a key that contains no raw email.
type Subject struct {
	kind  string
	value string
}

// EmailSubject keys a limit by the HMAC of a normalized email (TRD 6.9, 10). It takes an
// identity.Email, so the address has already gone through NormalizeEmail, and it never looks at
// whether an account exists, so eligible and ineligible emails are counted identically (AC-27).
func EmailSubject(h *identity.EmailHMAC, e identity.Email) Subject {
	return Subject{kind: "email", value: h.CurrentHex(e)}
}

// IPSubject keys a limit by a client address bucket from clientip (IPv4 address or IPv6 /64).
func IPSubject(r clientip.Result) Subject { return Subject{kind: "ip", value: r.Bucket} }

// UserSubject keys a limit by user id.
func UserSubject(id uuid.UUID) Subject { return Subject{kind: "user", value: id.String()} }

// SessionSubject keys a limit by session id.
func SessionSubject(id uuid.UUID) Subject { return Subject{kind: "session", value: id.String()} }

// String returns "kind:value", which is also the tail of every counter key for the subject. The
// value is an HMAC, an IP bucket or an id, never a raw email, so it is safe to log.
func (s Subject) String() string { return s.kind + ":" + s.value }

// Kind is "email", "ip", "user" or "session"; empty for the zero Subject.
func (s Subject) Kind() string { return s.kind }

// Value is the email HMAC in hex, the IP bucket, or the user or session id.
func (s Subject) Value() string { return s.value }

// Check is one rule applied to one subject.
type Check struct {
	Rule    Rule
	Subject Subject
}

// key renders the counter key, for example "otp_start_email_1h:email:<64 hex>". The rule name
// keeps rules with different windows on the same subject apart.
func (c Check) key() string { return c.Rule.Name + ":" + c.Subject.kind + ":" + c.Subject.value }

// Decision is the outcome of one or more checks.
type Decision struct {
	// Allowed is false when any check is over its limit.
	Allowed bool
	// Rule is the rule behind the decision. For a denial it is the denying rule with the
	// longest wait. For an allowance it is the last rule checked.
	Rule Rule
	// Count is the counter value for Rule, including this attempt.
	Count int
	// ResetsIn is how long until Rule's window ends and its counter starts over.
	ResetsIn time.Duration
	// Subject is who Rule was applied to.
	Subject Subject
}

// RetryAfterSeconds is the value for a Retry-After header: whole seconds until the window
// resets, rounded up and at least 1 for a denial. It is 0 when the request was allowed.
func (d Decision) RetryAfterSeconds() int {
	if d.Allowed {
		return 0
	}
	return max(1, int(math.Ceil(d.ResetsIn.Seconds())))
}

// Error is a refused request, answered with 429 and Retry-After (TRD 10). RetryAfter is in
// whole seconds, at least 1. Rule names the limit, for logs and the auth.rate_limited event.
type Error struct {
	Rule       string
	RetryAfter int
	// Window and Subject identify the limit that refused, so the refusal can be audited once
	// per window and subject (TRD 11.1 auth.rate_limited). Both are set by Decision.Err.
	Window  time.Duration
	Subject Subject
	// Scope narrows the audit deduplication when one rule covers several independent limits,
	// for example the cooldown, which is per purpose and email. Optional.
	Scope string
}

func (e *Error) Error() string {
	return fmt.Sprintf("rate_limited: %s, retry after %ds", e.Rule, e.RetryAfter)
}

// Err is nil for an allowed decision and an *Error for a denied one.
func (d Decision) Err() error {
	if d.Allowed {
		return nil
	}
	return &Error{Rule: d.Rule.Name, RetryAfter: d.RetryAfterSeconds(), Window: d.Rule.Window, Subject: d.Subject}
}

// Limiter counts events in fixed windows stored in PostgreSQL. It is safe for concurrent use.
//
// It holds a *pgxpool.Pool on purpose and never accepts a transaction: counter writes are
// separate autocommit statements, so they survive whatever happens to the caller's business
// transaction, and they never hold locks the business transaction could wait on (TRD 7.1 rule 6).
type Limiter struct {
	q    *sqlc.Queries
	pool *pgxpool.Pool
}

// NewLimiter returns a Limiter on pool.
func NewLimiter(pool *pgxpool.Pool) *Limiter { return &Limiter{q: sqlc.New(pool), pool: pool} }

// Allow records one event for every check and decides.
//
// Every check is incremented even when an earlier one is already over its limit, and even
// when the request is going to be rejected. That keeps the count equal to the number of attempts
// and makes the behavior independent of what happens afterwards, including whether the account
// exists. Counting is one atomic statement per check, so N concurrent callers on a limit of L
// see exactly L allowed and N-L denied, with no check-then-act window (TRD 7.2).
//
// A check is allowed while its count, including this attempt, is at most its limit. When several
// are over, the returned Decision is the one with the longest wait, so a client that honors
// Retry-After is not turned away again by a longer rule.
//
// On a database error it returns the error and a denied Decision. Callers should answer 503, not
// let the request through: a limiter that fails open would be bypassed by stressing the database.
func (l *Limiter) Allow(ctx context.Context, checks ...Check) (Decision, error) {
	if len(checks) == 0 {
		return Decision{}, errors.New("ratelimit: no checks given")
	}
	var denied *Decision
	last := Decision{Allowed: true}
	for _, c := range checks {
		if err := c.Rule.Validate(); err != nil {
			return Decision{}, err
		}
		row, err := l.q.IncrementRateLimitWindow(ctx, sqlc.IncrementRateLimitWindowParams{
			Key: c.key(), WindowSeconds: int64(c.Rule.Window / time.Second)})
		if err != nil {
			return Decision{}, fmt.Errorf("ratelimit: increment %s: %w", c.Rule.Name, err)
		}
		d := decide(c.Rule, int(row.Count), row.WindowStart, row.DbNow)
		d.Subject = c.Subject
		last = d
		if !d.Allowed && (denied == nil || d.ResetsIn > denied.ResetsIn) {
			dd := d
			denied = &dd
		}
	}
	if denied != nil {
		return *denied, nil
	}
	return last, nil
}

// Peek reports where a check stands without counting an event. It is the pre-check of TRD 7.3
// (step P) for rules whose counter only moves on failures. The Decision is Allowed while a
// further event would still fit, that is while Count < Limit. It is never "used up" by Peek.
func (l *Limiter) Peek(ctx context.Context, c Check) (Decision, error) {
	if err := c.Rule.Validate(); err != nil {
		return Decision{}, err
	}
	row, err := l.q.PeekRateLimitWindow(ctx, sqlc.PeekRateLimitWindowParams{
		Key: c.key(), WindowSeconds: int64(c.Rule.Window / time.Second)})
	if err != nil {
		return Decision{}, fmt.Errorf("ratelimit: peek %s: %w", c.Rule.Name, err)
	}
	d := decide(c.Rule, int(row.Count), row.WindowStart, row.DbNow)
	d.Subject = c.Subject
	d.Allowed = int(row.Count) < c.Rule.Limit
	return d, nil
}

func decide(rule Rule, count int, windowStart, dbNow time.Time) Decision {
	resets := windowStart.Add(rule.Window).Sub(dbNow)
	if resets < 0 {
		resets = 0
	}
	return Decision{Allowed: count <= rule.Limit, Rule: rule, Count: count, ResetsIn: resets}
}
