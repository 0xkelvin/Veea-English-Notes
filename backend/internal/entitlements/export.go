package entitlements

import (
	"strconv"
	"time"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/learning"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/db/sqlc"
)

// The owner export section (TRD 09 §7, export schema 3). It contains the effective plan at the
// snapshot and every retained grant period, and nothing else: no staff identifier, reason
// code, ticket reference or audit metadata. Every value has a fixed maximum width, so the
// section has a hard bound (MaxExportSectionBytes) that keeps the whole export inside the
// verified TRD 05 §11.1 header budget.

// Grant statuses in the export.
const (
	StatusActive   = "active"
	StatusExpired  = "expired"
	StatusReplaced = "replaced"
	StatusRevoked  = "revoked"
)

// maxGrantEntryBytes is one period at its widest: three fixed-width timestamps, the longest
// status, the source, and the separating comma.
var maxGrantEntryBytes = len(`,{"starts_at":"` + exportTimeMax + `","ends_at":"` + exportTimeMax + `","ended_at":"` + exportTimeMax +
	`","status":"` + StatusReplaced + `","source":"manual"}`)

// exportTimeMax is the widest learning.ExportTime value (the format is fixed-width).
const exportTimeMax = "9999-12-31T23:59:59.999Z"

// MaxExportSectionBytes bounds AppendExport's output: the wrapper with the widest plan and
// expiry, plus MaxRetainedGrants widest entries.
var MaxExportSectionBytes = len(`,"entitlements":{"plan":"premium","plan_expires_at":"`+exportTimeMax+
	`","retention_days":180,"grants":[]}`) + MaxRetainedGrants*maxGrantEntryBytes

// AppendExport appends `,"entitlements":{…}` for plan (evaluated at the snapshot time at) and
// grants (newest first, at most MaxRetainedGrants).
func AppendExport(b []byte, plan Plan, grants []sqlc.ListRetainedEntitlementGrantsRow, at time.Time) []byte {
	b = append(b, `,"entitlements":{"plan":"`...)
	b = append(b, plan.Name...)
	b = append(b, `","plan_expires_at":`...)
	b = appendTime(b, plan.ExpiresAt)
	b = append(b, `,"retention_days":`...)
	b = strconv.AppendInt(b, RetentionDays, 10)
	b = append(b, `,"grants":[`...)
	if len(grants) > MaxRetainedGrants {
		grants = grants[:MaxRetainedGrants]
	}
	for i, g := range grants {
		if i > 0 {
			b = append(b, ',')
		}
		var ended *time.Time
		status := StatusActive
		switch {
		case g.ClosedAt != nil && !g.ClosedAt.Before(g.EndsAt):
			// closed (replaced) only after it had already run out: it expired
			status, ended = StatusExpired, &g.EndsAt
		case g.ClosedReason != nil && *g.ClosedReason == "revoked":
			status, ended = StatusRevoked, g.PeriodEnd
		case g.ClosedReason != nil:
			status, ended = StatusReplaced, g.PeriodEnd
		case !at.Before(g.EndsAt):
			status, ended = StatusExpired, &g.EndsAt
		}
		b = append(b, `{"starts_at":`...)
		b = appendTime(b, &g.StartsAt)
		b = append(b, `,"ends_at":`...)
		b = appendTime(b, &g.EndsAt)
		b = append(b, `,"ended_at":`...)
		b = appendTime(b, ended)
		b = append(b, `,"status":"`...)
		b = append(b, status...)
		b = append(b, `","source":"manual"}`...)
	}
	return append(b, "]}"...)
}

func appendTime(b []byte, t *time.Time) []byte {
	if t == nil {
		return append(b, "null"...)
	}
	b = append(b, '"')
	b = t.UTC().AppendFormat(b, learning.ExportTime)
	return append(b, '"')
}
