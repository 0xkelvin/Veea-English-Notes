package admin

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"fmt"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/audit"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/auth/session"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/identity"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/identity/accounts"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/lifecycle"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/db"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/db/sqlc"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/metrics"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/ratelimit"
)

// Errors mapped by the HTTP layer (TRD 06 §6.9).
var (
	ErrForbidden          = errors.New("admin: actor is not staff")          // 403 forbidden
	ErrTargetNotPermitted = errors.New("admin: target not permitted")        // 403 target_not_permitted
	ErrNotFound           = errors.New("admin: not found")                   // 404 not_found
	ErrLifecycleConflict  = errors.New("admin: lifecycle revision conflict") // 409 lifecycle_conflict
	ErrRoleConflict       = errors.New("admin: role revision conflict")      // 409 role_conflict
	ErrInvalidPageToken   = errors.New("admin: invalid page token")          // 400 invalid_request
)

// StatusConflictError is 409 status_conflict: the target's status does not allow the action.
type StatusConflictError struct{ Status string }

func (e *StatusConflictError) Error() string { return "admin: status conflict: " + e.Status }

// Revocation reasons written by this package (migration 00012).
const (
	ReasonAdminRevoked     = "admin_revoked"
	ReasonAccountSuspended = "account_suspended"
	ReasonRoleChange       = "role_change"
)

// Rate limits per acting user, outside every transaction (TRD 01 §7.1 rule 6).
var (
	readRule  = ratelimit.Rule{Name: "admin_read_user_1m", Limit: 120, Window: time.Minute}
	writeRule = ratelimit.Rule{Name: "admin_write_user_1m", Limit: 30, Window: time.Minute}
)

// Reason is a mutation's fixed code and optional validated ticket reference.
type Reason struct {
	Code      string
	TicketRef *string
}

// Service serves the /v1/admin routes. It is safe for concurrent use.
type Service struct {
	pool    *pgxpool.Pool
	tx      db.Tx
	limiter *ratelimit.Limiter
	email   *identity.EmailHMAC
	metrics *metrics.Metrics
}

// New returns a Service.
func New(pool *pgxpool.Pool, email *identity.EmailHMAC, m *metrics.Metrics, onRetry func(string)) *Service {
	return &Service{pool: pool, tx: db.Tx{Pool: pool, OnRetry: onRetry}, limiter: ratelimit.NewLimiter(pool), email: email, metrics: m}
}

// Detail is the administrative view of one account (TRD 06 §6.4).
type Detail struct {
	User               sqlc.User
	LiveSessions       int64
	LastSeenAt         *time.Time
	DeletionAcceptedAt *time.Time
	AllowedActions     []string
	AssignableRoles    []string
}

// Filter is a validated list request. Email is normalized; EmailPrefix is NFC-lowercased and
// not yet escaped.
type Filter struct {
	Email       *identity.Email
	EmailPrefix *string
	Role        *string
	Status      *string
	Limit       int
	PageToken   string
}

// Page is one keyset page.
type Page struct {
	Items         []sqlc.AdminListUsersRow
	NextPageToken *string
}

// --- reads (TRD 06 §8.3) -----------------------------------------------------------------------

// read runs fn in one REPEATABLE READ transaction that first revalidates the acting session,
// account standing and staff role in the same snapshot, then commits fn's audit event before
// any data is returned. op names the action for metrics and denial audit.
func (s *Service) read(ctx context.Context, p session.Principal, op string, target *uuid.UUID, c session.Client,
	fn func(ctx context.Context, q *sqlc.Queries, actorRole string) (audit.Event, error)) error {
	if err := s.allow(ctx, p, readRule); err != nil {
		return err
	}
	err := func() error {
		tx, err := s.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead})
		if err != nil {
			return fmt.Errorf("admin: begin read: %w", err)
		}
		defer tx.Rollback(context.WithoutCancel(ctx))
		q := sqlc.New(tx)
		role, err := q.AdminActingSessionLive(ctx, sqlc.AdminActingSessionLiveParams{SessionID: p.SessionID, UserID: p.UserID})
		if errors.Is(err, pgx.ErrNoRows) {
			return session.ErrUnauthorized
		}
		if err != nil {
			return fmt.Errorf("admin: revalidate actor: %w", err)
		}
		if !IsStaff(role) {
			return ErrForbidden
		}
		ev, err := fn(ctx, q, role)
		if err != nil {
			return err
		}
		ev.Outcome, ev.ActorUserID, ev.SessionID = audit.Success, &p.UserID, &p.SessionID
		ev.IP, ev.UserAgent, ev.RequestID = c.IP, c.UserAgent, c.RequestID
		if err := audit.Record(ctx, tx, ev); err != nil {
			return err
		}
		return tx.Commit(ctx)
	}()
	s.finish(ctx, p, op, err, target, c)
	return err
}

// List returns one page of accounts the actor may view. An Admin sees role user only.
func (s *Service) List(ctx context.Context, p session.Principal, f Filter, c session.Client) (Page, error) {
	var page Page
	err := s.read(ctx, p, "search", nil, c, func(ctx context.Context, q *sqlc.Queries, actorRole string) (audit.Event, error) {
		page = Page{}
		params := sqlc.AdminListUsersParams{Role: f.Role, Status: f.Status, PageLimit: int32(f.Limit + 1)}
		if actorRole == accounts.RoleAdmin {
			if f.Role != nil && *f.Role != accounts.RoleUser {
				return audit.Event{}, ErrTargetNotPermitted
			}
			params.Role = ptr(accounts.RoleUser)
		}
		if f.Email != nil {
			params.Email = &f.Email.Normalized
		}
		if f.EmailPrefix != nil {
			params.EmailPrefix = ptr(escapeLike(*f.EmailPrefix))
		}
		fp := fingerprint(f)
		if f.PageToken != "" {
			at, id, ok := decodePageToken(f.PageToken, fp)
			if !ok {
				return audit.Event{}, ErrInvalidPageToken
			}
			params.AfterCreatedAt, params.AfterID = &at, &id
		}
		rows, err := q.AdminListUsers(ctx, params)
		if err != nil {
			return audit.Event{}, fmt.Errorf("admin: list: %w", err)
		}
		if len(rows) > f.Limit {
			rows = rows[:f.Limit]
			last := rows[len(rows)-1]
			page.NextPageToken = ptr(encodePageToken(last.CreatedAt, last.ID, fp))
		}
		page.Items = rows
		ev := audit.Event{Action: "admin.user.search", Metadata: map[string]string{
			"filters": filterNames(f), "result_count": strconv.Itoa(len(rows)), "page": "first"}}
		if f.PageToken != "" {
			ev.Metadata["page"] = "next"
		}
		if f.Email != nil && s.email != nil {
			ev.EmailHMAC = s.email.Current(*f.Email) // never the address or a prefix
		}
		return ev, nil
	})
	return page, err
}

// Get returns one account's administrative detail.
func (s *Service) Get(ctx context.Context, p session.Principal, id uuid.UUID, c session.Client) (Detail, error) {
	var d Detail
	err := s.read(ctx, p, "view", &id, c, func(ctx context.Context, q *sqlc.Queries, actorRole string) (audit.Event, error) {
		t, err := getUser(ctx, q, id)
		if err != nil {
			return audit.Event{}, err
		}
		if !Permits(actorRole, p.UserID, t.Role, t.ID, ActView) {
			return audit.Event{}, ErrTargetNotPermitted
		}
		if d, err = buildDetail(ctx, q, actorRole, p.UserID, t); err != nil {
			return audit.Event{}, err
		}
		return audit.Event{Action: "admin.user.view", TargetUserID: &t.ID}, nil
	})
	return d, err
}

// ListSessions returns the target's live sessions (TRD 02 §2.1 predicate, no is_current).
func (s *Service) ListSessions(ctx context.Context, p session.Principal, id uuid.UUID, c session.Client) ([]sqlc.AdminListLiveSessionsRow, error) {
	var rows []sqlc.AdminListLiveSessionsRow
	err := s.read(ctx, p, "sessions_view", &id, c, func(ctx context.Context, q *sqlc.Queries, actorRole string) (audit.Event, error) {
		t, err := getUser(ctx, q, id)
		if err != nil {
			return audit.Event{}, err
		}
		if !Permits(actorRole, p.UserID, t.Role, t.ID, ActSessions) {
			return audit.Event{}, ErrTargetNotPermitted
		}
		if rows, err = q.AdminListLiveSessions(ctx, t.ID); err != nil {
			return audit.Event{}, fmt.Errorf("admin: list sessions: %w", err)
		}
		return audit.Event{Action: "admin.user.sessions.view", TargetUserID: &t.ID}, nil
	})
	return rows, err
}

// --- writes (TRD 06 §8.2) ----------------------------------------------------------------------

// errNoop ends a write whose end state already holds: 200, no change, no event.
var errNoop = errors.New("admin: no-op")

// write runs fn in one READ COMMITTED transaction:
//
//	[L2s guard] → L3 actor and target in UUID order → actor standing and staff role →
//	L4a acting session → fn (target checks, mutation, L4b, L5 audit, response detail).
//
// The actor is revalidated from its locked row, so a demotion, suspension or logout that
// commits first makes this write fail (403 or 401) instead of acting on a stale role.
func (s *Service) write(ctx context.Context, p session.Principal, op string, targetID uuid.UUID, guard bool, c session.Client,
	fn func(ctx context.Context, tx pgx.Tx, actor, target sqlc.User) error) error {
	if err := s.allow(ctx, p, writeRule); err != nil {
		return err
	}
	err := s.tx.Run(ctx, func(ctx context.Context, tx pgx.Tx) error {
		if guard {
			if err := accounts.LockSuperAdminGuard(ctx, tx); err != nil { // L2s
				return err
			}
		}
		actor, actorOK, target, targetOK, err := accounts.LockPair(ctx, tx, p.UserID, targetID) // L3
		if err != nil {
			return err
		}
		if !actorOK || !accounts.InGoodStanding(actor) {
			return session.ErrUnauthorized
		}
		if _, ok, err := session.LockActing(ctx, tx, p.UserID, p.SessionID); err != nil { // L4a
			return err
		} else if !ok {
			return session.ErrUnauthorized
		}
		if !IsStaff(actor.Role) {
			return ErrForbidden
		}
		if !targetOK {
			return ErrNotFound
		}
		return fn(ctx, tx, actor, target)
	})
	s.finish(ctx, p, op, err, &targetID, c)
	if errors.Is(err, errNoop) {
		return nil
	}
	return err
}

// RevokeSessions revokes one owned session of the target, or all of them when sessionID is nil.
// It never blocks a later sign-in. A retained already-revoked row counts 0 and writes no event.
func (s *Service) RevokeSessions(ctx context.Context, p session.Principal, targetID uuid.UUID, sessionID *uuid.UUID, r Reason, c session.Client) (int64, error) {
	var n int64
	err := s.write(ctx, p, "sessions_revoke", targetID, false, c, func(ctx context.Context, tx pgx.Tx, actor, t sqlc.User) error {
		n = 0
		if !Permits(actor.Role, actor.ID, t.Role, t.ID, ActSessions) {
			return ErrTargetNotPermitted
		}
		q := sqlc.New(tx)
		reason := ReasonAdminRevoked
		var err error
		if sessionID != nil {
			if _, err := q.LockOwnedSession(ctx, sqlc.LockOwnedSessionParams{ID: *sessionID, UserID: t.ID}); errors.Is(err, pgx.ErrNoRows) {
				return ErrNotFound // unknown and foreign sessions are indistinguishable
			} else if err != nil {
				return fmt.Errorf("admin: lock target session: %w", err)
			}
			n, err = q.RevokeSession(ctx, sqlc.RevokeSessionParams{Reason: &reason, ID: *sessionID, UserID: t.ID})
		} else {
			n, err = q.RevokeAllSessionsForUser(ctx, sqlc.RevokeAllSessionsForUserParams{Reason: &reason, UserID: t.ID})
		}
		if err != nil {
			return fmt.Errorf("admin: revoke: %w", err)
		}
		if n == 0 {
			return errNoop
		}
		revoke := s.event("auth.session.revoke", p, t.ID, c, map[string]string{"reason": reason, "count": count(n)})
		command := s.event("admin.sessions.revoke", p, t.ID, c, map[string]string{"count": count(n)})
		command.Reason = r.Code
		if sessionID != nil {
			revoke.Metadata["target_session_id"] = sessionID.String()
			command.Metadata["target_session_id"] = sessionID.String()
		}
		addTicket(&command, r)
		return record(ctx, tx, revoke, command)
	})
	if err == nil {
		s.metrics.SessionsRevoked(ReasonAdminRevoked, n)
	}
	return n, err
}

// Transition suspends or reinstates the target (TRD 06 §5.2, §5.3).
func (s *Service) Transition(ctx context.Context, p session.Principal, targetID uuid.UUID, action string, expected int64, r Reason, c session.Client) (Detail, error) {
	act := ActSuspend
	if action == "reinstate" {
		act = ActReinstate
	}
	var d Detail
	var revoked int64
	err := s.write(ctx, p, action, targetID, true, c, func(ctx context.Context, tx pgx.Tx, actor, t sqlc.User) error {
		revoked = 0
		if !Permits(actor.Role, actor.ID, t.Role, t.ID, act) {
			return ErrTargetNotPermitted
		}
		q := sqlc.New(tx)
		noop := func() error {
			var err error
			if d, err = buildDetail(ctx, q, actor.Role, actor.ID, t); err != nil {
				return err
			}
			return errNoop
		}
		if act == ActSuspend {
			switch {
			case t.Status == accounts.StatusSuspended:
				return noop()
			case t.Status != accounts.StatusActive && t.Status != accounts.StatusDeactivated:
				return &StatusConflictError{Status: t.Status}
			case t.LifecycleRevision != expected:
				return ErrLifecycleConflict
			}
			// The actor is another active Super Admin or the target is a user, so this always
			// passes; it is the shared guarded recheck all the same.
			if err := accounts.CheckNotLastSuperAdmin(ctx, tx, t); err != nil {
				return err
			}
			if err := accounts.Suspend(ctx, tx, t.ID, actor.ID, r.Code, r.TicketRef); err != nil {
				return err
			}
			reason := ReasonAccountSuspended
			n, err := q.RevokeAllSessionsForUser(ctx, sqlc.RevokeAllSessionsForUserParams{Reason: &reason, UserID: t.ID}) // L4b
			if err != nil {
				return fmt.Errorf("admin: revoke: %w", err)
			}
			revoked = n
			if err := lifecycle.CancelExports(ctx, tx, c, actor.ID, t.ID); err != nil {
				return err
			}
			command := s.event("admin.user.suspend", p, t.ID, c, map[string]string{
				"from_status": t.Status, "lifecycle_revision": count(t.LifecycleRevision + 1)})
			command.Reason = r.Code
			addTicket(&command, r)
			if err := record(ctx, tx, s.event("auth.session.revoke", p, t.ID, c, map[string]string{"reason": reason, "count": count(n)}), command); err != nil {
				return err
			}
		} else {
			switch {
			case t.Status == accounts.StatusPendingDeletion:
				return &StatusConflictError{Status: t.Status}
			case t.Status != accounts.StatusSuspended:
				return noop()
			case t.LifecycleRevision != expected:
				return ErrLifecycleConflict
			}
			if err := accounts.Reinstate(ctx, tx, t.ID); err != nil {
				return err
			}
			if err := lifecycle.CancelExports(ctx, tx, c, actor.ID, t.ID); err != nil { // exports made while suspended
				return err
			}
			command := s.event("admin.user.reinstate", p, t.ID, c, map[string]string{
				"to_status": deref(t.ResumeStatus), "lifecycle_revision": count(t.LifecycleRevision + 1)})
			command.Reason = r.Code
			addTicket(&command, r)
			if err := record(ctx, tx, command); err != nil {
				return err
			}
		}
		fresh, err := getUser(ctx, q, t.ID)
		if err != nil {
			return err
		}
		d, err = buildDetail(ctx, q, actor.Role, actor.ID, fresh)
		return err
	})
	if err == nil {
		s.metrics.SessionsRevoked(ReasonAccountSuspended, revoked)
	}
	return d, err
}

// ChangeRole sets the target's role (TRD 06 §5.1). Promotion revokes every target session;
// demotion keeps them and takes effect on the next request.
func (s *Service) ChangeRole(ctx context.Context, p session.Principal, targetID uuid.UUID, role string, expected int64, r Reason, c session.Client) (Detail, error) {
	var d Detail
	var revoked int64
	err := s.write(ctx, p, "role_change", targetID, true, c, func(ctx context.Context, tx pgx.Tx, actor, t sqlc.User) error {
		revoked = 0
		q := sqlc.New(tx)
		if !Permits(actor.Role, actor.ID, t.Role, t.ID, ActRole) {
			return ErrTargetNotPermitted
		}
		if t.Role == role {
			var err error
			if d, err = buildDetail(ctx, q, actor.Role, actor.ID, t); err != nil {
				return err
			}
			return errNoop
		}
		if !slices.Contains(AssignableRoles(actor.Role, actor.ID, t.Role, t.ID), role) {
			return ErrTargetNotPermitted // for example a Super Admin stepping down to admin
		}
		promotion := accounts.Rank(role) > accounts.Rank(t.Role)
		switch {
		case t.Status == accounts.StatusPendingDeletion, promotion && !accounts.InGoodStanding(t):
			return &StatusConflictError{Status: t.Status}
		case t.RoleRevision != expected:
			return ErrRoleConflict
		}
		if t.Role == accounts.RoleSuperAdmin {
			if err := accounts.CheckNotLastSuperAdmin(ctx, tx, t); err != nil {
				return err
			}
		}
		if err := accounts.SetRole(ctx, tx, t.ID, role); err != nil {
			return err
		}
		if role == accounts.RoleSuperAdmin { // backstop for the TRD 08 marker; idempotent
			if err := q.MarkSuperAdminBootstrapped(ctx); err != nil {
				return fmt.Errorf("admin: bootstrap marker: %w", err)
			}
		}
		var events []audit.Event
		if promotion {
			reason := ReasonRoleChange
			n, err := q.RevokeAllSessionsForUser(ctx, sqlc.RevokeAllSessionsForUserParams{Reason: &reason, UserID: t.ID}) // L4b
			if err != nil {
				return fmt.Errorf("admin: revoke: %w", err)
			}
			if revoked = n; n > 0 {
				events = append(events, s.event("auth.session.revoke", p, t.ID, c, map[string]string{"reason": reason, "count": count(n)}))
			}
		}
		command := s.event("admin.role.change", p, t.ID, c, map[string]string{
			"from_role": t.Role, "to_role": role, "role_revision": count(t.RoleRevision + 1)})
		command.Reason = r.Code
		addTicket(&command, r)
		if err := record(ctx, tx, append(events, command)...); err != nil {
			return err
		}
		fresh, err := getUser(ctx, q, t.ID)
		if err != nil {
			return err
		}
		d, err = buildDetail(ctx, q, actor.Role, actor.ID, fresh)
		return err
	})
	if err == nil {
		s.metrics.SessionsRevoked(ReasonRoleChange, revoked)
	}
	return d, err
}

// --- shared helpers ----------------------------------------------------------------------------

func (s *Service) allow(ctx context.Context, p session.Principal, rule ratelimit.Rule) error {
	d, err := s.limiter.Allow(ctx, ratelimit.Check{Rule: rule, Subject: ratelimit.UserSubject(p.UserID)})
	if err != nil {
		return err
	}
	return d.Err()
}

// finish counts the request and records an authorization refusal.
func (s *Service) finish(ctx context.Context, p session.Principal, op string, err error, target *uuid.UUID, c session.Client) {
	var status *StatusConflictError
	var limited *ratelimit.Error
	switch {
	case err == nil:
		s.metrics.AdminAction(op, "success")
	case errors.Is(err, errNoop):
		s.metrics.AdminAction(op, "noop")
	case errors.Is(err, ErrForbidden), errors.Is(err, ErrTargetNotPermitted), errors.Is(err, accounts.ErrLastSuperAdmin):
		s.metrics.AdminAction(op, "denied")
		_ = s.RecordDenied(ctx, p, op, err, target, c)
	case errors.Is(err, ErrLifecycleConflict), errors.Is(err, ErrRoleConflict), errors.As(err, &status):
		s.metrics.AdminAction(op, "conflict")
	case errors.As(err, &limited), errors.Is(err, session.ErrUnauthorized):
	default:
		s.metrics.AdminAction(op, "error")
	}
}

// RecordDenied writes admin.access.denied for an authorization refusal, at most once per acting
// session, operation and reason per minute. The dedupe counter and the event commit together in
// one short transaction after the refused one, detached from the request's cancellation.
func (s *Service) RecordDenied(ctx context.Context, p session.Principal, op string, err error, target *uuid.UUID, c session.Client) error {
	reason := ""
	switch {
	case errors.Is(err, ErrForbidden):
		reason = "insufficient_role"
	case errors.Is(err, ErrTargetNotPermitted):
		reason = "target_not_permitted"
	case errors.Is(err, accounts.ErrLastSuperAdmin):
		reason = "last_super_admin"
	default:
		return nil
	}
	ctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 2*time.Second)
	defer cancel()
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	row, err := sqlc.New(tx).IncrementRateLimitWindow(ctx, sqlc.IncrementRateLimitWindowParams{
		Key: "admin_denied_audit:" + op + ":" + reason + ":session:" + p.SessionID.String(), WindowSeconds: 60})
	if err != nil {
		return err
	}
	if row.Count != 1 {
		return nil
	}
	ev := audit.Event{Action: "admin.access.denied", Outcome: audit.Failure, Reason: reason,
		ActorUserID: &p.UserID, TargetUserID: target, SessionID: &p.SessionID,
		IP: c.IP, UserAgent: c.UserAgent, RequestID: c.RequestID, Metadata: map[string]string{"operation": op}}
	if err := audit.Record(ctx, tx, ev); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

func (s *Service) event(action string, p session.Principal, target uuid.UUID, c session.Client, meta map[string]string) audit.Event {
	return audit.Event{Action: action, Outcome: audit.Success, ActorUserID: &p.UserID, TargetUserID: &target,
		SessionID: &p.SessionID, IP: c.IP, UserAgent: c.UserAgent, RequestID: c.RequestID, Metadata: meta}
}

func record(ctx context.Context, tx pgx.Tx, events ...audit.Event) error {
	for _, e := range events {
		if err := audit.Record(ctx, tx, e); err != nil {
			return err
		}
	}
	return nil
}

func addTicket(e *audit.Event, r Reason) {
	if r.TicketRef != nil {
		e.Metadata["ticket_ref"] = *r.TicketRef
	}
}

func getUser(ctx context.Context, q *sqlc.Queries, id uuid.UUID) (sqlc.User, error) {
	u, err := q.GetUserByID(ctx, id)
	if errors.Is(err, pgx.ErrNoRows) {
		return sqlc.User{}, ErrNotFound
	}
	if err != nil {
		return sqlc.User{}, fmt.Errorf("admin: get user: %w", err)
	}
	return u, nil
}

// buildDetail projects t for an actor, computing the permitted actions at this snapshot.
func buildDetail(ctx context.Context, q *sqlc.Queries, actorRole string, actorID uuid.UUID, t sqlc.User) (Detail, error) {
	d := Detail{User: t, AllowedActions: []string{}, AssignableRoles: []string{}}
	sum, err := q.AdminSessionSummary(ctx, t.ID)
	if err != nil {
		return d, fmt.Errorf("admin: session summary: %w", err)
	}
	d.LiveSessions = sum.LiveCount
	if sum.HasSessions {
		at := sum.LastSeenAt.UTC()
		d.LastSeenAt = &at
	}
	if t.Status == accounts.StatusPendingDeletion {
		at, err := q.AcceptedDeletionAt(ctx, &t.ID)
		if err == nil {
			at = at.UTC()
			d.DeletionAcceptedAt = &at
		} else if !errors.Is(err, pgx.ErrNoRows) {
			return d, fmt.Errorf("admin: deletion: %w", err)
		}
	}
	others := int64(1)
	if accounts.IsActiveSuperAdmin(t) {
		if others, err = q.CountOtherActiveSuperAdmins(ctx, t.ID); err != nil {
			return d, fmt.Errorf("admin: count super admins: %w", err)
		}
	}
	if t.Status != accounts.StatusPendingDeletion {
		for _, r := range AssignableRoles(actorRole, actorID, t.Role, t.ID) {
			promotion := accounts.Rank(r) > accounts.Rank(t.Role)
			if (promotion && !accounts.InGoodStanding(t)) || (t.Role == accounts.RoleSuperAdmin && others == 0) {
				continue
			}
			d.AssignableRoles = append(d.AssignableRoles, r)
		}
	}
	if Permits(actorRole, actorID, t.Role, t.ID, ActSuspend) && (t.Status == accounts.StatusActive || t.Status == accounts.StatusDeactivated) {
		d.AllowedActions = append(d.AllowedActions, "suspend")
	}
	if Permits(actorRole, actorID, t.Role, t.ID, ActReinstate) && t.Status == accounts.StatusSuspended {
		d.AllowedActions = append(d.AllowedActions, "reinstate")
	}
	if len(d.AssignableRoles) > 0 {
		d.AllowedActions = append(d.AllowedActions, "change_role")
	}
	if Permits(actorRole, actorID, t.Role, t.ID, ActSessions) {
		d.AllowedActions = append(d.AllowedActions, "view_sessions", "revoke_sessions")
	}
	return d, nil
}

// --- page tokens (TRD 06 §6.3) -----------------------------------------------------------------

const pageTokenPrefix = "a1."

// fingerprint binds a page token to the filters it was issued for.
func fingerprint(f Filter) [8]byte {
	var b strings.Builder
	if f.Email != nil {
		b.WriteString("email=" + f.Email.Normalized)
	}
	b.WriteString("\x00prefix=" + deref(f.EmailPrefix) + "\x00role=" + deref(f.Role) + "\x00status=" + deref(f.Status))
	sum := sha256.Sum256([]byte(b.String()))
	var out [8]byte
	copy(out[:], sum[:8])
	return out
}

func encodePageToken(at time.Time, id uuid.UUID, fp [8]byte) string {
	var raw [32]byte
	binary.BigEndian.PutUint64(raw[:8], uint64(at.UnixMicro()))
	copy(raw[8:24], id[:])
	copy(raw[24:], fp[:])
	return pageTokenPrefix + base64.RawURLEncoding.EncodeToString(raw[:])
}

func decodePageToken(tok string, fp [8]byte) (time.Time, uuid.UUID, bool) {
	rest, ok := strings.CutPrefix(tok, pageTokenPrefix)
	if !ok || len(rest) != 43 {
		return time.Time{}, uuid.Nil, false
	}
	raw, err := base64.RawURLEncoding.DecodeString(rest)
	if err != nil || len(raw) != 32 || [8]byte(raw[24:]) != fp {
		return time.Time{}, uuid.Nil, false
	}
	id, err := uuid.FromBytes(raw[8:24])
	if err != nil {
		return time.Time{}, uuid.Nil, false
	}
	return time.UnixMicro(int64(binary.BigEndian.Uint64(raw[:8]))).UTC(), id, true
}

// filterNames lists the filter kinds used, never their values.
func filterNames(f Filter) string {
	var names []string
	if f.Email != nil {
		names = append(names, "email")
	}
	if f.EmailPrefix != nil {
		names = append(names, "email_prefix")
	}
	if f.Role != nil {
		names = append(names, "role")
	}
	if f.Status != nil {
		names = append(names, "status")
	}
	if len(names) == 0 {
		return "none"
	}
	return strings.Join(names, ",")
}

// escapeLike makes s a literal LIKE prefix under the default backslash escape.
func escapeLike(s string) string {
	return strings.NewReplacer(`\`, `\\`, `%`, `\%`, `_`, `\_`).Replace(s)
}

func count(n int64) string { return strconv.FormatInt(n, 10) }

func ptr[T any](v T) *T { return &v }

func deref(s *string) string {
	if s == nil {
		return ""
	}
	return *s
}
