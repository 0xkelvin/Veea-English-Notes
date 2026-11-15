// Package entitlements is the Free/Premium plan model of TRD 09. Plans are separate from RBAC
// roles: a role never grants a plan and a plan never grants an administrative permission.
//
// This package only reads. Grants are written by the admin service (manual grants, TRD 09 §6)
// and removed by retention cleanup and the TRD 04 purge. TRD 10 gates new Premium cartridge
// downloads/installs; both plans retain the same TRD 05 vocabulary limits (E3).
package entitlements

import (
	"context"
	"fmt"
	"time"

	"github.com/google/uuid"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/learning"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/db/sqlc"
)

// Plans.
const (
	Free    = "free"
	Premium = "premium"
)

// Grant bounds and retention (TRD 09 §4). MaxRetainedGrants also bounds the owner export.
const (
	MaxGrantDuration  = 366 * 24 * time.Hour
	MaxRetainedGrants = 50
	RetentionDays     = 180
)

// Limits are the per-account limits of a plan. They are identical for both plans (TRD 09 E3):
// the approved TRD 05 limits.
type Limits struct {
	LiveWords    int   `json:"live_words"`
	ContentBytes int64 `json:"content_bytes"`
	Writers      int   `json:"writers"`
}

// LimitsFor returns the limits of plan.
func LimitsFor(plan string) Limits {
	_ = plan // identical by decision; kept as a function so a future decision changes one place
	return Limits{LiveWords: learning.MaxLiveWords, ContentBytes: learning.MaxContentBytes, Writers: learning.MaxActiveWriters}
}

// Plan is an account's effective plan at CheckedAt (database time).
type Plan struct {
	Name      string
	ExpiresAt *time.Time // the active grant's end; nil on Free
	CheckedAt time.Time
}

// Effective evaluates the plan at database time, at the moment of the read (TRD 09 §5.1).
func Effective(ctx context.Context, q *sqlc.Queries, user uuid.UUID) (Plan, error) {
	row, err := q.EffectiveEntitlement(ctx, user)
	if err != nil {
		return Plan{}, fmt.Errorf("entitlements: effective: %w", err)
	}
	return planOf(row.Premium, row.PremiumUntil, row.CheckedAt), nil
}

// At evaluates the plan at a given database time (the export snapshot).
func At(ctx context.Context, q *sqlc.Queries, user uuid.UUID, at time.Time) (Plan, error) {
	row, err := q.EntitlementAt(ctx, sqlc.EntitlementAtParams{UserID: user, At: at})
	if err != nil {
		return Plan{}, fmt.Errorf("entitlements: at: %w", err)
	}
	return planOf(row.Premium, row.PremiumUntil, at), nil
}

func planOf(premium bool, until, at time.Time) Plan {
	if !premium {
		return Plan{Name: Free, CheckedAt: at.UTC()}
	}
	u := until.UTC()
	return Plan{Name: Premium, ExpiresAt: &u, CheckedAt: at.UTC()}
}
