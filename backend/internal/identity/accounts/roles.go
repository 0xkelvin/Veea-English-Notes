package accounts

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"fmt"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/db/sqlc"
)

// Roles (TRD 06 section 2), in rank order.
const (
	RoleUser       = "user"
	RoleAdmin      = "admin"
	RoleSuperAdmin = "super_admin"
)

// Statuses besides StatusActive (TRD 04 section 3.1).
const (
	StatusSuspended       = "suspended"
	StatusDeactivated     = "deactivated"
	StatusPendingDeletion = "pending_deletion"
)

// ErrLastSuperAdmin refuses a transition that would leave no active Super Admin (TRD 06 §4).
var ErrLastSuperAdmin = errors.New("accounts: last active super admin")

// Rank orders roles: user < admin < super_admin. An unknown role ranks below user.
func Rank(role string) int {
	switch role {
	case RoleUser:
		return 1
	case RoleAdmin:
		return 2
	case RoleSuperAdmin:
		return 3
	}
	return 0
}

// IsActiveSuperAdmin reports whether u counts toward the TRD 06 §4.1 invariant.
func IsActiveSuperAdmin(u sqlc.User) bool {
	return u.Role == RoleSuperAdmin && InGoodStanding(u)
}

// guardKey is the one advisory key of the Super Admin guard, in its own namespace so it can
// never collide with the address locks (otp.LockAddresses) by construction of the input.
var guardKey = func() int64 {
	h := sha256.Sum256([]byte("veea:rbac:super_admin_guard"))
	return int64(binary.BigEndian.Uint64(h[:8]))
}()

// LockSuperAdminGuard takes L2s (TRD 06 §8.1): a transaction-scoped advisory lock that every
// transaction able to remove an active Super Admin holds until it commits. It comes after any
// L0 to L2b lock and before L3, and is never taken after a users row lock. Taken by role changes,
// bootstrap, admin suspension and reinstatement, owner deactivation and deletion acceptance.
func LockSuperAdminGuard(ctx context.Context, tx pgx.Tx) error {
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock($1)`, guardKey); err != nil {
		return fmt.Errorf("accounts: super admin guard: %w", err)
	}
	return nil
}

// CheckNotLastSuperAdmin is the guarded recheck. The caller holds L2s and subject's row at L3
// and is about to remove subject from the active Super Admin set. It returns ErrLastSuperAdmin
// when no other active Super Admin exists, and nil when subject is not one.
func CheckNotLastSuperAdmin(ctx context.Context, tx pgx.Tx, subject sqlc.User) error {
	if !IsActiveSuperAdmin(subject) {
		return nil
	}
	n, err := sqlc.New(tx).CountOtherActiveSuperAdmins(ctx, subject.ID)
	if err != nil {
		return fmt.Errorf("accounts: count super admins: %w", err)
	}
	if n == 0 {
		return ErrLastSuperAdmin
	}
	return nil
}

// LockPair locks the actor and target rows at L3 (FOR NO KEY UPDATE) in ascending UUID order,
// one row when they are the same account (TRD 06 §8.1). A missing row has ok false.
func LockPair(ctx context.Context, tx pgx.Tx, actorID, targetID uuid.UUID) (actor sqlc.User, actorOK bool, target sqlc.User, targetOK bool, err error) {
	if actorID == targetID {
		actor, actorOK, err = LockForNoKeyUpdate(ctx, tx, actorID)
		return actor, actorOK, actor, actorOK, err
	}
	first, second := actorID, targetID
	if bytes.Compare(first[:], second[:]) > 0 {
		first, second = second, first
	}
	a, aOK, err := LockForNoKeyUpdate(ctx, tx, first)
	if err != nil {
		return
	}
	b, bOK, err := LockForNoKeyUpdate(ctx, tx, second)
	if err != nil {
		return
	}
	if first == actorID {
		return a, aOK, b, bOK, nil
	}
	return b, bOK, a, aOK, nil
}

// Suspend stores the suspension on a row held at L3. reason is a fixed code, ticketRef the
// validated optional reference.
func Suspend(ctx context.Context, tx pgx.Tx, id, actor uuid.UUID, reason string, ticketRef *string) error {
	n, err := sqlc.New(tx).SuspendUser(ctx, sqlc.SuspendUserParams{Reason: &reason, TicketRef: ticketRef, ActorID: &actor, ID: id})
	if err != nil {
		return fmt.Errorf("accounts: suspend: %w", err)
	}
	if n != 1 {
		return errors.New("accounts: suspend: locked account not updated")
	}
	return nil
}

// Reinstate restores the saved state of a suspended row held at L3.
func Reinstate(ctx context.Context, tx pgx.Tx, id uuid.UUID) error {
	n, err := sqlc.New(tx).ReinstateUser(ctx, id)
	if err != nil {
		return fmt.Errorf("accounts: reinstate: %w", err)
	}
	if n != 1 {
		return errors.New("accounts: reinstate: locked account not updated")
	}
	return nil
}

// SetRole writes a new role and increments role_revision on a row held at L3.
func SetRole(ctx context.Context, tx pgx.Tx, id uuid.UUID, role string) error {
	if Rank(role) == 0 {
		return errors.New("accounts: set role: unknown role")
	}
	n, err := sqlc.New(tx).SetUserRole(ctx, sqlc.SetUserRoleParams{Role: role, ID: id})
	if err != nil {
		return fmt.Errorf("accounts: set role: %w", err)
	}
	if n != 1 {
		return errors.New("accounts: set role: locked account not updated")
	}
	return nil
}
