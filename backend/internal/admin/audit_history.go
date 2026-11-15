package admin

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"fmt"
	"strings"
	"time"

	"github.com/google/uuid"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/audit"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/auth/session"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/db/sqlc"
)

// AuditActions maps the stored TRD 06 mutation actions to the public enum of the history API.
// Nothing else (reads, denials, owner or session events) is ever returned.
var AuditActions = map[string]string{
	"admin.user.suspend":    "suspend",
	"admin.user.reinstate":  "reinstate",
	"admin.role.change":     "role_change",
	"admin.role.bootstrap":  "role_bootstrap",
	"admin.sessions.revoke": "sessions_revoke",
}

// AuditEntry is the operator view of one event: exactly these fields (TRD 06 §9a).
type AuditEntry struct {
	OccurredAt  time.Time
	Action      string     // public enum from AuditActions
	Outcome     string     // success or failure, as stored
	ActorUserID *uuid.UUID // nil for the CLI bootstrap
	ReasonCode  *string
	TicketRef   *string // nil when none was given, or after audit minimization
}

// AuditPage is one keyset page.
type AuditPage struct {
	Items         []AuditEntry
	NextPageToken *string
}

// AuditHistory returns the administrative mutation history of one account, newest first. It
// reuses the TRD 06 view rule (an Admin sees User accounts only; a Super Admin sees every
// account including its own), revalidates the actor in the same snapshot, and commits
// admin.user.audit.view before any data is returned.
func (s *Service) AuditHistory(ctx context.Context, p session.Principal, id uuid.UUID, pageToken string, limit int, c session.Client) (AuditPage, error) {
	var page AuditPage
	err := s.read(ctx, p, "audit_view", &id, c, func(ctx context.Context, q *sqlc.Queries, actorRole string) (audit.Event, error) {
		page = AuditPage{}
		t, err := getUser(ctx, q, id)
		if err != nil {
			return audit.Event{}, err
		}
		if !Permits(actorRole, p.UserID, t.Role, t.ID, ActView) {
			return audit.Event{}, ErrTargetNotPermitted
		}
		params := sqlc.AdminAuditHistoryParams{TargetUserID: &t.ID, PageLimit: int32(limit + 1)}
		if pageToken != "" {
			at, after, ok := decodeAuditToken(pageToken, t.ID)
			if !ok {
				return audit.Event{}, ErrInvalidPageToken
			}
			params.AfterOccurredAt, params.AfterID = &at, &after
		}
		rows, err := q.AdminAuditHistory(ctx, params)
		if err != nil {
			return audit.Event{}, fmt.Errorf("admin: audit history: %w", err)
		}
		if len(rows) > limit {
			rows = rows[:limit]
			last := rows[len(rows)-1]
			page.NextPageToken = ptr(encodeAuditToken(last.OccurredAt, last.ID, t.ID))
		}
		page.Items = make([]AuditEntry, 0, len(rows))
		for _, r := range rows {
			e := AuditEntry{OccurredAt: r.OccurredAt.UTC(), Action: AuditActions[r.Action], Outcome: r.Outcome,
				ActorUserID: r.ActorUserID, ReasonCode: r.Reason}
			if r.TicketRef != "" {
				e.TicketRef = ptr(r.TicketRef)
			}
			page.Items = append(page.Items, e)
		}
		meta := map[string]string{"result_count": count(int64(len(rows))), "page": "first"}
		if pageToken != "" {
			meta["page"] = "next"
		}
		return audit.Event{Action: "admin.user.audit.view", TargetUserID: &t.ID, Metadata: meta}, nil
	})
	return page, err
}

const auditTokenPrefix = "h1."

// The token binds the cursor (occurred_at, id) to the target account, so it cannot be replayed
// against another account's history. It is not secret: a forged one only moves the start
// position within rows the actor may already read.
func auditFingerprint(target uuid.UUID) [8]byte {
	sum := sha256.Sum256(append([]byte("veea:audit-history:"), target[:]...))
	return [8]byte(sum[:8])
}

func encodeAuditToken(at time.Time, id int64, target uuid.UUID) string {
	var raw [24]byte
	binary.BigEndian.PutUint64(raw[:8], uint64(at.UnixMicro()))
	binary.BigEndian.PutUint64(raw[8:16], uint64(id))
	fp := auditFingerprint(target)
	copy(raw[16:], fp[:])
	return auditTokenPrefix + base64.RawURLEncoding.EncodeToString(raw[:])
}

func decodeAuditToken(tok string, target uuid.UUID) (time.Time, int64, bool) {
	rest, ok := strings.CutPrefix(tok, auditTokenPrefix)
	if !ok || len(rest) != 32 {
		return time.Time{}, 0, false
	}
	raw, err := base64.RawURLEncoding.DecodeString(rest)
	if err != nil || len(raw) != 24 || [8]byte(raw[16:]) != auditFingerprint(target) {
		return time.Time{}, 0, false
	}
	id := int64(binary.BigEndian.Uint64(raw[8:16]))
	if id <= 0 {
		return time.Time{}, 0, false
	}
	return time.UnixMicro(int64(binary.BigEndian.Uint64(raw[:8]))).UTC(), id, true
}
