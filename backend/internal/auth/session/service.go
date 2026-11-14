package session

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/netip"
	"strconv"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/audit"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/identity/accounts"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/db"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/db/sqlc"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/ratelimit"
)

// ErrUnauthorized is the single answer for every token that does not authenticate: unknown,
// expired, revoked, consumed, past retention, or owned by an account that is not in good
// standing (TRD 5.3 endpoints 9 to 11, AC-19). It never says which.
var ErrUnauthorized = errors.New("unauthorized")

// Revocation and failure reasons (TRD 6.5, 11.1).
const (
	ReasonLogout          = "logout"
	ReasonRefreshReuse    = "refresh_reuse"
	ReasonAccountInactive = "account_inactive"
	reasonSessionRevoked  = "session_revoked"
	reasonSessionExpired  = "session_expired"
)

// Principal is an authenticated caller.
type Principal struct {
	SessionID uuid.UUID
	UserID    uuid.UUID
	Role      string
}

// Client is what the HTTP layer knows about the caller.
type Client struct {
	IP        netip.Addr
	UserAgent string // sanitized
	RequestID string
}

// Config wires a Service.
type Config struct {
	Pool *pgxpool.Pool
	// Rules supplies RefreshSession and RequestSession. Nil means ratelimit.DefaultRules().
	Rules *ratelimit.Rules
	// Random is the source for new tokens. Nil means crypto/rand.
	Random    io.Reader
	Logger    *slog.Logger
	OnTxRetry func(sqlstate string)
}

// Service authenticates access tokens, rotates refresh tokens and logs out (TRD 7.6, 7.7, 8.1,
// 8.4, 8.5). It is safe for concurrent use.
type Service struct {
	pool    *pgxpool.Pool
	tx      db.Tx
	limiter *ratelimit.Limiter
	rules   ratelimit.Rules
	random  io.Reader
	log     *slog.Logger
}

// NewService validates cfg and returns a Service.
func NewService(cfg Config) (*Service, error) {
	if cfg.Pool == nil {
		return nil, errors.New("session: a pool is required")
	}
	rules := ratelimit.DefaultRules()
	if cfg.Rules != nil {
		rules = *cfg.Rules
	}
	if err := errors.Join(rules.RefreshSession.Validate(), rules.RequestSession.Validate()); err != nil {
		return nil, err
	}
	s := &Service{pool: cfg.Pool, limiter: ratelimit.NewLimiter(cfg.Pool), rules: rules, random: cfg.Random, log: cfg.Logger}
	if s.log == nil {
		s.log = slog.New(slog.DiscardHandler)
	}
	s.tx = db.Tx{Pool: cfg.Pool, OnRetry: func(code string) {
		s.log.Warn("session: transaction retried", "sqlstate", code)
		if cfg.OnTxRetry != nil {
			cfg.OnTxRetry(code)
		}
	}}
	return s, nil
}

// --- per-request authentication (TRD 8.1) ----------------------------------------------------

// Authenticate checks an access token with one indexed read: the session exists, is not revoked,
// neither the access nor the absolute expiry has passed, and its account is active with a
// verified email. Then the per-session request limit is counted, and last_seen_at is refreshed
// at most every 5 minutes.
//
// A token whose session is live but whose account left good standing also revokes that session
// (account_inactive) before the 401.
//
// Errors: ErrUnauthorized, *ratelimit.Error, or an internal error.
func (s *Service) Authenticate(ctx context.Context, accessToken string, c Client) (Principal, error) {
	if !strings.HasPrefix(accessToken, AccessPrefix) {
		return Principal{}, ErrUnauthorized
	}
	hash := HashToken(accessToken)
	q := sqlc.New(s.pool)
	row, err := q.AuthenticateAccessToken(ctx, hash)
	if errors.Is(err, pgx.ErrNoRows) {
		s.revokeIfAccountInactive(ctx, hash, c)
		return Principal{}, ErrUnauthorized
	}
	if err != nil {
		return Principal{}, fmt.Errorf("session: authenticate: %w", err)
	}
	d, err := s.limiter.Allow(ctx, ratelimit.Check{Rule: s.rules.RequestSession, Subject: ratelimit.SessionSubject(row.SessionID)})
	if err != nil {
		return Principal{}, err
	}
	if err := d.Err(); err != nil {
		return Principal{}, err
	}
	if _, err := q.TouchSessionLastSeen(ctx, sqlc.TouchSessionLastSeenParams{LastSeenIp: addrPtr(c.IP), ID: row.SessionID}); err != nil {
		s.log.Warn("session: last_seen_at not updated", "error", err)
	}
	return Principal{SessionID: row.SessionID, UserID: row.UserID, Role: row.Role}, nil
}

// revokeIfAccountInactive is the automatic account_inactive revocation (TRD 8.1, 8.7): a short
// transaction on the acting session only (L4a → L5). Failures are logged; the caller gets 401
// either way.
func (s *Service) revokeIfAccountInactive(ctx context.Context, hash []byte, c Client) {
	owner, err := sqlc.New(s.pool).GetSessionOwnerStatus(ctx, hash)
	if err != nil || owner.RevokedAt != nil || (owner.Status == accounts.StatusActive && owner.EmailVerifiedAt != nil) {
		return // unknown token, already revoked, or simply expired
	}
	err = s.tx.Run(ctx, func(ctx context.Context, tx pgx.Tx) error {
		n, err := sqlc.New(tx).RevokeSession(ctx, sqlc.RevokeSessionParams{
			Reason: ptr(ReasonAccountInactive), ID: owner.SessionID, UserID: owner.UserID})
		if err != nil || n == 0 {
			return err
		}
		return recordRevoke(ctx, tx, owner.UserID, owner.SessionID, ReasonAccountInactive, n, c)
	})
	if err != nil {
		s.log.Error("session: account_inactive revocation failed", "error", err)
	}
}

// CurrentUser reads the caller's account for GET /v1/me.
func (s *Service) CurrentUser(ctx context.Context, p Principal) (sqlc.User, error) {
	u, ok, err := accounts.Get(ctx, s.pool, p.UserID)
	if err != nil {
		return sqlc.User{}, err
	}
	if !ok {
		return sqlc.User{}, ErrUnauthorized
	}
	return u, nil
}

// --- refresh (TRD 8.4, 8.5) ------------------------------------------------------------------

// Refreshed is a committed rotation: the new token pair and the account.
type Refreshed struct {
	Issued
	User sqlc.User
}

// Refresh rotates a refresh token with no grace window.
//
// Before the transaction, an unlocked read finds the token's session (as its current token, or
// as a consumed one within retention). No session: ErrUnauthorized at once, nothing written.
// Otherwise the per-session refresh limit is counted.
//
// Then one transaction, L4a → L5:
//
//   - The session row is locked by its current refresh hash. If it is live and its account in
//     good standing, the presented hash is recorded as consumed with retain_until = the row's
//     current refresh_expires_at (the token's own recorded expiry), the row gets a new pair,
//     and the transaction commits. Only then is the new pair returned. The old access token
//     stops working with the commit, because its hash was replaced.
//   - If no row matches, the token was already rotated. Within retention that is reuse: the
//     session it belonged to is revoked (refresh_reuse), and only that one. A concurrent refresh
//     with the same token lands here after waiting for the winner's lock, so the winner's new
//     pair dies with the session.
//   - A revoked or expired session, or an account out of good standing, gets ErrUnauthorized;
//     the last also revokes the session (account_inactive). These outcomes commit their audit
//     event and revocation.
//
// Errors: ErrUnauthorized, *ratelimit.Error, or an internal error (the transaction then rolled
// back and the presented token is unchanged).
func (s *Service) Refresh(ctx context.Context, refreshToken string, c Client) (Refreshed, error) {
	if !strings.HasPrefix(refreshToken, RefreshPrefix) {
		return Refreshed{}, ErrUnauthorized
	}
	hash := HashToken(refreshToken)
	sid, err := sqlc.New(s.pool).FindSessionForRefreshToken(ctx, hash)
	if errors.Is(err, pgx.ErrNoRows) {
		return Refreshed{}, ErrUnauthorized
	}
	if err != nil {
		return Refreshed{}, fmt.Errorf("session: refresh pre-check: %w", err)
	}
	d, err := s.limiter.Allow(ctx, ratelimit.Check{Rule: s.rules.RefreshSession, Subject: ratelimit.SessionSubject(sid)})
	if err != nil {
		return Refreshed{}, err
	}
	if err := d.Err(); err != nil {
		return Refreshed{}, err
	}
	// New tokens are generated before the transaction (TRD 7.1 rule 5); the id is unused.
	next, err := NewPending(s.random)
	if err != nil {
		return Refreshed{}, err
	}

	var out Refreshed
	var refused bool
	err = s.tx.Run(ctx, func(ctx context.Context, tx pgx.Tx) error {
		out, refused = Refreshed{}, false
		var err error
		out, refused, err = s.rotate(ctx, tx, hash, next, c)
		return err
	})
	if err != nil {
		return Refreshed{}, err
	}
	if refused {
		return Refreshed{}, ErrUnauthorized
	}
	return out, nil
}

// rotate is the refresh transaction. refused means the caller answers 401 after the commit of
// whatever this transaction recorded (a revocation, an audit event).
func (s *Service) rotate(ctx context.Context, tx pgx.Tx, hash []byte, next Pending, c Client) (Refreshed, bool, error) {
	q := sqlc.New(tx)
	now, err := q.DatabaseNow(ctx)
	if err != nil {
		return Refreshed{}, false, fmt.Errorf("session: read database time: %w", err)
	}
	// Step 1, L4a.
	row, err := q.LockSessionByRefreshTokenHash(ctx, hash)
	if errors.Is(err, pgx.ErrNoRows) {
		return Refreshed{}, true, s.reuse(ctx, tx, hash, c) // step 3
	}
	if err != nil {
		return Refreshed{}, false, fmt.Errorf("session: lock session: %w", err)
	}
	// Step 2: checks.
	if reason := refreshRefusal(row, now); reason != "" {
		if reason == ReasonAccountInactive {
			n, err := q.RevokeSessionByID(ctx, sqlc.RevokeSessionByIDParams{Reason: ptr(ReasonAccountInactive), ID: row.ID})
			if err != nil {
				return Refreshed{}, false, fmt.Errorf("session: revoke: %w", err)
			}
			if err := recordRevoke(ctx, tx, row.UserID, row.ID, ReasonAccountInactive, n, c); err != nil {
				return Refreshed{}, false, err
			}
		}
		return Refreshed{}, true, recordRefreshFailure(ctx, tx, row.UserID, row.ID, reason, c)
	}
	// L5 then the row we hold: record the consumed token with its own recorded expiry, rotate.
	if err := q.InsertConsumedRefreshToken(ctx, sqlc.InsertConsumedRefreshTokenParams{
		TokenHash: hash, SessionID: row.ID, RetainUntil: row.RefreshExpiresAt}); err != nil {
		return Refreshed{}, false, fmt.Errorf("session: record consumed token: %w", err)
	}
	out := Issued{
		SessionID: row.ID, AccessToken: next.access, RefreshToken: next.refresh,
		AccessExpiresAt:   earliest(now.Add(AccessTTL), row.AbsoluteExpiresAt),
		RefreshExpiresAt:  earliest(now.Add(RefreshIdleTTL), row.AbsoluteExpiresAt),
		AbsoluteExpiresAt: row.AbsoluteExpiresAt,
	}
	n, err := q.RotateSession(ctx, sqlc.RotateSessionParams{
		AccessTokenHash: next.accessHash, AccessExpiresAt: out.AccessExpiresAt,
		RefreshTokenHash: next.refreshHash, RefreshExpiresAt: out.RefreshExpiresAt, ID: row.ID})
	if err != nil {
		return Refreshed{}, false, fmt.Errorf("session: rotate: %w", err)
	}
	if n != 1 {
		return Refreshed{}, false, errors.New("session: rotate: locked session not updated")
	}
	user, ok, err := accounts.Get(ctx, tx, row.UserID)
	if err != nil || !ok {
		return Refreshed{}, false, errors.Join(errors.New("session: read account"), err)
	}
	return Refreshed{Issued: out, User: user}, false, nil
}

// refreshRefusal returns why a locked session cannot be refreshed, or "" if it can.
func refreshRefusal(row sqlc.LockSessionByRefreshTokenHashRow, now time.Time) string {
	switch {
	case row.RevokedAt != nil:
		return reasonSessionRevoked
	case !row.RefreshExpiresAt.After(now) || !row.AbsoluteExpiresAt.After(now):
		return reasonSessionExpired
	case row.UserStatus != accounts.StatusActive || row.UserEmailVerifiedAt == nil:
		return ReasonAccountInactive
	}
	return ""
}

// reuse is TRD 8.4 step 3: the token is no longer current. Within retention, revoke the session
// it belonged to (L4a) and record it (L5). Past retention, nothing happens.
func (s *Service) reuse(ctx context.Context, tx pgx.Tx, hash []byte, c Client) error {
	q := sqlc.New(tx)
	r, err := q.FindReusedRefreshToken(ctx, hash)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil // the pre-check saw it, but it has since passed retain_until
	}
	if err != nil {
		return fmt.Errorf("session: reuse lookup: %w", err)
	}
	n, err := q.RevokeSessionByID(ctx, sqlc.RevokeSessionByIDParams{Reason: ptr(ReasonRefreshReuse), ID: r.SessionID})
	if err != nil {
		return fmt.Errorf("session: revoke: %w", err)
	}
	if err := recordRefreshFailure(ctx, tx, r.UserID, r.SessionID, ReasonRefreshReuse, c); err != nil {
		return err
	}
	return recordRevoke(ctx, tx, r.UserID, r.SessionID, ReasonRefreshReuse, n, c)
}

// --- logout (TRD 7.7) ------------------------------------------------------------------------

// Logout revokes the caller's current session only (AC-18). If the session was revoked between
// authentication and this transaction, it returns ErrUnauthorized and writes nothing.
func (s *Service) Logout(ctx context.Context, p Principal, c Client) error {
	return s.tx.Run(ctx, func(ctx context.Context, tx pgx.Tx) error {
		n, err := sqlc.New(tx).RevokeSession(ctx, sqlc.RevokeSessionParams{Reason: ptr(ReasonLogout), ID: p.SessionID, UserID: p.UserID})
		if err != nil {
			return fmt.Errorf("session: logout: %w", err)
		}
		if n == 0 {
			return ErrUnauthorized
		}
		if err := audit.Record(ctx, tx, audit.Event{Action: "auth.logout", Outcome: audit.Success,
			ActorUserID: &p.UserID, TargetUserID: &p.UserID, SessionID: &p.SessionID,
			IP: c.IP, UserAgent: c.UserAgent, RequestID: c.RequestID}); err != nil {
			return err
		}
		return recordRevoke(ctx, tx, p.UserID, p.SessionID, ReasonLogout, n, c)
	})
}

// --- audit helpers ---------------------------------------------------------------------------

func recordRevoke(ctx context.Context, tx pgx.Tx, user, sessionID uuid.UUID, reason string, n int64, c Client) error {
	if n == 0 {
		return nil
	}
	return audit.Record(ctx, tx, audit.Event{Action: "auth.session.revoke", Outcome: audit.Success,
		TargetUserID: &user, SessionID: &sessionID, IP: c.IP, UserAgent: c.UserAgent, RequestID: c.RequestID,
		Metadata: map[string]string{"reason": reason, "count": strconv.FormatInt(n, 10)}})
}

func recordRefreshFailure(ctx context.Context, tx pgx.Tx, user, sessionID uuid.UUID, reason string, c Client) error {
	return audit.Record(ctx, tx, audit.Event{Action: "auth.session.refresh", Outcome: audit.Failure, Reason: reason,
		TargetUserID: &user, SessionID: &sessionID, IP: c.IP, UserAgent: c.UserAgent, RequestID: c.RequestID})
}

func earliest(a, b time.Time) time.Time {
	if b.Before(a) {
		return b
	}
	return a
}

func addrPtr(a netip.Addr) *netip.Addr {
	if !a.IsValid() {
		return nil
	}
	return &a
}

func ptr[T any](v T) *T { return &v }
