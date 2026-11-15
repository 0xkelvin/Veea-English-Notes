package admin

import (
	"context"
	"errors"
	"fmt"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/audit"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/identity"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/identity/accounts"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/db"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/db/sqlc"
)

// Bootstrap modes (TRD 06 §4.3). Break-glass exists only in the CLI.
const (
	ModeFirst      = "first"
	ModeBreakGlass = "break_glass"
)

// Bootstrap refusals. The CLI prints fixed messages for them, never an address.
var (
	ErrAlreadyProvisioned = errors.New("admin: an active super admin already exists")
	ErrIneligibleTarget   = errors.New("admin: target is not an active, verified account without the super_admin role")
	ErrInvalidBootstrap   = errors.New("admin: invalid bootstrap request")
)

// BootstrapRequest names one existing account by ID or by email.
type BootstrapRequest struct {
	UserID     *uuid.UUID
	Email      *identity.Email
	Mode       string
	ReasonCode string  // required for break_glass; "bootstrap" for first
	TicketRef  *string // optional, validated
}

// BootstrapResult reports what committed.
type BootstrapResult struct {
	UserID          uuid.UUID
	RoleRevision    int64
	RevokedSessions int64
}

// Bootstrap promotes an existing active, verified account to super_admin. Mode first requires
// that no active Super Admin exists. Mode break_glass skips only that check and must carry a
// reason. Both hold the Super Admin guard (L2s) and then the target row (L3), revoke every
// target session (role_change) and commit admin.role.bootstrap with no actor. It never creates
// an account or sets a password, and it never runs on API startup.
func Bootstrap(ctx context.Context, pool *pgxpool.Pool, req BootstrapRequest) (BootstrapResult, error) {
	if (req.UserID == nil) == (req.Email == nil) {
		return BootstrapResult{}, ErrInvalidBootstrap
	}
	switch req.Mode {
	case ModeFirst:
		if req.ReasonCode == "" {
			req.ReasonCode = "bootstrap"
		}
		if req.ReasonCode != "bootstrap" {
			return BootstrapResult{}, ErrInvalidBootstrap
		}
	case ModeBreakGlass:
		if !ValidReason("break_glass", req.ReasonCode) {
			return BootstrapResult{}, ErrInvalidBootstrap
		}
	default:
		return BootstrapResult{}, ErrInvalidBootstrap
	}
	if req.TicketRef != nil && !ValidTicketRef(*req.TicketRef) {
		return BootstrapResult{}, ErrInvalidBootstrap
	}
	var out BootstrapResult
	err := db.Tx{Pool: pool}.Run(ctx, func(ctx context.Context, tx pgx.Tx) error {
		out = BootstrapResult{}
		if err := accounts.LockSuperAdminGuard(ctx, tx); err != nil { // L2s
			return err
		}
		id := uuid.Nil
		if req.UserID != nil {
			id = *req.UserID
		} else {
			u, ok, err := accounts.Find(ctx, tx, *req.Email)
			if err != nil {
				return err
			}
			if !ok {
				return ErrIneligibleTarget
			}
			id = u.ID
		}
		u, ok, err := accounts.LockForNoKeyUpdate(ctx, tx, id) // L3
		if err != nil {
			return err
		}
		if !ok || !accounts.InGoodStanding(u) || u.Role == accounts.RoleSuperAdmin {
			return ErrIneligibleTarget
		}
		q := sqlc.New(tx)
		if req.Mode == ModeFirst {
			n, err := q.CountActiveSuperAdmins(ctx)
			if err != nil {
				return fmt.Errorf("admin: count super admins: %w", err)
			}
			if n > 0 {
				return ErrAlreadyProvisioned
			}
		}
		if err := accounts.SetRole(ctx, tx, u.ID, accounts.RoleSuperAdmin); err != nil {
			return err
		}
		if err := q.MarkSuperAdminBootstrapped(ctx); err != nil { // TRD 08 monitoring marker
			return fmt.Errorf("admin: bootstrap marker: %w", err)
		}
		reason := ReasonRoleChange
		n, err := q.RevokeAllSessionsForUser(ctx, sqlc.RevokeAllSessionsForUserParams{Reason: &reason, UserID: u.ID}) // L4b
		if err != nil {
			return fmt.Errorf("admin: revoke: %w", err)
		}
		out = BootstrapResult{UserID: u.ID, RoleRevision: u.RoleRevision + 1, RevokedSessions: n}
		if n > 0 {
			if err := audit.Record(ctx, tx, audit.Event{Action: "auth.session.revoke", Outcome: audit.Success, TargetUserID: &u.ID,
				Metadata: map[string]string{"reason": reason, "count": count(n)}}); err != nil {
				return err
			}
		}
		meta := map[string]string{"mode": req.Mode, "source": "cli", "from_role": u.Role, "role_revision": count(u.RoleRevision + 1)}
		if req.TicketRef != nil {
			meta["ticket_ref"] = *req.TicketRef
		}
		return audit.Record(ctx, tx, audit.Event{Action: "admin.role.bootstrap", Outcome: audit.Success, Reason: req.ReasonCode,
			TargetUserID: &u.ID, Metadata: meta})
	})
	return out, err
}
