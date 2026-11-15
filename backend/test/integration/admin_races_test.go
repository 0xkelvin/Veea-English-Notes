//go:build integration

package integration

import (
	"context"
	"errors"
	"testing"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/admin"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/identity"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/db/sqlc"
)

// =============================================================================================
// Bootstrap (TRD 06 §4.3)
// =============================================================================================

func TestAdmin_Bootstrap(t *testing.T) {
	e := newSignupEnv(t, nil)
	ctx := context.Background()
	u := newUser(t, e.q)
	a, b := e.issue(t, u, "A"), e.issue(t, u, "B")

	t.Run("refuses ineligible targets and bad requests", func(t *testing.T) {
		suspended, unverified := newUser(t, e.q), newUser(t, e.q)
		mustExec(t, e.d.Pool, `UPDATE users SET status = 'suspended', resume_status = 'active', suspension_reason = 'other' WHERE id = $1`, suspended.ID)
		mustExec(t, e.d.Pool, `UPDATE users SET email_verified_at = NULL WHERE id = $1`, unverified.ID)
		unknown := newID()
		missing, _ := identity.NormalizeEmail("nobody@example.test")
		for _, req := range []admin.BootstrapRequest{
			{UserID: &suspended.ID, Mode: admin.ModeFirst}, {UserID: &unverified.ID, Mode: admin.ModeFirst},
			{UserID: &unknown, Mode: admin.ModeFirst}, {Email: &missing, Mode: admin.ModeFirst},
		} {
			if _, err := admin.Bootstrap(ctx, e.d.Pool, req); !errors.Is(err, admin.ErrIneligibleTarget) {
				t.Fatalf("%+v: %v", req, err)
			}
		}
		for _, req := range []admin.BootstrapRequest{
			{Mode: admin.ModeFirst}, {UserID: &u.ID, Mode: "other"}, {UserID: &u.ID, Mode: admin.ModeBreakGlass},
			{UserID: &u.ID, Mode: admin.ModeBreakGlass, ReasonCode: "abuse"}, {UserID: &u.ID, Mode: admin.ModeFirst, ReasonCode: "lost_access"},
			{UserID: &u.ID, Mode: admin.ModeFirst, TicketRef: ptr("a b")},
		} {
			if _, err := admin.Bootstrap(ctx, e.d.Pool, req); !errors.Is(err, admin.ErrInvalidBootstrap) {
				t.Fatalf("%+v: %v", req, err)
			}
		}
		if e.activeSuperAdmins(t) != 0 {
			t.Fatal("a refused bootstrap promoted someone")
		}
	})

	t.Run("first promotes an existing account and revokes its sessions", func(t *testing.T) {
		email, _ := identity.NormalizeEmail(u.Email)
		res, err := admin.Bootstrap(ctx, e.d.Pool, admin.BootstrapRequest{Email: &email, Mode: admin.ModeFirst, TicketRef: ptr("OPS-1")})
		if err != nil || res.UserID != u.ID || res.RoleRevision != 1 || res.RevokedSessions != 2 {
			t.Fatalf("bootstrap: %+v %v", res, err)
		}
		e.assertRevokedPair(t, a)
		e.assertRevokedPair(t, b)
		if rowCount(t, e.d.Pool, `SELECT count(*) FROM audit_events WHERE action = 'admin.role.bootstrap' AND actor_user_id IS NULL
			AND target_user_id = $1 AND reason = 'bootstrap' AND metadata->>'mode' = 'first' AND metadata->>'source' = 'cli'
			AND metadata->>'ticket_ref' = 'OPS-1'`, u.ID) != 1 ||
			rowCount(t, e.d.Pool, `SELECT count(*) FROM audit_events WHERE action = 'auth.session.revoke' AND target_user_id = $1
			AND metadata->>'reason' = 'role_change' AND metadata->>'count' = '2'`, u.ID) != 1 {
			t.Fatal("bootstrap audit")
		}
		s := e.issue(t, u, "Console")
		wantStatus(t, e.adminGet(t, s.AccessToken, pathAdminUsers), 200)
	})

	t.Run("first is refused once an active Super Admin exists; break-glass is not", func(t *testing.T) {
		v := newUser(t, e.q)
		if _, err := admin.Bootstrap(ctx, e.d.Pool, admin.BootstrapRequest{UserID: &v.ID, Mode: admin.ModeFirst}); !errors.Is(err, admin.ErrAlreadyProvisioned) {
			t.Fatal(err)
		}
		if _, err := admin.Bootstrap(ctx, e.d.Pool, admin.BootstrapRequest{UserID: &u.ID, Mode: admin.ModeBreakGlass, ReasonCode: "lost_access"}); !errors.Is(err, admin.ErrIneligibleTarget) {
			t.Fatal("an existing Super Admin cannot be bootstrapped again:", err)
		}
		res, err := admin.Bootstrap(ctx, e.d.Pool, admin.BootstrapRequest{UserID: &v.ID, Mode: admin.ModeBreakGlass, ReasonCode: "lost_access"})
		if err != nil || res.RevokedSessions != 0 || e.activeSuperAdmins(t) != 2 {
			t.Fatalf("break glass: %+v %v", res, err)
		}
		if rowCount(t, e.d.Pool, `SELECT count(*) FROM audit_events WHERE action = 'admin.role.bootstrap' AND target_user_id = $1
			AND reason = 'lost_access' AND metadata->>'mode' = 'break_glass'`, v.ID) != 1 {
			t.Fatal("break-glass audit")
		}
	})

	t.Run("concurrent first bootstraps promote exactly one", func(t *testing.T) {
		e := newSignupEnv(t, nil)
		x, y := newUser(t, e.q), newUser(t, e.q)
		release := e.holdGuard(t)
		errs := make(chan error, 2)
		for _, id := range []sqlc.User{x, y} {
			go func() {
				_, err := admin.Bootstrap(ctx, e.d.Pool, admin.BootstrapRequest{UserID: &id.ID, Mode: admin.ModeFirst})
				errs <- err
			}()
		}
		waitForLockWaiters(t, e, 2)
		release()
		e1, e2 := <-errs, <-errs
		if (e1 == nil) == (e2 == nil) || (!errors.Is(e1, admin.ErrAlreadyProvisioned) && !errors.Is(e2, admin.ErrAlreadyProvisioned)) {
			t.Fatalf("results %v / %v", e1, e2)
		}
		if e.activeSuperAdmins(t) != 1 {
			t.Fatal("exactly one Super Admin must exist")
		}
	})
}

// =============================================================================================
// Last active Super Admin across flows (TRD 06 §4)
// =============================================================================================

func TestAdmin_LastSuperAdminSingle(t *testing.T) {
	e := newSignupEnv(t, nil)
	a, sa := e.staff(t, "super_admin")
	r := e.adminGet(t, sa.AccessToken, adminPath(a.ID, ""))
	wantStatus(t, r, 200)
	if len(strs2(r.body["assignable_roles"])) != 0 || len(strs2(r.body["allowed_actions"])) != 0 {
		t.Fatalf("the last Super Admin may not step down: %s", r.raw)
	}
	wantProblem(t, e.adminRole(t, sa.AccessToken, a.ID, "user", 0), 409, "last_super_admin")
	rid := newRID()
	wantProblem(t, e.call(t, "POST", pathDeactivate, map[string]any{"confirm": true, "expected_revision": 0}, rid, bearer(sa.AccessToken)...), 409, "last_super_admin")
	e.wantEvents(t, rid, ev{action: "account.deactivate", outcome: "failure", reason: "last_super_admin", actor: a.ID.String(), target: a.ID.String(), session: sa.SessionID.String()})
	p, pr := e.rightsStart(t, "delete", a.Email)
	wantStatus(t, pr, 202)
	wantProblem(t, e.rightsComplete(t, p), 409, "last_super_admin")
	if rowCount(t, e.d.Pool, `SELECT count(*) FROM audit_events WHERE action = 'account.delete.verify' AND reason = 'last_super_admin'`) != 1 {
		t.Fatal("deletion refusal audit")
	}
	if u := e.userRow(t, a.ID); u.Status != "active" || u.Role != "super_admin" {
		t.Fatal("the last Super Admin was removed")
	}
	wantStatus(t, e.me(t, sa.AccessToken), 200)
	// Once a successor exists, the same unexpired proof is accepted: it was never consumed.
	b := e.withRole(t, "user")
	wantStatus(t, e.adminRole(t, sa.AccessToken, b.ID, "super_admin", 0), 200)
	wantStatus(t, e.rightsComplete(t, p), 202)
	if e.activeSuperAdmins(t) != 1 || e.userRow(t, b.ID).Role != "super_admin" {
		t.Fatal("successor must remain")
	}
	// A suspended Super Admin does not count.
	c, sc := e.staff(t, "super_admin")
	bs := e.issue(t, b, "B")
	wantStatus(t, e.suspend(t, bs.AccessToken, c.ID), 200)
	wantProblem(t, e.adminRole(t, bs.AccessToken, b.ID, "user", e.userRow(t, b.ID).RoleRevision), 409, "last_super_admin")
	wantUnauthorized(t, e.me(t, sc.AccessToken))
}

func TestAdmin_LastSuperAdminRaces(t *testing.T) {
	// Two active Super Admins A and B. Each case is two guarded requests; whichever the database
	// serializes first succeeds and the other is refused, leaving exactly one active Super Admin.
	type req func(e *signupEnv, t *testing.T) response
	cases := []struct {
		name        string
		build       func(e *signupEnv, t *testing.T, a, b sqlc.User, sa, sb string) (ra, rb req, okA, okB int)
		loserStatus int
		loserCode   string
	}{
		{"both step down", func(e *signupEnv, t *testing.T, a, b sqlc.User, sa, sb string) (req, req, int, int) {
			return func(e *signupEnv, t *testing.T) response { return e.adminRole(t, sa, a.ID, "user", 0) },
				func(e *signupEnv, t *testing.T) response { return e.adminRole(t, sb, b.ID, "user", 0) }, 200, 200
		}, 409, "last_super_admin"},
		{"mutual demotion", func(e *signupEnv, t *testing.T, a, b sqlc.User, sa, sb string) (req, req, int, int) {
			return func(e *signupEnv, t *testing.T) response { return e.adminRole(t, sa, b.ID, "user", 0) },
				func(e *signupEnv, t *testing.T) response { return e.adminRole(t, sb, a.ID, "user", 0) }, 200, 200
		}, 403, "forbidden"}, // the loser's own role is gone when its transaction revalidates it
		{"step down vs self-deactivation", func(e *signupEnv, t *testing.T, a, b sqlc.User, sa, sb string) (req, req, int, int) {
			return func(e *signupEnv, t *testing.T) response { return e.adminRole(t, sa, a.ID, "user", 0) },
				func(e *signupEnv, t *testing.T) response { return e.deactivate(t, sb, 0) }, 200, 204
		}, 409, "last_super_admin"},
		{"step down vs deletion acceptance", func(e *signupEnv, t *testing.T, a, b sqlc.User, sa, sb string) (req, req, int, int) {
			p, r := e.rightsStart(t, "delete", b.Email)
			wantStatus(t, r, 202)
			return func(e *signupEnv, t *testing.T) response { return e.adminRole(t, sa, a.ID, "user", 0) },
				func(e *signupEnv, t *testing.T) response { return e.rightsComplete(t, p) }, 200, 202
		}, 409, "last_super_admin"},
	}
	for _, c := range cases {
		for _, aFirst := range []bool{true, false} {
			order := "/A first"
			if !aFirst {
				order = "/B first"
			}
			t.Run(c.name+order, func(t *testing.T) {
				e := newSignupEnv(t, nil)
				a, sa := e.staff(t, "super_admin")
				b, sb := e.staff(t, "super_admin")
				ra, rb, okA, okB := c.build(e, t, a, b, sa.AccessToken, sb.AccessToken)
				release := e.holdGuard(t) // the test holds L2s; both requests queue in a known order
				chA, chB := make(chan response, 1), make(chan response, 1)
				goA := func() { chA <- ra(e, t) }
				goB := func() { chB <- rb(e, t) }
				if aFirst {
					go goA()
					waitForLockWaiters(t, e, 1)
					go goB()
				} else {
					go goB()
					waitForLockWaiters(t, e, 1)
					go goA()
				}
				waitForLockWaiters(t, e, 2)
				release()
				gotA, gotB := <-chA, <-chB
				winner, winnerOK, loser := gotA, okA, gotB
				if !aFirst {
					winner, winnerOK, loser = gotB, okB, gotA
				}
				if winner.status != winnerOK {
					t.Fatalf("the first serialized request must succeed: %d %s", winner.status, winner.raw)
				}
				wantProblem(t, loser, c.loserStatus, c.loserCode)
				if n := e.activeSuperAdmins(t); n != 1 {
					t.Fatalf("%d active Super Admins remain, want exactly 1", n)
				}
			})
		}
	}
}

// =============================================================================================
// Suspension racing sign-in, refresh and owner deletion (TRD 06 §5.5)
// =============================================================================================

func TestAdmin_SuspensionRaces(t *testing.T) {
	for _, first := range []string{"suspension", "other"} {
		t.Run("password login/"+first+" first", func(t *testing.T) {
			e := newSignupEnv(t, nil)
			_, s := e.staff(t, "admin")
			u, pw := e.passwordUser(t)
			action := "admin.user.suspend"
			if first == "other" {
				action = "auth.password.login"
			}
			release := managementGate(t, e, action)
			sus, login := make(chan response, 1), make(chan response, 1)
			doSuspend := func() { sus <- e.adminTransition(t, s.AccessToken, u.ID, "suspend", "abuse", 0) }
			doLogin := func() { login <- e.login(t, u.Email, pw) }
			if first == "suspension" {
				go doSuspend()
				waitForLockWaiters(t, e, 1)
				go doLogin()
			} else {
				go doLogin()
				waitForLockWaiters(t, e, 1)
				go doSuspend()
			}
			waitForLockWaiters(t, e, 2)
			release()
			wantStatus(t, <-sus, 200)
			l := <-login
			if first == "suspension" {
				if l.status == 200 {
					t.Fatal("a sign-in serialized after the suspension succeeded")
				}
			} else {
				e.assertRevokedPair(t, sessionTokens(t, l)) // issued first, then revoked
			}
		})
		t.Run("refresh/"+first+" first", func(t *testing.T) {
			e := newSignupEnv(t, nil)
			_, s := e.staff(t, "admin")
			u := newUser(t, e.q)
			b := e.issue(t, u, "B")
			sus, ref := make(chan response, 1), make(chan response, 1)
			if first == "other" {
				ctx := context.Background()
				tx, err := e.d.Pool.Begin(ctx)
				if err != nil {
					t.Fatal(err)
				}
				defer tx.Rollback(ctx)
				if _, err := sqlc.New(tx).LockActingSessionForUpdate(ctx, sqlc.LockActingSessionForUpdateParams{ID: b.SessionID, UserID: u.ID}); err != nil {
					t.Fatal(err)
				}
				go func() { ref <- e.refresh(t, b.RefreshToken) }()
				waitForLockWaiters(t, e, 1)
				go func() { sus <- e.adminTransition(t, s.AccessToken, u.ID, "suspend", "abuse", 0) }()
				waitForLockWaiters(t, e, 2)
				if err := tx.Commit(ctx); err != nil {
					t.Fatal(err)
				}
				rotated := sessionTokens(t, <-ref)
				wantStatus(t, <-sus, 200)
				e.assertRevokedPair(t, rotated)
			} else {
				release := managementGate(t, e, "admin.user.suspend")
				go func() { sus <- e.adminTransition(t, s.AccessToken, u.ID, "suspend", "abuse", 0) }()
				waitForLockWaiters(t, e, 1)
				go func() { ref <- e.refresh(t, b.RefreshToken) }()
				waitForLockWaiters(t, e, 2)
				release()
				wantStatus(t, <-sus, 200)
				wantUnauthorized(t, <-ref)
			}
			e.assertRevokedPair(t, b)
		})
		t.Run("owner deletion/"+first+" first", func(t *testing.T) {
			e := newSignupEnv(t, nil)
			_, s := e.staff(t, "admin")
			u := newUser(t, e.q)
			p, r := e.rightsStart(t, "delete", u.Email)
			wantStatus(t, r, 202)
			action := "admin.user.suspend"
			if first == "other" {
				action = "account.delete.request"
			}
			release := managementGate(t, e, action)
			sus, del := make(chan response, 1), make(chan response, 1)
			doSuspend := func() { sus <- e.adminTransition(t, s.AccessToken, u.ID, "suspend", "abuse", 0) }
			doDelete := func() { del <- e.rightsComplete(t, p) }
			if first == "suspension" {
				go doSuspend()
				waitForLockWaiters(t, e, 1)
				go doDelete()
			} else {
				go doDelete()
				waitForLockWaiters(t, e, 1)
				go doSuspend()
			}
			waitForLockWaiters(t, e, 2) // the second waits on L2s, held by the first
			release()
			if first == "suspension" {
				wantStatus(t, <-sus, 200)
				wantProblem(t, <-del, 409, "lifecycle_conflict")
				if e.userRow(t, u.ID).Status != "suspended" {
					t.Fatal("suspension must stand")
				}
				// The suspended owner can still start a new proof and delete.
				e.expireCooldownForPurpose(t, "account_delete", u.Email)
				p2, r := e.rightsStart(t, "delete", u.Email)
				wantStatus(t, r, 202)
				wantStatus(t, e.rightsComplete(t, p2), 202)
			} else {
				wantStatus(t, <-del, 202)
				res := <-sus
				wantProblem(t, res, 409, "status_conflict")
				if res.str("account_status") != "pending_deletion" {
					t.Fatalf("account_status: %s", res.raw)
				}
			}
			if e.userRow(t, u.ID).Status == "active" {
				t.Fatal("no flow may leave the account active")
			}
		})
	}
}

// =============================================================================================
// Audit (TRD 06 §9; TRD 01 §11.1)
// =============================================================================================

func TestAdmin_AuditEvents(t *testing.T) {
	e := newSignupEnv(t, nil)
	sa, s := e.staff(t, "super_admin")
	actor, sess := sa.ID.String(), s.SessionID.String()
	u := e.withRole(t, "user")
	v := e.issue(t, u, "V")
	target := u.ID.String()
	rid := newRID()
	wantStatus(t, e.call(t, "GET", pathAdminUsers+"?email="+u.Email, "", rid, bearer(s.AccessToken)...), 200)
	e.wantEvents(t, rid, ev{action: "admin.user.search", outcome: "success", actor: actor, target: "-", session: sess, email: true,
		meta: map[string]string{"filters": "email", "result_count": "1", "page": "first"}})
	rid = newRID()
	wantStatus(t, e.call(t, "GET", adminPath(u.ID, ""), "", rid, bearer(s.AccessToken)...), 200)
	e.wantEvents(t, rid, ev{action: "admin.user.view", outcome: "success", actor: actor, target: target, session: sess})
	rid = newRID()
	wantStatus(t, e.call(t, "GET", adminPath(u.ID, "/sessions"), "", rid, bearer(s.AccessToken)...), 200)
	e.wantEvents(t, rid, ev{action: "admin.user.sessions.view", outcome: "success", actor: actor, target: target, session: sess})
	rid = newRID()
	wantStatus(t, e.call(t, "POST", adminPath(u.ID, "/session-revocations"), map[string]any{"session_id": v.SessionID.String(),
		"reason_code": "security_review", "ticket_ref": nil}, rid, bearer(s.AccessToken)...), 200)
	e.wantEvents(t, rid,
		ev{action: "auth.session.revoke", outcome: "success", actor: actor, target: target, session: sess, meta: map[string]string{"reason": "admin_revoked", "count": "1", "target_session_id": v.SessionID.String()}},
		ev{action: "admin.sessions.revoke", outcome: "success", reason: "security_review", actor: actor, target: target, session: sess, meta: map[string]string{"count": "1"}})
	e.issue(t, u, "W")
	rid = newRID()
	wantStatus(t, e.call(t, "POST", adminPath(u.ID, "/lifecycle-transitions"), map[string]any{"action": "suspend", "reason_code": "fraud",
		"ticket_ref": "SUP-7", "expected_lifecycle_revision": 0}, rid, bearer(s.AccessToken)...), 200)
	e.wantEvents(t, rid,
		ev{action: "auth.session.revoke", outcome: "success", actor: actor, target: target, session: sess, meta: map[string]string{"reason": "account_suspended", "count": "1"}},
		ev{action: "admin.user.suspend", outcome: "success", reason: "fraud", actor: actor, target: target, session: sess, meta: map[string]string{"from_status": "active", "lifecycle_revision": "1", "ticket_ref": "SUP-7"}})
	rid = newRID()
	wantStatus(t, e.call(t, "POST", adminPath(u.ID, "/lifecycle-transitions"), map[string]any{"action": "suspend", "reason_code": "fraud",
		"ticket_ref": nil, "expected_lifecycle_revision": 0}, rid, bearer(s.AccessToken)...), 200)
	e.wantEvents(t, rid) // no-op
	rid = newRID()
	wantStatus(t, e.call(t, "POST", adminPath(u.ID, "/lifecycle-transitions"), map[string]any{"action": "reinstate", "reason_code": "issue_resolved",
		"ticket_ref": nil, "expected_lifecycle_revision": 1}, rid, bearer(s.AccessToken)...), 200)
	e.wantEvents(t, rid, ev{action: "admin.user.reinstate", outcome: "success", reason: "issue_resolved", actor: actor, target: target, session: sess,
		meta: map[string]string{"to_status": "active", "lifecycle_revision": "2"}})
	e.issue(t, u, "X")
	rid = newRID()
	wantStatus(t, e.call(t, "PUT", adminPath(u.ID, "/role"), map[string]any{"role": "admin", "reason_code": "staffing_change",
		"ticket_ref": nil, "expected_role_revision": 0}, rid, bearer(s.AccessToken)...), 200)
	e.wantEvents(t, rid,
		ev{action: "auth.session.revoke", outcome: "success", actor: actor, target: target, session: sess, meta: map[string]string{"reason": "role_change", "count": "1"}},
		ev{action: "admin.role.change", outcome: "success", reason: "staffing_change", actor: actor, target: target, session: sess, meta: map[string]string{"from_role": "user", "to_role": "admin", "role_revision": "1"}})
	rid = newRID()
	wantStatus(t, e.call(t, "PUT", adminPath(u.ID, "/role"), map[string]any{"role": "user", "reason_code": "access_review",
		"ticket_ref": nil, "expected_role_revision": 1}, rid, bearer(s.AccessToken)...), 200)
	e.wantEvents(t, rid, ev{action: "admin.role.change", outcome: "success", reason: "access_review", actor: actor, target: target, session: sess,
		meta: map[string]string{"from_role": "admin", "to_role": "user", "role_revision": "2"}}) // demotion revokes nothing
	rid = newRID()
	wantProblem(t, e.call(t, "PUT", adminPath(sa.ID, "/role"), map[string]any{"role": "user", "reason_code": "access_review",
		"ticket_ref": nil, "expected_role_revision": 0}, rid, bearer(s.AccessToken)...), 409, "last_super_admin")
	e.wantEvents(t, rid, ev{action: "admin.access.denied", outcome: "failure", reason: "last_super_admin", actor: actor, target: actor, session: sess,
		meta: map[string]string{"operation": "role_change"}})

	// Denials are recorded once per session, operation and reason per minute.
	_, us := e.staff(t, "user")
	for i := range 3 {
		rid = newRID()
		wantProblem(t, e.call(t, "GET", pathAdminUsers, "", rid, bearer(us.AccessToken)...), 403, "forbidden")
		if i == 0 {
			e.wantEvents(t, rid, ev{action: "admin.access.denied", outcome: "failure", reason: "insufficient_role", target: "-", session: us.SessionID.String(),
				meta: map[string]string{"operation": "search"}})
		} else {
			e.wantEvents(t, rid)
		}
	}
	_, as := e.staff(t, "admin")
	rid = newRID()
	wantProblem(t, e.call(t, "GET", adminPath(sa.ID, ""), "", rid, bearer(as.AccessToken)...), 403, "target_not_permitted")
	e.wantEvents(t, rid, ev{action: "admin.access.denied", outcome: "failure", reason: "target_not_permitted", target: actor, meta: map[string]string{"operation": "view"}})
	wantMetric(t, e.metrics, `admin_actions_total{action="suspend",result="success"}`, 1)
	wantMetric(t, e.metrics, `admin_actions_total{action="suspend",result="noop"}`, 1)
	wantMetric(t, e.metrics, `auth_sessions_revoked_total{reason="account_suspended"}`, 1)
	wantMetric(t, e.metrics, `admin_active_super_admins`, 1)
}

func TestAdmin_TransactionalAuditAndRetry(t *testing.T) {
	e := newSignupEnv(t, nil)
	_, s := e.staff(t, "admin")
	u := e.withRole(t, "user")
	v := e.issue(t, u, "V")
	mustExec(t, e.d.Pool, `CREATE FUNCTION fail_admin_audit() RETURNS trigger LANGUAGE plpgsql AS $$
	BEGIN RAISE EXCEPTION 'forced'; END $$`)
	mustExec(t, e.d.Pool, `CREATE TRIGGER fail_admin_audit BEFORE INSERT ON audit_events
	FOR EACH ROW WHEN (NEW.action IN ('admin.user.suspend', 'admin.user.view')) EXECUTE FUNCTION fail_admin_audit()`)
	wantProblem(t, e.suspend(t, s.AccessToken, u.ID), 500, "internal_error")
	if e.userRow(t, u.ID).Status != "active" || e.sessionRow(t, v.SessionID).revoked {
		t.Fatal("a suspension whose audit failed committed")
	}
	wantStatus(t, e.me(t, v.AccessToken), 200)
	r := e.adminGet(t, s.AccessToken, adminPath(u.ID, ""))
	wantProblem(t, r, 500, "internal_error")
	mustExec(t, e.d.Pool, `DROP TRIGGER fail_admin_audit ON audit_events`)
	mustExec(t, e.d.Pool, `CREATE SEQUENCE retry_admin_once`)
	mustExec(t, e.d.Pool, `CREATE FUNCTION retry_admin_audit() RETURNS trigger LANGUAGE plpgsql AS $$
	BEGIN IF nextval('retry_admin_once') = 1 THEN RAISE EXCEPTION 'forced' USING ERRCODE = '40001'; END IF; RETURN NEW; END $$`)
	mustExec(t, e.d.Pool, `CREATE TRIGGER retry_admin_audit BEFORE INSERT ON audit_events
	FOR EACH ROW WHEN (NEW.action = 'admin.user.suspend') EXECUTE FUNCTION retry_admin_audit()`)
	wantStatus(t, e.suspend(t, s.AccessToken, u.ID), 200)
	if e.retries.Swap(0) != 1 {
		t.Fatal("expected exactly one forced transaction retry")
	}
	if rowCount(t, e.d.Pool, `SELECT count(*) FROM audit_events WHERE action IN ('admin.user.suspend')`) != 1 ||
		rowCount(t, e.d.Pool, `SELECT count(*) FROM audit_events WHERE action = 'auth.session.revoke' AND metadata->>'reason' = 'account_suspended'`) != 1 {
		t.Fatal("a retried transaction duplicated events")
	}
	wantMetric(t, e.metrics, `auth_sessions_revoked_total{reason="account_suspended"}`, 1)
	e.assertRevokedPair(t, v)
}
