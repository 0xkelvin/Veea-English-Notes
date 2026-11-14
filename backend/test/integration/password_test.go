//go:build integration

package integration

import (
	"context"
	"fmt"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/auth/otp"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/auth/session"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/db/sqlc"
)

const (
	pathResetStart    = "/v1/auth/password/reset/start"
	pathResetComplete = "/v1/auth/password/reset/complete"
	pathSetStart      = "/v1/me/password/set/start"
	pathSet           = "/v1/me/password/set"
	pathChange        = "/v1/me/password"
)

func (e *signupEnv) setStart(t *testing.T, access string) response {
	t.Helper()
	return e.post(t, pathSetStart, "", bearer(access)...)
}

func (e *signupEnv) setPassword(t *testing.T, access, token, code, password string) response {
	t.Helper()
	e.remember(password)
	return e.post(t, pathSet, map[string]string{"challenge_token": token, "code": code, "new_password": password}, bearer(access)...)
}

func (e *signupEnv) change(t *testing.T, access, current, next string) response {
	t.Helper()
	e.remember(next)
	return e.send(t, http.MethodPut, pathChange, map[string]string{"current_password": current, "new_password": next}, bearer(access)...)
}

func (e *signupEnv) resetStart(t *testing.T, addr string) response {
	t.Helper()
	return e.post(t, pathResetStart, map[string]string{"email": addr})
}

func (e *signupEnv) resetComplete(t *testing.T, token, code, password string) response {
	t.Helper()
	e.remember(password)
	return e.post(t, pathResetComplete, map[string]string{"challenge_token": token, "code": code, "new_password": password})
}

func want204(t *testing.T, r response) {
	t.Helper()
	if r.status != http.StatusNoContent || len(r.raw) != 0 {
		t.Fatalf("want 204 with no body, got %d %s", r.status, r.raw)
	}
}

// sessionStates checks every session through both GET /v1/me and refresh. alive lists those that
// must still work; every other must give 401 on both. Refreshing rotates the live ones, so it
// returns their new pairs.
func (e *signupEnv) assertSessions(t *testing.T, alive []session.Issued, dead []session.Issued) []session.Issued {
	t.Helper()
	for _, s := range dead {
		wantUnauthorized(t, e.me(t, s.AccessToken))
		wantUnauthorized(t, e.refresh(t, s.RefreshToken))
	}
	var next []session.Issued
	for _, s := range alive {
		if r := e.me(t, s.AccessToken); r.status != http.StatusOK {
			t.Fatalf("session %s must still work: GET /v1/me %d", s.SessionID, r.status)
		}
		r := e.refresh(t, s.RefreshToken)
		if r.status != http.StatusOK {
			t.Fatalf("session %s must still refresh: %d %s", s.SessionID, r.status, r.raw)
		}
		next = append(next, session.Issued{SessionID: s.SessionID, AccessToken: r.str("access_token"), RefreshToken: r.str("refresh_token")})
	}
	return next
}

func (e *signupEnv) notifications(t *testing.T, u sqlc.User, template string) int {
	t.Helper()
	return rowCount(t, e.d.Pool, `SELECT count(*) FROM email_outbox WHERE user_id = $1 AND template = $2 AND challenge_id IS NULL`, u.ID, template)
}

func (e *signupEnv) storedHash(t *testing.T, u sqlc.User) string {
	t.Helper()
	cur, _ := e.q.GetUserByID(context.Background(), u.ID)
	if cur.PasswordHash == nil {
		return ""
	}
	return *cur.PasswordHash
}

func (e *signupEnv) revocations(t *testing.T, reason string) int {
	t.Helper()
	return rowCount(t, e.d.Pool, `SELECT count(*) FROM audit_events WHERE action = 'auth.session.revoke' AND metadata->>'reason' = $1`, reason)
}

// =============================================================================================
// Flow E: first-password set (AC-10, AC-28)
// =============================================================================================

func TestSetPassword_KeepsCurrentSessionAndRevokesOthers(t *testing.T) {
	env := newSignupEnv(t, nil)
	u := newUser(t, env.q)
	a, b := env.issue(t, u, "Phone"), env.issue(t, u, "Tablet")

	ack := env.setStart(t, a.AccessToken)
	if ack.status != http.StatusAccepted || !strings.HasPrefix(ack.str("challenge_token"), "vct_") {
		t.Fatalf("set start: %d %s", ack.status, ack.raw)
	}
	code := env.mailedCode(t, u.Email)
	newPw := newPassword()
	want204(t, env.setPassword(t, a.AccessToken, ack.str("challenge_token"), code, newPw))

	me := env.me(t, a.AccessToken)
	if me.body["has_password"] != true || me.body["password_changed_at"] == nil {
		t.Fatalf("A sees the new password state: %s", me.raw)
	}
	a = env.assertSessions(t, []session.Issued{a}, []session.Issued{b})[0] // A's pair is rotated
	if r := env.login(t, u.Email, newPw); r.status != http.StatusOK {
		t.Fatalf("password sign-in works afterwards (AC-10): %d", r.status)
	}
	if env.notifications(t, u, "password_added") != 1 || env.revocations(t, "password_set") != 1 {
		t.Fatal("one password_added email and one revocation event")
	}
	if rowCount(t, env.d.Pool, `SELECT count(*) FROM audit_events WHERE action = 'auth.password.set' AND outcome = 'success'
		AND session_id = $1`, a.SessionID) != 1 {
		t.Fatal("success audit event for the acting session")
	}
	// A retry after a lost response gets invalid_code (TRD 5.4) and changes nothing.
	before := env.storedHash(t, u)
	wantProblem(t, env.setPassword(t, a.AccessToken, ack.str("challenge_token"), code, newPassword()), http.StatusBadRequest, "invalid_code")
	if env.storedHash(t, u) != before {
		t.Fatal("a resend must not change the password")
	}
	wantProblem(t, env.setStart(t, a.AccessToken), http.StatusConflict, "password_already_set")
}

func TestSetPassword_PolicyAndBindingAreCheckedFirst(t *testing.T) {
	env := newSignupEnv(t, nil)
	u := newUser(t, env.q)
	a, b := env.issue(t, u, "Phone"), env.issue(t, u, "Tablet")
	code := env.queueCode()
	ack := env.setStart(t, a.AccessToken)
	tok := ack.str("challenge_token")

	// Policy first: no attempt and no Argon2id spent.
	hashes := env.hasher.n.Load()
	weak := env.setPassword(t, a.AccessToken, tok, code, "short")
	wantProblem(t, weak, http.StatusUnprocessableEntity, "password_policy_violation")
	if env.hasher.n.Load() != hashes {
		t.Fatal("a policy failure runs no Argon2id")
	}
	// Bound to user and session: another session of the same user gets invalid_code.
	wantProblem(t, env.setPassword(t, b.AccessToken, tok, code, newPassword()), http.StatusBadRequest, "invalid_code")
	// Another user's session too.
	other := newUser(t, env.q)
	o := env.issue(t, other, "Other")
	wantProblem(t, env.setPassword(t, o.AccessToken, tok, code, newPassword()), http.StatusBadRequest, "invalid_code")
	// The set_password challenge is unusable at the reset endpoint (wrong purpose).
	wantProblem(t, env.resetComplete(t, tok, code, newPassword()), http.StatusBadRequest, "invalid_code")
	if attempts, consumed, _ := env.challengeByToken(t, tok); attempts != 0 || consumed {
		t.Fatal("wrong binding or purpose is unusable, not a counted failure")
	}
	if env.storedHash(t, u) != "" || env.storedHash(t, other) != "" {
		t.Fatal("nothing changed")
	}
	want204(t, env.setPassword(t, a.AccessToken, tok, code, newPassword()))
	if env.storedHash(t, other) != "" {
		t.Fatal("only the bound account gets the password")
	}
}

func TestSetPassword_RechecksStateInsideTheTransaction(t *testing.T) {
	cases := []struct {
		name      string
		mutate    string // runs between Argon2id and the transaction
		bySession bool   // $1 is the acting session id instead of the user id
		status    int
		code      string
		tFailWhy  string
	}{
		{"acting session logged out", `UPDATE sessions SET revoked_at = now(), revoked_reason = 'logout' WHERE id = $1`, true,
			http.StatusUnauthorized, "unauthorized", "session_invalid"},
		{"account suspended", `UPDATE users SET status = 'suspended' WHERE id = $1`, false,
			http.StatusUnauthorized, "unauthorized", "account_unavailable"},
		{"password set meanwhile", `UPDATE users SET password_hash = '$argon2id$v=19$m=64,t=1,p=1$c2FsdHNhbHRzYWx0$aGFzaGhhc2hoYXNoaGFzaA' WHERE id = $1`, false,
			http.StatusConflict, "password_already_set", "password_already_set"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			env := newSignupEnv(t, nil)
			u := newUser(t, env.q)
			a, b := env.issue(t, u, "Phone"), env.issue(t, u, "Tablet")
			code := env.queueCode()
			ack := env.setStart(t, a.AccessToken)
			target := u.ID
			if c.bySession {
				target = a.SessionID
			}
			env.hasher.afterHash.Store(func() { mustExec(t, env.d.Pool, c.mutate, target) })
			r := env.setPassword(t, a.AccessToken, ack.str("challenge_token"), code, newPassword())
			env.hasher.afterHash.Store(func() {})
			wantProblem(t, r, c.status, c.code)

			if _, consumed, _ := env.challengeByToken(t, ack.str("challenge_token")); consumed {
				t.Fatal("the consumption must roll back")
			}
			if env.notifications(t, u, "password_added") != 0 || env.revocations(t, "password_set") != 0 {
				t.Fatal("no notification and no revocation")
			}
			if rowCount(t, env.d.Pool, `SELECT count(*) FROM sessions WHERE id = $1 AND revoked_at IS NULL`, b.SessionID) != 1 {
				t.Fatal("other sessions are untouched by a failed set")
			}
			if rowCount(t, env.d.Pool, `SELECT count(*) FROM audit_events WHERE action = 'auth.password.set'
				AND outcome = 'failure' AND reason = $1`, c.tFailWhy) != 1 {
				t.Fatalf("expected the T-fail %s event", c.tFailWhy)
			}
		})
	}
}

// =============================================================================================
// Flow F: change (AC-11, AC-12, AC-16, AC-25)
// =============================================================================================

func TestChangePassword_KeepsCurrentSessionAndRevokesOthers(t *testing.T) {
	env := newSignupEnv(t, nil)
	u, oldPw := env.passwordUser(t)
	a, b := env.issue(t, u, "Phone"), env.issue(t, u, "Tablet")
	var changedBefore string
	_ = env.d.Pool.QueryRow(context.Background(), `SELECT password_changed_at::text FROM users WHERE id = $1`, u.ID).Scan(&changedBefore)

	newPw := newPassword()
	want204(t, env.change(t, a.AccessToken, oldPw, newPw))
	env.assertSessions(t, []session.Issued{a}, []session.Issued{b})
	wantProblem(t, env.login(t, u.Email, oldPw), http.StatusUnauthorized, "invalid_credentials")
	if r := env.login(t, u.Email, newPw); r.status != http.StatusOK {
		t.Fatalf("the new password works (AC-16): %d", r.status)
	}
	var changedAfter string
	_ = env.d.Pool.QueryRow(context.Background(), `SELECT password_changed_at::text FROM users WHERE id = $1`, u.ID).Scan(&changedAfter)
	if changedAfter == changedBefore {
		t.Fatal("password_changed_at is updated")
	}
	if env.notifications(t, u, "password_changed") != 1 || env.revocations(t, "password_change") != 1 {
		t.Fatal("one password_changed email and one revocation event")
	}
	if _, err := env.worker.RunOnce(context.Background()); err != nil {
		t.Fatal(err)
	}
	sent := env.fake.Sent()
	if len(sent) == 0 || sent[len(sent)-1].To != u.Email || !strings.Contains(sent[len(sent)-1].Text, "Phone") {
		t.Fatal("the notification names the acting device and goes to the account address (AC-23)")
	}
}

func TestChangePassword_WrongCurrentChangesNothingAndIsLimited(t *testing.T) {
	env := newSignupEnv(t, nil)
	u, oldPw := env.passwordUser(t)
	a, b := env.issue(t, u, "Phone"), env.issue(t, u, "Tablet")
	hash := env.storedHash(t, u)

	for i := range 5 {
		wantProblem(t, env.change(t, a.AccessToken, newPassword(), newPassword()), http.StatusForbidden, "invalid_current_password")
		if n := rowCount(t, env.d.Pool, `SELECT coalesce(sum(count), 0)::int FROM rate_limit_counters WHERE key = $1`,
			"wrong_current_password_user_15m:user:"+u.ID.String()); n != i+1 {
			t.Fatalf("wrong-current counter %d, want %d", n, i+1)
		}
	}
	if env.storedHash(t, u) != hash || env.notifications(t, u, "password_changed") != 0 {
		t.Fatal("nothing changes on a wrong current password (AC-12)")
	}
	next := env.assertSessions(t, []session.Issued{a, b}, nil)
	// Over the limit even the right password is refused, before Argon2id.
	verifies := env.hasher.verifies.Load()
	wantProblem(t, env.change(t, next[0].AccessToken, oldPw, newPassword()), http.StatusTooManyRequests, "rate_limited")
	if env.hasher.verifies.Load() != verifies {
		t.Fatal("a limited change runs no Argon2id")
	}
	if rowCount(t, env.d.Pool, `SELECT count(*) FROM audit_events WHERE action = 'auth.password.change' AND reason = 'invalid_current_password'`) != 5 {
		t.Fatal("each wrong current password is audited")
	}
}

// TRD 7.5: the password changed between verification of current_password and the lock. 403,
// nothing changes, and it is not counted as a wrong guess.
func TestChangePassword_StaleCurrentAfterConcurrentChange(t *testing.T) {
	env := newSignupEnv(t, nil)
	u, oldPw := env.passwordUser(t)
	a, b := env.issue(t, u, "Phone"), env.issue(t, u, "Tablet")
	replacement, _ := env.hasher.h.Hash(context.Background(), newPassword())
	env.hasher.afterVerify.Store(func() {
		mustExec(t, env.d.Pool, `UPDATE users SET password_hash = $2 WHERE id = $1`, u.ID, replacement)
	})
	r := env.change(t, a.AccessToken, oldPw, newPassword())
	env.hasher.afterVerify.Store(func() {})
	wantProblem(t, r, http.StatusForbidden, "invalid_current_password")
	if env.storedHash(t, u) != replacement {
		t.Fatal("the concurrent change stands")
	}
	if rowCount(t, env.d.Pool, `SELECT count(*) FROM rate_limit_counters WHERE key LIKE 'wrong_current_password_user_15m:%'`) != 0 {
		t.Fatal("a stale current password is not counted as a wrong guess")
	}
	if rowCount(t, env.d.Pool, `SELECT count(*) FROM audit_events WHERE reason = 'stale_current_password'`) != 1 {
		t.Fatal("expected the stale_current_password event")
	}
	env.assertSessions(t, []session.Issued{a, b}, nil)
}

func TestChangePassword_PolicyAndPasswordlessAccount(t *testing.T) {
	env := newSignupEnv(t, nil)
	u, oldPw := env.passwordUser(t)
	a := env.issue(t, u, "Phone")
	r := env.change(t, a.AccessToken, oldPw, "short")
	wantProblem(t, r, http.StatusUnprocessableEntity, "password_policy_violation")
	if v, _ := r.body["violations"].([]any); len(v) == 0 || env.hasher.verifies.Load() != 0 {
		t.Fatal("the policy is checked before current_password, with no Argon2id")
	}
	p := newUser(t, env.q)
	ps := env.issue(t, p, "Phone")
	wantProblem(t, env.change(t, ps.AccessToken, "anything at all here", newPassword()), http.StatusConflict, "password_not_set")
	wantUnauthorized(t, env.send(t, http.MethodPut, pathChange, map[string]string{"current_password": oldPw, "new_password": newPassword()}))
}

// TRD 5.4 and AC-25 (a): the first change committed and its response was lost; the client
// resends the identical body.
func TestChangePassword_LostResponseResend(t *testing.T) {
	env := newSignupEnv(t, nil)
	u, oldPw := env.passwordUser(t)
	a, b := env.issue(t, u, "Phone"), env.issue(t, u, "Tablet")
	newPw := newPassword()
	want204(t, env.change(t, a.AccessToken, oldPw, newPw)) // lost on the way back
	resend := env.change(t, a.AccessToken, oldPw, newPw)
	wantProblem(t, resend, http.StatusForbidden, "invalid_current_password")

	wantProblem(t, env.login(t, u.Email, oldPw), http.StatusUnauthorized, "invalid_credentials")
	if r := env.login(t, u.Email, newPw); r.status != http.StatusOK {
		t.Fatalf("the new password is in effect: %d", r.status)
	}
	env.assertSessions(t, []session.Issued{a}, []session.Issued{b})
	if env.revocations(t, "password_change") != 1 || env.notifications(t, u, "password_changed") != 1 {
		t.Fatal("exactly one revocation and one notification")
	}
	if rowCount(t, env.d.Pool, `SELECT count(*) FROM audit_events WHERE action = 'auth.password.change' AND outcome = 'success'`) != 1 ||
		rowCount(t, env.d.Pool, `SELECT count(*) FROM audit_events WHERE action = 'auth.password.change' AND outcome = 'failure'`) != 1 {
		t.Fatal("one success and one failure event")
	}
	if rowCount(t, env.d.Pool, `SELECT coalesce(sum(count), 0)::int FROM rate_limit_counters WHERE key = $1`,
		"wrong_current_password_user_15m:user:"+u.ID.String()) != 1 {
		t.Fatal("the resend counts once toward the wrong-current-password limit")
	}
	if rowCount(t, env.d.Pool, `SELECT count(*) FROM users WHERE id = $1 AND password_changed_at IS NOT NULL`, u.ID) != 1 {
		t.Fatal("password_changed_at is set (informational only)")
	}
}

// AC-25 (b): the transaction failed before commit; the resend then succeeds normally.
func TestChangePassword_FailedBeforeCommitThenResend(t *testing.T) {
	env := newSignupEnv(t, nil)
	u, oldPw := env.passwordUser(t)
	a, b := env.issue(t, u, "Phone"), env.issue(t, u, "Tablet")
	hash := env.storedHash(t, u)
	mustExec(t, env.d.Pool, `CREATE FUNCTION test_fail() RETURNS trigger LANGUAGE plpgsql
		AS $$ BEGIN RAISE EXCEPTION 'forced failure'; END $$`)
	mustExec(t, env.d.Pool, `CREATE TRIGGER test_fail BEFORE INSERT ON email_outbox FOR EACH ROW
		WHEN (NEW.template = 'password_changed') EXECUTE FUNCTION test_fail()`)

	newPw := newPassword()
	r := env.change(t, a.AccessToken, oldPw, newPw)
	wantProblem(t, r, http.StatusInternalServerError, "internal_error")
	if env.storedHash(t, u) != hash || env.revocations(t, "password_change") != 0 {
		t.Fatal("the hash write and the revocation roll back with the failed enqueue")
	}
	next := env.assertSessions(t, []session.Issued{a, b}, nil) // rotates both pairs

	mustExec(t, env.d.Pool, `DROP TRIGGER test_fail ON email_outbox`)
	want204(t, env.change(t, next[0].AccessToken, oldPw, newPw))
	env.assertSessions(t, []session.Issued{next[0]}, []session.Issued{next[1]})
	if r := env.login(t, u.Email, newPw); r.status != http.StatusOK || env.notifications(t, u, "password_changed") != 1 ||
		env.revocations(t, "password_change") != 1 {
		t.Fatal("the resend produces the same end state as one successful change")
	}
}

// =============================================================================================
// Flow G: reset (AC-13, AC-14, R7)
// =============================================================================================

func TestReset_RevokesEverySessionAndIssuesNone(t *testing.T) {
	env := newSignupEnv(t, nil)
	u, oldPw := env.passwordUser(t)
	a, b := env.issue(t, u, "Phone"), env.issue(t, u, "Tablet")
	ack := env.resetStart(t, u.Email)
	code := env.mailedCode(t, u.Email)

	newPw := newPassword()
	r := env.resetComplete(t, ack.str("challenge_token"), code, newPw)
	want204(t, r)
	env.assertSessions(t, nil, []session.Issued{a, b})
	wantProblem(t, env.login(t, u.Email, oldPw), http.StatusUnauthorized, "invalid_credentials")
	if r := env.login(t, u.Email, newPw); r.status != http.StatusOK {
		t.Fatalf("the new password works: %d", r.status)
	}
	if env.notifications(t, u, "password_reset_done") != 1 || env.revocations(t, "password_reset") != 1 {
		t.Fatal("one password_reset_done email and one revocation event")
	}
	if rowCount(t, env.d.Pool, `SELECT count(*) FROM sessions WHERE user_id = $1`, u.ID) != 3 {
		t.Fatal("reset issues no session (only the later login does)")
	}
	// Lost-response retry: invalid_code; the new password stays in effect.
	wantProblem(t, env.resetComplete(t, ack.str("challenge_token"), code, newPassword()), http.StatusBadRequest, "invalid_code")
	if r := env.login(t, u.Email, newPw); r.status != http.StatusOK {
		t.Fatal("the reset's password stays in effect after a retry")
	}
}

// R7: reset also sets a first password on a passwordless account.
func TestReset_SetsAFirstPasswordOnAPasswordlessAccount(t *testing.T) {
	env := newSignupEnv(t, nil)
	u := newUser(t, env.q)
	ack := env.resetStart(t, u.Email)
	newPw := newPassword()
	want204(t, env.resetComplete(t, ack.str("challenge_token"), env.mailedCode(t, u.Email), newPw))
	if r := env.login(t, u.Email, newPw); r.status != http.StatusOK || userID(r) != u.ID.String() {
		t.Fatalf("password sign-in after a first-password reset: %d", r.status)
	}
}

func TestReset_AcknowledgementIsUniform(t *testing.T) {
	env := newSignupEnv(t, nil)
	known, _ := env.passwordUser(t)
	suspended := newUser(t, env.q)
	mustExec(t, env.d.Pool, `UPDATE users SET status = 'suspended' WHERE id = $1`, suspended.ID)
	shape := func(r response) string {
		s := string(r.raw)
		for _, k := range []string{"challenge_token", "expires_at", "resend_after"} {
			s = strings.Replace(s, r.str(k), "<"+k+">", 1)
		}
		return fmt.Sprintf("%d %s", r.status, s)
	}
	base := shape(env.resetStart(t, known.Email))
	for _, addr := range []string{newAddress("unknown"), suspended.Email} {
		if got := shape(env.resetStart(t, addr)); got != base {
			t.Fatalf("acknowledgements differ:\n%s\n%s", base, got)
		}
	}
	if _, err := env.worker.RunOnce(context.Background()); err != nil {
		t.Fatal(err)
	}
	if sent := env.fake.Sent(); len(sent) != 1 || sent[0].To != known.Email {
		t.Fatalf("only the account in good standing gets a reset email, got %d", len(sent))
	}
}

// AC-14: wrong, expired, used and superseded codes, and an inert challenge with its correct
// stored code, change nothing; counted failures are committed.
func TestReset_BadCodeChangesNothing(t *testing.T) {
	env := newSignupEnv(t, nil)
	u, _ := env.passwordUser(t)
	a := env.issue(t, u, "Phone")
	hash := env.storedHash(t, u)
	check := func(t *testing.T) {
		t.Helper()
		if env.storedHash(t, u) != hash || env.revocations(t, "password_reset") != 0 {
			t.Fatal("hash unchanged and no session revoked")
		}
		if r := env.me(t, a.AccessToken); r.status != http.StatusOK {
			t.Fatal("the session is untouched")
		}
	}

	t.Run("wrong", func(t *testing.T) {
		code := env.queueCode()
		ack := env.resetStart(t, u.Email)
		wantProblem(t, env.resetComplete(t, ack.str("challenge_token"), wrongCode(code), newPassword()), http.StatusBadRequest, "invalid_code")
		if attempts, _, _ := env.challengeByToken(t, ack.str("challenge_token")); attempts != 1 {
			t.Fatal("the attempt is committed")
		}
		check(t)
		env.expireCooldownForPurpose(t, "password_reset", u.Email)
	})
	t.Run("superseded and expired", func(t *testing.T) {
		code := env.queueCode()
		first := env.resetStart(t, u.Email)
		env.expireCooldownForPurpose(t, "password_reset", u.Email)
		second := env.resetStart(t, u.Email)
		secondCode := env.mailedCode(t, u.Email) // only the newest code is mailed
		wantProblem(t, env.resetComplete(t, first.str("challenge_token"), code, newPassword()), http.StatusBadRequest, "invalid_code")
		mustExec(t, env.d.Pool, `UPDATE otp_challenges SET expires_at = now() - interval '1 second' WHERE token_hash = $1`,
			otp.HashToken(second.str("challenge_token")))
		wantProblem(t, env.resetComplete(t, second.str("challenge_token"), secondCode, newPassword()), http.StatusBadRequest, "invalid_code")
		check(t)
	})
	t.Run("inert challenge with its stored code", func(t *testing.T) {
		unknown := newAddress("none")
		code := env.queueCode()
		ack := env.resetStart(t, unknown)
		wantProblem(t, env.resetComplete(t, ack.str("challenge_token"), code, newPassword()), http.StatusBadRequest, "invalid_code")
		if attempts, _, _ := env.challengeByToken(t, ack.str("challenge_token")); attempts != 1 {
			t.Fatal("an inert challenge is charged like a wrong code")
		}
		check(t)
	})
}

func (e *signupEnv) expireCooldownForPurpose(t *testing.T, purpose, addr string) {
	t.Helper()
	mustExec(t, e.d.Pool, `UPDATE otp_cooldowns SET last_issued_at = now() - interval '61 seconds' WHERE purpose = $1 AND email_hmac = $2`,
		purpose, e.hmac.Current(email(t, addr)))
}

func TestReset_AccountOutOfGoodStandingOrFailedWriteRollsBack(t *testing.T) {
	t.Run("account suspended after the code was sent", func(t *testing.T) {
		env := newSignupEnv(t, nil)
		u, _ := env.passwordUser(t)
		code := env.queueCode()
		ack := env.resetStart(t, u.Email)
		hash := env.storedHash(t, u)
		mustExec(t, env.d.Pool, `UPDATE users SET status = 'suspended' WHERE id = $1`, u.ID)
		wantProblem(t, env.resetComplete(t, ack.str("challenge_token"), code, newPassword()), http.StatusBadRequest, "invalid_code")
		if _, consumed, _ := env.challengeByToken(t, ack.str("challenge_token")); consumed || env.storedHash(t, u) != hash {
			t.Fatal("nothing changes and the code is not consumed")
		}
	})
	t.Run("revocation write fails", func(t *testing.T) {
		env := newSignupEnv(t, nil)
		u, _ := env.passwordUser(t)
		a := env.issue(t, u, "Phone")
		code := env.queueCode()
		ack := env.resetStart(t, u.Email)
		hash := env.storedHash(t, u)
		mustExec(t, env.d.Pool, `CREATE FUNCTION test_fail() RETURNS trigger LANGUAGE plpgsql
			AS $$ BEGIN RAISE EXCEPTION 'forced failure'; END $$`)
		mustExec(t, env.d.Pool, `CREATE TRIGGER test_fail BEFORE UPDATE ON sessions FOR EACH ROW
			WHEN (NEW.revoked_at IS NOT NULL) EXECUTE FUNCTION test_fail()`)
		newPw := newPassword()
		wantProblem(t, env.resetComplete(t, ack.str("challenge_token"), code, newPw), http.StatusInternalServerError, "internal_error")
		if _, consumed, _ := env.challengeByToken(t, ack.str("challenge_token")); consumed || env.storedHash(t, u) != hash ||
			env.notifications(t, u, "password_reset_done") != 0 {
			t.Fatal("the hash, the consumption and the notification roll back together")
		}
		if r := env.me(t, a.AccessToken); r.status != http.StatusOK {
			t.Fatal("the session survives a failed reset")
		}
		mustExec(t, env.d.Pool, `DROP TRIGGER test_fail ON sessions`)
		want204(t, env.resetComplete(t, ack.str("challenge_token"), code, newPw))
		env.assertSessions(t, nil, []session.Issued{a})
	})
}

// =============================================================================================
// Races (TRD 8.4 table, 12.3)
// =============================================================================================

// TestConcurrent_RefreshVsPasswordChange: whatever the order, B ends revoked and A survives.
func TestConcurrent_RefreshVsChange(t *testing.T) {
	env := newSignupEnv(t, nil)
	for round := range 5 {
		u, oldPw := env.passwordUser(t)
		a, b := env.issue(t, u, "Phone"), env.issue(t, u, "Tablet")
		var changeRes, refreshRes response
		gate := make(chan struct{})
		var wg sync.WaitGroup
		wg.Add(2)
		go func() { defer wg.Done(); <-gate; changeRes = env.change(t, a.AccessToken, oldPw, newPassword()) }()
		go func() { defer wg.Done(); <-gate; refreshRes = env.refresh(t, b.RefreshToken) }()
		close(gate)
		wg.Wait()
		want204(t, changeRes)
		latest := b
		switch refreshRes.status {
		case http.StatusOK: // the refresh committed first; the change then revoked the rotated row
			latest = session.Issued{AccessToken: refreshRes.str("access_token"), RefreshToken: refreshRes.str("refresh_token")}
		case http.StatusUnauthorized: // the change committed first
		default:
			t.Fatalf("round %d: refresh %d", round, refreshRes.status)
		}
		env.assertSessions(t, []session.Issued{a}, []session.Issued{latest})
		if rowCount(t, env.d.Pool, `SELECT count(*) FROM sessions WHERE id = $1 AND revoked_reason = 'password_change'`, b.SessionID) != 1 {
			t.Fatalf("round %d: B must end revoked by the change", round)
		}
	}
}

// TestConcurrent_RefreshVsReset: every session ends revoked, including a pair the refresh issued.
func TestConcurrent_RefreshVsReset(t *testing.T) {
	env := newSignupEnv(t, nil)
	for round := range 5 {
		u, _ := env.passwordUser(t)
		a := env.issue(t, u, "Phone")
		code := env.queueCode()
		ack := env.resetStart(t, u.Email)
		var resetRes, refreshRes response
		gate := make(chan struct{})
		var wg sync.WaitGroup
		wg.Add(2)
		go func() {
			defer wg.Done()
			<-gate
			resetRes = env.resetComplete(t, ack.str("challenge_token"), code, newPassword())
		}()
		go func() { defer wg.Done(); <-gate; refreshRes = env.refresh(t, a.RefreshToken) }()
		close(gate)
		wg.Wait()
		want204(t, resetRes)
		latest := a
		if refreshRes.status == http.StatusOK {
			latest = session.Issued{AccessToken: refreshRes.str("access_token"), RefreshToken: refreshRes.str("refresh_token")}
		} else if refreshRes.status != http.StatusUnauthorized {
			t.Fatalf("round %d: refresh %d", round, refreshRes.status)
		}
		env.assertSessions(t, nil, []session.Issued{latest})
		env.expireCooldownForPurpose(t, "password_reset", u.Email)
	}
}

// waitForLockWaiters blocks until n backends of this test database wait on a lock.
func waitForLockWaiters(t *testing.T, e *signupEnv, n int) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		if rowCount(t, e.d.Pool, `SELECT count(*) FROM pg_stat_activity WHERE datname = current_database()
			AND wait_event_type = 'Lock'`) >= n {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %d lock waiters", n)
}

// TestConcurrent_LogoutVsPasswordChangeOnSameSession: either logout wins (the change gets 401
// and nothing changes) or the change wins (logout then revokes the kept session). No deadlock.
// Three interleavings:
//   - free: both start together. The change spends two Argon2id runs first, so logout usually
//     lands before its transaction (L4a then finds the session revoked).
//   - gated: logout starts only once the change has hashed, so both meet at the locks.
//   - blocked: a third transaction holds the acting session row; the change queues on it while
//     holding the account (L3 then L4a), logout queues behind it; then the blocker commits.
func TestConcurrent_LogoutVsChangeOnTheActingSession(t *testing.T) {
	env := newSignupEnv(t, nil)
	outcomes := map[string]int{}
	for round := range 9 {
		mode := []string{"free", "gated", "blocked"}[round%3]
		u, oldPw := env.passwordUser(t)
		a, b := env.issue(t, u, "Phone"), env.issue(t, u, "Tablet")
		hash := env.storedHash(t, u)
		var changeRes, logoutRes response
		gate, hashed := make(chan struct{}), make(chan struct{})
		var once sync.Once
		release := func() {}
		switch mode {
		case "gated":
			env.hasher.afterHash.Store(func() { once.Do(func() { close(hashed) }) })
		case "blocked":
			blocker, err := env.d.Pool.Begin(context.Background())
			if err != nil {
				t.Fatal(err)
			}
			if _, err := blocker.Exec(context.Background(), `SELECT 1 FROM sessions WHERE id = $1 FOR UPDATE`, a.SessionID); err != nil {
				t.Fatal(err)
			}
			release = func() { _ = blocker.Commit(context.Background()) }
		}
		var wg sync.WaitGroup
		wg.Add(2)
		newPw := newPassword()
		go func() { defer wg.Done(); <-gate; changeRes = env.change(t, a.AccessToken, oldPw, newPw) }()
		go func() {
			defer wg.Done()
			<-gate
			switch mode {
			case "gated":
				<-hashed
			case "blocked":
				waitForLockWaiters(t, env, 1) // the change, at L4a
			}
			logoutRes = env.logout(t, a.AccessToken)
		}()
		close(gate)
		if mode == "blocked" {
			waitForLockWaiters(t, env, 2)
			release()
		}
		wg.Wait()
		env.hasher.afterHash.Store(func() {})
		want204(t, logoutRes) // the change never revokes the acting session, so logout always lands
		switch changeRes.status {
		case http.StatusNoContent:
			outcomes["change first"]++
			env.assertSessions(t, nil, []session.Issued{a, b})
			if r := env.login(t, u.Email, newPw); r.status != http.StatusOK {
				t.Fatalf("round %d: the change committed, so the new password works", round)
			}
		case http.StatusUnauthorized:
			outcomes["logout first"]++
			if env.storedHash(t, u) != hash || env.notifications(t, u, "password_changed") != 0 {
				t.Fatalf("round %d: a change refused after logout changes nothing", round)
			}
			env.assertSessions(t, []session.Issued{b}, []session.Issued{a})
		default:
			t.Fatalf("round %d: change %d %s", round, changeRes.status, changeRes.raw)
		}
	}
	t.Logf("outcomes: %v", outcomes)
	if outcomes["change first"] == 0 || outcomes["logout first"] == 0 {
		t.Fatalf("both orders must be exercised, got %v", outcomes)
	}
}

func TestPasswordRoutes_RequireAuthentication(t *testing.T) {
	env := newSignupEnv(t, nil)
	for _, r := range []response{
		env.post(t, pathSetStart, ""),
		env.post(t, pathSet, map[string]string{"challenge_token": "x", "code": "1", "new_password": "y"}),
		env.send(t, http.MethodPut, pathChange, map[string]string{"current_password": "x", "new_password": "y"}),
	} {
		wantUnauthorized(t, r)
	}
}

// The verify limits of TRD 10 are checked before the new password is hashed, so a limited set or
// reset costs no Argon2id (TRD 7.1 rule 4, 9.2).
func TestPasswordCodes_VerifyLimitsRunBeforeArgon2id(t *testing.T) {
	rules := generousRules()
	rules.PasswordSignupStartIP.Limit = 10_000
	rules.VerifyFailEmail.Limit = 1
	env := newSignupEnv(t, rules)
	u, _ := env.passwordUser(t)
	code := env.queueCode()
	ack := env.resetStart(t, u.Email)
	wantProblem(t, env.resetComplete(t, ack.str("challenge_token"), wrongCode(code), newPassword()), http.StatusBadRequest, "invalid_code")

	hashes := env.hasher.n.Load()
	limited := env.resetComplete(t, ack.str("challenge_token"), code, newPassword())
	wantProblem(t, limited, http.StatusTooManyRequests, "rate_limited")
	if env.hasher.n.Load() != hashes {
		t.Fatal("a limited reset must not hash the new password")
	}

	p := newUser(t, env.q)
	s := env.issue(t, p, "Phone")
	setCode := env.queueCode()
	setAck := env.setStart(t, s.AccessToken)
	wantProblem(t, env.setPassword(t, s.AccessToken, setAck.str("challenge_token"), wrongCode(setCode), newPassword()), http.StatusBadRequest, "invalid_code")
	hashes = env.hasher.n.Load()
	wantProblem(t, env.setPassword(t, s.AccessToken, setAck.str("challenge_token"), setCode, newPassword()), http.StatusTooManyRequests, "rate_limited")
	if env.hasher.n.Load() != hashes {
		t.Fatal("a limited set must not hash the new password")
	}
}

// AC-23: first-password set, change and reset each deliver a notification to the account address.
func TestAC23_SecurityNotificationsAreDeliveredToTheAccount(t *testing.T) {
	env := newSignupEnv(t, nil)
	u := newUser(t, env.q)
	a := env.issue(t, u, "Pixel 9")

	code := env.queueCode()
	ack := env.setStart(t, a.AccessToken)
	first := newPassword()
	want204(t, env.setPassword(t, a.AccessToken, ack.str("challenge_token"), code, first))
	second := newPassword()
	want204(t, env.change(t, a.AccessToken, first, second))
	code = env.queueCode()
	rack := env.resetStart(t, u.Email)
	want204(t, env.resetComplete(t, rack.str("challenge_token"), code, newPassword()))

	if _, err := env.worker.RunOnce(context.Background()); err != nil {
		t.Fatal(err)
	}
	var subjects []string
	for _, e := range env.fake.Sent() {
		if e.To != u.Email {
			t.Fatalf("an email went to %q, not the account address", e.To)
		}
		if !codePattern.MatchString(e.Text) { // the notifications, not the code emails
			subjects = append(subjects, e.Subject)
		}
	}
	if len(subjects) != 3 {
		t.Fatalf("want 3 notifications (added, changed, reset), got %d: %v", len(subjects), subjects)
	}
	for _, tmpl := range []string{"password_added", "password_changed", "password_reset_done"} {
		if rowCount(t, env.d.Pool, `SELECT count(*) FROM email_outbox WHERE template = $1 AND status = 'sent' AND user_id = $2`, tmpl, u.ID) != 1 {
			t.Fatalf("%s must be sent exactly once", tmpl)
		}
	}
}
