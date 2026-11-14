package session

import (
	"context"
	"errors"
	"fmt"
	"strconv"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/audit"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/identity/accounts"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/db/sqlc"
)

var (
	ErrSessionNotFound = errors.New("session not found")
	ErrCurrentSession  = errors.New("current session not allowed")
)

const (
	ReasonUserRevoked = "user_revoked"
	ReasonLogoutAll   = "logout_all"
)

// ListLive rechecks caller eligibility in the same snapshot as the owned session projection.
func (s *Service) ListLive(ctx context.Context, p Principal) ([]sqlc.ListLiveSessionsRow, error) {
	rows, err := sqlc.New(s.pool).ListLiveSessions(ctx, sqlc.ListLiveSessionsParams{UserID: p.UserID, ActingSessionID: p.SessionID})
	if err != nil {
		return nil, fmt.Errorf("session: list: %w", err)
	}
	if len(rows) == 0 {
		return nil, ErrUnauthorized
	}
	return rows, nil
}

// RevokeOwned revokes one other owned session; a retained revoked row is a successful no-op.
func (s *Service) RevokeOwned(ctx context.Context, p Principal, target uuid.UUID, c Client) error {
	return s.manage(ctx, p, &target, c)
}

// LogoutAll serializes with issuance on L3. A later valid sign-in may create a new session.
func (s *Service) LogoutAll(ctx context.Context, p Principal, c Client) error {
	return s.manage(ctx, p, nil, c)
}

func (s *Service) manage(ctx context.Context, p Principal, target *uuid.UUID, c Client) error {
	reason := ReasonLogoutAll
	if target != nil {
		reason = ReasonUserRevoked
	}
	var n int64
	err := s.tx.Run(ctx, func(ctx context.Context, tx pgx.Tx) error {
		n = 0                                                        // a rolled-back attempt must not leak counts into the next attempt
		u, ok, err := accounts.LockForNoKeyUpdate(ctx, tx, p.UserID) // L3
		if err != nil {
			return err
		}
		if !ok || !accounts.InGoodStanding(u) {
			return ErrUnauthorized
		}
		if _, ok, err := LockActing(ctx, tx, p.UserID, p.SessionID); err != nil { // L4a
			return err
		} else if !ok {
			return ErrUnauthorized
		}
		q := sqlc.New(tx)
		if target != nil {
			if *target == p.SessionID {
				return ErrCurrentSession
			}
			if _, err := q.LockOwnedSession(ctx, sqlc.LockOwnedSessionParams{ID: *target, UserID: p.UserID}); err != nil {
				if errors.Is(err, pgx.ErrNoRows) {
					return ErrSessionNotFound // unknown and foreign identifiers are indistinguishable
				}
				return fmt.Errorf("session: lock target: %w", err)
			}
			n, err = q.RevokeSession(ctx, sqlc.RevokeSessionParams{ID: *target, UserID: p.UserID, Reason: &reason})
		} else {
			n, err = q.RevokeAllSessionsForUser(ctx, sqlc.RevokeAllSessionsForUserParams{UserID: p.UserID, Reason: &reason})
		}
		if err != nil {
			return fmt.Errorf("session: management revoke: %w", err)
		}
		if n == 0 {
			return nil
		}
		// L5: both command and revocation evidence commit with the actual state change.
		event := audit.Event{Action: "auth.session.revoke", Outcome: audit.Success,
			ActorUserID: &p.UserID, TargetUserID: &p.UserID, SessionID: &p.SessionID,
			IP: c.IP, UserAgent: c.UserAgent, RequestID: c.RequestID,
			Metadata: map[string]string{"reason": reason, "count": strconv.FormatInt(n, 10)}}
		if target == nil {
			command := event
			command.Action = "auth.logout.all"
			command.Metadata = map[string]string{"revoked_sessions": strconv.FormatInt(n, 10)}
			if err := audit.Record(ctx, tx, command); err != nil {
				return err
			}
		} else {
			event.Metadata["target_session_id"] = target.String()
		}
		return audit.Record(ctx, tx, event)
	})
	if err == nil {
		s.metrics.SessionsRevoked(reason, n)
	}
	return err
}
