// Package admin implements the RBAC user administration of TRD 06: the authorization matrix,
// admin reads and mutations, and first Super Admin bootstrap.
//
// policy.go is pure: no database access. The service always evaluates it against the actor and
// target rows it has locked (or read in its snapshot), never against Principal.Role alone.
package admin

import (
	"regexp"
	"slices"
	"strings"

	"github.com/google/uuid"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/identity/accounts"
)

// Action is one kind of admin act (TRD 06 §3.1).
type Action string

const (
	ActView      Action = "view"      // list, search and account detail
	ActSessions  Action = "sessions"  // view and revoke the target's sessions
	ActSuspend   Action = "suspend"   // lifecycle transition
	ActReinstate Action = "reinstate" // lifecycle transition
	ActRole      Action = "role"      // change role
)

// IsStaff reports whether role may use /v1/admin at all.
func IsStaff(role string) bool { return role == accounts.RoleAdmin || role == accounts.RoleSuperAdmin }

// Permits is the approved TRD 06 matrix:
//
//   - A User has no admin access.
//   - An Admin may view and manage only accounts whose role is user, never itself, and never
//     changes roles.
//   - A Super Admin may act on every other account at every role level. On itself it may only
//     view, and step down to user (AssignableRoles; guarded by the last-Super-Admin check).
func Permits(actorRole string, actorID uuid.UUID, targetRole string, targetID uuid.UUID, a Action) bool {
	self := actorID == targetID
	switch actorRole {
	case accounts.RoleSuperAdmin:
		if self {
			return a == ActView || a == ActRole
		}
		return true
	case accounts.RoleAdmin:
		return !self && targetRole == accounts.RoleUser && a != ActRole
	}
	return false
}

// AssignableRoles lists the roles actor may give target, ignoring target state. Only a Super
// Admin assigns roles; on itself the sole option is stepping down to user.
func AssignableRoles(actorRole string, actorID uuid.UUID, targetRole string, targetID uuid.UUID) []string {
	if actorRole != accounts.RoleSuperAdmin {
		return nil
	}
	if actorID == targetID {
		if targetRole == accounts.RoleSuperAdmin {
			return []string{accounts.RoleUser}
		}
		return nil
	}
	var out []string
	for _, r := range []string{accounts.RoleUser, accounts.RoleAdmin, accounts.RoleSuperAdmin} {
		if r != targetRole {
			out = append(out, r)
		}
	}
	return out
}

// Reason codes per mutation (TRD 06 §6.8). They are stored in audit_events.reason, which
// survives purge minimization.
var reasonCodes = map[string][]string{
	"suspend":     {"abuse", "fraud", "account_compromise", "policy_violation", "legal_request", "owner_request", "other"},
	"reinstate":   {"appeal_upheld", "issue_resolved", "suspended_in_error", "other"},
	"role":        {"staffing_change", "access_review", "account_compromise", "other"},
	"sessions":    {"account_compromise", "owner_request", "security_review", "other"},
	"break_glass": {"lost_access", "account_compromise", "other"},
}

// ValidReason reports whether code is a reason for kind (suspend, reinstate, role, sessions,
// break_glass).
func ValidReason(kind, code string) bool { return slices.Contains(reasonCodes[kind], code) }

var ticketPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,39}$`)

// ValidTicketRef reports whether ref is an acceptable external ticket reference: a short
// identifier with no spaces or @, so it cannot carry an address or prose, and nothing shaped
// like a token, which the audit writer would refuse.
func ValidTicketRef(ref string) bool {
	if !ticketPattern.MatchString(ref) {
		return false
	}
	lower := strings.ToLower(ref)
	for _, p := range []string{"vct_", "vat_", "vrt_", "vop_"} { // the audit writer's prefixes
		if strings.Contains(lower, p) {
			return false
		}
	}
	return true
}
