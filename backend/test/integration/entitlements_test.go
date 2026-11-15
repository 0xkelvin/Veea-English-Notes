//go:build integration

package integration

import (
	"context"
	"encoding/json"
	"net/http"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/entitlements"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/learning"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/db/sqlc"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/migrate"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/pgtest"
)

// TRD 09: Free/Premium plan management through the real router and PostgreSQL.

const pathMyEntitlements = "/v1/me/entitlements"

func (e *signupEnv) putPlan(t *testing.T, access string, target uuid.UUID, plan string, endsAt *time.Time, rev int64, reason string, ticket any) response {
	t.Helper()
	var ends any
	if endsAt != nil {
		ends = endsAt.UTC().Format(time.RFC3339Nano)
	}
	return e.send(t, http.MethodPut, adminPath(target, "/entitlement"), map[string]any{"plan": plan, "ends_at": ends,
		"reason_code": reason, "ticket_ref": ticket, "expected_entitlement_revision": rev}, bearer(access)...)
}

func (e *signupEnv) grantPremium(t *testing.T, access string, target uuid.UUID, ends time.Time, rev int64) response {
	t.Helper()
	return e.putPlan(t, access, target, "premium", &ends, rev, "support_courtesy", "SUP-1")
}

func (e *signupEnv) revokePremium(t *testing.T, access string, target uuid.UUID, rev int64) response {
	t.Helper()
	return e.putPlan(t, access, target, "free", nil, rev, "ended_early", "SUP-2")
}

func (e *signupEnv) myPlan(t *testing.T, access string) response {
	t.Helper()
	return e.send(t, http.MethodGet, pathMyEntitlements, "", bearer(access)...)
}

func (e *signupEnv) dbNow(t *testing.T) time.Time {
	t.Helper()
	var now time.Time
	if err := e.d.Pool.QueryRow(context.Background(), `SELECT clock_timestamp()`).Scan(&now); err != nil {
		t.Fatal(err)
	}
	return now.UTC()
}

func wantPlan(t *testing.T, r response, plan string, expires *time.Time) {
	t.Helper()
	wantStatus(t, r, 200)
	if r.str("plan") != plan {
		t.Fatalf("plan %q, want %q: %s", r.str("plan"), plan, r.raw)
	}
	got := r.body["plan_expires_at"]
	if expires == nil {
		if got != nil {
			t.Fatalf("plan_expires_at %v, want null", got)
		}
		return
	}
	at, err := time.Parse(time.RFC3339Nano, r.str("plan_expires_at"))
	if err != nil || !at.Equal(expires.Truncate(time.Microsecond)) {
		t.Fatalf("plan_expires_at %v, want %v", got, *expires)
	}
}

// insertGrant is a fixture row (the API is the only writer in production).
func (e *signupEnv) insertGrant(t *testing.T, user uuid.UUID, starts, ends time.Time, closedAt *time.Time, reason *string) {
	t.Helper()
	var by any
	if closedAt != nil {
		by = uuid.New()
	}
	var code, ticket any
	if reason != nil && *reason == "revoked" {
		code, ticket = "other", "FIX-2"
	}
	mustExec(t, e.d.Pool, `INSERT INTO entitlement_grants (id, user_id, plan, source, starts_at, ends_at, granted_by, reason_code, ticket_ref,
		closed_at, closed_reason, closed_by, close_reason_code, close_ticket_ref)
		VALUES ($1, $2, 'premium', 'manual', $3, $4, $5, 'other', 'FIX-1', $6, $7, $8, $9, $10)`,
		newID(), user, starts, ends, uuid.New(), closedAt, reason, by, code, ticket)
}

// --- before a grant, after it, after revocation and after expiry -------------------------------

func TestEntitlements_GrantRevokeAndExpiry(t *testing.T) {
	e := newSignupEnv(t, nil)
	_, s := e.staff(t, "admin")
	u := e.withRole(t, "user")
	us := e.issue(t, u, "Phone")

	r := e.myPlan(t, us.AccessToken)
	wantPlan(t, r, "free", nil)
	limits := r.body["limits"].(map[string]any)
	if limits["live_words"].(float64) != 50000 || limits["content_bytes"].(float64) != 67108864 || limits["writers"].(float64) != 20 {
		t.Fatalf("limits: %v", limits)
	}
	if _, err := time.Parse(time.RFC3339Nano, r.str("checked_at")); err != nil {
		t.Fatal("checked_at")
	}
	d := e.adminGet(t, s.AccessToken, adminPath(u.ID, ""))
	wantPlan(t, d, "free", nil)
	if d.body["entitlement_revision"].(float64) != 0 || !slices.Contains(strs(d.body["allowed_actions"]), "manage_plan") {
		t.Fatalf("detail: %s", d.raw)
	}
	before := e.userRow(t, u.ID)
	heads := rowCount(t, e.d.Pool, `SELECT count(*) FROM learning_sync_heads WHERE user_id = $1`, u.ID)

	ends := e.dbNow(t).Add(30 * 24 * time.Hour)
	g := e.grantPremium(t, s.AccessToken, u.ID, ends, 0)
	wantPlan(t, g, "premium", &ends)
	if g.body["entitlement_revision"].(float64) != 1 {
		t.Fatalf("revision: %s", g.raw)
	}
	wantPlan(t, e.myPlan(t, us.AccessToken), "premium", &ends) // effective on the next request

	wantPlan(t, e.revokePremium(t, s.AccessToken, u.ID, 1), "free", nil)
	wantPlan(t, e.myPlan(t, us.AccessToken), "free", nil)

	// Expiry at database time, with no job: Premium until ends_at, Free from then on.
	soon := e.dbNow(t).Add(1500 * time.Millisecond)
	wantPlan(t, e.grantPremium(t, s.AccessToken, u.ID, soon, 2), "premium", &soon)
	wantPlan(t, e.myPlan(t, us.AccessToken), "premium", &soon)
	for e.dbNow(t).Before(soon) {
		time.Sleep(100 * time.Millisecond)
	}
	wantPlan(t, e.myPlan(t, us.AccessToken), "free", nil)
	wantPlan(t, e.adminGet(t, s.AccessToken, adminPath(u.ID, "")), "free", nil)
	if e.userRow(t, u.ID).EntitlementRevision != 3 || rowCount(t, e.d.Pool, `SELECT count(*) FROM entitlement_grants WHERE user_id = $1 AND closed_at IS NULL`, u.ID) != 1 {
		t.Fatal("expiry changes no row")
	}

	// Data, role, sessions and the lifecycle are untouched by every plan change.
	after := e.userRow(t, u.ID)
	if after.Role != before.Role || after.LifecycleRevision != before.LifecycleRevision || after.RoleRevision != before.RoleRevision ||
		rowCount(t, e.d.Pool, `SELECT count(*) FROM learning_sync_heads WHERE user_id = $1`, u.ID) != heads {
		t.Fatal("a plan change touched role, lifecycle or learning data")
	}
	wantStatus(t, e.me(t, us.AccessToken), 200)
	// Export, deletion and reactivation access does not depend on the plan.
	p, pr := e.rightsStart(t, "export", u.Email)
	wantStatus(t, pr, 202)
	wantStatus(t, e.rightsComplete(t, p), 202)
}

func TestEntitlements_ExpiryBoundaryIsExact(t *testing.T) {
	e := newSignupEnv(t, nil)
	u := e.withRole(t, "user")
	starts := time.Date(2026, 11, 1, 0, 0, 0, 0, time.UTC)
	ends := starts.Add(48 * time.Hour)
	e.insertGrant(t, u.ID, starts, ends, nil, nil)
	q := sqlc.New(e.d.Pool)
	for _, c := range []struct {
		at   time.Time
		want string
	}{
		{starts.Add(-time.Microsecond), "free"}, {starts, "premium"}, {ends.Add(-time.Microsecond), "premium"},
		{ends, "free"}, {ends.Add(time.Microsecond), "free"},
	} {
		p, err := entitlements.At(context.Background(), q, u.ID, c.at)
		if err != nil || p.Name != c.want || (c.want == "premium" && !p.ExpiresAt.Equal(ends)) {
			t.Fatalf("at %v: %+v %v, want %s", c.at, p, err, c.want)
		}
	}
	// A revoked or replaced grant is never effective, even inside its period.
	mustExec(t, e.d.Pool, `UPDATE entitlement_grants SET closed_at = starts_at + interval '1 hour', closed_reason = 'replaced', closed_by = $2 WHERE user_id = $1`, u.ID, uuid.New())
	if p, _ := entitlements.At(context.Background(), q, u.ID, starts.Add(30*time.Minute)); p.Name != "free" {
		t.Fatal("a closed grant is not effective")
	}
}

// --- authority and validation ------------------------------------------------------------------

func TestEntitlements_GrantAuthority(t *testing.T) {
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
				r := e.grantPremium(t, s.AccessToken, target.ID, e.dbNow(t).Add(24*time.Hour), 0)
				want := map[string]bool{"admin/user": true, "super_admin/user": true, "super_admin/admin": true, "super_admin/super_admin": true}[actorRole+"/"+kind]
				switch {
				case want:
					wantStatus(t, r, 200)
					if r.str("plan") != "premium" {
						t.Fatalf("%s → %s: %s", actorRole, kind, r.raw)
					}
				case actorRole == "user":
					wantProblem(t, r, 403, "forbidden")
				default:
					wantProblem(t, r, 403, "target_not_permitted")
				}
				if !want && (rowCount(t, e.d.Pool, `SELECT count(*) FROM entitlement_grants WHERE user_id = $1`, target.ID) != 0 || e.userRow(t, target.ID).EntitlementRevision != 0) {
					t.Fatalf("%s → %s: a refused grant wrote something", actorRole, kind)
				}
			}
		})
	}
	t.Run("state, not found and validation", func(t *testing.T) {
		e := newSignupEnv(t, nil)
		_, s := e.staff(t, "super_admin")
		u := e.withRole(t, "user")
		now := e.dbNow(t)
		day := now.Add(24 * time.Hour)
		gone := e.withRole(t, "user")
		mustExec(t, e.d.Pool, `UPDATE users SET status = 'pending_deletion' WHERE id = $1`, gone.ID)
		r := e.grantPremium(t, s.AccessToken, gone.ID, day, 0)
		wantProblem(t, r, 409, "status_conflict")
		if r.str("account_status") != "pending_deletion" {
			t.Fatal("account_status")
		}
		wantProblem(t, e.grantPremium(t, s.AccessToken, uuid.New(), day, 0), 404, "not_found")
		for name, r := range map[string]response{
			"ticket missing":       e.putPlan(t, s.AccessToken, u.ID, "premium", &day, 0, "support_courtesy", nil),
			"ticket with a space":  e.putPlan(t, s.AccessToken, u.ID, "premium", &day, 0, "support_courtesy", "has space"),
			"ticket token-shaped":  e.putPlan(t, s.AccessToken, u.ID, "premium", &day, 0, "support_courtesy", "vat_x"),
			"revoke reason":        e.putPlan(t, s.AccessToken, u.ID, "premium", &day, 0, "abuse", "SUP-1"),
			"grant reason on free": e.putPlan(t, s.AccessToken, u.ID, "free", nil, 0, "support_courtesy", "SUP-1"),
			"premium without end":  e.putPlan(t, s.AccessToken, u.ID, "premium", nil, 0, "support_courtesy", "SUP-1"),
			"free with an end":     e.putPlan(t, s.AccessToken, u.ID, "free", &day, 0, "ended_early", "SUP-1"),
			"unknown plan":         e.putPlan(t, s.AccessToken, u.ID, "gold", &day, 0, "support_courtesy", "SUP-1"),
			"negative revision":    e.putPlan(t, s.AccessToken, u.ID, "premium", &day, -1, "support_courtesy", "SUP-1"),
		} {
			if r.status != 400 || r.str("code") != "invalid_request" {
				t.Errorf("%s: %d %s", name, r.status, r.raw)
			}
		}
		past, far := now.Add(-time.Minute), now.Add(367*24*time.Hour)
		wantProblem(t, e.grantPremium(t, s.AccessToken, u.ID, past, 0), 400, "invalid_expiry")
		wantProblem(t, e.grantPremium(t, s.AccessToken, u.ID, far, 0), 400, "invalid_expiry")
		if rowCount(t, e.d.Pool, `SELECT count(*) FROM entitlement_grants WHERE user_id = $1`, u.ID) != 0 {
			t.Fatal("a refused change wrote a grant")
		}
		limit := e.dbNow(t).Add(366*24*time.Hour - time.Minute)
		wantPlan(t, e.grantPremium(t, s.AccessToken, u.ID, limit, 0), "premium", &limit) // within 366 days
	})
}

// --- revisions, retries and audit --------------------------------------------------------------

func TestEntitlements_RevisionRetryAndAudit(t *testing.T) {
	e := newSignupEnv(t, nil)
	a, s := e.staff(t, "admin")
	u := e.withRole(t, "user")
	us := e.issue(t, u, "Phone")
	actor, target, sess := a.ID.String(), u.ID.String(), s.SessionID.String()
	ends := e.dbNow(t).Add(10 * 24 * time.Hour)
	body := func(plan string, ends *time.Time, rev int64, reason, ticket string) map[string]any {
		var v any
		if ends != nil {
			v = ends.Format(time.RFC3339Nano)
		}
		return map[string]any{"plan": plan, "ends_at": v, "reason_code": reason, "ticket_ref": ticket, "expected_entitlement_revision": rev}
	}
	rid := newRID()
	wantStatus(t, e.call(t, "PUT", adminPath(u.ID, "/entitlement"), body("premium", &ends, 0, "beta_access", "SUP-10"), rid, bearer(s.AccessToken)...), 200)
	e.wantEvents(t, rid, ev{action: "admin.entitlement.grant", outcome: "success", reason: "beta_access", actor: actor, target: target, session: sess,
		meta: map[string]string{"ticket_ref": "SUP-10", "entitlement_revision": "1", "replaced": "false"}})
	// A retry after a lost response: the end state holds, so 200 with no new event.
	rid = newRID()
	wantPlan(t, e.call(t, "PUT", adminPath(u.ID, "/entitlement"), body("premium", &ends, 0, "beta_access", "SUP-10"), rid, bearer(s.AccessToken)...), "premium", &ends)
	e.wantEvents(t, rid)
	if rowCount(t, e.d.Pool, `SELECT count(*) FROM audit_events WHERE action = 'admin.entitlement.grant'`) != 1 || e.userRow(t, u.ID).EntitlementRevision != 1 {
		t.Fatal("a no-op retry changed something")
	}
	// A stale revision with a different end state is refused.
	later := ends.Add(24 * time.Hour)
	wantProblem(t, e.putPlan(t, s.AccessToken, u.ID, "premium", &later, 0, "beta_access", "SUP-11"), 409, "entitlement_conflict")
	// Replacing with the current revision closes the old period.
	rid = newRID()
	wantStatus(t, e.call(t, "PUT", adminPath(u.ID, "/entitlement"), body("premium", &later, 1, "promotion", "SUP-11"), rid, bearer(s.AccessToken)...), 200)
	e.wantEvents(t, rid, ev{action: "admin.entitlement.grant", outcome: "success", reason: "promotion", actor: actor, target: target,
		meta: map[string]string{"replaced": "true", "entitlement_revision": "2"}})
	if rowCount(t, e.d.Pool, `SELECT count(*) FROM entitlement_grants WHERE user_id = $1 AND closed_reason = 'replaced' AND closed_by = $2`, u.ID, a.ID) != 1 {
		t.Fatal("replacement closes the previous period")
	}
	rid = newRID()
	wantStatus(t, e.call(t, "PUT", adminPath(u.ID, "/entitlement"), body("free", nil, 2, "owner_request", "SUP-12"), rid, bearer(s.AccessToken)...), 200)
	e.wantEvents(t, rid, ev{action: "admin.entitlement.revoke", outcome: "success", reason: "owner_request", actor: actor, target: target,
		meta: map[string]string{"ticket_ref": "SUP-12", "entitlement_revision": "3"}})
	rid = newRID()
	wantStatus(t, e.call(t, "PUT", adminPath(u.ID, "/entitlement"), body("free", nil, 2, "owner_request", "SUP-12"), rid, bearer(s.AccessToken)...), 200)
	e.wantEvents(t, rid) // revoke retry: no duplicate event
	if rowCount(t, e.d.Pool, `SELECT count(*) FROM audit_events WHERE action = 'admin.entitlement.revoke'`) != 1 {
		t.Fatal("duplicate revoke event")
	}
	// ABA: a new grant, then the old revoke retried with its stale revision is refused, not applied.
	wantStatus(t, e.grantPremium(t, s.AccessToken, u.ID, ends, 3), 200)
	wantProblem(t, e.revokePremium(t, s.AccessToken, u.ID, 2), 409, "entitlement_conflict")
	wantPlan(t, e.myPlan(t, us.AccessToken), "premium", &ends)
	// The audit history shows the plan actions with the allowlisted fields only.
	h := e.auditPage(t, s.AccessToken, u.ID, "")
	wantStatus(t, h, 200)
	var actions, reasons, tickets []string
	for _, it := range items(h) {
		actions = append(actions, it["action"].(string))
		reasons = append(reasons, it["reason_code"].(string))
		tickets = append(tickets, it["ticket_ref"].(string))
		if len(it) != 6 || it["actor_user_id"] != actor {
			t.Fatalf("history item %v", it)
		}
	}
	if !slices.Equal(actions, []string{"premium_grant", "premium_revoke", "premium_grant", "premium_grant"}) ||
		!slices.Equal(reasons, []string{"support_courtesy", "owner_request", "promotion", "beta_access"}) ||
		!slices.Equal(tickets, []string{"SUP-1", "SUP-12", "SUP-11", "SUP-10"}) {
		t.Fatalf("history %v %v %v", actions, reasons, tickets)
	}
	wantMetric(t, e.metrics, `admin_actions_total{action="plan_change",result="noop"}`, 2)
	wantMetric(t, e.metrics, `admin_actions_total{action="plan_change",result="conflict"}`, 2)
	wantStatus(t, e.me(t, us.AccessToken), 200) // the target's session was never touched
}

func TestEntitlements_ConcurrentChanges(t *testing.T) {
	e := newSignupEnv(t, nil)
	_, s1 := e.staff(t, "admin")
	_, s2 := e.staff(t, "admin")
	u := e.withRole(t, "user")
	ctx := context.Background()
	tx, err := e.d.Pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx)
	if _, err := sqlc.New(tx).LockUserForNoKeyUpdate(ctx, u.ID); err != nil { // hold the target at L3
		t.Fatal(err)
	}
	now := e.dbNow(t)
	e1, e2 := now.Add(24*time.Hour), now.Add(48*time.Hour)
	r1, r2 := make(chan response, 1), make(chan response, 1)
	go func() { r1 <- e.grantPremium(t, s1.AccessToken, u.ID, e1, 0) }()
	go func() { r2 <- e.grantPremium(t, s2.AccessToken, u.ID, e2, 0) }()
	waitForLockWaiters(t, e, 2)
	if err := tx.Commit(ctx); err != nil {
		t.Fatal(err)
	}
	a, b := <-r1, <-r2
	if (a.status == 200) == (b.status == 200) {
		t.Fatalf("exactly one concurrent change must win: %d %d", a.status, b.status)
	}
	loser := b
	if a.status != 200 {
		loser = a
	}
	wantProblem(t, loser, 409, "entitlement_conflict")
	if rowCount(t, e.d.Pool, `SELECT count(*) FROM entitlement_grants WHERE user_id = $1`, u.ID) != 1 ||
		rowCount(t, e.d.Pool, `SELECT count(*) FROM audit_events WHERE action = 'admin.entitlement.grant' AND target_user_id = $1`, u.ID) != 1 ||
		e.userRow(t, u.ID).EntitlementRevision != 1 {
		t.Fatal("concurrent grants must leave one grant, one event and revision 1")
	}
	// Changes to different accounts do not interfere.
	x, y := e.withRole(t, "user"), e.withRole(t, "user")
	c1, c2 := make(chan response, 1), make(chan response, 1)
	go func() { c1 <- e.grantPremium(t, s1.AccessToken, x.ID, e1, 0) }()
	go func() { c2 <- e.grantPremium(t, s2.AccessToken, y.ID, e2, 0) }()
	wantStatus(t, <-c1, 200)
	wantStatus(t, <-c2, 200)
}

// --- isolation and separation from roles -------------------------------------------------------

func TestEntitlements_IsolationAndRoleSeparation(t *testing.T) {
	e := newSignupEnv(t, nil)
	sa, s := e.staff(t, "super_admin")
	e.superAdmin(t)
	a, b := e.withRole(t, "user"), e.withRole(t, "user")
	as, bs := e.issue(t, a, "A"), e.issue(t, b, "B")
	ends := e.dbNow(t).Add(24 * time.Hour)
	wantStatus(t, e.grantPremium(t, s.AccessToken, a.ID, ends, 0), 200)
	wantPlan(t, e.myPlan(t, as.AccessToken), "premium", &ends)
	wantPlan(t, e.myPlan(t, bs.AccessToken), "free", nil) // another account is unaffected
	wantProblem(t, e.grantPremium(t, bs.AccessToken, a.ID, ends, 1), 403, "forbidden")
	wantProblem(t, e.grantPremium(t, bs.AccessToken, b.ID, ends, 0), 403, "forbidden")
	wantProblem(t, e.adminGet(t, as.AccessToken, adminPath(b.ID, "")), 403, "forbidden") // Premium is not a role
	// Role changes never change the plan, and plan changes never change the role.
	wantStatus(t, e.adminRole(t, s.AccessToken, a.ID, "admin", 0), 200)
	if e.userRow(t, a.ID).EntitlementRevision != 1 {
		t.Fatal("a role change touched the plan")
	}
	as = e.issue(t, a, "A2") // promotion revoked the earlier session
	wantPlan(t, e.myPlan(t, as.AccessToken), "premium", &ends)
	// A Super Admin cannot grant itself Premium, even through its own detail.
	wantProblem(t, e.grantPremium(t, s.AccessToken, sa.ID, ends, 0), 403, "target_not_permitted")
	if slices.Contains(strs(e.adminGet(t, s.AccessToken, adminPath(sa.ID, "")).body["allowed_actions"]), "manage_plan") {
		t.Fatal("self plan management is never offered")
	}
}

// --- export contents, size and retention -------------------------------------------------------

type exportDoc struct {
	SchemaVersion int `json:"schema_version"`
	Entitlements  struct {
		Plan          string           `json:"plan"`
		PlanExpiresAt *string          `json:"plan_expires_at"`
		RetentionDays int              `json:"retention_days"`
		Grants        []map[string]any `json:"grants"`
	} `json:"entitlements"`
}

func (e *signupEnv) exportOf(t *testing.T, email string) (exportDoc, []byte) {
	t.Helper()
	p, r := e.rightsStart(t, "export", email)
	wantStatus(t, r, 202)
	wantStatus(t, e.rightsComplete(t, p), 202)
	e.finishRightsJobs(t)
	if rowCount(t, e.d.Pool, `SELECT count(*) FROM account_operations WHERE id = $1 AND schema_version = 3`, uuid.MustParse(p.id)) != 1 {
		t.Fatal("the export must be published as schema version 3")
	}
	file := e.download(t, p)
	wantStatus(t, file, 200)
	var doc exportDoc
	if err := json.Unmarshal(file.raw, &doc); err != nil {
		t.Fatal(err)
	}
	return doc, file.raw
}

func TestEntitlements_ExportContentsAndSize(t *testing.T) {
	e := newSignupEnv(t, nil)
	a, s := e.staff(t, "admin")
	u := e.withRole(t, "user")
	now := e.dbNow(t)
	wantStatus(t, e.grantPremium(t, s.AccessToken, u.ID, now.Add(24*time.Hour), 0), 200)
	wantStatus(t, e.putPlan(t, s.AccessToken, u.ID, "premium", ptr(now.Add(48*time.Hour)), 1, "partner", "SUP-PARTNER"), 200)
	wantStatus(t, e.revokePremium(t, s.AccessToken, u.ID, 2), 200)
	doc, raw := e.exportOf(t, u.Email)
	if doc.SchemaVersion != 3 || doc.Entitlements.Plan != "free" || doc.Entitlements.PlanExpiresAt != nil || doc.Entitlements.RetentionDays != 180 {
		t.Fatalf("section: %+v", doc.Entitlements)
	}
	var statuses []string
	for _, g := range doc.Entitlements.Grants {
		statuses = append(statuses, g["status"].(string))
		if len(g) != 5 || g["source"] != "manual" || g["ended_at"] == nil {
			t.Fatalf("grant entry %v", g)
		}
	}
	if !slices.Equal(statuses, []string{"revoked", "replaced"}) {
		t.Fatalf("statuses %v", statuses)
	}
	// Excluded: staff identifiers, ticket references, reason codes and audit metadata.
	for _, leak := range []string{a.ID.String(), "SUP-", "support_courtesy", "partner", "ended_early", "granted_by", "closed_by", "ticket", "reason", "entitlement_revision"} {
		if strings.Contains(string(raw), leak) {
			t.Fatalf("export leaked %q", leak)
		}
	}

	t.Run("an active grant is exported with its expiry", func(t *testing.T) {
		v := e.withRole(t, "user")
		ends := e.dbNow(t).Add(72 * time.Hour)
		wantStatus(t, e.grantPremium(t, s.AccessToken, v.ID, ends, 0), 200)
		doc, _ := e.exportOf(t, v.Email)
		if doc.Entitlements.Plan != "premium" || doc.Entitlements.PlanExpiresAt == nil || len(doc.Entitlements.Grants) != 1 ||
			doc.Entitlements.Grants[0]["status"] != "active" || doc.Entitlements.Grants[0]["ended_at"] != nil {
			t.Fatalf("active section: %+v", doc.Entitlements)
		}
	})

	t.Run("history is capped at 50 rows and the export stays inside its bound", func(t *testing.T) {
		w := e.withRole(t, "user")
		base := e.dbNow(t).Add(-100 * 24 * time.Hour)
		replaced := "replaced"
		for i := range 60 { // older closed periods, inside retention
			st := base.Add(time.Duration(i) * time.Hour)
			closed := st.Add(30 * time.Minute)
			e.insertGrant(t, w.ID, st, st.Add(time.Hour), &closed, &replaced)
		}
		wantStatus(t, e.grantPremium(t, s.AccessToken, w.ID, e.dbNow(t).Add(time.Hour), 0), 200)
		if n := rowCount(t, e.d.Pool, `SELECT count(*) FROM entitlement_grants WHERE user_id = $1`, w.ID); n != entitlements.MaxRetainedGrants {
			t.Fatalf("retained rows %d, want %d", n, entitlements.MaxRetainedGrants)
		}
		doc, raw := e.exportOf(t, w.Email)
		if len(doc.Entitlements.Grants) != entitlements.MaxRetainedGrants || doc.Entitlements.Grants[0]["status"] != "active" {
			t.Fatalf("exported %d periods", len(doc.Entitlements.Grants))
		}
		header := len(raw) - len(`"vocabulary":[]}`)
		if header > learning.MaxHeaderBytes || int64(len(raw)) > learning.MaxExportPlainBytes {
			t.Fatalf("export %d bytes, header ~%d over its bound", len(raw), header)
		}
	})

	t.Run("periods past the 180-day retention are not exported", func(t *testing.T) {
		x := e.withRole(t, "user")
		now := e.dbNow(t)
		old := now.Add(-181 * 24 * time.Hour)
		recent := now.Add(-179 * 24 * time.Hour)
		e.insertGrant(t, x.ID, old.Add(-time.Hour), old, nil, nil)                                       // expired 181 days ago, not yet cleaned
		e.insertGrant(t, x.ID, recent.Add(-2*time.Hour), recent.Add(time.Hour), &recent, ptr("revoked")) // revoked before its end
		doc, _ := e.exportOf(t, x.Email)
		if len(doc.Entitlements.Grants) != 1 || doc.Entitlements.Grants[0]["status"] != "revoked" {
			t.Fatalf("retained periods: %v", doc.Entitlements.Grants)
		}
	})
}

// --- purge and retention cleanup ---------------------------------------------------------------

func TestEntitlements_PurgeAndRetention(t *testing.T) {
	e := newSignupEnv(t, nil)
	_, s := e.staff(t, "admin")
	u := e.withRole(t, "user")
	now := e.dbNow(t)
	wantStatus(t, e.grantPremium(t, s.AccessToken, u.ID, now.Add(24*time.Hour), 0), 200)
	wantStatus(t, e.grantPremium(t, s.AccessToken, u.ID, now.Add(48*time.Hour), 1), 200)
	// RESTRICT: nothing may erase an account that still has grant rows.
	_, err := e.d.Pool.Exec(context.Background(), `DELETE FROM users WHERE id = $1`, u.ID)
	wantPgError(t, err, "23503", "entitlement_grants_user_id_fkey")
	p, r := e.rightsStart(t, "delete", u.Email)
	wantStatus(t, r, 202)
	wantStatus(t, e.rightsComplete(t, p), 202)
	e.finishRightsJobs(t)
	if rowCount(t, e.d.Pool, `SELECT count(*) FROM entitlement_grants WHERE user_id = $1`, u.ID) != 0 ||
		rowCount(t, e.d.Pool, `SELECT count(*) FROM users WHERE id = $1`, u.ID) != 0 {
		t.Fatal("the purge must remove grant history and then the account")
	}
	// Retention: a period that ended over 180 days ago is removed by the cleanup pass.
	v := e.withRole(t, "user")
	old, kept := now.Add(-181*24*time.Hour), now.Add(-179*24*time.Hour)
	e.insertGrant(t, v.ID, old.Add(-time.Hour), old, nil, nil)
	e.insertGrant(t, v.ID, kept.Add(-time.Hour), kept, &kept, ptr("replaced"))
	e.finishRightsJobs(t) // runs the account job, whose cleanup list includes grants
	if n := rowCount(t, e.d.Pool, `SELECT count(*) FROM entitlement_grants WHERE user_id = $1`, v.ID); n != 1 {
		t.Fatalf("retention left %d rows, want 1", n)
	}
	if rowCount(t, e.d.Pool, `SELECT count(*) FROM entitlement_grants WHERE user_id = $1 AND period_end = $2`, v.ID, kept) != 1 {
		t.Fatal("the 179-day-old period must be kept")
	}
}

// --- contract errors -----------------------------------------------------------------------------

func TestEntitlements_ContractErrors(t *testing.T) {
	t.Run("owner route", func(t *testing.T) {
		rules := generousRules()
		rules.RequestSession.Limit = 1
		e := newSignupEnv(t, rules)
		avoidMinuteBoundary(t, e)
		u := newUser(t, e.q)
		s1 := e.issue(t, u, "A")
		wantProblem(t, e.send(t, "GET", pathMyEntitlements+"?x=1", "", bearer(s1.AccessToken)...), 400, "invalid_request")
		wantProblem(t, e.myPlan(t, s1.AccessToken), 429, "rate_limited")
	})
	t.Run("internal errors", func(t *testing.T) {
		e := newSignupEnv(t, nil)
		_, s := e.staff(t, "super_admin")
		u := e.withRole(t, "user")
		us := e.issue(t, u, "A")
		ends := e.dbNow(t).Add(time.Hour)
		mustExec(t, e.d.Pool, `ALTER TABLE entitlement_grants RENAME TO test_missing_grants`)
		defer mustExec(t, e.d.Pool, `ALTER TABLE test_missing_grants RENAME TO entitlement_grants`)
		wantProblem(t, e.myPlan(t, us.AccessToken), 500, "internal_error")
		wantProblem(t, e.grantPremium(t, s.AccessToken, u.ID, ends, 0), 500, "internal_error")
	})
	t.Run("admin route", func(t *testing.T) {
		e := newSignupEnv(t, nil)
		_, s := e.staff(t, "super_admin")
		u := e.withRole(t, "user")
		ends := e.dbNow(t).Add(time.Hour)
		for _, bad := range []string{"invalid", uuid.Nil.String()} {
			wantProblem(t, e.send(t, "PUT", pathAdminUsers+"/"+bad+"/entitlement", "{}", bearer(s.AccessToken)...), 400, "invalid_request")
		}
		wantProblem(t, e.send(t, "PUT", adminPath(u.ID, "/entitlement"), `{}`, bearer(s.AccessToken)...), 400, "invalid_request")
		avoidMinuteBoundary(t, e)
		wantStatus(t, e.grantPremium(t, s.AccessToken, u.ID, ends, 0), 200)
		mustExec(t, e.d.Pool, `UPDATE rate_limit_counters SET count = 10000 WHERE key LIKE 'admin_write_user_1m:%'`)
		wantProblem(t, e.revokePremium(t, s.AccessToken, u.ID, 1), 429, "rate_limited")
		wantPlan(t, e.adminGet(t, s.AccessToken, adminPath(u.ID, "")), "premium", &ends)
	})
}

// --- migration 00014 -------------------------------------------------------------------------------

func TestMigrations_EntitlementsUpgradeFrom13(t *testing.T) {
	d := pgtest.NewEmpty(t)
	ctx := context.Background()
	if _, err := migrate.Up(ctx, d.URL, migrationsUpTo(t, 13)); err != nil {
		t.Fatal(err)
	}
	seedCleanupData(t, d, 50)
	before := tableCounts(t, d)
	r, err := migrate.Up(ctx, d.URL, migrationsUpTo(t, 14))
	if err != nil || r.Current != 14 || len(r.Applied) != 1 || before != tableCounts(t, d) {
		t.Fatalf("upgrade: %+v %v", r, err)
	}
	user := newID()
	mustExec(t, d.Pool, `INSERT INTO users (id, email, email_normalized, email_verified_at) VALUES ($1, 'p@example.test', 'p@example.test', now())`, user)
	ins := `INSERT INTO entitlement_grants (id, user_id, plan, source, starts_at, ends_at, granted_by, reason_code, ticket_ref,
		closed_at, closed_reason, closed_by, close_reason_code, close_ticket_ref) VALUES ($1, $2, 'premium', 'manual', now(), $3, $4, 'other', 'T-1', $5, $6, $7, $8, $9)`
	mustExec(t, d.Pool, ins, newID(), user, time.Now().Add(time.Hour), uuid.New(), nil, nil, nil, nil, nil)
	_, err = d.Pool.Exec(ctx, ins, newID(), user, time.Now().Add(time.Hour), uuid.New(), nil, nil, nil, nil, nil)
	wantPgError(t, err, "23505", "entitlement_grants_one_open")
	other := newID()
	mustExec(t, d.Pool, `INSERT INTO users (id, email, email_normalized, email_verified_at) VALUES ($1, 'q@example.test', 'q@example.test', now())`, other)
	_, err = d.Pool.Exec(ctx, ins, newID(), other, time.Now().Add(367*24*time.Hour), uuid.New(), nil, nil, nil, nil, nil)
	wantPgError(t, err, pgCheck, "entitlement_grants_period")
	closed := time.Now().Add(time.Minute) // after starts_at whatever the clock skew
	_, err = d.Pool.Exec(ctx, ins, newID(), user, time.Now().Add(time.Hour), uuid.New(), closed, "revoked", uuid.New(), nil, nil)
	wantPgError(t, err, pgCheck, "entitlement_grants_closed") // a revocation must carry its reason and ticket
	_, err = d.Pool.Exec(ctx, ins, newID(), user, time.Now().Add(time.Hour), uuid.New(), closed, nil, nil, nil, nil)
	wantPgError(t, err, pgCheck, "entitlement_grants_closed")
	if _, err := migrate.Up(ctx, d.URL, migrationsUpTo(t, 14)); err != nil {
		t.Fatal("replay:", err)
	}
}
