//go:build integration

package integration

import (
	"context"
	"strings"
	"testing"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/auth/session"
)

// TRD 8.6 and R11: Issue keeps at most 20 active sessions, evicting the least recently seen
// in the caller's transaction, and stores only token hashes.
func TestSession_IssueEnforcesTheCapInTheCallersTransaction(t *testing.T) {
	d, q := migratedDB(t)
	u := newUser(t, q)
	ctx := context.Background()
	for i := range session.MaxActive {
		s := newSession(t, q, u.ID)
		mustExec(t, d.Pool, `UPDATE sessions SET last_seen_at = now() - make_interval(mins => $2) WHERE id = $1`, s.ID, 100-i)
	}
	tx, _ := inTx(t, d.Pool)
	if _, err := q.LockUserForNoKeyUpdate(ctx, u.ID); err != nil { // the caller's L3
		t.Fatal(err)
	}
	p, err := session.NewPending(nil)
	if err != nil {
		t.Fatal(err)
	}
	issued, err := session.Issue(ctx, tx, p, session.Request{UserID: u.ID, Method: session.MethodPassword,
		Device: session.Device{Name: "Laptop", Platform: "web"}, RequestID: "req-cap-test"})
	if err != nil {
		t.Fatal(err)
	}
	if issued.Evicted != 1 {
		t.Fatalf("evicted %d, want 1", issued.Evicted)
	}
	// Nothing is visible before the caller commits.
	if rowCount(t, d.Pool, `SELECT count(*) FROM sessions WHERE revoked_at IS NOT NULL`) != 0 {
		t.Fatal("the eviction must belong to the caller's transaction")
	}
	if err := tx.Commit(ctx); err != nil {
		t.Fatal(err)
	}
	if n := rowCount(t, d.Pool, `SELECT count(*) FROM sessions WHERE user_id = $1 AND revoked_at IS NULL`, u.ID); n != session.MaxActive {
		t.Fatalf("%d active sessions, want %d", n, session.MaxActive)
	}
	if rowCount(t, d.Pool, `SELECT count(*) FROM sessions WHERE revoked_reason = 'session_limit'
		AND last_seen_at = (SELECT min(last_seen_at) FROM sessions WHERE user_id = $1)`, u.ID) != 1 {
		t.Fatal("the least recently seen session must be the one evicted")
	}
	if rowCount(t, d.Pool, `SELECT count(*) FROM audit_events WHERE action = 'auth.session.revoke'
		AND metadata->>'reason' = 'session_limit' AND metadata->>'count' = '1'`) != 1 {
		t.Fatal("expected one auth.session.revoke event")
	}
	var text string
	_ = d.Pool.QueryRow(ctx, `SELECT row_to_json(s)::text FROM sessions s WHERE id = $1`, issued.SessionID).Scan(&text)
	if strings.Contains(text, issued.AccessToken) || strings.Contains(text, issued.RefreshToken) || strings.Contains(text, "vat_") {
		t.Fatal("a session row must hold token hashes only")
	}
	// All three expiries come from one database now().
	if issued.AbsoluteExpiresAt.Sub(issued.AccessExpiresAt) != session.AbsoluteTTL-session.AccessTTL ||
		issued.AbsoluteExpiresAt.Sub(issued.RefreshExpiresAt) != session.AbsoluteTTL-session.RefreshIdleTTL {
		t.Fatalf("unexpected expiries: access %s, refresh %s, absolute %s",
			issued.AccessExpiresAt, issued.RefreshExpiresAt, issued.AbsoluteExpiresAt)
	}
}
