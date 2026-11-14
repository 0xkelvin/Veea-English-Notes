//go:build integration

package integration

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"testing"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/maintenance"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/db/sqlc"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/migrate"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/pgtest"
	"github.com/0xkelvin/Veea-English-Notes/backend/migrations"
	"github.com/google/uuid"
)

const pathProfile = "/v1/me/profile"
const pathEmailStart = "/v1/me/email-change/start"

func emailCompletePath(id string) string { return "/v1/me/email-change/" + id + "/complete" }

type emailProofs struct{ id, currentToken, currentCode, newToken, newCode string }

func (p emailProofs) body() map[string]string {
	return map[string]string{"current_challenge_token": p.currentToken, "current_code": p.currentCode, "new_challenge_token": p.newToken, "new_code": p.newCode}
}
func (e *signupEnv) emailStart(t *testing.T, access, next string) (emailProofs, response) {
	t.Helper()
	p := emailProofs{currentCode: e.queueCode(), newCode: e.queueCode()}
	r := e.post(t, pathEmailStart, map[string]string{"new_email": next}, bearer(access)...)
	if r.status == 202 {
		p.id = r.str("change_id")
		p.currentToken = r.body["current_email"].(map[string]any)["challenge_token"].(string)
		p.newToken = r.body["new_email"].(map[string]any)["challenge_token"].(string)
		e.remember(p.currentToken, p.newToken)
	}
	return p, r
}
func (e *signupEnv) emailComplete(t *testing.T, access string, p emailProofs) response {
	t.Helper()
	return e.post(t, emailCompletePath(p.id), p.body(), bearer(access)...)
}
func profileInput(rev int) map[string]any {
	return map[string]any{"expected_revision": rev, "display_name": " Learner ", "preferred_language": "vi", "time_zone": "Asia/Ho_Chi_Minh", "daily_goal": 30}
}
func (e *signupEnv) emailUnchanged(t *testing.T, id uuid.UUID, email string, p emailProofs) {
	t.Helper()
	if rowCount(t, e.d.Pool, `SELECT count(*) FROM users WHERE id=$1 AND email_normalized=$2 AND email_revision=0`, id, email) != 1 || rowCount(t, e.d.Pool, `SELECT count(*) FROM otp_challenges WHERE change_id=$1 AND consumed_at IS NOT NULL`, uuid.MustParse(p.id)) != 0 {
		t.Fatal("failed change mutated account/proofs")
	}
}
func (e *signupEnv) expireEmailCooldown(t *testing.T) {
	t.Helper()
	mustExec(t, e.d.Pool, `UPDATE otp_cooldowns SET last_issued_at=now()-interval '2 minutes' WHERE purpose IN ('email_change_current','email_change_new')`)
}

func TestAccount_Profile(t *testing.T) {
	e := newSignupEnv(t, nil)
	u := newUser(t, e.q)
	s := e.issue(t, u, "A")
	other := newUser(t, e.q)
	r := e.me(t, s.AccessToken)
	wantStatus(t, r, 200)
	p := r.body["profile"].(map[string]any)
	if p["display_name"] != nil || p["preferred_language"] != "en" || p["time_zone"] != "UTC" || p["daily_goal"] != float64(20) || p["revision"] != float64(0) {
		t.Fatal("profile defaults")
	}
	rid := newRID()
	r = e.call(t, "PUT", pathProfile, profileInput(0), rid, bearer(s.AccessToken)...)
	wantStatus(t, r, 200)
	p = r.body["profile"].(map[string]any)
	if p["display_name"] != "Learner" || p["revision"] != float64(1) {
		t.Fatal("normalization/revision")
	}
	e.wantEvents(t, rid, ev{action: "account.profile.update", outcome: "success", actor: u.ID.String(), target: u.ID.String(), session: s.SessionID.String(), meta: map[string]string{"revision": "1", "fields": "display_name,preferred_language,time_zone,daily_goal"}})
	wantStatus(t, e.send(t, "PUT", pathProfile, profileInput(1), bearer(s.AccessToken)...), 200)
	wantProblem(t, e.send(t, "PUT", pathProfile, profileInput(0), bearer(s.AccessToken)...), 409, "profile_conflict")
	for _, field := range []string{"preferred_language", "time_zone", "daily_goal", "display_name"} {
		t.Run(field, func(t *testing.T) {
			in := profileInput(1)
			switch field {
			case "preferred_language":
				in[field] = "fr"
			case "time_zone":
				in[field] = "Local"
			case "daily_goal":
				in[field] = 0
			case "display_name":
				in[field] = "x\nprivate"
			}
			wantProblem(t, e.send(t, "PUT", pathProfile, in, bearer(s.AccessToken)...), 422, "invalid_profile")
		})
	}
	in := profileInput(1)
	in["display_name"] = nil
	wantStatus(t, e.send(t, "PUT", pathProfile, in, bearer(s.AccessToken)...), 200)
	for _, body := range []string{`{}`, `{"expected_revision":1,"expected_revision":2}`, `{"user_id":"foreign"}`, `{"expected_revision":null,"display_name":null,"preferred_language":"en","time_zone":"UTC","daily_goal":20}`} {
		wantProblem(t, e.send(t, "PUT", pathProfile, body, bearer(s.AccessToken)...), 400, "invalid_request")
	}
	wantProblem(t, e.send(t, "PUT", pathProfile+"?x=1", profileInput(2), bearer(s.AccessToken)...), 400, "invalid_request")
	wantUnauthorized(t, e.send(t, "PUT", pathProfile, profileInput(2)))
	if rowCount(t, e.d.Pool, `SELECT count(*) FROM users WHERE id=$1 AND profile_revision=0`, other.ID) != 1 {
		t.Fatal("foreign profile modified")
	}
}

func TestAccount_EmailCutoverAndRecovery(t *testing.T) {
	e := newSignupEnv(t, nil)
	u, pw := e.passwordUser(t)
	a, b := e.issue(t, u, "Caller"), e.issue(t, u, "Other")
	foreign := e.issue(t, newUser(t, e.q), "Foreign")
	wantStatus(t, e.send(t, "PUT", pathProfile, profileInput(0), bearer(a.AccessToken)...), 200)
	next := newAddress("next")
	p, r := e.emailStart(t, a.AccessToken, next)
	wantStatus(t, r, 202)
	if p.currentToken == p.newToken || p.currentCode == p.newCode {
		t.Fatal("proofs not distinct")
	}
	if _, err := e.worker.RunOnce(context.Background()); err != nil {
		t.Fatal(err)
	}
	if e.mailedCode(t, u.Email) != p.currentCode || e.mailedCode(t, next) != p.newCode {
		t.Fatal("proof recipients")
	}
	rid := newRID()
	want204(t, e.call(t, "POST", emailCompletePath(p.id), p.body(), rid, bearer(a.AccessToken)...))
	e.wantEvents(t, rid, ev{action: "auth.session.revoke", outcome: "success", actor: u.ID.String(), target: u.ID.String(), session: a.SessionID.String(), meta: map[string]string{"reason": "email_change", "count": "2"}}, ev{action: "account.email.change.complete", outcome: "success", actor: u.ID.String(), target: u.ID.String(), session: a.SessionID.String(), meta: map[string]string{"change_id": p.id, "revoked_sessions": "2"}})
	for _, s := range []struct{ access, refresh string }{{a.AccessToken, a.RefreshToken}, {b.AccessToken, b.RefreshToken}} {
		wantUnauthorized(t, e.me(t, s.access))
		wantUnauthorized(t, e.refresh(t, s.refresh))
	}
	wantStatus(t, e.me(t, foreign.AccessToken), 200)
	wantUnauthorized(t, e.emailComplete(t, a.AccessToken, p))
	wantProblem(t, e.login(t, u.Email, pw), 401, "invalid_credentials")
	login := e.login(t, strings.ToUpper(next), pw)
	wantStatus(t, login, 200)
	if userID(login) != u.ID.String() {
		t.Fatal("email change replaced user ID")
	}
	me := e.me(t, login.str("access_token"))
	wantStatus(t, me, 200)
	if me.body["profile"].(map[string]any)["revision"] != float64(1) {
		t.Fatal("owned profile lost")
	}
	if rowCount(t, e.d.Pool, `SELECT count(*) FROM otp_challenges WHERE change_id=$1 AND consumed_at IS NOT NULL`, uuid.MustParse(p.id)) != 2 {
		t.Fatal("proofs not consumed atomically")
	}
	if _, err := e.worker.RunOnce(context.Background()); err != nil {
		t.Fatal(err)
	}
	notices := 0
	for _, m := range e.fake.Sent() {
		if !strings.Contains(m.Subject, "email") && !strings.Contains(m.Text, "now uses") && !strings.Contains(m.Text, "sign-in email was changed") {
			continue
		}
		if strings.Contains(m.Text, "sign-in email was changed") {
			notices++
			if m.To != u.Email || strings.Contains(m.Text, next) || strings.Contains(m.HTML, next) || strings.Contains(m.Subject, next) {
				t.Fatal("old notice leaks new address")
			}
		}
		if strings.Contains(m.Text, "now uses this address") {
			notices++
			if m.To != next {
				t.Fatal("new confirmation recipient")
			}
		}
	}
	if notices != 2 {
		t.Fatalf("notifications=%d", notices)
	}
	ack := e.startOTP(t, u.Email)
	wantStatus(t, ack, 202)
	created := e.verify(t, ack.str("challenge_token"), e.mailedCode(t, u.Email))
	wantStatus(t, created, 201)
	if userID(created) == u.ID.String() {
		t.Fatal("released address inherited original ownership")
	}
	wantMetric(t, e.metrics, `auth_sessions_revoked_total{reason="email_change"}`, 2)
}

func TestAccount_ProofBindingExpiryAndAttempts(t *testing.T) {
	for _, mode := range []string{"session", "user", "request", "swap", "login token", "duplicate token", "expired current", "expired new", "request expired", "superseded", "attempts", "occupied"} {
		t.Run(mode, func(t *testing.T) {
			e := newSignupEnv(t, nil)
			u := newUser(t, e.q)
			a := e.issue(t, u, "A")
			next := newAddress("proof")
			if mode == "occupied" {
				next = newUser(t, e.q).Email
			}
			p, r := e.emailStart(t, a.AccessToken, next)
			wantStatus(t, r, 202)
			original := p
			access := a.AccessToken
			switch mode {
			case "session":
				access = e.issue(t, u, "B").AccessToken
			case "user":
				access = e.issue(t, newUser(t, e.q), "X").AccessToken
			case "request":
				e.expireEmailCooldown(t)
				other, r := e.emailStart(t, a.AccessToken, newAddress("other"))
				wantStatus(t, r, 202)
				p.id = other.id
			case "login token":
				code := e.queueCode()
				ack := e.otpLoginStart(t, u.Email)
				wantStatus(t, ack, 202)
				p.currentToken = ack.str("challenge_token")
				p.currentCode = code
			case "duplicate token":
				p.newToken = p.currentToken
				p.newCode = p.currentCode
			case "swap":
				p.currentToken, p.newToken = p.newToken, p.currentToken
				p.currentCode, p.newCode = p.newCode, p.currentCode
			case "expired current", "expired new":
				purpose := "email_change_current"
				if mode == "expired new" {
					purpose = "email_change_new"
				}
				mustExec(t, e.d.Pool, `UPDATE otp_challenges SET expires_at=now() WHERE change_id=$1 AND purpose=$2`, uuid.MustParse(p.id), purpose)
			case "request expired":
				mustExec(t, e.d.Pool, `UPDATE email_changes SET expires_at=now() WHERE id=$1`, uuid.MustParse(p.id))
			case "superseded":
				e.expireEmailCooldown(t)
				_, r = e.emailStart(t, a.AccessToken, newAddress("supersede"))
				wantStatus(t, r, 202)
			case "attempts":
				bad := p
				bad.newCode = wrongCode(p.newCode)
				for range 5 {
					wantProblem(t, e.emailComplete(t, access, bad), 400, "invalid_code")
				}
				wantProblem(t, e.emailComplete(t, access, p), 400, "code_attempts_exceeded")
				if rowCount(t, e.d.Pool, `SELECT count(*) FROM otp_challenges WHERE change_id=$1 AND purpose='email_change_current' AND attempts=0`, uuid.MustParse(p.id)) != 1 {
					t.Fatal("valid proof attempt spent")
				}
				e.emailUnchanged(t, u.ID, u.EmailNormalized, original)
				return
			}
			result := e.emailComplete(t, access, p)
			if mode == "user" {
				wantProblem(t, result, 404, "not_found")
				unknown := p
				unknown.id = uuid.NewString()
				if withoutRequestID(result) != withoutRequestID(e.emailComplete(t, access, unknown)) {
					t.Fatal("foreign and unknown distinguishable")
				}
			} else {
				wantProblem(t, result, 400, "invalid_code")
			}
			e.emailUnchanged(t, u.ID, u.EmailNormalized, original)
			if mode == "occupied" && rowCount(t, e.d.Pool, `SELECT count(*) FROM email_outbox WHERE challenge_id IN (SELECT id FROM otp_challenges WHERE change_id=$1 AND purpose='email_change_new')`, uuid.MustParse(p.id)) != 0 {
				t.Fatal("occupied address mailed")
			}
		})
	}
}

func TestAccount_EmailAuditOutboxRollback(t *testing.T) {
	for _, failure := range []string{"audit", "outbox"} {
		t.Run(failure, func(t *testing.T) {
			e := newSignupEnv(t, nil)
			u := newUser(t, e.q)
			s := e.issue(t, u, "A")
			p, r := e.emailStart(t, s.AccessToken, newAddress("rollback"))
			wantStatus(t, r, 202)
			table, condition := "audit_events", "NEW.action='account.email.change.complete'"
			if failure == "outbox" {
				table = "email_outbox"
				condition = "NEW.template='email_changed_new'"
			}
			mustExec(t, e.d.Pool, `CREATE FUNCTION reject_change() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'synthetic write failure'; END $$`)
			mustExec(t, e.d.Pool, `CREATE TRIGGER reject_change BEFORE INSERT ON `+table+` FOR EACH ROW WHEN (`+condition+`) EXECUTE FUNCTION reject_change()`)
			wantProblem(t, e.emailComplete(t, s.AccessToken, p), 500, "internal_error")
			e.emailUnchanged(t, u.ID, u.EmailNormalized, p)
			if e.sessionRow(t, s.SessionID).revoked || rowCount(t, e.d.Pool, `SELECT count(*) FROM email_outbox WHERE template IN ('email_changed_old','email_changed_new')`) != 0 || rowCount(t, e.d.Pool, `SELECT count(*) FROM audit_events WHERE action='account.email.change.complete'`) != 0 {
				t.Fatal("partial transaction committed")
			}
			mustExec(t, e.d.Pool, `DROP TRIGGER reject_change ON `+table)
			want204(t, e.emailComplete(t, s.AccessToken, p))
			if rowCount(t, e.d.Pool, `SELECT count(*) FROM audit_events WHERE action='account.email.change.complete'`) != 1 {
				t.Fatal("retry duplicated success")
			}
		})
	}
}

func TestAccount_ConcurrentEmailClaims(t *testing.T) {
	for _, winner := range []string{"first user", "second user", "signup"} {
		t.Run(winner, func(t *testing.T) {
			e := newSignupEnv(t, nil)
			a, b := newUser(t, e.q), newUser(t, e.q)
			sa, sb := e.issue(t, a, "A"), e.issue(t, b, "B")
			next := newAddress("contended")
			pa, r := e.emailStart(t, sa.AccessToken, next)
			wantStatus(t, r, 202)
			e.expireEmailCooldown(t)
			pb, r := e.emailStart(t, sb.AccessToken, strings.ToUpper(next))
			wantStatus(t, r, 202)
			if winner == "signup" {
				code := e.queueCode()
				ack := e.startOTP(t, next)
				wantStatus(t, ack, 202)
				release := managementGate(t, e, "auth.signup.verify")
				signed, changed := make(chan response, 1), make(chan response, 1)
				go func() { signed <- e.verify(t, ack.str("challenge_token"), code) }()
				waitForLockWaiters(t, e, 1)
				go func() { changed <- e.emailComplete(t, sa.AccessToken, pa) }()
				waitForLockWaiters(t, e, 2)
				release()
				wantStatus(t, <-signed, 201)
				wantProblem(t, <-changed, 409, "email_unavailable")
				e.emailUnchanged(t, a.ID, a.EmailNormalized, pa)
				return
			}
			wa, wp, lp, la, loser := sa, pa, pb, sb, b
			if winner == "second user" {
				wa, wp, lp, la, loser = sb, pb, pa, sa, a
			}
			release := managementGate(t, e, "account.email.change.complete")
			win, lose := make(chan response, 1), make(chan response, 1)
			go func() { win <- e.emailComplete(t, wa.AccessToken, wp) }()
			waitForLockWaiters(t, e, 1)
			go func() { lose <- e.emailComplete(t, la.AccessToken, lp) }()
			waitForLockWaiters(t, e, 2)
			release()
			want204(t, <-win)
			wantProblem(t, <-lose, 409, "email_unavailable")
			e.emailUnchanged(t, loser.ID, loser.EmailNormalized, lp)
			if e.sessionRow(t, la.SessionID).revoked {
				t.Fatal("loser sessions revoked")
			}
		})
	}
}

func TestAccount_StaleChallengesAndABA(t *testing.T) {
	e := newSignupEnv(t, nil)
	u := newUser(t, e.q)
	a := e.issue(t, u, "A")
	loginCode := e.queueCode()
	login := e.otpLoginStart(t, u.Email)
	wantStatus(t, login, 202)
	resetCode := e.queueCode()
	reset := e.resetStart(t, u.Email)
	wantStatus(t, reset, 202)
	setCode := e.queueCode()
	set := e.setStart(t, a.AccessToken)
	wantStatus(t, set, 202)
	p, r := e.emailStart(t, a.AccessToken, newAddress("revision"))
	wantStatus(t, r, 202)
	want204(t, e.emailComplete(t, a.AccessToken, p))
	wantProblem(t, e.otpLoginVerify(t, login.str("challenge_token"), loginCode), 400, "invalid_code")
	wantProblem(t, e.resetComplete(t, reset.str("challenge_token"), resetCode, newPassword()), 400, "invalid_code")
	// Sign in with a fresh proof at B, then change back to A; old A proofs must remain stale.
	freshCode := e.queueCode()
	fresh := e.otpLoginStart(t, pickEmail(t, e, u.ID))
	wantStatus(t, fresh, 202)
	s := sessionTokens(t, e.otpLoginVerify(t, fresh.str("challenge_token"), freshCode))
	e.expireEmailCooldown(t)
	back, r := e.emailStart(t, s.AccessToken, u.Email)
	wantStatus(t, r, 202)
	want204(t, e.emailComplete(t, s.AccessToken, back))
	// Authenticated again with A, old set-password proof still belongs to the revoked origin.
	mustExec(t, e.d.Pool, `UPDATE otp_cooldowns SET last_issued_at=now()-interval '2 minutes' WHERE purpose='login'`)
	updated, err := e.q.GetUserByID(context.Background(), u.ID)
	if err != nil {
		t.Fatal(err)
	}
	live := e.issue(t, updated, "After ABA")
	wantProblem(t, e.setPassword(t, live.AccessToken, set.str("challenge_token"), setCode, newPassword()), 400, "invalid_code")
	wantProblem(t, e.otpLoginVerify(t, login.str("challenge_token"), loginCode), 400, "invalid_code")
	wantProblem(t, e.resetComplete(t, reset.str("challenge_token"), resetCode, newPassword()), 400, "invalid_code")
	if rowCount(t, e.d.Pool, `SELECT count(*) FROM users WHERE id=$1 AND email_revision=2`, u.ID) != 1 {
		t.Fatal("ABA revision")
	}
}
func pickEmail(t *testing.T, e *signupEnv, id uuid.UUID) string {
	t.Helper()
	u, err := e.q.GetUserByID(context.Background(), id)
	if err != nil {
		t.Fatal(err)
	}
	return u.Email
}

func TestAccount_PasswordReadBeforeCutoverRejected(t *testing.T) {
	e := newSignupEnv(t, nil)
	u, pw := e.passwordUser(t)
	s := e.issue(t, u, "A")
	p, r := e.emailStart(t, s.AccessToken, newAddress("hash-window"))
	wantStatus(t, r, 202)
	ready, release := make(chan struct{}), make(chan struct{})
	e.hasher.afterVerify.Store(func() { close(ready); <-release })
	done := make(chan response, 1)
	go func() { done <- e.login(t, u.Email, pw) }()
	<-ready
	want204(t, e.emailComplete(t, s.AccessToken, p))
	close(release)
	wantProblem(t, <-done, 401, "invalid_credentials")
	e.hasher.afterVerify.Store((func())(nil))
}

func TestAccount_EmailVsIssuance(t *testing.T) {
	for _, first := range []string{"issuance", "cutover"} {
		t.Run(first, func(t *testing.T) {
			e := newSignupEnv(t, nil)
			u, pw := e.passwordUser(t)
			s := e.issue(t, u, "A")
			p, r := e.emailStart(t, s.AccessToken, newAddress("ordered"))
			wantStatus(t, r, 202)
			action := "account.email.change.complete"
			if first == "issuance" {
				action = "auth.password.login"
			}
			release := managementGate(t, e, action)
			issued, changed := make(chan response, 1), make(chan response, 1)
			issue := func() { issued <- e.login(t, u.Email, pw) }
			change := func() { changed <- e.emailComplete(t, s.AccessToken, p) }
			if first == "issuance" {
				go issue()
			} else {
				go change()
			}
			waitForLockWaiters(t, e, 1)
			if first == "issuance" {
				go change()
			} else {
				go issue()
			}
			waitForLockWaiters(t, e, 2)
			release()
			want204(t, <-changed)
			login := <-issued
			if first == "issuance" {
				pair := sessionTokens(t, login)
				e.assertRevokedPair(t, pair)
			} else {
				wantProblem(t, login, 401, "invalid_credentials")
			}
		})
	}
}

func TestAccount_EmailContractErrors(t *testing.T) {
	e := newSignupEnv(t, nil)
	u := newUser(t, e.q)
	s := e.issue(t, u, "A")
	p, r := e.emailStart(t, s.AccessToken, newAddress("errors"))
	wantStatus(t, r, 202)
	wantProblem(t, e.post(t, pathEmailStart, map[string]string{"new_email": u.Email}, bearer(s.AccessToken)...), 409, "email_unchanged")
	wantProblem(t, e.post(t, pathEmailStart, map[string]string{"new_email": "invalid"}, bearer(s.AccessToken)...), 400, "invalid_email")
	for _, path := range []string{pathEmailStart, emailCompletePath(p.id)} {
		wantUnauthorized(t, e.post(t, path, `{}`))
		wantProblem(t, e.post(t, path+"?x=1", `{}`, bearer(s.AccessToken)...), 400, "invalid_request")
		wantProblem(t, e.post(t, path, `{}`, bearer(s.AccessToken)...), 400, "invalid_request")
	}
	wantProblem(t, e.post(t, emailCompletePath("invalid"), p.body(), bearer(s.AccessToken)...), 400, "invalid_request")
	for _, path := range []string{pathProfile, pathEmailStart, emailCompletePath(p.id)} {
		method := "POST"
		if path == pathProfile {
			method = "PUT"
		}
		req, err := http.NewRequest(method, e.srv.URL+path, strings.NewReader(`{}`))
		if err != nil {
			t.Fatal(err)
		}
		req.Header.Set("Content-Type", "text/plain")
		req.Header.Set("Authorization", "Bearer "+s.AccessToken)
		res, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		raw, _ := io.ReadAll(res.Body)
		res.Body.Close()
		var body map[string]any
		_ = json.Unmarshal(raw, &body)
		wantProblem(t, response{status: res.StatusCode, header: res.Header, raw: raw, body: body}, 415, "unsupported_media_type")
	}
}

func TestAccount_RateLimitsAndWriteFailures(t *testing.T) {
	t.Run("limits", func(t *testing.T) {
		rules := generousRules()
		rules.RequestSession.Limit = 1
		e := newSignupEnv(t, rules)
		avoidMinuteBoundary(t, e)
		for _, path := range []string{pathProfile, pathEmailStart, emailCompletePath(uuid.NewString())} {
			s := e.issue(t, newUser(t, e.q), "A")
			wantStatus(t, e.me(t, s.AccessToken), 200)
			method := "POST"
			if path == pathProfile {
				method = "PUT"
			}
			wantProblem(t, e.send(t, method, path, `{}`, bearer(s.AccessToken)...), 429, "rate_limited")
		}
	})
	t.Run("writes", func(t *testing.T) {
		e := newSignupEnv(t, nil)
		s := e.issue(t, newUser(t, e.q), "A")
		mustExec(t, e.d.Pool, `CREATE FUNCTION reject_account() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'synthetic write failure'; END $$`)
		mustExec(t, e.d.Pool, `CREATE TRIGGER reject_account BEFORE INSERT ON audit_events FOR EACH ROW WHEN (NEW.action IN ('account.profile.update','account.email.change.start')) EXECUTE FUNCTION reject_account()`)
		wantProblem(t, e.send(t, "PUT", pathProfile, profileInput(0), bearer(s.AccessToken)...), 500, "internal_error")
		_, r := e.emailStart(t, s.AccessToken, newAddress("fail"))
		wantProblem(t, r, 500, "internal_error")
		if rowCount(t, e.d.Pool, `SELECT count(*) FROM email_changes`) != 0 {
			t.Fatal("start not rolled back")
		}
	})
}

func TestMigrations_AccountUpgradeFrom8(t *testing.T) {
	d := pgtest.NewEmpty(t)
	ctx := context.Background()
	if _, err := migrate.Up(ctx, d.URL, migrationsUpTo(t, 8)); err != nil {
		t.Fatal(err)
	}
	seedCleanupData(t, d, 50)
	before := tableCounts(t, d)
	res, err := migrate.Up(ctx, d.URL, migrations.FS)
	if err != nil || res.Current != 9 || len(res.Applied) != 1 || before != tableCounts(t, d) {
		t.Fatalf("migration9: %+v %v", res, err)
	}
	if rowCount(t, d.Pool, `SELECT count(*) FROM users WHERE email_revision<>0 OR profile_revision<>0 OR preferred_language<>'en' OR time_zone<>'UTC' OR daily_goal<>20 OR display_name IS NOT NULL`) != 0 {
		t.Fatal("existing users not initialized")
	}
}

func TestAccount_EmailVsRefresh(t *testing.T) {
	for _, first := range []string{"refresh", "cutover"} {
		for _, acting := range []bool{false, true} {
			t.Run(fmt.Sprintf("%s/acting=%v", first, acting), func(t *testing.T) {
				e := newSignupEnv(t, nil)
				u := newUser(t, e.q)
				a, b := e.issue(t, u, "A"), e.issue(t, u, "B")
				if acting {
					b = a
				}
				p, r := e.emailStart(t, a.AccessToken, newAddress("refresh"))
				wantStatus(t, r, 202)
				ref, out := make(chan response, 1), make(chan response, 1)
				if first == "refresh" {
					tx, err := e.d.Pool.Begin(context.Background())
					if err != nil {
						t.Fatal(err)
					}
					defer tx.Rollback(context.Background())
					if _, err := sqlc.New(tx).LockActingSessionForUpdate(context.Background(), sqlc.LockActingSessionForUpdateParams{ID: b.SessionID, UserID: u.ID}); err != nil {
						t.Fatal(err)
					}
					go func() { ref <- e.refresh(t, b.RefreshToken) }()
					waitForLockWaiters(t, e, 1)
					go func() { out <- e.emailComplete(t, a.AccessToken, p) }()
					waitForLockWaiters(t, e, 2)
					if err := tx.Commit(context.Background()); err != nil {
						t.Fatal(err)
					}
					latest := sessionTokens(t, <-ref)
					want204(t, <-out)
					e.assertRevokedPair(t, latest)
				} else {
					release := managementGate(t, e, "account.email.change.complete")
					go func() { out <- e.emailComplete(t, a.AccessToken, p) }()
					waitForLockWaiters(t, e, 1)
					go func() { ref <- e.refresh(t, b.RefreshToken) }()
					waitForLockWaiters(t, e, 2)
					release()
					want204(t, <-out)
					wantUnauthorized(t, <-ref)
				}
				e.assertRevokedPair(t, a)
				e.assertRevokedPair(t, b)
			})
		}
	}
}

func TestAccount_CommitRetryAndDuplicateCompletion(t *testing.T) {
	e := newSignupEnv(t, nil)
	u := newUser(t, e.q)
	a := e.issue(t, u, "A")
	p, r := e.emailStart(t, a.AccessToken, newAddress("retry"))
	wantStatus(t, r, 202)
	mustExec(t, e.d.Pool, `CREATE SEQUENCE retry_email_once`)
	mustExec(t, e.d.Pool, `CREATE FUNCTION retry_email() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF nextval('retry_email_once')=1 THEN RAISE EXCEPTION 'synthetic retry' USING ERRCODE='40001'; END IF; RETURN NEW; END $$`)
	mustExec(t, e.d.Pool, `CREATE TRIGGER retry_email BEFORE INSERT ON audit_events FOR EACH ROW WHEN (NEW.action='account.email.change.complete') EXECUTE FUNCTION retry_email()`)
	want204(t, e.emailComplete(t, a.AccessToken, p))
	if e.retries.Swap(0) != 1 {
		t.Fatal("expected one transaction retry")
	}
	wantMetric(t, e.metrics, `auth_sessions_revoked_total{reason="email_change"}`, 1)
	if rowCount(t, e.d.Pool, `SELECT count(*) FROM email_outbox WHERE template IN ('email_changed_old','email_changed_new')`) != 2 || rowCount(t, e.d.Pool, `SELECT count(*) FROM audit_events WHERE action='account.email.change.complete'`) != 1 {
		t.Fatal("retry duplicated side effects")
	}
	wantUnauthorized(t, e.emailComplete(t, a.AccessToken, p))
}

func TestAccount_PendingSignupLosesToCutover(t *testing.T) {
	e := newSignupEnv(t, nil)
	u := newUser(t, e.q)
	s := e.issue(t, u, "A")
	next := newAddress("signup-loser")
	code := e.queueCode()
	ack := e.startOTP(t, next)
	wantStatus(t, ack, 202)
	p, r := e.emailStart(t, s.AccessToken, next)
	wantStatus(t, r, 202)
	release := managementGate(t, e, "account.email.change.complete")
	changed, signed := make(chan response, 1), make(chan response, 1)
	go func() { changed <- e.emailComplete(t, s.AccessToken, p) }()
	waitForLockWaiters(t, e, 1)
	go func() { signed <- e.verify(t, ack.str("challenge_token"), code) }()
	waitForLockWaiters(t, e, 2)
	release()
	want204(t, <-changed)
	wantProblem(t, <-signed, 409, "signup_unavailable")
	if rowCount(t, e.d.Pool, `SELECT count(*) FROM users WHERE email_normalized=$1 AND id=$2`, strings.ToLower(next), u.ID) != 1 {
		t.Fatal("signup replaced owner")
	}
}

func TestAccount_ActingRevalidationInsideTransaction(t *testing.T) {
	for _, op := range []string{"profile", "start", "complete"} {
		t.Run(op, func(t *testing.T) {
			e := newSignupEnv(t, nil)
			u := newUser(t, e.q)
			a := e.issue(t, u, "A")
			p, r := e.emailStart(t, a.AccessToken, newAddress("revoked-actor"))
			wantStatus(t, r, 202)
			e.expireEmailCooldown(t)
			tx, err := e.d.Pool.Begin(context.Background())
			if err != nil {
				t.Fatal(err)
			}
			defer tx.Rollback(context.Background())
			if _, err := sqlc.New(tx).LockUserForNoKeyUpdate(context.Background(), u.ID); err != nil {
				t.Fatal(err)
			}
			done := make(chan response, 1)
			go func() {
				switch op {
				case "profile":
					done <- e.send(t, "PUT", pathProfile, profileInput(0), bearer(a.AccessToken)...)
				case "start":
					_, r := e.emailStart(t, a.AccessToken, newAddress("second"))
					done <- r
				case "complete":
					done <- e.emailComplete(t, a.AccessToken, p)
				}
			}()
			waitForLockWaiters(t, e, 1)
			want204(t, e.logout(t, a.AccessToken))
			if err := tx.Commit(context.Background()); err != nil {
				t.Fatal(err)
			}
			wantUnauthorized(t, <-done)
			e.emailUnchanged(t, u.ID, u.EmailNormalized, p)
		})
	}
}

func TestAccount_ExpiredRequestCleanup(t *testing.T) {
	e := newSignupEnv(t, nil)
	u := newUser(t, e.q)
	s := e.issue(t, u, "A")
	old, r := e.emailStart(t, s.AccessToken, newAddress("cleanup"))
	wantStatus(t, r, 202)
	e.expireEmailCooldown(t)
	live, r := e.emailStart(t, s.AccessToken, newAddress("live"))
	wantStatus(t, r, 202)
	mustExec(t, e.d.Pool, `UPDATE email_changes SET expires_at=now()-interval '25 hours' WHERE id=$1`, uuid.MustParse(old.id))
	mustExec(t, e.d.Pool, `UPDATE otp_challenges SET expires_at=now()-interval '25 hours' WHERE change_id=$1`, uuid.MustParse(old.id))
	runner := newRunner(t, e.d, maintenance.Config{BatchSize: 1})
	results := runner.RunOnce(context.Background())
	noErrors(t, results)
	if r := resultOf(t, results, "email_changes"); r.Rows != 1 {
		t.Fatalf("request cleanup: %+v", r)
	}
	if rowCount(t, e.d.Pool, `SELECT count(*) FROM email_changes WHERE id=$1`, uuid.MustParse(old.id)) != 0 || rowCount(t, e.d.Pool, `SELECT count(*) FROM email_changes WHERE id=$1`, uuid.MustParse(live.id)) != 1 {
		t.Fatal("request retention")
	}
	// The superseded pair never sends; the live pair still does.
	if _, err := e.worker.RunOnce(context.Background()); err != nil {
		t.Fatal(err)
	}
}

func TestAccount_ConcurrentCompletionIsSafe(t *testing.T) {
	e := newSignupEnv(t, nil)
	u := newUser(t, e.q)
	s := e.issue(t, u, "A")
	p, r := e.emailStart(t, s.AccessToken, newAddress("duplicate"))
	wantStatus(t, r, 202)
	release := managementGate(t, e, "account.email.change.complete")
	one, two := make(chan response, 1), make(chan response, 1)
	go func() { one <- e.emailComplete(t, s.AccessToken, p) }()
	waitForLockWaiters(t, e, 1)
	go func() { two <- e.emailComplete(t, s.AccessToken, p) }()
	waitForLockWaiters(t, e, 2)
	release()
	want204(t, <-one)
	wantProblem(t, <-two, 400, "invalid_code")
	if rowCount(t, e.d.Pool, `SELECT count(*) FROM audit_events WHERE action='account.email.change.complete'`) != 1 || rowCount(t, e.d.Pool, `SELECT count(*) FROM email_outbox WHERE template IN ('email_changed_old','email_changed_new')`) != 2 {
		t.Fatal("duplicate completion produced side effects")
	}
}
