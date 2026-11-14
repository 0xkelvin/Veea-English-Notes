//go:build integration

package integration

import (
	"bytes"
	"net/http"
	"strings"
	"testing"

	"github.com/google/uuid"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/ratelimit"
)

// These tests exercise documented responses the flow tests do not reach, so the contract
// checker sees every status the spec promises (TestMain prints what is still unexercised).

func TestContract_RemainingRateLimitResponses(t *testing.T) {
	t.Run("per-email start limit across purposes", func(t *testing.T) {
		rules := generousRules()
		rules.PasswordSignupStartIP.Limit = 10_000
		rules.StartEmailHourly.Limit = 1
		env := newSignupEnv(t, rules)
		for _, path := range []string{pathOTPLoginStart, pathResetStart} {
			u := newUser(t, env.q)
			wantStatus(t, env.post(t, pathOTPStart, map[string]string{"email": u.Email}), http.StatusAccepted)
			wantProblem(t, env.post(t, path, map[string]string{"email": u.Email}), http.StatusTooManyRequests, "rate_limited")
		}
		u := newUser(t, env.q)
		s := env.issue(t, u, "Phone")
		wantStatus(t, env.otpLoginStart(t, u.Email), http.StatusAccepted)
		wantProblem(t, env.setStart(t, s.AccessToken), http.StatusTooManyRequests, "rate_limited")
	})
	t.Run("per-IP verify limit on signup verify", func(t *testing.T) {
		rules := generousRules()
		rules.PasswordSignupStartIP.Limit = 10_000
		rules.VerifyIP.Limit = 1
		env := newSignupEnv(t, rules)
		ack := env.startOTP(t, newAddress("ipv"))
		env.verify(t, ack.str("challenge_token"), "000000")
		wantProblem(t, env.verify(t, ack.str("challenge_token"), "000000"), http.StatusTooManyRequests, "rate_limited")
	})
	t.Run("per-session request limit on logout", func(t *testing.T) {
		rules := generousRules()
		rules.PasswordSignupStartIP.Limit = 10_000
		rules.RequestSession.Limit = 1
		env := newSignupEnv(t, rules)
		avoidMinuteBoundary(t, env)
		s := env.issue(t, newUser(t, env.q), "Phone")
		env.me(t, s.AccessToken)
		wantProblem(t, env.logout(t, s.AccessToken), http.StatusTooManyRequests, "rate_limited")
	})
}

func TestContract_RemainingValidationResponses(t *testing.T) {
	env := newSignupEnv(t, nil)
	u, _ := env.passwordUser(t)
	s := env.issue(t, u, "Phone")
	wantProblem(t, env.send(t, http.MethodPut, pathChange, `{"current_password":"x","new_password":"y","extra":1}`, bearer(s.AccessToken)...),
		http.StatusBadRequest, "invalid_request")
	ack := env.resetStart(t, u.Email)
	r := env.resetComplete(t, ack.str("challenge_token"), "000000", "short")
	wantProblem(t, r, http.StatusUnprocessableEntity, "password_policy_violation")
	if attempts, _, _ := env.challengeByToken(t, ack.str("challenge_token")); attempts != 0 {
		t.Fatal("a policy failure on reset costs no attempt (AC-15)")
	}
}

// TRD 9.2: a saturated hasher answers 503 busy with Retry-After on every endpoint that hashes.
func TestContract_BusyHasherAnswers503(t *testing.T) {
	env := newSignupEnv(t, nil)
	u, pw := env.passwordUser(t)
	p := newUser(t, env.q)
	s, ps := env.issue(t, u, "Phone"), env.issue(t, p, "Phone")
	setAck := env.setStart(t, ps.AccessToken)
	env.hasher.busy.Store(true)
	defer env.hasher.busy.Store(false)
	for name, r := range map[string]response{
		"password signup": env.post(t, pathPasswordStart, map[string]string{"email": newAddress("busy"), "password": newPassword()}),
		"password login":  env.login(t, u.Email, pw),
		"reset complete":  env.resetComplete(t, "vct_"+strings.Repeat("A", 43), "000000", newPassword()),
		"first password":  env.setPassword(t, ps.AccessToken, setAck.str("challenge_token"), "000000", newPassword()),
		"change password": env.change(t, s.AccessToken, pw, newPassword()),
	} {
		t.Run(name, func(t *testing.T) {
			wantProblem(t, r, http.StatusServiceUnavailable, "busy")
			if r.header.Get("Retry-After") != "1" {
				t.Fatalf("Retry-After %q", r.header.Get("Retry-After"))
			}
		})
	}
	if env.storedHash(t, u) == "" || env.storedHash(t, p) != "" {
		t.Fatal("a busy answer changes nothing")
	}
}

// A failure the client cannot cause is 500 internal_error, in the problem shape, with no detail.
func TestContract_InternalErrorsUseTheProblemShape(t *testing.T) {
	env := newSignupEnv(t, nil)
	u, _ := env.passwordUser(t)
	s := env.issue(t, u, "Phone")
	other := env.issue(t, u, "Tablet")
	mustExec(t, env.d.Pool, `CREATE FUNCTION test_fail_audit() RETURNS trigger LANGUAGE plpgsql
		AS $$ BEGIN RAISE EXCEPTION 'forced audit failure SECRET_DETAIL'; END $$`)
	mustExec(t, env.d.Pool, `CREATE TRIGGER test_fail_audit BEFORE INSERT ON audit_events FOR EACH ROW EXECUTE FUNCTION test_fail_audit()`)
	defer mustExec(t, env.d.Pool, `DROP TRIGGER test_fail_audit ON audit_events`)
	for name, r := range map[string]response{
		"signup otp start":      env.post(t, pathOTPStart, map[string]string{"email": newAddress("e500")}),
		"signup password start": env.post(t, pathPasswordStart, map[string]string{"email": newAddress("e500"), "password": newPassword()}),
		"otp start":             env.otpLoginStart(t, u.Email),
		"reset start":           env.resetStart(t, newAddress("e500")),
		"password login":        env.login(t, u.Email, newPassword()),
		"first password start":  env.setStart(t, env.issue(t, newUser(t, env.q), "Phone").AccessToken),
		"first password set":    env.setPassword(t, other.AccessToken, "vct_"+strings.Repeat("B", 43), "000000", newPassword()),
		"logout":                env.logout(t, s.AccessToken),
	} {
		t.Run(name, func(t *testing.T) {
			wantProblem(t, r, http.StatusInternalServerError, "internal_error")
			if bytes.Contains(r.raw, []byte("SECRET_DETAIL")) || bytes.Contains(r.raw, []byte("forced")) {
				t.Fatalf("an internal error leaks its cause: %s", r.raw)
			}
		})
	}
}

// AC-22, scoped: an issued six-digit code never appears in any error body returned while it is
// live, whatever went wrong. Each assertion is against the response of a request made with that
// code, with the request id removed, so it cannot match by accident elsewhere.
func TestAC22_ErrorBodiesNeverContainTheIssuedCode(t *testing.T) {
	rules := generousRules()
	rules.PasswordSignupStartIP.Limit = 10_000
	env := newSignupEnv(t, rules)
	noCode := func(t *testing.T, r response, code string) {
		t.Helper()
		if r.status < 400 {
			t.Fatalf("expected an error, got %d", r.status)
		}
		body := strings.ReplaceAll(string(r.raw), r.str("request_id"), "")
		if strings.Contains(body, code) {
			t.Fatalf("error body contains the issued code: %s", r.raw)
		}
		for _, h := range []string{"Retry-After", "WWW-Authenticate"} {
			if strings.Contains(r.header.Get(h), code) {
				t.Fatalf("header %s contains the issued code", h)
			}
		}
	}

	t.Run("signup verify", func(t *testing.T) {
		addr := newAddress("ac22")
		code := env.queueCode()
		ack := env.startOTP(t, addr)
		tok := ack.str("challenge_token")
		noCode(t, env.post(t, pathVerify, map[string]any{"challenge_token": tok, "code": code}), code) // 400 invalid_request
		noCode(t, env.verify(t, "vct_"+strings.Repeat("C", 43), code), code)                           // 400 invalid_code, unknown token
		for range 5 {
			noCode(t, env.verify(t, tok, wrongCode(code)), wrongCode(code))
		}
		noCode(t, env.verify(t, tok, code), code) // 400 code_attempts_exceeded with the right code
	})
	t.Run("signup verify conflict", func(t *testing.T) {
		addr := newAddress("ac22c")
		code := env.queueCode()
		ack := env.startOTP(t, addr)
		mustExec(t, env.d.Pool, `INSERT INTO users (id, email, email_normalized, email_verified_at) VALUES ($1, $2, $3, now())`,
			uuid.New(), addr, strings.ToLower(addr))
		noCode(t, env.verify(t, ack.str("challenge_token"), code), code) // 409 signup_unavailable
	})
	t.Run("OTP sign-in, account unavailable", func(t *testing.T) {
		u := newUser(t, env.q)
		code := env.queueCode()
		ack := env.otpLoginStart(t, u.Email)
		mustExec(t, env.d.Pool, `UPDATE users SET status = 'suspended' WHERE id = $1`, u.ID)
		noCode(t, env.otpLoginVerify(t, ack.str("challenge_token"), code), code)
	})
	t.Run("set and reset with the right code", func(t *testing.T) {
		u := newUser(t, env.q)
		s := env.issue(t, u, "Phone")
		code := env.queueCode()
		ack := env.setStart(t, s.AccessToken)
		noCode(t, env.setPassword(t, s.AccessToken, ack.str("challenge_token"), code, "short"), code) // 422
		wrongSession := env.issue(t, u, "Tablet")
		noCode(t, env.setPassword(t, wrongSession.AccessToken, ack.str("challenge_token"), code, newPassword()), code) // binding

		w, _ := env.passwordUser(t)
		rcode := env.queueCode()
		rack := env.resetStart(t, w.Email)
		noCode(t, env.resetComplete(t, rack.str("challenge_token"), rcode, "short"), rcode)                    // 422
		noCode(t, env.setPassword(t, s.AccessToken, rack.str("challenge_token"), rcode, newPassword()), rcode) // wrong purpose
	})
}

// auth.rate_limited with an IP subject: once per window, the client address in ip, no email.
func TestAudit_IPSubjectRateLimitedOncePerWindow(t *testing.T) {
	cases := []struct {
		name, rule string
		tune       func(r *ratelimit.Rules)
		do         func(t *testing.T, env *signupEnv, rid string) response
	}{
		{"signup start", "otp_start_ip_1h", func(r *ratelimit.Rules) { r.StartIP.Limit = 1 },
			func(t *testing.T, env *signupEnv, rid string) response {
				return env.call(t, "POST", pathOTPStart, map[string]string{"email": newAddress("ip")}, rid)
			}},
		{"password signup start", "signup_password_start_ip_1h", func(r *ratelimit.Rules) { r.PasswordSignupStartIP.Limit = 1 },
			func(t *testing.T, env *signupEnv, rid string) response {
				return env.call(t, "POST", pathPasswordStart, map[string]string{"email": newAddress("ip"), "password": newPassword()}, rid)
			}},
		{"OTP verification", "otp_verify_ip_1h", func(r *ratelimit.Rules) { r.VerifyIP.Limit = 1 },
			func(t *testing.T, env *signupEnv, rid string) response {
				return env.call(t, "POST", pathOTPLoginVerify, map[string]any{"challenge_token": "vct_" + strings.Repeat("D", 43), "code": "000000", "device": testDevice}, rid)
			}},
		{"password login", "login_ip_15m", func(r *ratelimit.Rules) { r.PasswordLoginIP.Limit = 1 },
			func(t *testing.T, env *signupEnv, rid string) response {
				return env.call(t, "POST", pathPasswordLogin, map[string]any{"email": newAddress("ip"), "password": newPassword(), "device": testDevice}, rid)
			}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			rules := generousRules()
			rules.PasswordSignupStartIP.Limit = 10_000
			c.tune(rules)
			env := newSignupEnv(t, rules)
			if r := c.do(t, env, newRID()); r.status == http.StatusTooManyRequests {
				t.Fatal("the first request is within the limit")
			}
			rid := newRID()
			wantStatus(t, c.do(t, env, rid), http.StatusTooManyRequests)
			env.wantEvents(t, rid, ev{action: "auth.rate_limited", outcome: "failure", reason: c.rule, target: "-", session: "-",
				meta: map[string]string{"rule": c.rule, "subject": "ip"}})
			if rowCount(t, env.d.Pool, `SELECT count(*) FROM audit_events WHERE request_id = $1 AND ip = '127.0.0.1' AND email_hmac IS NULL`, rid) != 1 {
				t.Fatal("the event records the client address and no email")
			}
			rid = newRID()
			wantStatus(t, c.do(t, env, rid), http.StatusTooManyRequests)
			env.wantEvents(t, rid) // once per window
		})
	}
}

// The remaining documented codes the flow tests leave out.
func TestContract_RemainingDocumentedCodes(t *testing.T) {
	env := newSignupEnv(t, nil)
	for _, path := range []string{pathOTPLoginStart, pathResetStart} {
		wantProblem(t, env.post(t, path, map[string]string{"email": "not an email"}), http.StatusBadRequest, "invalid_email")
	}

	u, _ := env.passwordUser(t)
	code := env.queueCode()
	ack := env.resetStart(t, u.Email)
	for range 5 {
		env.resetComplete(t, ack.str("challenge_token"), wrongCode(code), newPassword())
	}
	wantProblem(t, env.resetComplete(t, ack.str("challenge_token"), code, newPassword()), http.StatusBadRequest, "code_attempts_exceeded")

	p := newUser(t, env.q)
	s := env.issue(t, p, "Phone")
	setCode := env.queueCode()
	setAck := env.setStart(t, s.AccessToken)
	wantProblem(t, env.post(t, pathSet, map[string]string{"challenge_token": setAck.str("challenge_token"), "code": setCode},
		bearer(s.AccessToken)...), http.StatusBadRequest, "invalid_request") // new_password missing
	for range 5 {
		env.setPassword(t, s.AccessToken, setAck.str("challenge_token"), wrongCode(setCode), newPassword())
	}
	wantProblem(t, env.setPassword(t, s.AccessToken, setAck.str("challenge_token"), setCode, newPassword()),
		http.StatusBadRequest, "code_attempts_exceeded")
}

// Review findings 4, 5 and 10 through the router: unmatched requests and HEAD get problem
// documents, and request bodies must be the JSON the spec describes.
func TestContract_UnmatchedRequestsAndStrictBodies(t *testing.T) {
	env := newSignupEnv(t, nil)
	s := env.issue(t, newUser(t, env.q), "Phone")
	notFound := env.get(t, "/v1/nope")
	wantProblem(t, notFound, http.StatusNotFound, "not_found")
	wrong := env.send(t, http.MethodDelete, pathMe, "", bearer(s.AccessToken)...)
	wantProblem(t, wrong, http.StatusMethodNotAllowed, "method_not_allowed")
	if wrong.header.Get("Allow") != "GET" {
		t.Fatalf("Allow %q", wrong.header.Get("Allow"))
	}
	head, err := http.NewRequest(http.MethodHead, env.srv.URL+pathMe, nil)
	if err != nil {
		t.Fatal(err)
	}
	head.Header.Set("Authorization", "Bearer "+s.AccessToken)
	res, err := http.DefaultClient.Do(head)
	if err != nil {
		t.Fatal(err)
	}
	res.Body.Close()
	if res.StatusCode != http.StatusMethodNotAllowed || res.Header.Get("Allow") != "GET" {
		t.Fatalf("HEAD /v1/me: %d, Allow %q", res.StatusCode, res.Header.Get("Allow"))
	}

	addr := newAddress("strict")
	for name, c := range map[string]struct{ ct, body string }{
		"form content type": {"application/x-www-form-urlencoded", `{"email":"` + addr + `"}`},
		"no content type":   {"", `{"email":"` + addr + `"}`},
		"other key case":    {"application/json", `{"Email":"` + addr + `"}`},
		"duplicate key":     {"application/json", `{"email":"` + addr + `","email":"` + addr + `"}`},
		"null":              {"application/json", `null`},
	} {
		t.Run(name, func(t *testing.T) {
			req, _ := http.NewRequest(http.MethodPost, env.srv.URL+pathOTPStart, strings.NewReader(c.body))
			if c.ct != "" {
				req.Header.Set("Content-Type", c.ct)
			}
			res, err := http.DefaultClient.Do(req)
			if err != nil {
				t.Fatal(err)
			}
			res.Body.Close()
			want := http.StatusBadRequest // malformed payload
			if strings.Contains(name, "content type") {
				want = http.StatusUnsupportedMediaType
			}
			if res.StatusCode != want {
				t.Fatalf("got %d, want %d", res.StatusCode, want)
			}
		})
	}
	// An empty refresh body is malformed, not an unknown token.
	wantProblem(t, env.post(t, pathRefresh, map[string]string{}), http.StatusBadRequest, "invalid_request")
	if env.count(t, "otp_challenges") != 0 {
		t.Fatal("no malformed request may issue a challenge")
	}
}

// Review finding 1: the deduplication slot and the auth.rate_limited row commit together, so a
// failed insert does not use up the window; the refusal itself is unaffected.
func TestAudit_RateLimitedRecordFailureDoesNotConsumeTheWindow(t *testing.T) {
	env := newSignupEnv(t, nil)
	addr := newAddress("slot")
	env.startOTP(t, addr)
	mustExec(t, env.d.Pool, `CREATE FUNCTION test_fail_audit() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'forced'; END $$`)
	mustExec(t, env.d.Pool, `CREATE TRIGGER test_fail_audit BEFORE INSERT ON audit_events FOR EACH ROW
		WHEN (NEW.action = 'auth.rate_limited') EXECUTE FUNCTION test_fail_audit()`)
	rid := newRID()
	wantProblem(t, env.call(t, "POST", pathOTPStart, map[string]string{"email": addr}, rid), http.StatusTooManyRequests, "rate_limited")
	env.wantEvents(t, rid)
	mustExec(t, env.d.Pool, `DROP TRIGGER test_fail_audit ON audit_events`)
	rid = newRID()
	wantProblem(t, env.call(t, "POST", pathOTPStart, map[string]string{"email": addr}, rid), http.StatusTooManyRequests, "rate_limited")
	env.wantEvents(t, rid, ev{action: "auth.rate_limited", outcome: "failure", reason: "otp_start_cooldown", email: true,
		meta: map[string]string{"scope": "signup"}})
}

// Review finding 11: the cooldown is per purpose, so is its once-per-window record.
func TestAudit_CooldownRecordIsScopedByPurpose(t *testing.T) {
	env := newSignupEnv(t, nil)
	u := newUser(t, env.q)
	env.otpLoginStart(t, u.Email)
	env.resetStart(t, u.Email)
	for _, c := range []struct{ path, scope string }{{pathOTPLoginStart, "login"}, {pathResetStart, "password_reset"}} {
		rid := newRID()
		wantProblem(t, env.call(t, "POST", c.path, map[string]string{"email": u.Email}, rid), http.StatusTooManyRequests, "rate_limited")
		env.wantEvents(t, rid, ev{action: "auth.rate_limited", outcome: "failure", reason: "otp_start_cooldown", email: true,
			meta: map[string]string{"scope": c.scope}})
	}
}

// Every operation with a JSON body answers 415 unsupported_media_type to a missing or other
// Content-Type, before looking at the body (spec-driven, so new operations are covered).
func TestContract_JSONOperationsRequireTheJSONMediaType(t *testing.T) {
	env := newSignupEnv(t, nil)
	s := env.issue(t, newUser(t, env.q), "Phone")
	doc, _, err := loadContract()
	if err != nil {
		t.Fatal(err)
	}
	for path, item := range doc.Paths.Map() {
		for method, op := range item.Operations() {
			if op.RequestBody == nil {
				continue
			}
			for _, ct := range []string{"", "text/plain", "application/x-www-form-urlencoded"} {
				t.Run(method+" "+path+" "+ct, func(t *testing.T) {
					concrete := path
					for _, param := range op.Parameters {
						if param.Value.In == "path" {
							concrete = strings.ReplaceAll(concrete, "{"+param.Value.Name+"}", uuid.NewString())
						}
					}
					req, _ := http.NewRequest(method, env.srv.URL+concrete, strings.NewReader(`{}`))
					if ct != "" {
						req.Header.Set("Content-Type", ct)
					}
					if op.Security != nil && len(*op.Security) > 0 {
						req.Header.Set("Authorization", "Bearer "+s.AccessToken)
					}
					res, err := http.DefaultClient.Do(req)
					if err != nil {
						t.Fatal(err)
					}
					defer res.Body.Close()
					if res.StatusCode != http.StatusUnsupportedMediaType || res.Header.Get("Content-Type") != "application/problem+json" {
						t.Fatalf("got %d %s", res.StatusCode, res.Header.Get("Content-Type"))
					}
				})
			}
		}
	}
}
