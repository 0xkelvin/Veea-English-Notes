//go:build integration

package integration

import (
	"bytes"
	"context"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"testing"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/auth/otp"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/identity"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/db/sqlc"
)

const (
	pathOTPLoginStart  = "/v1/auth/otp/start"
	pathOTPLoginVerify = "/v1/auth/otp/verify"
	pathPasswordLogin  = "/v1/auth/password/login"
)

// passwordUser creates a synthetic verified account whose password hash is made by the test
// hasher, so it needs no rehash.
func (e *signupEnv) passwordUser(t *testing.T) (sqlc.User, string) {
	t.Helper()
	u := newUser(t, e.q)
	password := newPassword()
	e.remember(password)
	hash, err := e.hasher.h.Hash(context.Background(), password)
	if err != nil {
		t.Fatal(err)
	}
	mustExec(t, e.d.Pool, `UPDATE users SET password_hash = $2, password_changed_at = now() WHERE id = $1`, u.ID, hash)
	u, _ = e.q.GetUserByID(context.Background(), u.ID)
	return u, password
}

func (e *signupEnv) login(t *testing.T, addr, password string) response {
	t.Helper()
	return e.post(t, pathPasswordLogin, map[string]any{"email": addr, "password": password, "device": testDevice})
}

func (e *signupEnv) otpLoginStart(t *testing.T, addr string) response {
	t.Helper()
	return e.post(t, pathOTPLoginStart, map[string]string{"email": addr})
}

func (e *signupEnv) otpLoginVerify(t *testing.T, token, code string) response {
	t.Helper()
	return e.post(t, pathOTPLoginVerify, map[string]any{"challenge_token": token, "code": code, "device": testDevice})
}

// otpLogin runs Flow C end to end, reading the code from the delivered email.
func (e *signupEnv) otpLogin(t *testing.T, addr, mailbox string) response {
	t.Helper()
	ack := e.otpLoginStart(t, addr)
	if ack.status != http.StatusAccepted {
		t.Fatalf("otp start: %d %s", ack.status, ack.raw)
	}
	return e.otpLoginVerify(t, ack.str("challenge_token"), e.mailedCode(t, mailbox))
}

// meID checks a token through GET /v1/me and returns the user id it resolves to.
func (e *signupEnv) meID(t *testing.T, access string) string {
	t.Helper()
	r := e.me(t, access)
	if r.status != http.StatusOK {
		t.Fatalf("GET /v1/me: %d %s", r.status, r.raw)
	}
	return r.str("id")
}

func userID(r response) string {
	u, _ := r.body["user"].(map[string]any)
	s, _ := u["id"].(string)
	return s
}

// withoutRequestID is a response body with its request_id removed, for byte comparisons.
func withoutRequestID(r response) string {
	return string(bytes.Replace(r.raw, []byte(r.str("request_id")), nil, 1))
}

// =============================================================================================
// Same account either way (AC-2, AC-5, AC-8, AC-17)
// =============================================================================================

func TestSignin_PasswordAndOTPResolveToTheSameUser(t *testing.T) {
	env := newSignupEnv(t, nil)
	u, password := env.passwordUser(t)

	pw := env.login(t, strings.ToUpper(u.Email), password) // case differences are one account (AC-8)
	if pw.status != http.StatusOK || userID(pw) != u.ID.String() || pw.header.Get("Cache-Control") != "no-store" {
		t.Fatalf("password login: %d %s", pw.status, pw.raw)
	}
	otpRes := env.otpLogin(t, u.Email, u.Email)
	if otpRes.status != http.StatusOK || userID(otpRes) != u.ID.String() {
		t.Fatalf("OTP login: %d %s", otpRes.status, otpRes.raw)
	}
	// Both sessions are live and separate (AC-17), and both tokens resolve to the account.
	if env.meID(t, pw.str("access_token")) != u.ID.String() || env.meID(t, otpRes.str("access_token")) != u.ID.String() {
		t.Fatal("both access tokens must resolve to the same account")
	}
	if pw.str("session_id") == otpRes.str("session_id") ||
		rowCount(t, env.d.Pool, `SELECT count(*) FROM sessions WHERE user_id = $1 AND revoked_at IS NULL`, u.ID) != 2 {
		t.Fatal("each sign-in creates its own session")
	}
	if rowCount(t, env.d.Pool, `SELECT count(*) FROM sessions WHERE user_id = $1 AND auth_method IN ('password', 'otp')`, u.ID) != 2 {
		t.Fatal("sessions record their sign-in method")
	}
	for _, action := range []string{"auth.password.login", "auth.otp.verify"} {
		if rowCount(t, env.d.Pool, `SELECT count(*) FROM audit_events WHERE action = $1 AND outcome = 'success'
			AND target_user_id = $2 AND session_id IS NOT NULL`, action, u.ID) != 1 {
			t.Fatalf("expected one %s success event", action)
		}
	}
}

// AC-2 through the router: an OTP signup, then OTP sign-in, gives the same user id.
func TestSignin_OTPSignupThenOTPLoginSameUserID(t *testing.T) {
	env := newSignupEnv(t, nil)
	addr := newAddress("Returning")
	ack := env.startOTP(t, addr)
	signup := env.verify(t, ack.str("challenge_token"), env.mailedCode(t, addr))
	if signup.status != http.StatusCreated {
		t.Fatalf("signup: %d", signup.status)
	}
	login := env.otpLogin(t, strings.ToLower(addr), addr)
	if login.status != http.StatusOK || userID(login) != userID(signup) || env.meID(t, login.str("access_token")) != userID(signup) {
		t.Fatalf("OTP login after signup: %d %s", login.status, login.raw)
	}
	if env.count(t, "users") != 1 {
		t.Fatal("sign-in never creates an account")
	}
}

// =============================================================================================
// OTP sign-in (Flow C)
// =============================================================================================

// AC-6, AC-27: an unknown email gets the same acknowledgement, no email, and can never sign in
// or create an account, even with the stored code.
func TestOTPLogin_UnknownOrIneligibleEmailGetsTheSameAckAndNoEmail(t *testing.T) {
	env := newSignupEnv(t, nil)
	active := newUser(t, env.q)
	suspended := newUser(t, env.q)
	mustExec(t, env.d.Pool, `UPDATE users SET status = 'suspended', resume_status = 'active', suspension_reason = 'other' WHERE id = $1`, suspended.ID)
	unknown := newAddress("nobody")
	users := env.count(t, "users")

	shape := func(r response) string {
		s := string(r.raw)
		for _, k := range []string{"challenge_token", "expires_at", "resend_after"} {
			s = strings.Replace(s, r.str(k), "<"+k+">", 1)
		}
		return fmt.Sprintf("%d %s %s", r.status, r.header.Get("Content-Type"), s)
	}
	eligible := env.otpLoginStart(t, active.Email)
	codes := map[string]string{}
	acks := map[string]response{}
	for _, addr := range []string{unknown, suspended.Email} {
		codes[addr] = env.queueCode()
		acks[addr] = env.otpLoginStart(t, addr)
		if shape(acks[addr]) != shape(eligible) {
			t.Fatalf("acknowledgements differ:\n%s\n%s", shape(eligible), shape(acks[addr]))
		}
	}
	if _, err := env.worker.RunOnce(context.Background()); err != nil {
		t.Fatal(err)
	}
	if sent := env.fake.Sent(); len(sent) != 1 || sent[0].To != active.Email {
		t.Fatalf("only the account in good standing gets a login email, got %d", len(sent))
	}
	for addr, ack := range acks {
		wantProblem(t, env.otpLoginVerify(t, ack.str("challenge_token"), codes[addr]), http.StatusBadRequest, "invalid_code")
	}
	if env.count(t, "users") != users || env.count(t, "sessions") != 0 {
		t.Fatal("OTP sign-in must never create an account or a session for these emails")
	}
}

// TRD 7.3: the account left good standing after the code was sent. The transaction rolls back
// (the code stays usable), the response is invalid_code, and only the T-fail audit commits.
func TestOTPLogin_AccountNoLongerEligibleAtVerify(t *testing.T) {
	env := newSignupEnv(t, nil)
	for _, mutate := range []string{
		`UPDATE users SET status = 'suspended', resume_status = 'active', suspension_reason = 'other' WHERE id = $1`,
		`UPDATE users SET email_verified_at = NULL WHERE id = $1`,
	} {
		t.Run(strings.Fields(mutate)[3], func(t *testing.T) {
			u := newUser(t, env.q)
			code := env.queueCode()
			ack := env.otpLoginStart(t, u.Email)
			mustExec(t, env.d.Pool, mutate, u.ID)

			wantProblem(t, env.otpLoginVerify(t, ack.str("challenge_token"), code), http.StatusBadRequest, "invalid_code")
			if attempts, consumed, _ := env.challengeByToken(t, ack.str("challenge_token")); consumed || attempts != 0 {
				t.Fatal("the consumption must roll back and no attempt be charged")
			}
			if rowCount(t, env.d.Pool, `SELECT count(*) FROM sessions WHERE user_id = $1`, u.ID) != 0 {
				t.Fatal("no session for an account out of good standing")
			}
			if rowCount(t, env.d.Pool, `SELECT count(*) FROM audit_events WHERE action = 'auth.otp.verify'
				AND outcome = 'failure' AND reason = 'account_unavailable' AND target_user_id = $1`, u.ID) != 1 {
				t.Fatal("expected the T-fail account_unavailable event")
			}
			// Back in good standing, the same code works.
			mustExec(t, env.d.Pool, `UPDATE users SET status = 'active', resume_status = NULL, suspension_reason = NULL, email_verified_at = now() WHERE id = $1`, u.ID)
			if r := env.otpLoginVerify(t, ack.str("challenge_token"), code); r.status != http.StatusOK {
				t.Fatalf("after reinstatement: %d %s", r.status, r.raw)
			}
		})
	}
}

// One transaction: consumption, session, email cancellation and audit commit together.
func TestOTPLogin_CommitsConsumptionSessionCancellationAndAuditTogether(t *testing.T) {
	env := newSignupEnv(t, nil)
	u := newUser(t, env.q)
	code := env.queueCode() // the worker never runs, so the email is still pending at verify
	ack := env.otpLoginStart(t, u.Email)
	res := env.otpLoginVerify(t, ack.str("challenge_token"), code)
	if res.status != http.StatusOK || env.meID(t, res.str("access_token")) != u.ID.String() {
		t.Fatalf("verify: %d %s", res.status, res.raw)
	}
	if _, consumed, _ := env.challengeByToken(t, ack.str("challenge_token")); !consumed {
		t.Fatal("challenge consumed")
	}
	if rowCount(t, env.d.Pool, `SELECT count(*) FROM email_outbox o JOIN otp_challenges c ON c.id = o.challenge_id
		WHERE c.token_hash = $1 AND o.status = 'cancelled' AND o.payload_ciphertext IS NULL`,
		otp.HashToken(ack.str("challenge_token"))) != 1 {
		t.Fatal("the unsent code email is cancelled and scrubbed")
	}
	if rowCount(t, env.d.Pool, `SELECT count(*) FROM audit_events WHERE action = 'auth.otp.verify' AND outcome = 'success'
		AND session_id = $1`, res.str("session_id")) != 1 {
		t.Fatal("success audit event with the new session")
	}
	wantProblem(t, env.otpLoginVerify(t, ack.str("challenge_token"), code), http.StatusBadRequest, "invalid_code")
}

// A failed session insert rolls back the consumption and the cancellation; the code then works.
func TestOTPLogin_SessionIssuanceFailureRollsBackEverything(t *testing.T) {
	env := newSignupEnv(t, nil)
	u := newUser(t, env.q)
	code := env.queueCode()
	ack := env.otpLoginStart(t, u.Email)
	mustExec(t, env.d.Pool, `CREATE FUNCTION test_fail_session() RETURNS trigger LANGUAGE plpgsql
		AS $$ BEGIN RAISE EXCEPTION 'forced session failure'; END $$`)
	mustExec(t, env.d.Pool, `CREATE TRIGGER test_fail_session BEFORE INSERT ON sessions FOR EACH ROW EXECUTE FUNCTION test_fail_session()`)

	r := env.otpLoginVerify(t, ack.str("challenge_token"), code)
	wantProblem(t, r, http.StatusInternalServerError, "internal_error")
	if r.body["access_token"] != nil || bytes.Contains(r.raw, []byte("forced")) {
		t.Fatalf("no tokens and no detail: %s", r.raw)
	}
	if attempts, consumed, _ := env.challengeByToken(t, ack.str("challenge_token")); consumed || attempts != 0 {
		t.Fatal("the consumption must roll back")
	}
	if rowCount(t, env.d.Pool, `SELECT count(*) FROM email_outbox WHERE status = 'pending' AND payload_ciphertext IS NOT NULL`) != 1 {
		t.Fatal("the cancellation must roll back")
	}
	if rowCount(t, env.d.Pool, `SELECT count(*) FROM audit_events WHERE action = 'auth.otp.verify' AND outcome = 'success'`) != 0 {
		t.Fatal("no success event for a rolled-back sign-in")
	}
	mustExec(t, env.d.Pool, `DROP TRIGGER test_fail_session ON sessions`)
	ok := env.otpLoginVerify(t, ack.str("challenge_token"), code)
	if ok.status != http.StatusOK || env.meID(t, ok.str("access_token")) != u.ID.String() {
		t.Fatalf("after the fault the same code works: %d %s", ok.status, ok.raw)
	}
}

// =============================================================================================
// Password sign-in (Flow D)
// =============================================================================================

// AC-7: wrong password, unknown email, passwordless account and pending registration all get
// the identical 401, each after exactly one Argon2id run (the dummy where there is no hash), and
// each failure is counted and audited.
func TestPasswordLogin_GenericFailure(t *testing.T) {
	env := newSignupEnv(t, nil)
	withPassword, _ := env.passwordUser(t)
	passwordless := newUser(t, env.q)
	pending := newAddress("pending")
	if r := env.startPassword(t, pending, newPassword()); r.status != http.StatusAccepted {
		t.Fatalf("pending registration: %d", r.status)
	}
	cases := []struct {
		name, addr string
		dummy      bool
	}{
		{"wrong password", withPassword.Email, false},
		{"unknown email", newAddress("unknown"), true},
		{"passwordless account", passwordless.Email, true},
		{"pending registration", pending, true},
	}
	var bodies []string
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			verifies, dummies := env.hasher.verifies.Load(), env.hasher.dummies.Load()
			r := env.login(t, c.addr, newPassword())
			wantProblem(t, r, http.StatusUnauthorized, "invalid_credentials")
			bodies = append(bodies, withoutRequestID(r))
			if env.hasher.verifies.Load()-verifies != 1 {
				t.Fatal("every failure must cost exactly one Argon2id run")
			}
			if (env.hasher.dummies.Load()-dummies == 1) != c.dummy {
				t.Fatalf("dummy verification used = %v, want %v", env.hasher.dummies.Load()-dummies == 1, c.dummy)
			}
			key := "login_fail_email_15m:email:" + env.hmac.CurrentHex(email(t, c.addr))
			if rowCount(t, env.d.Pool, `SELECT coalesce(sum(count), 0)::int FROM rate_limit_counters WHERE key = $1`, key) != 1 {
				t.Fatal("the failure is counted against the email")
			}
			if rowCount(t, env.d.Pool, `SELECT count(*) FROM audit_events WHERE action = 'auth.password.login'
				AND outcome = 'failure' AND reason = 'invalid_credentials' AND email_hmac = $1`, env.hmac.Current(email(t, c.addr))) != 1 {
				t.Fatal("the failure is audited by email HMAC")
			}
		})
	}
	for _, b := range bodies[1:] {
		if b != bodies[0] {
			t.Fatalf("public responses differ:\n%s\n%s", bodies[0], b)
		}
	}
	if env.count(t, "sessions") != 0 || env.count(t, "users") != 2 {
		t.Fatal("no session, and the pending registration is still not an account (AC-26)")
	}
	// Unknown-email events carry no user id (TRD 11.1).
	if rowCount(t, env.d.Pool, `SELECT count(*) FROM audit_events WHERE action = 'auth.password.login' AND target_user_id IS NULL`) != 2 {
		t.Fatal("unknown and pending emails are audited by HMAC only")
	}
}

// AC-9: a correct password on an account out of good standing gets 403 only after it verified;
// a wrong password there still gets the generic 401. No session either way.
func TestPasswordLogin_NonActiveAccount(t *testing.T) {
	env := newSignupEnv(t, nil)
	for _, mutate := range []string{
		`UPDATE users SET status = 'suspended', resume_status = 'active', suspension_reason = 'other' WHERE id = $1`,
		`UPDATE users SET status = 'deactivated' WHERE id = $1`,
		`UPDATE users SET status = 'pending_deletion' WHERE id = $1`,
		`UPDATE users SET email_verified_at = NULL WHERE id = $1`,
	} {
		t.Run(strings.Fields(mutate)[3]+strings.Fields(mutate)[5], func(t *testing.T) {
			u, password := env.passwordUser(t)
			mustExec(t, env.d.Pool, mutate, u.ID)
			wantProblem(t, env.login(t, u.Email, newPassword()), http.StatusUnauthorized, "invalid_credentials")
			wantProblem(t, env.login(t, u.Email, password), http.StatusForbidden, "account_unavailable")
			if rowCount(t, env.d.Pool, `SELECT count(*) FROM sessions WHERE user_id = $1`, u.ID) != 0 {
				t.Fatal("no session for an account out of good standing")
			}
			if rowCount(t, env.d.Pool, `SELECT count(*) FROM audit_events WHERE action = 'auth.password.login'
				AND reason = 'account_unavailable' AND target_user_id = $1`, u.ID) != 1 {
				t.Fatal("expected the account_unavailable failure event")
			}
			// OTP start for it sends nothing.
			sent := env.fake.Calls()
			env.otpLoginStart(t, u.Email)
			if _, err := env.worker.RunOnce(context.Background()); err != nil || env.fake.Calls() != sent {
				t.Fatal("no login code for an account out of good standing")
			}
		})
	}
}

// AC-20 and TRD 10: after 10 failures in 15 minutes password sign-in is refused before Argon2id,
// even with the right password, while OTP sign-in still works.
func TestPasswordLogin_LockoutStillAllowsOTPSignin(t *testing.T) {
	rules := generousRules()
	rules.PasswordSignupStartIP.Limit = 10_000
	rules.PasswordLoginFailEmail.Limit = 3
	env := newSignupEnv(t, rules)
	u, password := env.passwordUser(t)
	for range 3 {
		wantProblem(t, env.login(t, u.Email, newPassword()), http.StatusUnauthorized, "invalid_credentials")
	}
	verifies := env.hasher.verifies.Load()
	locked := env.login(t, u.Email, password)
	wantProblem(t, locked, http.StatusTooManyRequests, "rate_limited")
	if ra, err := strconv.Atoi(locked.header.Get("Retry-After")); err != nil || ra < 1 || ra > 15*60 {
		t.Fatalf("Retry-After %q", locked.header.Get("Retry-After"))
	}
	if env.hasher.verifies.Load() != verifies {
		t.Fatal("a locked-out request must not run Argon2id")
	}
	// Case and spelling do not escape the lockout (AC-8).
	wantProblem(t, env.login(t, strings.ToUpper(u.Email), password), http.StatusTooManyRequests, "rate_limited")

	res := env.otpLogin(t, u.Email, u.Email)
	if res.status != http.StatusOK || env.meID(t, res.str("access_token")) != u.ID.String() {
		t.Fatalf("OTP sign-in must still work during a password lockout: %d %s", res.status, res.raw)
	}
	// Another account is unaffected.
	other, otherPassword := env.passwordUser(t)
	if r := env.login(t, other.Email, otherPassword); r.status != http.StatusOK {
		t.Fatalf("another account: %d", r.status)
	}
}

func TestPasswordLogin_IPLimitRunsBeforeArgon2id(t *testing.T) {
	rules := generousRules()
	rules.PasswordSignupStartIP.Limit = 10_000
	rules.PasswordLoginIP.Limit = 2
	env := newSignupEnv(t, rules)
	u, password := env.passwordUser(t)
	for range 2 {
		if r := env.login(t, u.Email, password); r.status != http.StatusOK {
			t.Fatalf("login: %d", r.status)
		}
	}
	verifies := env.hasher.verifies.Load()
	wantProblem(t, env.login(t, newAddress("x"), newPassword()), http.StatusTooManyRequests, "rate_limited")
	if env.hasher.verifies.Load() != verifies {
		t.Fatal("an IP-limited request must not run Argon2id")
	}
}

// TRD 7.4 step 3: the hash changed between verification and the transaction (a concurrent
// change or reset). No session is issued from the stale password.
func TestPasswordLogin_HashChangedAfterVerificationIssuesNoSession(t *testing.T) {
	env := newSignupEnv(t, nil)
	u, password := env.passwordUser(t)
	replacement, _ := env.hasher.h.Hash(context.Background(), newPassword())
	env.hasher.afterVerify.Store(func() {
		mustExec(t, env.d.Pool, `UPDATE users SET password_hash = $2 WHERE id = $1`, u.ID, replacement)
	})
	defer env.hasher.afterVerify.Store(func() {})

	wantProblem(t, env.login(t, u.Email, password), http.StatusUnauthorized, "invalid_credentials")
	if rowCount(t, env.d.Pool, `SELECT count(*) FROM sessions WHERE user_id = $1`, u.ID) != 0 {
		t.Fatal("no session may be issued from a password that changed under the lock")
	}
	if rowCount(t, env.d.Pool, `SELECT count(*) FROM audit_events WHERE action = 'auth.password.login'
		AND reason = 'password_changed_concurrently' AND target_user_id = $1`, u.ID) != 1 {
		t.Fatal("expected the password_changed_concurrently event")
	}
	if rowCount(t, env.d.Pool, `SELECT count(*) FROM users WHERE id = $1 AND password_hash = $2`, u.ID, replacement) != 1 {
		t.Fatal("the concurrent change must stand")
	}
}

// TRD 9.2: outdated parameters are rehashed on success, with the Argon2id run outside the
// transaction and a compare-and-set on the old hash. password_changed_at is not touched.
func TestPasswordLogin_RehashesOutdatedParameters(t *testing.T) {
	env := newSignupEnv(t, nil)
	u := newUser(t, env.q)
	password := newPassword()
	env.remember(password)
	old, err := identity.NewHasher(identity.HasherConfig{Params: identity.Params{MemoryKiB: 32, Time: 1, Threads: 1, SaltLen: 16, KeyLen: 32}})
	if err != nil {
		t.Fatal(err)
	}
	oldHash, _ := old.Hash(context.Background(), password)
	mustExec(t, env.d.Pool, `UPDATE users SET password_hash = $2, password_changed_at = '2026-01-01T00:00:00Z' WHERE id = $1`, u.ID, oldHash)
	hashes := env.hasher.n.Load()

	r := env.login(t, u.Email, password)
	if r.status != http.StatusOK || env.meID(t, r.str("access_token")) != u.ID.String() {
		t.Fatalf("login: %d %s", r.status, r.raw)
	}
	stored, _ := env.q.GetUserByID(context.Background(), u.ID)
	if *stored.PasswordHash == oldHash || !strings.Contains(*stored.PasswordHash, "m=64,t=1,p=1") || env.hasher.n.Load() != hashes+1 {
		t.Fatal("the hash must be replaced with the current parameters, computed once")
	}
	if v, err := env.hasher.h.Verify(context.Background(), *stored.PasswordHash, password); err != nil || !v.Match || v.NeedsRehash {
		t.Fatal("the new hash must verify with current parameters")
	}
	if stored.PasswordChangedAt == nil || stored.PasswordChangedAt.Year() != 2026 || stored.PasswordChangedAt.Month() != 1 {
		t.Fatal("a rehash is not a password change")
	}
}

func TestPasswordLogin_RequestContract(t *testing.T) {
	env := newSignupEnv(t, nil)
	u, password := env.passwordUser(t)
	for name, body := range map[string]any{
		"malformed email": map[string]any{"email": "not-an-email", "password": password, "device": testDevice},
		"no device":       map[string]any{"email": u.Email, "password": password},
		"bad device":      map[string]any{"email": u.Email, "password": password, "device": map[string]string{"name": "", "platform": "ios"}},
		"unknown field":   map[string]any{"email": u.Email, "password": password, "device": testDevice, "remember": true},
	} {
		t.Run(name, func(t *testing.T) {
			wantProblem(t, env.post(t, pathPasswordLogin, body), http.StatusBadRequest, "invalid_request")
		})
	}
	if env.hasher.verifies.Load() != 0 || env.count(t, "rate_limit_counters") != 0 {
		t.Fatal("a malformed request runs no Argon2id and counts nothing")
	}
	// Tokens from a successful login work, and the user body matches the account.
	r := env.login(t, u.Email, password)
	user, _ := r.body["user"].(map[string]any)
	if r.status != http.StatusOK || user["has_password"] != true || user["email"] != u.Email || env.meID(t, r.str("access_token")) != u.ID.String() {
		t.Fatalf("login: %d %s", r.status, r.raw)
	}
}
