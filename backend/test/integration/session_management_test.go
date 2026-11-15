//go:build integration

package integration

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/auth/session"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/db/sqlc"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/migrate"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/pgtest"
)

const pathSessions = "/v1/me/sessions"

func (e *signupEnv) removeSession(t *testing.T, access string, target uuid.UUID) response {
	t.Helper()
	return e.send(t, "DELETE", pathSessions+"/"+target.String(), "", bearer(access)...)
}

func (e *signupEnv) logoutAll(t *testing.T, access string) response {
	t.Helper()
	return e.send(t, "DELETE", pathSessions, "", bearer(access)...)
}

func sessionTokens(t *testing.T, r response) session.Issued {
	t.Helper()
	wantStatus(t, r, http.StatusOK)
	id, err := uuid.Parse(r.str("session_id"))
	if err != nil {
		t.Fatal(err)
	}
	return session.Issued{SessionID: id, AccessToken: r.str("access_token"), RefreshToken: r.str("refresh_token")}
}

func (e *signupEnv) assertRevokedPair(t *testing.T, s session.Issued) {
	t.Helper()
	wantUnauthorized(t, e.me(t, s.AccessToken))
	wantUnauthorized(t, e.refresh(t, s.RefreshToken))
}

func TestSessionManagement_ListOwnLiveSessions(t *testing.T) {
	e := newSignupEnv(t, nil)
	u, pw := e.passwordUser(t)
	a := sessionTokens(t, e.login(t, u.Email, pw)) // real router issuance
	b, c := e.issue(t, u, "Same label"), e.issue(t, u, "Same label")
	d := e.issue(t, u, "Refreshable")
	x := e.issue(t, newUser(t, e.q), "Foreign")
	mustExec(t, e.d.Pool, `UPDATE sessions SET last_seen_at = now() + interval '1 day', platform = 'android'
		WHERE id = $1 OR id = $2`, b.SessionID, c.SessionID)
	mustExec(t, e.d.Pool, `UPDATE sessions SET access_expires_at = now() - interval '1 second' WHERE id = $1`, d.SessionID)
	// The actual access predicate permits this edge case; do not hide the current usable row.
	mustExec(t, e.d.Pool, `UPDATE sessions SET refresh_expires_at = now() - interval '1 second' WHERE id = $1`, a.SessionID)
	for _, state := range []string{"both expired", "absolute expired", "revoked"} {
		s := e.issue(t, u, state)
		switch state {
		case "both expired":
			mustExec(t, e.d.Pool, `UPDATE sessions SET access_expires_at = now(), refresh_expires_at = now() WHERE id = $1`, s.SessionID)
		case "absolute expired":
			mustExec(t, e.d.Pool, `UPDATE sessions SET absolute_expires_at = now() WHERE id = $1`, s.SessionID)
		case "revoked":
			mustExec(t, e.d.Pool, `UPDATE sessions SET revoked_at = now(), revoked_reason = 'logout' WHERE id = $1`, s.SessionID)
		}
	}
	r := e.get(t, pathSessions, bearer(a.AccessToken)...)
	wantStatus(t, r, http.StatusOK)
	var out struct {
		Current string           `json:"current_session_id"`
		Rows    []map[string]any `json:"sessions"`
	}
	if err := json.Unmarshal(r.raw, &out); err != nil {
		t.Fatal(err)
	}
	if len(r.body) != 2 || out.Current != a.SessionID.String() || len(out.Rows) != 4 {
		t.Fatalf("unexpected list shape or membership: %s", r.raw)
	}
	want := []string{b.SessionID.String(), c.SessionID.String()}
	sort.Strings(want)
	if out.Rows[0]["id"] != want[0] || out.Rows[1]["id"] != want[1] {
		t.Fatal("tie ordering must use session UUID")
	}
	current := 0
	members := map[string]bool{a.SessionID.String(): true, b.SessionID.String(): true, c.SessionID.String(): true, d.SessionID.String(): true}
	for _, row := range out.Rows {
		id, _ := row["id"].(string)
		if !members[id] || id == x.SessionID.String() {
			t.Fatal("list contains an unexpected or foreign session")
		}
		delete(members, id)
		if len(row) != 8 {
			t.Fatalf("session projection leaked or omitted fields: %v", row)
		}
		if row["is_current"] == true {
			current++
			if row["id"] != out.Current {
				t.Fatal("current-session identity is not the bearer principal")
			}
		}
	}
	if current != 1 {
		t.Fatalf("current markers=%d", current)
	}
	if len(members) != 0 {
		t.Fatal("list omitted a live owned session")
	}
}

func TestSessionManagement_OwnershipRevocationAndRetries(t *testing.T) {
	e := newSignupEnv(t, nil)
	u := newUser(t, e.q) // passwordless bearer is sufficient
	a, b, c := e.issue(t, u, "A"), e.issue(t, u, "B"), e.issue(t, u, "C")
	foreign := e.issue(t, newUser(t, e.q), "Foreign")
	// Admin role does not grant a bypass on this self-service route.
	mustExec(t, e.d.Pool, `UPDATE users SET role = 'admin' WHERE id = $1`, u.ID)
	f := e.removeSession(t, a.AccessToken, foreign.SessionID)
	n := e.removeSession(t, a.AccessToken, uuid.New())
	wantProblem(t, f, 404, "not_found")
	wantProblem(t, n, 404, "not_found")
	if withoutRequestID(f) != withoutRequestID(n) {
		t.Fatal("foreign and unknown session IDs are distinguishable")
	}
	wantProblem(t, e.removeSession(t, a.AccessToken, a.SessionID), 409, "current_session_not_allowed")
	for _, id := range []string{"invalid", uuid.Nil.String(), strings.ReplaceAll(b.SessionID.String(), "-", "")} {
		wantProblem(t, e.send(t, "DELETE", pathSessions+"/"+id, "", bearer(a.AccessToken)...), 400, "invalid_request")
	}
	latestB := sessionTokens(t, e.refresh(t, b.RefreshToken))
	legacy := e.issue(t, u, "Already logged out")
	mustExec(t, e.d.Pool, `UPDATE sessions SET revoked_at = now(), revoked_reason = 'logout' WHERE id = $1`, legacy.SessionID)
	want204(t, e.removeSession(t, a.AccessToken, legacy.SessionID))
	if e.sessionRow(t, legacy.SessionID).reason != "logout" {
		t.Fatal("a no-op overwrote a preexisting revocation reason")
	}
	r := e.removeSession(t, a.AccessToken, b.SessionID)
	want204(t, r)
	var revokedAt time.Time
	if err := e.d.Pool.QueryRow(context.Background(), `SELECT revoked_at FROM sessions WHERE id = $1`, b.SessionID).Scan(&revokedAt); err != nil {
		t.Fatal(err)
	}
	want204(t, e.removeSession(t, a.AccessToken, b.SessionID))
	if rowCount(t, e.d.Pool, `SELECT count(*) FROM sessions WHERE id = $1 AND revoked_at = $2 AND revoked_reason = 'user_revoked'`, b.SessionID, revokedAt) != 1 {
		t.Fatal("retry changed revocation history")
	}
	e.assertRevokedPair(t, latestB)
	e.assertRevokedPair(t, b) // consumed refresh cannot resurrect the row or change its reason
	for _, s := range []session.Issued{a, c, foreign} {
		wantStatus(t, e.me(t, s.AccessToken), 200)
		wantStatus(t, e.refresh(t, s.RefreshToken), 200)
	}
	wantMetric(t, e.metrics, `auth_sessions_revoked_total{reason="user_revoked"}`, 1)
	if e.sessionRow(t, b.SessionID).reason != "user_revoked" {
		t.Fatal("a consumed refresh overwrote the revocation reason")
	}
}

func TestSessionManagement_LogoutAllAndContractErrors(t *testing.T) {
	e := newSignupEnv(t, nil)
	u := newUser(t, e.q)
	a, b := e.issue(t, u, "A"), e.issue(t, u, "B")
	expired := e.issue(t, u, "Expired but retained")
	mustExec(t, e.d.Pool, `UPDATE sessions SET access_expires_at = now(), refresh_expires_at = now() WHERE id = $1`, expired.SessionID)
	x := e.issue(t, newUser(t, e.q), "X")
	for _, method := range []string{"GET", "DELETE"} {
		wantProblem(t, e.send(t, method, pathSessions+"?user_id="+u.ID.String(), "", bearer(a.AccessToken)...), 400, "invalid_request")
	}
	wantProblem(t, e.send(t, "DELETE", pathSessions+"/"+b.SessionID.String()+"?x=1", "", bearer(a.AccessToken)...), 400, "invalid_request")
	for _, path := range []string{pathSessions, pathSessions + "/invalid"} {
		for _, tok := range []string{"invalid", a.RefreshToken} {
			wantUnauthorized(t, e.send(t, "DELETE", path, "", bearer(tok)...))
		}
	}
	// Bodies cannot select an owner; ignored even without a valid JSON object.
	want204(t, e.send(t, "DELETE", pathSessions, "not JSON", bearer(a.AccessToken)...))
	e.assertRevokedPair(t, a)
	e.assertRevokedPair(t, b)
	wantUnauthorized(t, e.logoutAll(t, a.AccessToken))
	wantStatus(t, e.me(t, x.AccessToken), 200)
	wantStatus(t, e.refresh(t, x.RefreshToken), 200)
	if e.sessionRow(t, expired.SessionID).reason != "logout_all" {
		t.Fatal("bulk sign-out omitted an expired unrevoked row")
	}
	wantMetric(t, e.metrics, `auth_sessions_revoked_total{reason="logout_all"}`, 3)
}

func TestSessionManagement_RateLimitsAndInternalErrors(t *testing.T) {
	t.Run("rate limits", func(t *testing.T) {
		rules := generousRules()
		rules.RequestSession.Limit = 1
		e := newSignupEnv(t, rules)
		avoidMinuteBoundary(t, e)
		for _, op := range []string{"list", "one", "all"} {
			u := newUser(t, e.q)
			a, b := e.issue(t, u, "A"), e.issue(t, u, "B")
			wantStatus(t, e.me(t, a.AccessToken), 200)
			var r response
			switch op {
			case "list":
				r = e.get(t, pathSessions, bearer(a.AccessToken)...)
			case "one":
				r = e.removeSession(t, a.AccessToken, b.SessionID)
			case "all":
				r = e.logoutAll(t, a.AccessToken)
			}
			wantProblem(t, r, 429, "rate_limited")
			if e.sessionRow(t, a.SessionID).revoked || e.sessionRow(t, b.SessionID).revoked {
				t.Fatal("limited management request changed a session")
			}
		}
	})
	t.Run("internal mapping on every route", func(t *testing.T) {
		e := newSignupEnv(t, nil)
		u := newUser(t, e.q)
		a, b := e.issue(t, u, "A"), e.issue(t, u, "B")
		// Authentication does not read this field; management projection/acting-row lock do.
		mustExec(t, e.d.Pool, `ALTER TABLE sessions RENAME COLUMN device_name TO test_missing_column`)
		defer mustExec(t, e.d.Pool, `ALTER TABLE sessions RENAME COLUMN test_missing_column TO device_name`)
		for _, r := range []response{e.get(t, pathSessions, bearer(a.AccessToken)...), e.removeSession(t, a.AccessToken, b.SessionID), e.logoutAll(t, a.AccessToken)} {
			wantProblem(t, r, 500, "internal_error")
		}
	})
}

func TestSessionManagement_AuthenticationAndListRevalidation(t *testing.T) {
	for _, state := range []string{"access expired", "absolute expired", "revoked", "inactive", "unverified"} {
		t.Run(state, func(t *testing.T) {
			e := newSignupEnv(t, nil)
			u := newUser(t, e.q)
			a, b := e.issue(t, u, "A"), e.issue(t, u, "B")
			switch state {
			case "access expired":
				mustExec(t, e.d.Pool, `UPDATE sessions SET access_expires_at = now() WHERE id = $1`, a.SessionID)
			case "absolute expired":
				mustExec(t, e.d.Pool, `UPDATE sessions SET absolute_expires_at = now() WHERE id = $1`, a.SessionID)
			case "revoked":
				mustExec(t, e.d.Pool, `UPDATE sessions SET revoked_at = now(), revoked_reason = 'logout' WHERE id = $1`, a.SessionID)
			case "inactive":
				mustExec(t, e.d.Pool, `UPDATE users SET status = 'suspended', resume_status = 'active', suspension_reason = 'other' WHERE id = $1`, u.ID)
			case "unverified":
				mustExec(t, e.d.Pool, `UPDATE users SET email_verified_at = NULL WHERE id = $1`, u.ID)
			}
			wantUnauthorized(t, e.get(t, pathSessions, bearer(a.AccessToken)...))
			wantUnauthorized(t, e.removeSession(t, a.AccessToken, b.SessionID))
			wantUnauthorized(t, e.logoutAll(t, a.AccessToken))
			if e.sessionRow(t, b.SessionID).revoked {
				t.Fatal("unauthorized management request changed another session")
			}
		})
	}
	t.Run("list rechecks after middleware read", func(t *testing.T) {
		e := newSignupEnv(t, nil)
		u := newUser(t, e.q)
		a := e.issue(t, u, "A")
		mustExec(t, e.d.Pool, `UPDATE sessions SET last_seen_at = now() - interval '10 minutes' WHERE id = $1`, a.SessionID)
		tx, err := e.d.Pool.Begin(context.Background())
		if err != nil {
			t.Fatal(err)
		}
		defer tx.Rollback(context.Background())
		if _, err := sqlc.New(tx).LockActingSessionForUpdate(context.Background(), sqlc.LockActingSessionForUpdateParams{ID: a.SessionID, UserID: u.ID}); err != nil {
			t.Fatal(err)
		}
		out := make(chan response, 1)
		go func() { out <- e.get(t, pathSessions, bearer(a.AccessToken)...) }()
		waitForLockWaiters(t, e, 1) // auth read succeeded and its throttled last-seen touch waits
		if _, err := sqlc.New(tx).RevokeSession(context.Background(), sqlc.RevokeSessionParams{ID: a.SessionID, UserID: u.ID, Reason: ptr("logout")}); err != nil {
			t.Fatal(err)
		}
		if err := tx.Commit(context.Background()); err != nil {
			t.Fatal(err)
		}
		wantUnauthorized(t, <-out)
	})
}

func TestSessionManagement_TransactionalAuditAndRetry(t *testing.T) {
	for _, bulk := range []bool{false, true} {
		t.Run(fmt.Sprintf("bulk=%v", bulk), func(t *testing.T) {
			e := newSignupEnv(t, nil)
			u := newUser(t, e.q)
			a, b := e.issue(t, u, "A"), e.issue(t, u, "B")
			mustExec(t, e.d.Pool, `CREATE FUNCTION fail_management_audit() RETURNS trigger LANGUAGE plpgsql AS $$
			BEGIN RAISE EXCEPTION 'forced'; END $$`)
			mustExec(t, e.d.Pool, `CREATE TRIGGER fail_management_audit BEFORE INSERT ON audit_events
			FOR EACH ROW WHEN (NEW.action = 'auth.session.revoke') EXECUTE FUNCTION fail_management_audit()`)
			call := func() response {
				if bulk {
					return e.logoutAll(t, a.AccessToken)
				}
				return e.removeSession(t, a.AccessToken, b.SessionID)
			}
			wantProblem(t, call(), 500, "internal_error")
			if e.sessionRow(t, a.SessionID).revoked || e.sessionRow(t, b.SessionID).revoked || rowCount(t, e.d.Pool, `SELECT count(*) FROM audit_events WHERE action IN ('auth.logout.all', 'auth.session.revoke')`) != 0 {
				t.Fatal("revocation or audit escaped rollback")
			}
			wantStatus(t, e.me(t, b.AccessToken), 200)
			b = sessionTokens(t, e.refresh(t, b.RefreshToken))
			reason, count := "user_revoked", float64(1)
			if bulk {
				reason, count = "logout_all", 2
			}
			wantMetric(t, e.metrics, `auth_sessions_revoked_total{reason="`+reason+`"}`, 0)
			mustExec(t, e.d.Pool, `DROP TRIGGER fail_management_audit ON audit_events`)
			mustExec(t, e.d.Pool, `CREATE SEQUENCE retry_management_once`)
			mustExec(t, e.d.Pool, `CREATE FUNCTION retry_management_audit() RETURNS trigger LANGUAGE plpgsql AS $$
			BEGIN IF nextval('retry_management_once') = 1 THEN RAISE EXCEPTION 'forced' USING ERRCODE = '40001'; END IF; RETURN NEW; END $$`)
			mustExec(t, e.d.Pool, `CREATE TRIGGER retry_management_audit BEFORE INSERT ON audit_events
			FOR EACH ROW WHEN (NEW.action = 'auth.session.revoke') EXECUTE FUNCTION retry_management_audit()`)
			want204(t, call())
			if e.retries.Swap(0) != 1 {
				t.Fatal("expected exactly one forced transaction retry")
			}
			if rowCount(t, e.d.Pool, `SELECT count(*) FROM audit_events WHERE action = 'auth.session.revoke' AND metadata->>'reason' = $1`, reason) != 1 {
				t.Fatal("retry duplicated the event")
			}
			if bulk && rowCount(t, e.d.Pool, `SELECT count(*) FROM audit_events WHERE action = 'auth.logout.all'`) != 1 {
				t.Fatal("retry duplicated logout-all event")
			}
			wantMetric(t, e.metrics, `auth_sessions_revoked_total{reason="`+reason+`"}`, count)
			e.assertRevokedPair(t, b)
		})
	}
}

// A transaction trigger waits on an advisory lock only after its real row locks are held.
// Observing both waiters proves which operation owns L3 (or the refresh row), without sleeps.
func managementGate(t *testing.T, e *signupEnv, action string) func() {
	t.Helper()
	const key int64 = 92847021
	c, err := e.d.Pool.Acquire(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if _, err := c.Exec(context.Background(), `SELECT pg_advisory_lock($1)`, key); err != nil {
		t.Fatal(err)
	}
	released := false
	release := func() {
		if !released {
			_, err := c.Exec(context.Background(), `SELECT pg_advisory_unlock($1)`, key)
			if err != nil {
				t.Error(err)
			}
			c.Release()
			released = true
		}
	}
	t.Cleanup(release)
	mustExec(t, e.d.Pool, `CREATE FUNCTION management_gate() RETURNS trigger LANGUAGE plpgsql AS $$
	BEGIN PERFORM pg_advisory_xact_lock(92847021); RETURN NEW; END $$`)
	// action is selected by these tests, never user input.
	mustExec(t, e.d.Pool, `CREATE TRIGGER management_gate BEFORE INSERT ON audit_events FOR EACH ROW
	WHEN (NEW.action = '`+action+`' AND NEW.outcome = 'success') EXECUTE FUNCTION management_gate()`)
	return release
}

func TestSessionManagement_LogoutAllVsIssuance(t *testing.T) {
	for _, flow := range []string{"password", "otp"} {
		for _, first := range []string{"issuance", "logout"} {
			t.Run(flow+"/"+first+" first", func(t *testing.T) {
				e := newSignupEnv(t, nil)
				u, pw := e.passwordUser(t)
				a := e.issue(t, u, "A")
				code, token := "", ""
				if flow == "otp" {
					code = e.queueCode()
					token = e.otpLoginStart(t, u.Email).str("challenge_token")
				}
				action := "auth.logout.all"
				if first == "issuance" {
					action = "auth.password.login"
					if flow == "otp" {
						action = "auth.otp.verify"
					}
				}
				release := managementGate(t, e, action)
				issued, loggedOut := make(chan response, 1), make(chan response, 1)
				issue := func() {
					if flow == "otp" {
						issued <- e.otpLoginVerify(t, token, code)
					} else {
						issued <- e.login(t, u.Email, pw)
					}
				}
				logout := func() { loggedOut <- e.logoutAll(t, a.AccessToken) }
				if first == "issuance" {
					go issue()
				} else {
					go logout()
				}
				waitForLockWaiters(t, e, 1) // winner holds L3 and waits inside its audit insert
				if first == "issuance" {
					go logout()
				} else {
					go issue()
				}
				waitForLockWaiters(t, e, 2) // loser now waits for winner's user row
				release()
				c := sessionTokens(t, <-issued)
				want204(t, <-loggedOut)
				e.assertRevokedPair(t, a)
				if first == "issuance" {
					e.assertRevokedPair(t, c)
				} else {
					wantStatus(t, e.me(t, c.AccessToken), 200)
					wantStatus(t, e.refresh(t, c.RefreshToken), 200)
				}
			})
		}
	}
}

func TestSessionManagement_RefreshRacesAndActingRevalidation(t *testing.T) {
	for _, first := range []string{"refresh", "logout"} {
		for _, mode := range []struct {
			name         string
			acting, bulk bool
		}{{"all other", false, true}, {"all acting", true, true}, {"one other", false, false}} {
			t.Run(first+" first/"+mode.name, func(t *testing.T) {
				e := newSignupEnv(t, nil)
				u := newUser(t, e.q)
				a, b := e.issue(t, u, "A"), e.issue(t, u, "B")
				if mode.acting {
					b = a
				}
				revoke := func() response {
					if mode.bulk {
						return e.logoutAll(t, a.AccessToken)
					}
					return e.removeSession(t, a.AccessToken, b.SessionID)
				}
				if first == "refresh" {
					// Hold B's row, queue refresh first, then let bulk own L3 while waiting for B.
					tx, err := e.d.Pool.Begin(context.Background())
					if err != nil {
						t.Fatal(err)
					}
					defer tx.Rollback(context.Background())
					if _, err := sqlc.New(tx).LockActingSessionForUpdate(context.Background(), sqlc.LockActingSessionForUpdateParams{ID: b.SessionID, UserID: u.ID}); err != nil {
						t.Fatal(err)
					}
					ref, out := make(chan response, 1), make(chan response, 1)
					go func() { ref <- e.refresh(t, b.RefreshToken) }()
					waitForLockWaiters(t, e, 1)
					go func() { out <- revoke() }()
					waitForLockWaiters(t, e, 2)
					if err := tx.Commit(context.Background()); err != nil {
						t.Fatal(err)
					}
					latest := sessionTokens(t, <-ref)
					want204(t, <-out)
					e.assertRevokedPair(t, latest)
				} else {
					action := "auth.logout.all"
					if !mode.bulk {
						action = "auth.session.revoke"
					}
					release := managementGate(t, e, action)
					out, ref := make(chan response, 1), make(chan response, 1)
					go func() { out <- revoke() }()
					waitForLockWaiters(t, e, 1)
					go func() { ref <- e.refresh(t, b.RefreshToken) }()
					waitForLockWaiters(t, e, 2)
					release()
					want204(t, <-out)
					wantUnauthorized(t, <-ref)
				}
				if mode.bulk {
					e.assertRevokedPair(t, a)
				} else {
					wantStatus(t, e.me(t, a.AccessToken), 200)
					wantStatus(t, e.refresh(t, a.RefreshToken), 200)
				}
				e.assertRevokedPair(t, b)
			})
		}
	}
	t.Run("acting revoked after middleware", func(t *testing.T) {
		e := newSignupEnv(t, nil)
		u := newUser(t, e.q)
		a, b := e.issue(t, u, "A"), e.issue(t, u, "B")
		tx, err := e.d.Pool.Begin(context.Background())
		if err != nil {
			t.Fatal(err)
		}
		defer tx.Rollback(context.Background())
		if _, err := sqlc.New(tx).LockUserForNoKeyUpdate(context.Background(), u.ID); err != nil {
			t.Fatal(err)
		}
		out := make(chan response, 1)
		go func() { out <- e.removeSession(t, a.AccessToken, b.SessionID) }()
		waitForLockWaiters(t, e, 1)
		want204(t, e.logout(t, a.AccessToken)) // logout takes only its session, never L3
		if err := tx.Commit(context.Background()); err != nil {
			t.Fatal(err)
		}
		wantUnauthorized(t, <-out)
		wantStatus(t, e.me(t, b.AccessToken), 200)
		wantStatus(t, e.refresh(t, b.RefreshToken), 200)
	})
}

func TestSessionManagement_ConcurrentMutations(t *testing.T) {
	for _, mode := range []string{"same target", "opposing", "bulk"} {
		t.Run(mode, func(t *testing.T) {
			e := newSignupEnv(t, nil)
			u := newUser(t, e.q)
			a, b := e.issue(t, u, "A"), e.issue(t, u, "B")
			action := "auth.session.revoke"
			if mode == "bulk" {
				action = "auth.logout.all"
			}
			release := managementGate(t, e, action)
			one, two := make(chan response, 1), make(chan response, 1)
			go func() {
				if mode == "bulk" {
					one <- e.logoutAll(t, a.AccessToken)
				} else {
					one <- e.removeSession(t, a.AccessToken, b.SessionID)
				}
			}()
			waitForLockWaiters(t, e, 1)
			go func() {
				switch mode {
				case "bulk":
					two <- e.logoutAll(t, a.AccessToken)
				case "opposing":
					two <- e.removeSession(t, b.AccessToken, a.SessionID)
				default:
					two <- e.removeSession(t, a.AccessToken, b.SessionID)
				}
			}()
			waitForLockWaiters(t, e, 2)
			release()
			want204(t, <-one)
			if mode == "same target" {
				want204(t, <-two)
			} else {
				wantUnauthorized(t, <-two)
			}
			if rowCount(t, e.d.Pool, `SELECT count(*) FROM audit_events WHERE action = 'auth.session.revoke'`) != 1 {
				t.Fatal("duplicate revocation event")
			}
			e.assertRevokedPair(t, b)
			if mode == "bulk" {
				e.assertRevokedPair(t, a)
			} else {
				wantStatus(t, e.me(t, a.AccessToken), 200)
			}
		})
	}
}

func TestMigrations_SessionManagementUpgradeFrom7(t *testing.T) {
	d := pgtest.NewEmpty(t)
	ctx := context.Background()
	if _, err := migrate.Up(ctx, d.URL, migrationsUpTo(t, 7)); err != nil {
		t.Fatal(err)
	}
	seedCleanupData(t, d, 50)
	before := tableCounts(t, d)
	r, err := migrate.Up(ctx, d.URL, migrationsUpTo(t, 8))
	if err != nil || r.Current != 8 || len(r.Applied) != 1 || r.Applied[0] != 8 || before != tableCounts(t, d) {
		t.Fatalf("upgrade: %+v %v", r, err)
	}
	for _, reason := range []string{"logout", "password_set", "password_change", "password_reset", "refresh_reuse", "session_limit", "account_inactive", "user_revoked", "logout_all"} {
		mustExec(t, d.Pool, `UPDATE sessions SET revoked_reason=$1 WHERE id=(SELECT id FROM sessions LIMIT 1)`, reason)
	}
	if _, err := d.Pool.Exec(ctx, `UPDATE sessions SET revoked_reason='invalid'`); err == nil {
		t.Fatal("reason constraint was lost")
	}
}
