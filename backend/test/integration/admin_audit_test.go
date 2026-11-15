//go:build integration

package integration

import (
	"context"
	"net/http"
	"slices"
	"sort"
	"strconv"
	"strings"
	"testing"

	"github.com/google/uuid"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/admin"
)

// TRD 06 §9a: per-account administrative audit history through the real router.

func (e *signupEnv) auditPage(t *testing.T, access string, target uuid.UUID, query string) response {
	t.Helper()
	return e.send(t, http.MethodGet, adminPath(target, "/audit")+query, "", bearer(access)...)
}

func items(r response) []map[string]any {
	var out []map[string]any
	for _, it := range r.body["items"].([]any) {
		out = append(out, it.(map[string]any))
	}
	return out
}

// The history uses the TRD 06 view rule, including its self-view rules.
func TestAdminAudit_TargetVisibility(t *testing.T) {
	for _, actorRole := range []string{"user", "admin", "super_admin"} {
		t.Run(actorRole, func(t *testing.T) {
			e := newSignupEnv(t, nil)
			actor, s := e.staff(t, actorRole)
			e.superAdmin(t)
			for _, kind := range []string{"self", "user", "admin", "super_admin"} {
				target := actor
				if kind != "self" {
					target = e.withRole(t, kind)
				}
				r := e.auditPage(t, s.AccessToken, target.ID, "")
				status, code := matrixWant(actorRole, kind, "view")
				if status != 200 {
					wantProblem(t, r, status, code)
					continue
				}
				wantStatus(t, r, 200)
				if len(items(r)) != 0 || r.body["next_page_token"] != nil {
					t.Fatalf("%s/%s: a fresh account has no history: %s", actorRole, kind, r.raw)
				}
			}
			if actorRole != "user" {
				wantProblem(t, e.auditPage(t, s.AccessToken, uuid.New(), ""), 404, "not_found")
				leaving := e.withRole(t, "user")
				mustExec(t, e.d.Pool, `UPDATE users SET status = 'pending_deletion' WHERE id = $1`, leaving.ID)
				wantStatus(t, e.auditPage(t, s.AccessToken, leaving.ID, ""), 200)
			}
		})
	}
	t.Run("demoted actor loses access on the next request", func(t *testing.T) {
		e := newSignupEnv(t, nil)
		a, s := e.staff(t, "admin")
		u := e.withRole(t, "user")
		wantStatus(t, e.auditPage(t, s.AccessToken, u.ID, ""), 200)
		mustExec(t, e.d.Pool, `UPDATE users SET role = 'user' WHERE id = $1`, a.ID)
		wantProblem(t, e.auditPage(t, s.AccessToken, u.ID, ""), 403, "forbidden")
		mustExec(t, e.d.Pool, `UPDATE users SET role = 'admin' WHERE id = $1`, a.ID)
		mustExec(t, e.d.Pool, `UPDATE users SET role = 'admin' WHERE id = $1`, u.ID) // the target became staff
		wantProblem(t, e.auditPage(t, s.AccessToken, u.ID, ""), 403, "target_not_permitted")
	})
}

func TestAdminAudit_PaginationWithTiedTimestampsAndRetention(t *testing.T) {
	e := newSignupEnv(t, nil)
	sa, s := e.staff(t, "super_admin")
	u := e.withRole(t, "user")
	other := e.withRole(t, "user")
	e.issue(t, u, "Phone")
	// Six real mutations through the router, plus events that must never appear.
	wantStatus(t, e.suspend(t, s.AccessToken, u.ID), 200)
	wantStatus(t, e.reinstate(t, s.AccessToken, u.ID), 200)
	wantStatus(t, e.adminRevoke(t, s.AccessToken, u.ID, nil), 200) // nothing live: no event
	e.issue(t, u, "Tablet")
	wantStatus(t, e.adminRevoke(t, s.AccessToken, u.ID, nil), 200)
	wantStatus(t, e.setRole(t, s.AccessToken, u.ID, "admin"), 200)
	wantStatus(t, e.setRole(t, s.AccessToken, u.ID, "user"), 200)
	wantStatus(t, e.suspend(t, s.AccessToken, u.ID), 200)
	wantStatus(t, e.suspend(t, s.AccessToken, other.ID), 200)             // another account
	wantStatus(t, e.adminGet(t, s.AccessToken, adminPath(u.ID, "")), 200) // a read
	_, us := e.staff(t, "user")
	wantProblem(t, e.adminGet(t, us.AccessToken, adminPath(u.ID, "")), 403, "forbidden") // a denial
	ctx := context.Background()
	var want []string
	rows, err := e.d.Pool.Query(ctx, `SELECT id FROM audit_events WHERE target_user_id = $1 AND action LIKE 'admin.%'
		AND action NOT IN ('admin.user.view', 'admin.access.denied', 'admin.user.audit.view') ORDER BY id DESC`, u.ID)
	if err != nil {
		t.Fatal(err)
	}
	for rows.Next() {
		var id int64
		_ = rows.Scan(&id)
		want = append(want, strconv.FormatInt(id, 10))
	}
	rows.Close()
	if len(want) != 6 {
		t.Fatalf("fixture produced %d mutation events, want 6", len(want))
	}
	// Every event at the same microsecond: only the identity tie-breaker orders them.
	mustExec(t, e.d.Pool, `UPDATE audit_events SET occurred_at = '2026-11-10T00:00:00Z' WHERE target_user_id = $1`, u.ID)

	var got []string
	next := ""
	for page := 0; ; page++ {
		q := "?limit=2"
		if next != "" {
			q += "&page_token=" + next
		}
		r := e.auditPage(t, s.AccessToken, u.ID, q)
		wantStatus(t, r, 200)
		for _, it := range items(r) {
			if it["occurred_at"] != "2026-11-10T00:00:00Z" || it["actor_user_id"] != sa.ID.String() {
				t.Fatalf("item %v", it)
			}
			got = append(got, it["action"].(string))
		}
		if r.body["next_page_token"] == nil {
			break
		}
		next = r.str("next_page_token")
		if page > 5 {
			t.Fatal("pagination did not end")
		}
	}
	wantActions := []string{"suspend", "role_change", "role_change", "sessions_revoke", "reinstate", "suspend"}
	if !slices.Equal(got, wantActions) {
		t.Fatalf("order %v, want %v (id descending within the tie)", got, wantActions)
	}
	// The token is bound to this account and to a well-formed cursor.
	first := e.auditPage(t, s.AccessToken, u.ID, "?limit=2")
	tok := first.str("next_page_token")
	wantProblem(t, e.auditPage(t, s.AccessToken, other.ID, "?page_token="+tok), 400, "invalid_request")
	for _, q := range []string{"?page_token=h1." + strings.Repeat("A", 32), "?page_token=", "?limit=0", "?limit=101", "?limit=+1",
		"?limit=1&limit=2", "?other=1", "?page_token=" + strings.Replace(tok, "h1.", "a1.", 1)} {
		wantProblem(t, e.auditPage(t, s.AccessToken, u.ID, q), 400, "invalid_request")
	}
	// Retention is unchanged: nothing past 180 days is served, even before cleanup removes it.
	mustExec(t, e.d.Pool, `UPDATE audit_events SET occurred_at = now() - interval '181 days'
		WHERE id = (SELECT max(id) FROM audit_events WHERE target_user_id = $1 AND action = 'admin.user.suspend')`, u.ID)
	r := e.auditPage(t, s.AccessToken, u.ID, "?limit=100")
	if len(items(r)) != 5 {
		t.Fatalf("expired event served: %s", r.raw)
	}
}

func TestAdminAudit_FieldAllowlist(t *testing.T) {
	e := newSignupEnv(t, nil)
	u := e.withRole(t, "user")
	e.issue(t, u, "Phone")
	if _, err := admin.Bootstrap(context.Background(), e.d.Pool, admin.BootstrapRequest{UserID: &u.ID, Mode: admin.ModeFirst, TicketRef: ptr("OPS-9")}); err != nil {
		t.Fatal(err)
	}
	_, s := e.staff(t, "super_admin")
	target := e.withRole(t, "user")
	e.issue(t, target, "Phone")
	mustExec(t, e.d.Pool, `UPDATE sessions SET user_agent = 'SecretAgent/1.0', created_ip = '203.0.113.9' WHERE user_id = $1`, target.ID)
	r := e.post(t, adminPath(target.ID, "/lifecycle-transitions"), map[string]any{"action": "suspend", "reason_code": "fraud",
		"ticket_ref": "SUP-7", "expected_lifecycle_revision": 0}, append(bearer(s.AccessToken), "User-Agent", "SecretAgent/1.0")...)
	wantStatus(t, r, 200)

	rid := newRID()
	h := e.call(t, "GET", adminPath(target.ID, "/audit"), "", rid, bearer(s.AccessToken)...)
	wantStatus(t, h, 200)
	var top []string
	for k := range h.body {
		top = append(top, k)
	}
	sort.Strings(top)
	if !slices.Equal(top, []string{"items", "next_page_token"}) {
		t.Fatalf("top-level keys %v", top)
	}
	allowed := []string{"action", "actor_user_id", "occurred_at", "outcome", "reason_code", "ticket_ref"}
	it := items(h)
	if len(it) != 1 {
		t.Fatalf("history: %s", h.raw)
	}
	var keys []string
	for k := range it[0] {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	if !slices.Equal(keys, allowed) {
		t.Fatalf("item keys %v, want exactly %v", keys, allowed)
	}
	if it[0]["action"] != "suspend" || it[0]["outcome"] != "success" || it[0]["reason_code"] != "fraud" || it[0]["ticket_ref"] != "SUP-7" {
		t.Fatalf("values: %v", it[0])
	}
	for _, leak := range []string{"SecretAgent", "203.0.113", "127.0.0.1", "from_status", "lifecycle_revision", "request_id", "session", "account_suspended", "admin.user"} {
		if strings.Contains(string(h.raw), leak) {
			t.Fatalf("history leaked %q: %s", leak, h.raw)
		}
	}
	// The read itself is audited, and is not part of the history.
	e.wantEvents(t, rid, ev{action: "admin.user.audit.view", outcome: "success", target: target.ID.String(),
		session: s.SessionID.String(), meta: map[string]string{"result_count": "1", "page": "first"}})
	if len(items(e.auditPage(t, s.AccessToken, target.ID, ""))) != 1 {
		t.Fatal("history must not include its own reads")
	}
	// The CLI bootstrap has no actor; its ticket reference is shown.
	b := items(e.auditPage(t, s.AccessToken, u.ID, ""))
	if len(b) != 1 || b[0]["action"] != "role_bootstrap" || b[0]["actor_user_id"] != nil || b[0]["reason_code"] != "bootstrap" || b[0]["ticket_ref"] != "OPS-9" {
		t.Fatalf("bootstrap entry: %v", b)
	}
	// A minimized row (TRD 04 purge of the actor) keeps action, reason and actor but loses the ticket.
	mustExec(t, e.d.Pool, `UPDATE audit_events SET metadata = '{}' WHERE target_user_id = $1`, target.ID)
	m := items(e.auditPage(t, s.AccessToken, target.ID, ""))
	if m[0]["ticket_ref"] != nil || m[0]["reason_code"] != "fraud" {
		t.Fatalf("minimized entry: %v", m[0])
	}
}
