package admin

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/audit"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/auth/session"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/entitlements"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/identity/accounts"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/db/sqlc"
)

// ChangePlan sets the target's plan (TRD 09 §6.2). plan premium needs endsAt, at most 366 days
// after the database time of the change; plan free revokes the active grant. Plans never touch
// roles, sessions or the lifecycle revision.
//
// Order inside the transaction (after write's L3 actor and target, actor revalidation and L4a):
// matrix → no-op (the end state already holds: 200, no event) → target state → expected
// entitlement revision → expiry range → close, prune, insert → revision + 1 → audit.
func (s *Service) ChangePlan(ctx context.Context, p session.Principal, targetID uuid.UUID, plan string, endsAt *time.Time, expected int64, r Reason, c session.Client) (Detail, error) {
	grantID, err := uuid.NewV7() // generated before the transaction (TRD 01 §7.1)
	if err != nil {
		return Detail{}, errors.New("admin: generate grant id")
	}
	if endsAt != nil {
		t := endsAt.UTC().Truncate(time.Microsecond) // PostgreSQL precision, so retries compare equal
		endsAt = &t
	}
	var d Detail
	err = s.write(ctx, p, "plan_change", targetID, false, c, func(ctx context.Context, tx pgx.Tx, actor, t sqlc.User) error {
		if !Permits(actor.Role, actor.ID, t.Role, t.ID, ActPlan) {
			return ErrTargetNotPermitted
		}
		q := sqlc.New(tx)
		cur, err := entitlements.Effective(ctx, q, t.ID) // database time, now
		if err != nil {
			return err
		}
		if (plan == entitlements.Free && cur.Name == entitlements.Free) ||
			(plan == entitlements.Premium && cur.Name == entitlements.Premium && endsAt != nil && cur.ExpiresAt.Equal(*endsAt)) {
			if d, err = buildDetail(ctx, q, actor.Role, actor.ID, t); err != nil {
				return err
			}
			return errNoop
		}
		switch {
		case t.Status == accounts.StatusPendingDeletion:
			return &StatusConflictError{Status: t.Status}
		case t.EntitlementRevision != expected:
			return ErrEntitlementConflict
		}
		var event audit.Event
		if plan == entitlements.Premium {
			now := cur.CheckedAt
			if endsAt == nil || !endsAt.After(now) || endsAt.Sub(now) > entitlements.MaxGrantDuration {
				return ErrInvalidExpiry
			}
			replaced := "replaced"
			n, err := q.CloseOpenEntitlementGrant(ctx, sqlc.CloseOpenEntitlementGrantParams{ClosedReason: &replaced, ClosedBy: &actor.ID, UserID: t.ID})
			if err != nil {
				return fmt.Errorf("admin: close grant: %w", err)
			}
			if err := q.PruneEntitlementHistory(ctx, sqlc.PruneEntitlementHistoryParams{UserID: t.ID, Keep: entitlements.MaxRetainedGrants - 1}); err != nil {
				return fmt.Errorf("admin: prune grants: %w", err)
			}
			if err := q.InsertEntitlementGrant(ctx, sqlc.InsertEntitlementGrantParams{ID: grantID, UserID: t.ID, StartsAt: now,
				EndsAt: *endsAt, GrantedBy: actor.ID, ReasonCode: r.Code, TicketRef: *r.TicketRef}); err != nil {
				return fmt.Errorf("admin: insert grant: %w", err)
			}
			event = s.event("admin.entitlement.grant", p, t.ID, c, map[string]string{
				"ends_at": endsAt.Format(time.RFC3339Nano), "replaced": fmt.Sprint(n > 0)})
		} else {
			revoked := "revoked"
			n, err := q.CloseOpenEntitlementGrant(ctx, sqlc.CloseOpenEntitlementGrantParams{ClosedReason: &revoked, ClosedBy: &actor.ID,
				CloseReasonCode: &r.Code, CloseTicketRef: r.TicketRef, UserID: t.ID})
			if err != nil {
				return fmt.Errorf("admin: revoke grant: %w", err)
			}
			if n != 1 {
				return errors.New("admin: revoke grant: no open grant for an effective Premium plan")
			}
			event = s.event("admin.entitlement.revoke", p, t.ID, c, map[string]string{})
		}
		if err := accounts.BumpEntitlementRevision(ctx, tx, t.ID); err != nil {
			return err
		}
		event.Reason = r.Code
		event.Metadata["entitlement_revision"] = count(t.EntitlementRevision + 1)
		addTicket(&event, r)
		if err := record(ctx, tx, event); err != nil {
			return err
		}
		fresh, err := getUser(ctx, q, t.ID)
		if err != nil {
			return err
		}
		d, err = buildDetail(ctx, q, actor.Role, actor.ID, fresh)
		return err
	})
	return d, err
}
