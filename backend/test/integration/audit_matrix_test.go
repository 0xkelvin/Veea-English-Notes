//go:build integration

package integration

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/audit"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/auth/session"
)

// ev is one expected audit row. For actor, target and session: "" is not checked, "-" must be
// NULL, anything else is the expected id.
type ev struct {
	action, outcome, reason string
	actor, target, session  string
	email                   bool              // email_hmac must be set
	meta                    map[string]string // a subset of metadata
}

type auditRow struct {
	action, outcome, reason string
	actor, target, session  *uuid.UUID
	email                   []byte
	meta                    map[string]string
}

// eventsFor returns the audit rows written for one request, in order.
func (e *signupEnv) eventsFor(t *testing.T, requestID string) []auditRow {
	t.Helper()
	rows, err := e.d.Pool.Query(context.Background(), `SELECT action, outcome, coalesce(reason, ''), actor_user_id,
		target_user_id, session_id, email_hmac, metadata FROM audit_events WHERE request_id = $1 ORDER BY id`, requestID)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var out []auditRow
	for rows.Next() {
		var r auditRow
		var meta []byte
		if err := rows.Scan(&r.action, &r.outcome, &r.reason, &r.actor, &r.target, &r.session, &r.email, &meta); err != nil {
			t.Fatal(err)
		}
		_ = json.Unmarshal(meta, &r.meta)
		out = append(out, r)
	}
	return out
}

func idMatches(want string, got *uuid.UUID) bool {
	switch want {
	case "":
		return true
	case "-":
		return got == nil
	}
	return got != nil && got.String() == want
}

// wantEvents asserts exactly the expected events, in order, for a request: no event missing and
// none duplicated.
func (e *signupEnv) wantEvents(t *testing.T, requestID string, want ...ev) {
	t.Helper()
	got := e.eventsFor(t, requestID)
	describe := func() string {
		var b strings.Builder
		for _, g := range got {
			fmt.Fprintf(&b, "\n  %s %s %s %v", g.action, g.outcome, g.reason, g.meta)
		}
		return b.String()
	}
	if len(got) != len(want) {
		t.Fatalf("request %s: %d audit events, want %d:%s", requestID, len(got), len(want), describe())
	}
	for i, w := range want {
		g := got[i]
		if g.action != w.action || g.outcome != w.outcome || g.reason != w.reason {
			t.Fatalf("event %d: got %s/%s/%q, want %s/%s/%q:%s", i, g.action, g.outcome, g.reason, w.action, w.outcome, w.reason, describe())
		}
		if !idMatches(w.actor, g.actor) || !idMatches(w.target, g.target) || !idMatches(w.session, g.session) {
			t.Fatalf("event %d (%s): actor %v target %v session %v, want %q %q %q", i, g.action, g.actor, g.target, g.session, w.actor, w.target, w.session)
		}
		if w.email && len(g.email) != 32 {
			t.Fatalf("event %d (%s): email_hmac missing", i, g.action)
		}
		for k, v := range w.meta {
			if g.meta[k] != v {
				t.Fatalf("event %d (%s): metadata %s = %q, want %q", i, g.action, k, g.meta[k], v)
			}
		}
	}
}

// call sends a request tagged with requestID, so its audit rows can be found exactly.
func (e *signupEnv) call(t *testing.T, method, path string, body any, requestID string, headers ...string) response {
	t.Helper()
	r := e.send(t, method, path, body, append([]string{"X-Request-Id", requestID}, headers...)...)
	if r.header.Get("X-Request-Id") != requestID {
		t.Fatalf("request id %q was not kept", requestID)
	}
	return r
}

func newRID() string { return "rid-" + strings.ReplaceAll(uuid.NewString(), "-", "") }

func wantStatus(t *testing.T, r response, status int) {
	t.Helper()
	if r.status != status {
		t.Fatalf("status %d, want %d: %s", r.status, status, r.raw)
	}
}

// TRD 11.1 and AC-24: every Phase 1 action writes the expected events, once, with actor and
// target where they exist, and no secrets (the env's hygiene check runs at cleanup over logs,
// audit rows, stored rows and every error body).
func TestAudit_Matrix(t *testing.T) {
	env := newSignupEnv(t, nil)
	ctx := context.Background()
	bearerOf := func(s session.Issued) []string { return bearer(s.AccessToken) }

	t.Run("TRD03 profile and paired email change", func(t *testing.T) {
		u := newUser(t, env.q)
		a := env.issue(t, u, "Email actor")
		rid := newRID()
		wantStatus(t, env.call(t, "PUT", pathProfile, profileInput(0), rid, bearer(a.AccessToken)...), 200)
		env.wantEvents(t, rid, ev{action: "account.profile.update", outcome: "success", actor: u.ID.String(), target: u.ID.String(), session: a.SessionID.String()})
		c, n := env.queueCode(), env.queueCode()
		rid = newRID()
		r := env.call(t, "POST", pathEmailStart, map[string]string{"new_email": newAddress("matrix-change")}, rid, bearer(a.AccessToken)...)
		wantStatus(t, r, 202)
		p := emailProofs{id: r.str("change_id"), currentCode: c, newCode: n, currentToken: r.body["current_email"].(map[string]any)["challenge_token"].(string), newToken: r.body["new_email"].(map[string]any)["challenge_token"].(string)}
		env.remember(p.currentToken, p.newToken)
		env.wantEvents(t, rid, ev{action: "account.email.change.start", outcome: "success", actor: u.ID.String(), target: u.ID.String(), session: a.SessionID.String()}, ev{action: "account.email.change.current.start", outcome: "success", actor: u.ID.String(), target: u.ID.String(), session: a.SessionID.String(), email: true}, ev{action: "account.email.change.new.start", outcome: "success", actor: u.ID.String(), target: u.ID.String(), session: a.SessionID.String(), email: true})
		bad := p
		bad.currentCode = wrongCode(c)
		rid = newRID()
		wantProblem(t, env.call(t, "POST", emailCompletePath(p.id), bad.body(), rid, bearer(a.AccessToken)...), 400, "invalid_code")
		env.wantEvents(t, rid, ev{action: "account.email.change.current.verify", outcome: "failure", reason: "invalid_code", actor: u.ID.String(), target: u.ID.String(), session: a.SessionID.String(), email: true})
		rid = newRID()
		want204(t, env.call(t, "POST", emailCompletePath(p.id), p.body(), rid, bearer(a.AccessToken)...))
		env.wantEvents(t, rid, ev{action: "auth.session.revoke", outcome: "success", actor: u.ID.String(), target: u.ID.String(), session: a.SessionID.String(), meta: map[string]string{"reason": "email_change", "count": "1"}}, ev{action: "account.email.change.complete", outcome: "success", actor: u.ID.String(), target: u.ID.String(), session: a.SessionID.String()})
	})

	t.Run("TRD04 lifecycle and rights", func(t *testing.T) {
		u := newUser(t, env.q)
		a := env.issue(t, u, "Lifecycle actor")
		rid := newRID()
		want204(t, env.call(t, "POST", pathDeactivate, map[string]any{"confirm": true, "expected_revision": 0}, rid, bearer(a.AccessToken)...))
		env.wantEvents(t, rid, ev{action: "auth.session.revoke", outcome: "success", actor: u.ID.String(), target: u.ID.String(), session: a.SessionID.String(), meta: map[string]string{"reason": "deactivated", "count": "1"}}, ev{action: "account.deactivate", outcome: "success", actor: u.ID.String(), target: u.ID.String(), session: a.SessionID.String()})
		p, r := env.rightsStart(t, "reactivate", u.Email)
		wantStatus(t, r, 202)
		rid = newRID()
		want204(t, env.call(t, "POST", p.completePath(), p.body(), rid, rightsHeaders(p.cap)...))
		env.wantEvents(t, rid, ev{action: "account.reactivate", outcome: "success", actor: u.ID.String(), target: u.ID.String(), meta: map[string]string{"operation_id": p.id}})
		p, r = env.rightsStart(t, "export", u.Email)
		wantStatus(t, r, 202)
		rid = newRID()
		wantStatus(t, env.call(t, "POST", p.completePath(), p.body(), rid, rightsHeaders(p.cap)...), 202)
		env.wantEvents(t, rid, ev{action: "account.export.request", outcome: "success", actor: u.ID.String(), target: u.ID.String()})
		export := p
		p, r = env.rightsStart(t, "delete", u.Email)
		wantStatus(t, r, 202)
		rid = newRID()
		wantStatus(t, env.call(t, "POST", p.completePath(), p.body(), rid, rightsHeaders(p.cap)...), 202)
		// The still-pending export is canceled inside the deletion transaction.
		env.wantEvents(t, rid, ev{action: "account.export.cancel", outcome: "success", actor: u.ID.String(), target: u.ID.String(), meta: map[string]string{"operation_id": export.id}},
			ev{action: "auth.session.revoke", outcome: "success", actor: u.ID.String(), target: u.ID.String(), meta: map[string]string{"reason": "account_delete", "count": "0"}}, ev{action: "account.delete.request", outcome: "success", actor: u.ID.String(), target: u.ID.String()})
	})

	t.Run("TRD06 admin", func(t *testing.T) {
		sa, s := env.staff(t, "super_admin")
		u := env.withRole(t, "user")
		env.issue(t, u, "Target")
		actor, target := sa.ID.String(), u.ID.String()
		rid := newRID()
		wantStatus(t, env.call(t, "GET", adminPath(u.ID, ""), "", rid, bearer(s.AccessToken)...), 200)
		env.wantEvents(t, rid, ev{action: "admin.user.view", outcome: "success", actor: actor, target: target, session: s.SessionID.String()})
		rid = newRID()
		wantStatus(t, env.call(t, "POST", adminPath(u.ID, "/lifecycle-transitions"), map[string]any{"action": "suspend",
			"reason_code": "abuse", "ticket_ref": nil, "expected_lifecycle_revision": 0}, rid, bearer(s.AccessToken)...), 200)
		env.wantEvents(t, rid,
			ev{action: "auth.session.revoke", outcome: "success", actor: actor, target: target, session: s.SessionID.String(), meta: map[string]string{"reason": "account_suspended", "count": "1"}},
			ev{action: "admin.user.suspend", outcome: "success", reason: "abuse", actor: actor, target: target, session: s.SessionID.String(), meta: map[string]string{"from_status": "active"}})
		rid = newRID()
		wantStatus(t, env.call(t, "PUT", adminPath(u.ID, "/role"), map[string]any{"role": "admin", "reason_code": "other",
			"ticket_ref": nil, "expected_role_revision": 0}, rid, bearer(s.AccessToken)...), 409)
		env.wantEvents(t, rid) // status_conflict: no event
	})

	t.Run("TRD09 plan management", func(t *testing.T) {
		a, s := env.staff(t, "admin")
		u := env.withRole(t, "user")
		ends := env.dbNow(t).Add(24 * time.Hour).Format(time.RFC3339Nano)
		rid := newRID()
		wantStatus(t, env.call(t, "PUT", adminPath(u.ID, "/entitlement"), map[string]any{"plan": "premium", "ends_at": ends,
			"reason_code": "beta_access", "ticket_ref": "SUP-9", "expected_entitlement_revision": 0}, rid, bearer(s.AccessToken)...), 200)
		env.wantEvents(t, rid, ev{action: "admin.entitlement.grant", outcome: "success", reason: "beta_access", actor: a.ID.String(),
			target: u.ID.String(), session: s.SessionID.String(), meta: map[string]string{"ticket_ref": "SUP-9", "entitlement_revision": "1"}})
		rid = newRID()
		wantStatus(t, env.call(t, "PUT", adminPath(u.ID, "/entitlement"), map[string]any{"plan": "free", "ends_at": nil,
			"reason_code": "granted_in_error", "ticket_ref": "SUP-9", "expected_entitlement_revision": 1}, rid, bearer(s.AccessToken)...), 200)
		env.wantEvents(t, rid, ev{action: "admin.entitlement.revoke", outcome: "success", reason: "granted_in_error", actor: a.ID.String(),
			target: u.ID.String(), meta: map[string]string{"entitlement_revision": "2"}})
	})

	// --- registration (Flows A, B) ---------------------------------------------------------
	t.Run("signup start, new email", func(t *testing.T) {
		rid := newRID()
		wantStatus(t, env.call(t, "POST", pathOTPStart, map[string]string{"email": newAddress("new")}, rid), http.StatusAccepted)
		env.wantEvents(t, rid, ev{action: "auth.signup.start", outcome: "success", actor: "-", target: "-", email: true,
			meta: map[string]string{"delivery": "code", "method": "otp"}})
	})
	t.Run("signup start, existing account", func(t *testing.T) {
		u := newUser(t, env.q)
		rid := newRID()
		wantStatus(t, env.call(t, "POST", pathPasswordStart, map[string]string{"email": u.Email, "password": newPassword()}, rid), http.StatusAccepted)
		env.wantEvents(t, rid, ev{action: "auth.signup.start", outcome: "success", target: "-", email: true,
			meta: map[string]string{"delivery": "none", "method": "password"}})
	})
	t.Run("signup verify: success, wrong code, account exists", func(t *testing.T) {
		addr := newAddress("verify")
		ack := env.startOTP(t, addr)
		code := env.mailedCode(t, addr)
		rid := newRID()
		wantStatus(t, env.call(t, "POST", pathVerify, map[string]any{"challenge_token": ack.str("challenge_token"), "code": wrongCode(code), "device": testDevice}, rid), http.StatusBadRequest)
		env.wantEvents(t, rid, ev{action: "auth.signup.verify", outcome: "failure", reason: "invalid_code", actor: "-", email: true})

		rid = newRID()
		r := env.call(t, "POST", pathVerify, map[string]any{"challenge_token": ack.str("challenge_token"), "code": code, "device": testDevice}, rid)
		wantStatus(t, r, http.StatusCreated)
		uid := userID(r)
		env.wantEvents(t, rid, ev{action: "auth.signup.verify", outcome: "success", actor: uid, target: uid, session: r.str("session_id"), email: true,
			meta: map[string]string{"method": "otp"}})

		other := newAddress("exists")
		ack2 := env.startOTP(t, other)
		code2 := env.mailedCode(t, other)
		now := time.Now()
		_, _ = env.d.Pool.Exec(ctx, `INSERT INTO users (id, email, email_normalized, email_verified_at) VALUES ($1, $2, $3, $4)`,
			uuid.New(), other, strings.ToLower(other), now)
		rid = newRID()
		wantStatus(t, env.call(t, "POST", pathVerify, map[string]any{"challenge_token": ack2.str("challenge_token"), "code": code2, "device": testDevice}, rid), http.StatusConflict)
		env.wantEvents(t, rid, ev{action: "auth.signup.verify", outcome: "failure", reason: "account_exists", email: true})
	})
	t.Run("signup verify rolled back writes no event", func(t *testing.T) {
		addr := newAddress("rolled")
		code := env.queueCode()
		ack := env.startOTP(t, addr)
		mustExec(t, env.d.Pool, `CREATE FUNCTION test_fail_session() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'forced'; END $$`)
		mustExec(t, env.d.Pool, `CREATE TRIGGER test_fail_session BEFORE INSERT ON sessions FOR EACH ROW EXECUTE FUNCTION test_fail_session()`)
		rid := newRID()
		wantStatus(t, env.call(t, "POST", pathVerify, map[string]any{"challenge_token": ack.str("challenge_token"), "code": code, "device": testDevice}, rid), http.StatusInternalServerError)
		mustExec(t, env.d.Pool, `DROP TRIGGER test_fail_session ON sessions`)
		mustExec(t, env.d.Pool, `DROP FUNCTION test_fail_session()`)
		env.wantEvents(t, rid) // the success event rolled back with the account and the session
	})

	// --- sign-in (Flows C, D) --------------------------------------------------------------
	t.Run("OTP sign-in: start, success, exhausted, account unavailable", func(t *testing.T) {
		u := newUser(t, env.q)
		uid := u.ID.String()
		rid := newRID()
		ackR := env.call(t, "POST", pathOTPLoginStart, map[string]string{"email": u.Email}, rid)
		env.wantEvents(t, rid, ev{action: "auth.otp.start", outcome: "success", target: uid, email: true, meta: map[string]string{"delivery": "code"}})
		code := env.mailedCode(t, u.Email)
		rid = newRID()
		r := env.call(t, "POST", pathOTPLoginVerify, map[string]any{"challenge_token": ackR.str("challenge_token"), "code": code, "device": testDevice}, rid)
		wantStatus(t, r, http.StatusOK)
		env.wantEvents(t, rid, ev{action: "auth.otp.verify", outcome: "success", actor: uid, target: uid, session: r.str("session_id"), email: true})

		env.expireCooldownForPurpose(t, "login", u.Email)
		code = env.queueCode()
		ack := env.otpLoginStart(t, u.Email)
		for range 5 {
			env.otpLoginVerify(t, ack.str("challenge_token"), wrongCode(code))
		}
		rid = newRID()
		env.call(t, "POST", pathOTPLoginVerify, map[string]any{"challenge_token": ack.str("challenge_token"), "code": code, "device": testDevice}, rid)
		env.wantEvents(t, rid, ev{action: "auth.otp.verify", outcome: "failure", reason: "attempts_exceeded", target: uid})

		env.expireCooldownForPurpose(t, "login", u.Email)
		code = env.queueCode()
		ack = env.otpLoginStart(t, u.Email)
		mustExec(t, env.d.Pool, `UPDATE users SET status = 'suspended', resume_status = 'active', suspension_reason = 'other' WHERE id = $1`, u.ID)
		rid = newRID()
		env.call(t, "POST", pathOTPLoginVerify, map[string]any{"challenge_token": ack.str("challenge_token"), "code": code, "device": testDevice}, rid)
		env.wantEvents(t, rid, ev{action: "auth.otp.verify", outcome: "failure", reason: "account_unavailable", target: uid})
	})
	t.Run("password sign-in: success, wrong, unknown, inactive", func(t *testing.T) {
		u, pw := env.passwordUser(t)
		uid := u.ID.String()
		body := func(addr, password string) map[string]any {
			return map[string]any{"email": addr, "password": password, "device": testDevice}
		}
		rid := newRID()
		r := env.call(t, "POST", pathPasswordLogin, body(u.Email, pw), rid)
		wantStatus(t, r, http.StatusOK)
		env.wantEvents(t, rid, ev{action: "auth.password.login", outcome: "success", actor: uid, target: uid, session: r.str("session_id"), email: true})
		rid = newRID()
		env.call(t, "POST", pathPasswordLogin, body(u.Email, newPassword()), rid)
		env.wantEvents(t, rid, ev{action: "auth.password.login", outcome: "failure", reason: "invalid_credentials", actor: "-", target: uid, email: true})
		rid = newRID()
		env.call(t, "POST", pathPasswordLogin, body(newAddress("ghost"), newPassword()), rid)
		env.wantEvents(t, rid, ev{action: "auth.password.login", outcome: "failure", reason: "invalid_credentials", actor: "-", target: "-", email: true})
		mustExec(t, env.d.Pool, `UPDATE users SET status = 'deactivated' WHERE id = $1`, u.ID)
		rid = newRID()
		env.call(t, "POST", pathPasswordLogin, body(u.Email, pw), rid)
		env.wantEvents(t, rid, ev{action: "auth.password.login", outcome: "failure", reason: "account_unavailable", target: uid})
	})

	// --- sessions --------------------------------------------------------------------------
	t.Run("refresh: success and unknown are silent, reuse and revoked are audited", func(t *testing.T) {
		u := newUser(t, env.q)
		uid := u.ID.String()
		s := env.issue(t, u, "Phone")
		sid := s.SessionID.String()
		rid := newRID()
		ok := env.call(t, "POST", pathRefresh, map[string]string{"refresh_token": s.RefreshToken}, rid)
		wantStatus(t, ok, http.StatusOK)
		env.wantEvents(t, rid)
		rid = newRID()
		env.call(t, "POST", pathRefresh, map[string]string{"refresh_token": "vrt_" + uuid.NewString()}, rid)
		env.wantEvents(t, rid)
		rid = newRID()
		env.call(t, "POST", pathRefresh, map[string]string{"refresh_token": s.RefreshToken}, rid)
		env.wantEvents(t, rid,
			ev{action: "auth.session.refresh", outcome: "failure", reason: "refresh_reuse", target: uid, session: sid},
			ev{action: "auth.session.revoke", outcome: "success", target: uid, session: sid, meta: map[string]string{"reason": "refresh_reuse", "count": "1"}})
		rid = newRID()
		env.call(t, "POST", pathRefresh, map[string]string{"refresh_token": ok.str("refresh_token")}, rid)
		env.wantEvents(t, rid, ev{action: "auth.session.refresh", outcome: "failure", reason: "session_revoked", target: uid, session: sid})
	})
	t.Run("logout and automatic account_inactive revocation", func(t *testing.T) {
		u := newUser(t, env.q)
		uid := u.ID.String()
		a, b := env.issue(t, u, "Phone"), env.issue(t, u, "Tablet")
		rid := newRID()
		wantStatus(t, env.call(t, "POST", pathLogout, "", rid, bearerOf(a)...), http.StatusNoContent)
		env.wantEvents(t, rid,
			ev{action: "auth.logout", outcome: "success", actor: uid, target: uid, session: a.SessionID.String()},
			ev{action: "auth.session.revoke", outcome: "success", target: uid, session: a.SessionID.String(), meta: map[string]string{"reason": "logout", "count": "1"}})
		mustExec(t, env.d.Pool, `UPDATE users SET status = 'suspended', resume_status = 'active', suspension_reason = 'other' WHERE id = $1`, u.ID)
		rid = newRID()
		wantStatus(t, env.call(t, "GET", pathMe, nil, rid, bearerOf(b)...), http.StatusUnauthorized)
		env.wantEvents(t, rid, ev{action: "auth.session.revoke", outcome: "success", target: uid, session: b.SessionID.String(),
			meta: map[string]string{"reason": "account_inactive", "count": "1"}})
	})
	t.Run("session cap eviction", func(t *testing.T) {
		u, pw := env.passwordUser(t)
		for range session.MaxActive {
			env.issue(t, u, "Old")
		}
		rid := newRID()
		r := env.call(t, "POST", pathPasswordLogin, map[string]any{"email": u.Email, "password": pw, "device": testDevice}, rid)
		wantStatus(t, r, http.StatusOK)
		env.wantEvents(t, rid,
			ev{action: "auth.session.revoke", outcome: "success", target: u.ID.String(), meta: map[string]string{"reason": "session_limit", "count": "1"}},
			ev{action: "auth.password.login", outcome: "success", target: u.ID.String(), session: r.str("session_id")})
	})

	// --- passwords (Flows E, F, G) ---------------------------------------------------------
	t.Run("first-password set: start, refused start, wrong binding, success", func(t *testing.T) {
		u := newUser(t, env.q)
		uid := u.ID.String()
		a, b := env.issue(t, u, "Phone"), env.issue(t, u, "Tablet")
		rid := newRID()
		code := env.queueCode()
		ack := env.call(t, "POST", pathSetStart, "", rid, bearerOf(a)...)
		wantStatus(t, ack, http.StatusAccepted)
		env.wantEvents(t, rid, ev{action: "auth.password.set.start", outcome: "success", actor: uid, target: uid, session: a.SessionID.String()})
		body := map[string]string{"challenge_token": ack.str("challenge_token"), "code": code, "new_password": newPassword()}
		rid = newRID()
		wantStatus(t, env.call(t, "POST", pathSet, body, rid, bearerOf(b)...), http.StatusBadRequest)
		env.wantEvents(t, rid, ev{action: "auth.password.set", outcome: "failure", reason: "invalid_code", actor: uid, session: b.SessionID.String()})
		rid = newRID()
		wantStatus(t, env.call(t, "POST", pathSet, body, rid, bearerOf(a)...), http.StatusNoContent)
		env.wantEvents(t, rid,
			ev{action: "auth.session.revoke", outcome: "success", target: uid, meta: map[string]string{"reason": "password_set", "count": "1"}},
			ev{action: "auth.password.set", outcome: "success", actor: uid, target: uid, session: a.SessionID.String(), meta: map[string]string{"revoked_sessions": "1"}})
		rid = newRID()
		wantStatus(t, env.call(t, "POST", pathSetStart, "", rid, bearerOf(a)...), http.StatusConflict)
		env.wantEvents(t, rid, ev{action: "auth.password.set.start", outcome: "failure", reason: "password_already_set", actor: uid, target: uid})
	})
	t.Run("change: success, wrong current, not set, policy", func(t *testing.T) {
		u, pw := env.passwordUser(t)
		uid := u.ID.String()
		a, _ := env.issue(t, u, "Phone"), env.issue(t, u, "Tablet")
		rid := newRID()
		wantStatus(t, env.call(t, "PUT", pathChange, map[string]string{"current_password": newPassword(), "new_password": newPassword()}, rid, bearerOf(a)...), http.StatusForbidden)
		env.wantEvents(t, rid, ev{action: "auth.password.change", outcome: "failure", reason: "invalid_current_password", actor: uid, target: uid})
		rid = newRID()
		wantStatus(t, env.call(t, "PUT", pathChange, map[string]string{"current_password": pw, "new_password": "short"}, rid, bearerOf(a)...), http.StatusUnprocessableEntity)
		env.wantEvents(t, rid) // input validation is not an account event
		rid = newRID()
		next := newPassword()
		env.remember(next)
		wantStatus(t, env.call(t, "PUT", pathChange, map[string]string{"current_password": pw, "new_password": next}, rid, bearerOf(a)...), http.StatusNoContent)
		env.wantEvents(t, rid,
			ev{action: "auth.session.revoke", outcome: "success", target: uid, meta: map[string]string{"reason": "password_change", "count": "1"}},
			ev{action: "auth.password.change", outcome: "success", actor: uid, target: uid, session: a.SessionID.String()})

		p := newUser(t, env.q)
		ps := env.issue(t, p, "Phone")
		rid = newRID()
		wantStatus(t, env.call(t, "PUT", pathChange, map[string]string{"current_password": "whatever goes here", "new_password": newPassword()}, rid, bearerOf(ps)...), http.StatusConflict)
		env.wantEvents(t, rid, ev{action: "auth.password.change", outcome: "failure", reason: "password_not_set", actor: p.ID.String()})
	})
	t.Run("reset: start, wrong code, success", func(t *testing.T) {
		u, _ := env.passwordUser(t)
		uid := u.ID.String()
		env.issue(t, u, "Phone")
		rid := newRID()
		code := env.queueCode()
		ack := env.call(t, "POST", pathResetStart, map[string]string{"email": u.Email}, rid)
		env.wantEvents(t, rid, ev{action: "auth.password.reset.start", outcome: "success", actor: "-", target: uid, email: true})
		body := func(c string) map[string]string {
			pw := newPassword()
			env.remember(pw)
			return map[string]string{"challenge_token": ack.str("challenge_token"), "code": c, "new_password": pw}
		}
		rid = newRID()
		env.call(t, "POST", pathResetComplete, body(wrongCode(code)), rid)
		env.wantEvents(t, rid, ev{action: "auth.password.reset.complete", outcome: "failure", reason: "invalid_code", target: uid})
		rid = newRID()
		wantStatus(t, env.call(t, "POST", pathResetComplete, body(code), rid), http.StatusNoContent)
		env.wantEvents(t, rid,
			ev{action: "auth.session.revoke", outcome: "success", target: uid, meta: map[string]string{"reason": "password_reset", "count": "1"}},
			ev{action: "auth.password.reset.complete", outcome: "success", actor: uid, target: uid, session: "-"})
	})
	t.Run("session management: revoke other, retry, logout all", func(t *testing.T) {
		u := newUser(t, env.q)
		a, b := env.issue(t, u, "A"), env.issue(t, u, "B")
		uid, sid := u.ID.String(), a.SessionID.String()
		rid := newRID()
		want204(t, env.call(t, "DELETE", pathSessions+"/"+b.SessionID.String(), "", rid, bearerOf(a)...))
		env.wantEvents(t, rid, ev{action: "auth.session.revoke", outcome: "success", actor: uid, target: uid, session: sid,
			meta: map[string]string{"reason": "user_revoked", "count": "1", "target_session_id": b.SessionID.String()}})
		rid = newRID()
		want204(t, env.call(t, "DELETE", pathSessions+"/"+b.SessionID.String(), "", rid, bearerOf(a)...))
		env.wantEvents(t, rid)
		rid = newRID()
		want204(t, env.call(t, "DELETE", pathSessions, "", rid, bearerOf(a)...))
		env.wantEvents(t, rid,
			ev{action: "auth.logout.all", outcome: "success", actor: uid, target: uid, session: sid, meta: map[string]string{"revoked_sessions": "1"}},
			ev{action: "auth.session.revoke", outcome: "success", actor: uid, target: uid, session: sid, meta: map[string]string{"reason": "logout_all", "count": "1"}})
	})

}

// auth.rate_limited (TRD 11.1): one event per rule, subject and window, recorded after the
// refusal, with the subject as email HMAC, user, session or IP.
func TestAudit_RateLimitedIsRecordedOncePerWindow(t *testing.T) {
	rules := generousRules()
	rules.PasswordSignupStartIP.Limit = 10_000
	rules.PasswordLoginFailEmail.Limit = 1
	rules.RequestSession.Limit = 1
	rules.WrongCurrentPasswordUser.Limit = 1
	rules.PasswordLoginIP.Limit = 10_000
	env := newSignupEnv(t, rules)
	avoidMinuteBoundary(t, env)

	limitedTwice := func(t *testing.T, do func(rid string) response, want ev) {
		t.Helper()
		rid := newRID()
		wantStatus(t, do(rid), http.StatusTooManyRequests)
		env.wantEvents(t, rid, want)
		rid = newRID()
		wantStatus(t, do(rid), http.StatusTooManyRequests)
		env.wantEvents(t, rid) // the same limit in the same window: refused, not recorded again
	}
	t.Run("start cooldown", func(t *testing.T) {
		addr := newAddress("cool")
		env.startOTP(t, addr)
		limitedTwice(t, func(rid string) response {
			return env.call(t, "POST", pathOTPStart, map[string]string{"email": addr}, rid)
		}, ev{action: "auth.rate_limited", outcome: "failure", reason: "otp_start_cooldown", target: "-", email: true,
			meta: map[string]string{"rule": "otp_start_cooldown", "subject": "email"}})
	})
	t.Run("password lockout", func(t *testing.T) {
		u, pw := env.passwordUser(t)
		env.login(t, u.Email, newPassword())
		limitedTwice(t, func(rid string) response {
			return env.call(t, "POST", pathPasswordLogin, map[string]any{"email": u.Email, "password": pw, "device": testDevice}, rid)
		}, ev{action: "auth.rate_limited", outcome: "failure", reason: "login_fail_email_15m", email: true,
			meta: map[string]string{"subject": "email"}})
	})
	t.Run("authenticated requests per session", func(t *testing.T) {
		u := newUser(t, env.q)
		s := env.issue(t, u, "Phone")
		env.me(t, s.AccessToken)
		limitedTwice(t, func(rid string) response { return env.call(t, "GET", pathMe, nil, rid, bearer(s.AccessToken)...) },
			ev{action: "auth.rate_limited", outcome: "failure", reason: "request_session_1m", session: s.SessionID.String(),
				meta: map[string]string{"subject": "session"}})
	})
	t.Run("wrong current password per user", func(t *testing.T) {
		u, pw := env.passwordUser(t)
		a := env.issue(t, u, "Phone")
		// RequestSession is 1 per minute here, so each call below uses a fresh session.
		env.change(t, a.AccessToken, newPassword(), newPassword())
		limitedTwice(t, func(rid string) response {
			s := env.issue(t, u, "Phone")
			return env.call(t, "PUT", pathChange, map[string]string{"current_password": pw, "new_password": newPassword()}, rid, bearer(s.AccessToken)...)
		}, ev{action: "auth.rate_limited", outcome: "failure", reason: "wrong_current_password_user_15m", target: u.ID.String(),
			meta: map[string]string{"subject": "user"}})
	})
}

// TRD 7.1 rule 7: a transaction retried after a serialization failure commits its events once.
func TestAudit_RetriedTransactionsDoNotDuplicateEvents(t *testing.T) {
	env := newSignupEnv(t, nil)
	// Fail the first attempt only. A sequence is not transactional, so the rollback of the
	// failed attempt does not reset it.
	mustExec(t, env.d.Pool, `CREATE SEQUENCE test_retry_once`)
	mustExec(t, env.d.Pool, `CREATE FUNCTION test_fail_once() RETURNS trigger LANGUAGE plpgsql AS $$
		BEGIN IF nextval('test_retry_once') = 1 THEN RAISE EXCEPTION 'forced' USING ERRCODE = '40001'; END IF; RETURN NEW; END $$`)

	t.Run("start", func(t *testing.T) {
		mustExec(t, env.d.Pool, `CREATE TRIGGER test_fail_once BEFORE INSERT ON audit_events FOR EACH ROW
			WHEN (NEW.action = 'auth.signup.start') EXECUTE FUNCTION test_fail_once()`)
		defer mustExec(t, env.d.Pool, `DROP TRIGGER test_fail_once ON audit_events`)
		addr := newAddress("retry")
		rid := newRID()
		wantStatus(t, env.call(t, "POST", pathOTPStart, map[string]string{"email": addr}, rid), http.StatusAccepted)
		env.wantEvents(t, rid, ev{action: "auth.signup.start", outcome: "success", meta: map[string]string{"delivery": "code"}})
		if env.retries.Load() != 1 {
			t.Fatalf("expected exactly one retry, got %d", env.retries.Load())
		}
		if rowCount(t, env.d.Pool, `SELECT count(*) FROM otp_challenges WHERE email_normalized = $1`, strings.ToLower(addr)) != 1 ||
			rowCount(t, env.d.Pool, `SELECT count(*) FROM email_outbox`) != 1 {
			t.Fatal("one challenge and one email after the retry")
		}
		env.retries.Store(0)
	})
	t.Run("signup verify", func(t *testing.T) {
		mustExec(t, env.d.Pool, `SELECT setval('test_retry_once', 1, false)`)
		mustExec(t, env.d.Pool, `CREATE TRIGGER test_fail_once BEFORE INSERT ON sessions FOR EACH ROW EXECUTE FUNCTION test_fail_once()`)
		defer mustExec(t, env.d.Pool, `DROP TRIGGER test_fail_once ON sessions`)
		addr := newAddress("retry-verify")
		code := env.queueCode()
		ack := env.startOTP(t, addr)
		rid := newRID()
		r := env.call(t, "POST", pathVerify, map[string]any{"challenge_token": ack.str("challenge_token"), "code": code, "device": testDevice}, rid)
		wantStatus(t, r, http.StatusCreated)
		env.wantEvents(t, rid, ev{action: "auth.signup.verify", outcome: "success", target: userID(r), session: r.str("session_id")})
		if env.retries.Load() != 1 {
			t.Fatalf("expected exactly one retry, got %d", env.retries.Load())
		}
		if rowCount(t, env.d.Pool, `SELECT count(*) FROM users WHERE email_normalized = $1`, strings.ToLower(addr)) != 1 ||
			rowCount(t, env.d.Pool, `SELECT count(*) FROM sessions`) != 1 {
			t.Fatal("one account and one session after the retry")
		}
		env.retries.Store(0)
	})
}

// Client-controlled request metadata never turns a valid request into a 500, and never reaches
// stored rows or logs in a token-shaped form.
func TestAudit_HostileClientMetadataIsHarmless(t *testing.T) {
	env := newSignupEnv(t, nil)
	u, pw := env.passwordUser(t)
	hostile := [][]string{
		{"User-Agent", "evil vct_planted", "X-Request-Id", "vat_planted00"},
		{"User-Agent", strings.Repeat("A", 8000), "X-Request-Id", strings.Repeat("x", 500)},
		{"User-Agent", "VRT_UPPER ‮ rtl", "X-Forwarded-For", "vat_123, ::1, garbage"},
		{"User-Agent", "émoji 🚀 agent", "X-Request-Id", "../../etc/passwd"},
	}
	for i, h := range hostile {
		t.Run(fmt.Sprint(i), func(t *testing.T) {
			login := env.post(t, pathPasswordLogin, map[string]any{"email": u.Email, "password": pw, "device": testDevice}, h...)
			wantStatus(t, login, http.StatusOK)
			wantStatus(t, env.get(t, pathMe, append(bearer(login.str("access_token")), h...)...), http.StatusOK)
			wantStatus(t, env.post(t, pathRefresh, map[string]string{"refresh_token": login.str("refresh_token")}, h...), http.StatusOK)
			wantStatus(t, env.post(t, pathOTPLoginStart, map[string]string{"email": newAddress("h")}, h...), http.StatusAccepted)
			if id := login.header.Get("X-Request-Id"); strings.Contains(strings.ToLower(id), "vat_") || len(id) > 64 {
				t.Fatalf("a hostile request id was echoed: %q", id)
			}
		})
	}
	var stored bytes.Buffer
	rows, _ := env.d.Pool.Query(context.Background(), `SELECT coalesce(user_agent, '') || ' ' || coalesce(request_id, '') FROM audit_events
		UNION ALL SELECT coalesce(user_agent, '') FROM sessions`)
	for rows.Next() {
		var s string
		_ = rows.Scan(&s)
		stored.WriteString(s + "\n")
	}
	rows.Close()
	low := strings.ToLower(stored.String())
	if strings.Contains(low, "vct_") || strings.Contains(low, "vat_") || strings.Contains(low, "vrt_") || strings.Contains(low, "../") {
		t.Fatal("hostile metadata reached stored rows")
	}
	for _, line := range strings.Split(stored.String(), "\n") {
		if len([]rune(line)) > 400 {
			t.Fatal("an oversized user agent was stored")
		}
	}
}

// The audit writer's own redaction is a backstop behind the HTTP sanitizers, so no router test
// reaches it: a token-shaped user agent or request id is stored as [redacted], never refused.
func TestAudit_WriterRedactsClientTextInsteadOfFailing(t *testing.T) {
	d, _ := migratedDB(t)
	err := audit.Record(context.Background(), d.Pool, audit.Event{Action: "auth.logout", Outcome: audit.Success,
		UserAgent: "client VAT_planted", RequestID: "vct_planted01"})
	if err != nil {
		t.Fatalf("client text must be redacted, not refused: %v", err)
	}
	if rowCount(t, d.Pool, `SELECT count(*) FROM audit_events WHERE user_agent = $1 AND request_id = $1`, audit.Redacted) != 1 {
		t.Fatal("both fields must be stored redacted")
	}
}
