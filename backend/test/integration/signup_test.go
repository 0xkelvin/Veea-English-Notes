//go:build integration

package integration

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/app"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/auth/otp"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/auth/session"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/identity"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/notify"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/db/sqlc"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/pgtest"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/ratelimit"
)

// countingHasher is a real Argon2id hasher (cheap test parameters) that counts its calls, so
// tests can prove when Argon2id runs relative to the limits. n counts Hash, verifies counts
// Verify and VerifyDummy.
type countingHasher struct {
	h        *identity.Hasher
	n        atomic.Int32
	verifies atomic.Int32
	dummies  atomic.Int32
	// afterVerify, when set to a func(), runs after each Verify: the window between Argon2id
	// and the sign-in transaction.
	afterVerify atomic.Value
	// afterHash, when set to a func(), runs after each Hash: the window between Argon2id and a
	// password mutation's transaction.
	afterHash atomic.Value
}

func (c *countingHasher) Hash(ctx context.Context, password string) (string, error) {
	c.n.Add(1)
	h, err := c.h.Hash(ctx, password)
	if hook, _ := c.afterHash.Load().(func()); hook != nil {
		hook()
	}
	return h, err
}

func (c *countingHasher) Verify(ctx context.Context, encoded, password string) (identity.VerifyResult, error) {
	c.verifies.Add(1)
	v, err := c.h.Verify(ctx, encoded, password)
	if hook, _ := c.afterVerify.Load().(func()); hook != nil {
		hook()
	}
	return v, err
}

func (c *countingHasher) VerifyDummy(ctx context.Context, password string) error {
	c.verifies.Add(1)
	c.dummies.Add(1)
	return c.h.VerifyDummy(ctx, password)
}

type signupEnv struct {
	d       *pgtest.DB
	q       *sqlc.Queries
	srv     *httptest.Server
	fake    *notify.FakeSender
	worker  *notify.Worker
	random  *codeRandom
	hasher  *countingHasher
	hmac    *identity.EmailHMAC
	logs    *syncBuffer
	retries atomic.Int64

	mu      sync.Mutex
	secrets []string // codes, tokens and passwords, for the hygiene check
}

func newSignupEnv(t *testing.T, rules *ratelimit.Rules) *signupEnv {
	t.Helper()
	d, q := migratedDB(t)
	h, err := identity.NewHasher(identity.HasherConfig{Params: identity.Params{MemoryKiB: 64, Time: 1, Threads: 1, SaltLen: 16, KeyLen: 32}})
	if err != nil {
		t.Fatal(err)
	}
	if rules == nil {
		rules = generousRules()
		rules.PasswordSignupStartIP.Limit = 10_000
	}
	env := &signupEnv{d: d, q: q, fake: &notify.FakeSender{}, random: &codeRandom{}, hasher: &countingHasher{h: h},
		hmac: testEmailHMAC(t), logs: &syncBuffer{}}
	log := slog.New(slog.NewJSONHandler(env.logs, &slog.HandlerOptions{Level: slog.LevelDebug}))
	outboxKeys := []notify.Key{{ID: 1, Key: outboxKey1}}
	handler, err := app.New(app.Options{
		Pool: d.Pool, ReadyTimeout: time.Second, Logger: log,
		EmailHMACKeys: [][]byte{bytes.Repeat([]byte{0x42}, 32)}, // same key as testEmailHMAC
		OTPKeys:       [][]byte{otpTestKey}, OutboxKeys: outboxKeys,
		Hasher: env.hasher, Rules: rules, Random: env.random,
		OnTxRetry: func(string) { env.retries.Add(1) },
	})
	if err != nil {
		t.Fatal(err)
	}
	env.srv = httptest.NewServer(handler)
	t.Cleanup(env.srv.Close)
	keys, _ := notify.NewKeyring(outboxKeys...)
	if env.worker, err = notify.NewWorker(d.Pool, keys, env.fake, notify.WorkerConfig{Logger: log}); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		env.assertNoSecrets(t)
		if n := env.retries.Load(); n != 0 {
			t.Errorf("%d transactions were retried after a deadlock or serialization failure", n)
		}
	})
	return env
}

func (e *signupEnv) remember(s ...string) {
	e.mu.Lock()
	e.secrets = append(e.secrets, s...)
	e.mu.Unlock()
}

type response struct {
	status int
	header http.Header
	raw    []byte
	body   map[string]any
}

func (r response) str(key string) string {
	s, _ := r.body[key].(string)
	return s
}

func (e *signupEnv) post(t *testing.T, path string, body any, headers ...string) response {
	t.Helper()
	return e.send(t, http.MethodPost, path, body, headers...)
}

func (e *signupEnv) send(t *testing.T, method, path string, body any, headers ...string) response {
	t.Helper()
	var payload []byte
	switch b := body.(type) {
	case string:
		payload = []byte(b)
	default:
		var err error
		if payload, err = json.Marshal(b); err != nil {
			t.Fatal(err)
		}
	}
	req, err := http.NewRequest(method, e.srv.URL+path, bytes.NewReader(payload))
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Content-Type", "application/json")
	for i := 0; i+1 < len(headers); i += 2 {
		req.Header.Add(headers[i], headers[i+1])
	}
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	var buf bytes.Buffer
	_, _ = buf.ReadFrom(res.Body)
	out := response{status: res.StatusCode, header: res.Header, raw: buf.Bytes()}
	_ = json.Unmarshal(out.raw, &out.body)
	if tok := out.str("challenge_token"); tok != "" {
		e.remember(tok)
	}
	for _, k := range []string{"access_token", "refresh_token"} {
		if tok := out.str(k); tok != "" {
			e.remember(tok)
		}
	}
	return out
}

const (
	pathOTPStart      = "/v1/auth/signup/otp/start"
	pathPasswordStart = "/v1/auth/signup/password/start"
	pathVerify        = "/v1/auth/signup/verify"
)

var testDevice = map[string]string{"name": "Test phone", "platform": "ios"}

func (e *signupEnv) startOTP(t *testing.T, addr string) response {
	t.Helper()
	return e.post(t, pathOTPStart, map[string]string{"email": addr})
}

func (e *signupEnv) startPassword(t *testing.T, addr, password string) response {
	t.Helper()
	e.remember(password)
	return e.post(t, pathPasswordStart, map[string]string{"email": addr, "password": password})
}

func (e *signupEnv) verify(t *testing.T, token, code string) response {
	t.Helper()
	return e.post(t, pathVerify, map[string]any{"challenge_token": token, "code": code, "device": testDevice})
}

// queueCode fixes the next issued code, so a test knows the code of an inert challenge.
func (e *signupEnv) queueCode() string {
	c := randomCode()
	e.random.queue(c)
	e.remember(c)
	return c
}

var codePattern = regexp.MustCompile(`\b(\d{6})\b`)

// mailedCode runs the outbox worker and returns the code in the newest email to addr.
func (e *signupEnv) mailedCode(t *testing.T, addr string) string {
	t.Helper()
	if _, err := e.worker.RunOnce(context.Background()); err != nil {
		t.Fatal(err)
	}
	sent := e.fake.Sent()
	for i := len(sent) - 1; i >= 0; i-- {
		if sent[i].To == addr {
			m := codePattern.FindStringSubmatch(sent[i].Text)
			if m == nil {
				t.Fatal("the email carries no code")
			}
			e.remember(m[1])
			return m[1]
		}
	}
	t.Fatalf("no email was sent to the signup address")
	return ""
}

func newAddress(prefix string) string { return prefix + "-" + uuid.NewString()[:8] + "@Example.test" }

// A valid password under the policy: 15+ characters, not in the blocklist, not the local part.
func newPassword() string { return "correct horse " + uuid.NewString()[:12] }

func (e *signupEnv) count(t *testing.T, table string) int {
	t.Helper()
	return rowCount(t, e.d.Pool, `SELECT count(*) FROM `+table)
}

func (e *signupEnv) challengeByToken(t *testing.T, token string) (attempts int, consumed bool, pending *string) {
	t.Helper()
	err := e.d.Pool.QueryRow(context.Background(),
		`SELECT attempts, consumed_at IS NOT NULL, pending_password_hash FROM otp_challenges WHERE token_hash = $1`,
		otp.HashToken(token)).Scan(&attempts, &consumed, &pending)
	if err != nil {
		t.Fatalf("read challenge: %v", err)
	}
	return attempts, consumed, pending
}

func wantProblem(t *testing.T, r response, status int, code string) {
	t.Helper()
	if r.status != status || r.str("code") != code || r.header.Get("Content-Type") != "application/problem+json" ||
		r.str("request_id") == "" || r.str("request_id") != r.header.Get("X-Request-Id") {
		t.Fatalf("want %d %s problem, got %d %s", status, code, r.status, r.raw)
	}
}

func (e *signupEnv) assertNoSecrets(t *testing.T) {
	ctx := context.Background()
	var b strings.Builder
	b.WriteString(e.logs.String())
	for _, query := range []string{
		`SELECT concat_ws(' ', purpose, signup_method, email, email_normalized, delivery) FROM otp_challenges`,
		`SELECT concat_ws(' ', action, outcome, reason, user_agent, request_id, metadata::text) FROM audit_events`,
		`SELECT concat_ws(' ', to_email, last_error, provider_message_id) FROM email_outbox`,
		`SELECT concat_ws(' ', device_name, platform, user_agent) FROM sessions`,
		`SELECT concat_ws(' ', email, email_normalized) FROM users`,
	} {
		rows, err := e.d.Pool.Query(ctx, query)
		if err != nil {
			t.Errorf("hygiene query: %v", err)
			return
		}
		for rows.Next() {
			var s string
			_ = rows.Scan(&s)
			b.WriteString("\n" + s)
		}
		rows.Close()
	}
	hay := b.String()
	e.mu.Lock()
	defer e.mu.Unlock()
	for _, s := range e.secrets {
		if len(s) == 6 {
			if regexp.MustCompile(`(^|` + nonWord + `)` + s + `(` + nonWord + `|$)`).MatchString(hay) {
				t.Errorf("an OTP code appears in logs or stored rows")
			}
		} else if strings.Contains(hay, s) {
			t.Errorf("a token or password appears in logs or stored rows")
		}
	}
	for _, p := range []string{"vct_", "vat_", "vrt_"} {
		if strings.Contains(hay, p) {
			t.Errorf("something token-shaped (%s) appears in logs or stored rows", p)
		}
	}
	for _, sent := range e.fake.Sent() {
		for _, s := range e.secrets {
			if len(s) > 6 && strings.Contains(sent.Text+sent.HTML, s) {
				t.Errorf("an email contains a token or password")
			}
		}
	}
}

// =============================================================================================
// Flow A and Flow B, end to end through the router
// =============================================================================================

// AC-1, AC-4, AC-17: OTP signup creates a verified, passwordless account and its first session.
func TestSignupOTP_CreatesVerifiedPasswordlessAccountAndSession(t *testing.T) {
	env := newSignupEnv(t, nil)
	addr := newAddress("Learner")
	norm := strings.ToLower(addr)

	ack := env.startOTP(t, addr)
	if ack.status != http.StatusAccepted || !strings.HasPrefix(ack.str("challenge_token"), "vct_") ||
		ack.str("expires_at") == "" || ack.str("resend_after") == "" || len(ack.body) != 3 {
		t.Fatalf("start: %d %s", ack.status, ack.raw)
	}
	// AC-4: a pending registration is not an account and has no session.
	if env.count(t, "users") != 0 || env.count(t, "sessions") != 0 {
		t.Fatal("nothing may exist before verification")
	}
	code := env.mailedCode(t, addr)

	res := env.verify(t, ack.str("challenge_token"), code)
	if res.status != http.StatusCreated || res.header.Get("Cache-Control") != "no-store" {
		t.Fatalf("verify: %d %s", res.status, res.raw)
	}
	u, _ := res.body["user"].(map[string]any)
	if !strings.HasPrefix(res.str("access_token"), "vat_") || !strings.HasPrefix(res.str("refresh_token"), "vrt_") ||
		res.str("session_id") == "" || u == nil || u["email"] != addr || u["has_password"] != false ||
		u["email_verified_at"] == nil || u["password_changed_at"] != nil || u["status"] != "active" || u["role"] != "user" {
		t.Fatalf("token response: %s", res.raw)
	}
	for _, k := range []string{"access_expires_at", "refresh_expires_at"} {
		if ts, err := time.Parse(time.RFC3339Nano, res.str(k)); err != nil || ts.Location() != time.UTC {
			t.Fatalf("%s must be RFC 3339 UTC, got %q", k, res.str(k))
		}
	}

	// The account and its session, with only token hashes stored.
	stored, err := env.q.GetUserByEmailNormalized(context.Background(), norm)
	if err != nil || stored.ID.String() != u["id"] || stored.EmailVerifiedAt == nil || stored.PasswordHash != nil || stored.Email != addr {
		t.Fatalf("account row: %+v, %v", stored, err)
	}
	access, refresh := res.str("access_token"), res.str("refresh_token")
	var method, device string
	var accessHash, refreshHash []byte
	if err := env.d.Pool.QueryRow(context.Background(), `SELECT auth_method, device_name, access_token_hash, refresh_token_hash
		FROM sessions WHERE id = $1 AND user_id = $2 AND revoked_at IS NULL`, res.str("session_id"), stored.ID).
		Scan(&method, &device, &accessHash, &refreshHash); err != nil {
		t.Fatal(err)
	}
	ah, rh := sha256.Sum256([]byte(access)), sha256.Sum256([]byte(refresh))
	if method != "signup_otp" || device != "Test phone" || !bytes.Equal(accessHash, ah[:]) || !bytes.Equal(refreshHash, rh[:]) {
		t.Fatal("the session must store SHA-256 of each token and the signup_otp method")
	}
	// The access token authenticates through the per-request check of TRD 8.1.
	row, err := env.q.AuthenticateAccessToken(context.Background(), session.HashToken(access))
	if err != nil || row.UserID != stored.ID {
		t.Fatalf("the issued access token must authenticate: %v", err)
	}
	if _, consumed, _ := env.challengeByToken(t, ack.str("challenge_token")); !consumed {
		t.Fatal("the challenge must be consumed")
	}
	if rowCount(t, env.d.Pool, `SELECT count(*) FROM audit_events WHERE action = 'auth.signup.verify' AND outcome = 'success'
		AND target_user_id = $1 AND session_id = $2 AND metadata->>'method' = 'otp'`, stored.ID, res.str("session_id")) != 1 {
		t.Fatal("expected the auth.signup.verify success event")
	}
	// Single use: the same request again creates nothing (AC-21, AC-25).
	again := env.verify(t, ack.str("challenge_token"), code)
	wantProblem(t, again, http.StatusBadRequest, "invalid_code")
	if env.count(t, "users") != 1 || env.count(t, "sessions") != 1 {
		t.Fatal("a repeated verify must not create a second account or session")
	}
}

// AC-26, Flow B: the pending hash lives only on the challenge until its own verification.
func TestSignupPassword_BindsTheHashToTheChallengeUntilVerified(t *testing.T) {
	env := newSignupEnv(t, nil)
	addr, password := newAddress("Writer"), newPassword()
	ack := env.startPassword(t, addr, password)
	if ack.status != http.StatusAccepted {
		t.Fatalf("start: %d %s", ack.status, ack.raw)
	}
	_, _, pending := env.challengeByToken(t, ack.str("challenge_token"))
	if pending == nil || !strings.HasPrefix(*pending, "$argon2id$") || strings.Contains(*pending, password) {
		t.Fatal("an eligible password signup binds an argon2id hash, never the password, to its challenge")
	}
	if env.count(t, "users") != 0 || env.count(t, "sessions") != 0 || env.hasher.n.Load() != 1 {
		t.Fatal("no account, no session and exactly one hash before verification")
	}
	code := env.mailedCode(t, addr)

	// A wrong code changes nothing and commits the attempt.
	wantProblem(t, env.verify(t, ack.str("challenge_token"), wrongCode(code)), http.StatusBadRequest, "invalid_code")
	if attempts, _, p := env.challengeByToken(t, ack.str("challenge_token")); attempts != 1 || p == nil || env.count(t, "users") != 0 {
		t.Fatal("a wrong code must commit the attempt and keep the pending hash")
	}

	res := env.verify(t, ack.str("challenge_token"), code)
	if res.status != http.StatusCreated {
		t.Fatalf("verify: %d %s", res.status, res.raw)
	}
	u := res.body["user"].(map[string]any)
	if u["has_password"] != true || u["password_changed_at"] == nil {
		t.Fatalf("a password signup has a password from creation: %s", res.raw)
	}
	stored, err := env.q.GetUserByEmailNormalized(context.Background(), strings.ToLower(addr))
	if err != nil || stored.PasswordHash == nil || *stored.PasswordHash != *pending {
		t.Fatal("the account must get exactly the hash bound to this challenge")
	}
	if v, err := env.hasher.h.Verify(context.Background(), *stored.PasswordHash, password); err != nil || !v.Match {
		t.Fatalf("the chosen password must verify against the stored hash: %v", err)
	}
	if _, _, p := env.challengeByToken(t, ack.str("challenge_token")); p != nil {
		t.Fatal("the pending hash must leave the challenge row on redemption")
	}
	if rowCount(t, env.d.Pool, `SELECT count(*) FROM sessions WHERE auth_method = 'signup_password' AND user_id = $1`, stored.ID) != 1 {
		t.Fatal("expected one signup_password session")
	}
}

// AC-27: per flow, eligible and ineligible requests get the same acknowledgement; only eligible
// ones send email; the existing account is untouched.
func TestSignup_AcknowledgementIsUniform(t *testing.T) {
	env := newSignupEnv(t, nil)
	existing := newUser(t, env.q)
	mustExec(t, env.d.Pool, `UPDATE users SET password_hash = '$argon2id$v=19$m=64,t=1,p=1$c2FsdHNhbHRzYWx0$aGFzaGhhc2hoYXNoaGFzaA' WHERE id = $1`, existing.ID)
	before, _ := env.q.GetUserByID(context.Background(), existing.ID)

	shape := func(r response) string {
		s := string(r.raw)
		for _, k := range []string{"challenge_token", "expires_at", "resend_after"} {
			s = strings.Replace(s, r.str(k), "<"+k+">", 1)
		}
		return fmt.Sprintf("%d %s %s %s", r.status, r.header.Get("Content-Type"), r.header.Get("Cache-Control"), s)
	}
	for _, method := range []string{"otp", "password"} {
		t.Run(method, func(t *testing.T) {
			start := func(addr string) response {
				if method == "otp" {
					return env.startOTP(t, addr)
				}
				return env.startPassword(t, addr, newPassword())
			}
			sentBefore := env.fake.Calls()
			fresh := newAddress("fresh")
			eligible, ineligible := start(fresh), start(existing.Email)
			if eligible.status != http.StatusAccepted || shape(eligible) != shape(ineligible) {
				t.Fatalf("responses differ:\n%s\n%s", shape(eligible), shape(ineligible))
			}
			if _, err := env.worker.RunOnce(context.Background()); err != nil {
				t.Fatal(err)
			}
			sent := env.fake.Sent()[sentBefore:]
			if len(sent) != 1 || sent[0].To != fresh {
				t.Fatalf("only the eligible request may send email, got %d emails", len(sent))
			}
			env.expireCooldownFor(t, existing.Email) // both methods share the signup cooldown
		})
	}
	after, _ := env.q.GetUserByID(context.Background(), existing.ID)
	if *after.PasswordHash != *before.PasswordHash || !after.UpdatedAt.Equal(before.UpdatedAt) || env.count(t, "sessions") != 0 {
		t.Fatal("signup for an existing email must not touch the account or sign anyone in")
	}
}

// AC-27 and TRD 12.3 TestDuplicateSignup_NoChangeNoSession: even the correct stored code of a
// duplicate signup never signs in or changes the account.
func TestSignup_DuplicateNeverChangesTheAccount(t *testing.T) {
	env := newSignupEnv(t, nil)
	existing := newUser(t, env.q)
	const hash = "$argon2id$v=19$m=64,t=1,p=1$c2FsdHNhbHRzYWx0$aGFzaGhhc2hoYXNoaGFzaA"
	mustExec(t, env.d.Pool, `UPDATE users SET password_hash = $2 WHERE id = $1`, existing.ID, hash)
	before, _ := env.q.GetUserByID(context.Background(), existing.ID)

	for _, method := range []string{"otp", "password"} {
		t.Run(method, func(t *testing.T) {
			code := env.queueCode()
			var ack response
			if method == "otp" {
				ack = env.startOTP(t, strings.ToUpper(existing.Email)) // case differences resolve to the same account (AC-8)
			} else {
				ack = env.startPassword(t, existing.Email, newPassword())
			}
			if ack.status != http.StatusAccepted {
				t.Fatalf("start: %d %s", ack.status, ack.raw)
			}
			for i := range 5 {
				wantProblem(t, env.verify(t, ack.str("challenge_token"), code), http.StatusBadRequest, "invalid_code")
				if attempts, _, pending := env.challengeByToken(t, ack.str("challenge_token")); attempts != i+1 || pending != nil {
					t.Fatalf("attempt %d: attempts %d, pending hash kept %v", i+1, attempts, pending != nil)
				}
			}
			wantProblem(t, env.verify(t, ack.str("challenge_token"), code), http.StatusBadRequest, "code_attempts_exceeded")
			env.expireCooldownFor(t, existing.Email)
		})
	}
	after, _ := env.q.GetUserByID(context.Background(), existing.ID)
	if *after.PasswordHash != hash || !after.UpdatedAt.Equal(before.UpdatedAt) || after.PasswordChangedAt != nil {
		t.Fatal("the existing account's credentials must not change")
	}
	if env.count(t, "sessions") != 0 || env.count(t, "users") != 1 || env.count(t, "email_outbox") != 0 {
		t.Fatal("no session, no new account and no email for a duplicate signup")
	}
}

func (e *signupEnv) expireCooldownFor(t *testing.T, addr string) {
	t.Helper()
	mustExec(t, e.d.Pool, `UPDATE otp_cooldowns SET last_issued_at = now() - interval '61 seconds' WHERE email_hmac = $1`,
		e.hmac.Current(email(t, addr)))
}

// TRD 12.3 TestSignupBinding_CodeOnlyValidForItsToken.
func TestSignup_CodeIsBoundToItsAttempt(t *testing.T) {
	env := newSignupEnv(t, nil)
	a, b := newAddress("first"), newAddress("second")
	ackA, ackB := env.startOTP(t, a), env.startOTP(t, b)
	codeA := env.mailedCode(t, a)
	codeB := env.mailedCode(t, b)
	if codeA == codeB {
		t.Skip("the two random codes collided; the binding is still covered by the HMAC unit tests")
	}
	wantProblem(t, env.verify(t, ackB.str("challenge_token"), codeA), http.StatusBadRequest, "invalid_code")
	if attempts, _, _ := env.challengeByToken(t, ackB.str("challenge_token")); attempts != 1 {
		t.Fatal("presenting another attempt's code is charged to this attempt")
	}
	if env.count(t, "users") != 0 {
		t.Fatal("no account from another attempt's code")
	}
	if r := env.verify(t, ackA.str("challenge_token"), codeA); r.status != http.StatusCreated {
		t.Fatalf("the code still works for its own attempt: %d", r.status)
	}
}

// AC-3: wrong and expired codes create nothing; failed attempts are committed.
func TestSignup_WrongOrExpiredCodeCreatesNothing(t *testing.T) {
	env := newSignupEnv(t, nil)
	addr := newAddress("late")
	ack := env.startPassword(t, addr, newPassword())
	code := env.mailedCode(t, addr)

	wantProblem(t, env.verify(t, ack.str("challenge_token"), wrongCode(code)), http.StatusBadRequest, "invalid_code")
	if attempts, _, _ := env.challengeByToken(t, ack.str("challenge_token")); attempts != 1 {
		t.Fatal("the failed attempt must be committed")
	}
	if rowCount(t, env.d.Pool, `SELECT coalesce(sum(count), 0)::int FROM rate_limit_counters WHERE key = $1`,
		"otp_verify_fail_email_1h:email:"+env.hmac.CurrentHex(email(t, addr))) != 1 {
		t.Fatal("the per-email failure counter must be incremented")
	}

	mustExec(t, env.d.Pool, `UPDATE otp_challenges SET expires_at = now() - interval '1 second' WHERE token_hash = $1`,
		otp.HashToken(ack.str("challenge_token")))
	wantProblem(t, env.verify(t, ack.str("challenge_token"), code), http.StatusBadRequest, "invalid_code")
	if env.count(t, "users") != 0 || env.count(t, "sessions") != 0 {
		t.Fatal("no account and no session from a wrong or expired code")
	}
}

// TRD 7.3: the account appeared after the attempt started. The code holder gets 409; the
// consumption stands; nothing about the account changes; no session is issued.
func TestSignup_AccountAppearedMeanwhileGives409(t *testing.T) {
	env := newSignupEnv(t, nil)
	addr := newAddress("raced")
	ack := env.startPassword(t, addr, newPassword())
	var challengeID uuid.UUID
	_ = env.d.Pool.QueryRow(context.Background(), `SELECT id FROM otp_challenges WHERE token_hash = $1`,
		otp.HashToken(ack.str("challenge_token"))).Scan(&challengeID)

	// Another path created the account first.
	other := uuid.New()
	now := time.Now()
	if _, err := env.q.InsertUserIfAbsent(context.Background(), sqlc.InsertUserIfAbsentParams{
		ID: other, Email: addr, EmailNormalized: strings.ToLower(addr), EmailVerifiedAt: &now,
		PasswordHash: ptr("$argon2id$v=19$m=64,t=1,p=1$b3RoZXJzYWx0$b3RoZXJoYXNoaGFzaA"),
	}); err != nil {
		t.Fatal(err)
	}
	before, _ := env.q.GetUserByID(context.Background(), other)
	code := env.mailedCode(t, addr)

	res := env.verify(t, ack.str("challenge_token"), code)
	wantProblem(t, res, http.StatusConflict, "signup_unavailable")
	if res.body["access_token"] != nil || env.count(t, "sessions") != 0 {
		t.Fatal("no session for a conflicting signup")
	}
	after, _ := env.q.GetUserByID(context.Background(), other)
	if *after.PasswordHash != *before.PasswordHash || !after.UpdatedAt.Equal(before.UpdatedAt) || env.count(t, "users") != 1 {
		t.Fatal("the existing account must not change")
	}
	if _, consumed, pending := env.challengeByToken(t, ack.str("challenge_token")); !consumed || pending != nil {
		t.Fatal("the consumption stays committed and the pending hash is gone")
	}
	if rowCount(t, env.d.Pool, `SELECT count(*) FROM email_outbox WHERE challenge_id = $1 AND status IN ('sent', 'cancelled') AND payload_ciphertext IS NULL`, challengeID) != 1 {
		t.Fatal("the challenge's email must be finished and scrubbed")
	}
	if rowCount(t, env.d.Pool, `SELECT count(*) FROM audit_events WHERE action = 'auth.signup.verify' AND reason = 'account_exists'`) != 1 {
		t.Fatal("expected the account_exists failure event")
	}
	wantProblem(t, env.verify(t, ack.str("challenge_token"), code), http.StatusBadRequest, "invalid_code")
}

// TRD 12.3 TestConcurrent_VerifySameToken.
func TestSignup_ConcurrentVerifySameTokenCreatesOneAccount(t *testing.T) {
	env := newSignupEnv(t, nil)
	addr := newAddress("parallel")
	ack := env.startOTP(t, addr)
	code := env.mailedCode(t, addr)

	const n = 10
	results := make([]response, n)
	gate := make(chan struct{})
	var wg sync.WaitGroup
	for i := range n {
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-gate
			results[i] = env.verify(t, ack.str("challenge_token"), code)
		}()
	}
	close(gate)
	wg.Wait()
	created := 0
	for _, r := range results {
		switch {
		case r.status == http.StatusCreated:
			created++
		case r.status == http.StatusBadRequest && r.str("code") == "invalid_code":
		default:
			t.Fatalf("unexpected response %d %s", r.status, r.raw)
		}
	}
	if created != 1 || env.count(t, "users") != 1 || env.count(t, "sessions") != 1 {
		t.Fatalf("%d created, %d users, %d sessions; want exactly one of each", created, env.count(t, "users"), env.count(t, "sessions"))
	}
}

// Concurrent first starts for one email: one challenge, the rest 429 with Retry-After (TRD 7.2).
func TestSignup_ConcurrentStartsIssueOneChallenge(t *testing.T) {
	env := newSignupEnv(t, nil)
	addr := newAddress("burst")
	const n = 10
	results := make([]response, n)
	gate := make(chan struct{})
	var wg sync.WaitGroup
	for i := range n {
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-gate
			results[i] = env.startPassword(t, addr, newPassword())
		}()
	}
	close(gate)
	wg.Wait()
	accepted := 0
	for _, r := range results {
		switch r.status {
		case http.StatusAccepted:
			accepted++
		case http.StatusTooManyRequests:
			if ra, err := strconv.Atoi(r.header.Get("Retry-After")); err != nil || ra < 1 || ra > 60 || r.str("code") != "rate_limited" {
				t.Fatalf("429 without a valid Retry-After: %v %s", r.header, r.raw)
			}
		default:
			t.Fatalf("unexpected %d %s", r.status, r.raw)
		}
	}
	if accepted != 1 || env.count(t, "otp_challenges") != 1 || env.count(t, "email_outbox") != 1 {
		t.Fatalf("%d accepted, %d challenges", accepted, env.count(t, "otp_challenges"))
	}
}

// The TRD 12.3 scenario "two signups for one email verified at once" cannot arise as written:
// a new start supersedes the open attempt. The race that does exist is a verify of attempt Y
// against a new start X for the same email. Whatever the interleaving, there is one account,
// it carries Y's password, and X never changes it or signs in.
func TestSignup_VerifyRacingANewAttemptForTheSameEmail(t *testing.T) {
	env := newSignupEnv(t, nil)
	for round := range 5 {
		addr := newAddress(fmt.Sprintf("race%d", round))
		passY := newPassword()
		ackY := env.startPassword(t, addr, passY)
		codeY := env.mailedCode(t, addr)
		_, _, pendingY := env.challengeByToken(t, ackY.str("challenge_token"))
		env.expireCooldownFor(t, addr)
		codeX := env.queueCode()

		var verifyY, startX response
		gate := make(chan struct{})
		var wg sync.WaitGroup
		wg.Add(2)
		go func() { defer wg.Done(); <-gate; verifyY = env.verify(t, ackY.str("challenge_token"), codeY) }()
		go func() { defer wg.Done(); <-gate; startX = env.startPassword(t, addr, newPassword()) }()
		close(gate)
		wg.Wait()
		if startX.status != http.StatusAccepted {
			t.Fatalf("round %d: start X: %d", round, startX.status)
		}
		if verifyY.status == http.StatusCreated {
			// Y won. X may have been eligible (its read ran before Y committed) or inert; either
			// way its verify cannot sign in or change the account.
			if r := env.verify(t, startX.str("challenge_token"), codeX); r.status != http.StatusConflict && r.str("code") != "invalid_code" {
				t.Fatalf("round %d: verify X after Y: %d %s", round, r.status, r.raw)
			}
			u, err := env.q.GetUserByEmailNormalized(context.Background(), strings.ToLower(addr))
			if err != nil || u.PasswordHash == nil || *u.PasswordHash != *pendingY {
				t.Fatalf("round %d: the account must carry Y's password", round)
			}
		} else {
			// X superseded Y first, so Y's code is dead.
			wantProblem(t, verifyY, http.StatusBadRequest, "invalid_code")
		}
		if n := rowCount(t, env.d.Pool, `SELECT count(*) FROM users WHERE email_normalized = $1`, strings.ToLower(addr)); n > 1 {
			t.Fatalf("round %d: %d accounts", round, n)
		}
		if n := rowCount(t, env.d.Pool, `SELECT count(*) FROM sessions s JOIN users u ON u.id = s.user_id WHERE u.email_normalized = $1`, strings.ToLower(addr)); n > 1 {
			t.Fatalf("round %d: %d sessions", round, n)
		}
	}
}

// One transaction: if the session insert fails, the account, the consumption and the email
// cancellation all roll back, and the same code works once the fault is gone.
func TestSignup_SessionInsertFailureRollsBackEverything(t *testing.T) {
	env := newSignupEnv(t, nil)
	addr := newAddress("rollback")
	fixed := env.queueCode() // known without running the worker, so the email stays pending
	ack := env.startOTP(t, addr)

	mustExec(t, env.d.Pool, `CREATE FUNCTION test_fail_session() RETURNS trigger LANGUAGE plpgsql
		AS $$ BEGIN RAISE EXCEPTION 'forced session failure'; END $$`)
	mustExec(t, env.d.Pool, `CREATE TRIGGER test_fail_session BEFORE INSERT ON sessions FOR EACH ROW EXECUTE FUNCTION test_fail_session()`)

	res := env.verify(t, ack.str("challenge_token"), fixed)
	wantProblem(t, res, http.StatusInternalServerError, "internal_error")
	if strings.Contains(string(res.raw), "forced") || res.body["access_token"] != nil {
		t.Fatalf("an internal error must not leak its cause or any token: %s", res.raw)
	}
	if env.count(t, "users") != 0 || env.count(t, "sessions") != 0 {
		t.Fatal("the account insert must roll back with the session")
	}
	if attempts, consumed, _ := env.challengeByToken(t, ack.str("challenge_token")); consumed || attempts != 0 {
		t.Fatal("the consumption must roll back and no attempt be charged")
	}
	if rowCount(t, env.d.Pool, `SELECT count(*) FROM email_outbox o JOIN otp_challenges c ON c.id = o.challenge_id
		WHERE c.token_hash = $1 AND o.status = 'pending' AND o.payload_ciphertext IS NOT NULL`, otp.HashToken(ack.str("challenge_token"))) != 1 {
		t.Fatal("the email cancellation must roll back too")
	}
	if rowCount(t, env.d.Pool, `SELECT count(*) FROM audit_events WHERE action = 'auth.signup.verify' AND outcome = 'success'`) != 0 {
		t.Fatal("no success audit event for a rolled-back signup")
	}

	mustExec(t, env.d.Pool, `DROP TRIGGER test_fail_session ON sessions`)
	if r := env.verify(t, ack.str("challenge_token"), fixed); r.status != http.StatusCreated {
		t.Fatalf("after the fault the same code must work: %d %s", r.status, r.raw)
	}
}

// TRD 10: the per-IP password-signup limit is counted before any Argon2id work, and a policy
// violation is answered before both.
func TestSignupPassword_IPLimitRunsBeforeHashing(t *testing.T) {
	rules := generousRules()
	rules.PasswordSignupStartIP.Limit = 2
	env := newSignupEnv(t, rules)

	weak := env.post(t, pathPasswordStart, map[string]string{"email": newAddress("weak"), "password": "short"})
	wantProblem(t, weak, http.StatusUnprocessableEntity, "password_policy_violation")
	if v, _ := weak.body["violations"].([]any); len(v) != 1 || v[0] != "too_short" || env.hasher.n.Load() != 0 {
		t.Fatalf("a policy violation is reported before hashing: %s", weak.raw)
	}

	for i := range 2 {
		if r := env.startPassword(t, newAddress("ok"), newPassword()); r.status != http.StatusAccepted {
			t.Fatalf("start %d: %d", i+1, r.status)
		}
	}
	challenges := env.count(t, "otp_challenges")
	limited := env.startPassword(t, newAddress("third"), newPassword())
	wantProblem(t, limited, http.StatusTooManyRequests, "rate_limited")
	if limited.header.Get("Retry-After") == "" {
		t.Fatal("429 needs Retry-After")
	}
	if n := env.hasher.n.Load(); n != 2 {
		t.Fatalf("the hasher ran %d times; the limited request must not hash", n)
	}
	if env.count(t, "otp_challenges") != challenges {
		t.Fatal("a limited request issues no challenge")
	}
	// OTP signup is not subject to the password-signup limit.
	if r := env.startOTP(t, newAddress("otp")); r.status != http.StatusAccepted {
		t.Fatalf("OTP signup must not share the argon2 limit: %d", r.status)
	}
}

func TestSignup_RequestContract(t *testing.T) {
	env := newSignupEnv(t, nil)
	wantProblem(t, env.startOTP(t, "Learner <learner@example.test>"), http.StatusBadRequest, "invalid_email")
	wantProblem(t, env.startPassword(t, "not-an-email", newPassword()), http.StatusBadRequest, "invalid_email")
	wantProblem(t, env.post(t, pathOTPStart, `{"email":"a@example.test","extra":true}`), http.StatusBadRequest, "invalid_request")
	wantProblem(t, env.post(t, pathOTPStart, `not json`), http.StatusBadRequest, "invalid_request")

	addr := newAddress("contract")
	ack := env.startOTP(t, addr)
	code := env.mailedCode(t, addr)
	tok := ack.str("challenge_token")
	for name, body := range map[string]any{
		"no device":     map[string]any{"challenge_token": tok, "code": code},
		"bad platform":  map[string]any{"challenge_token": tok, "code": code, "device": map[string]string{"name": "x", "platform": "symbian"}},
		"long name":     map[string]any{"challenge_token": tok, "code": code, "device": map[string]string{"name": strings.Repeat("n", 65), "platform": "ios"}},
		"unknown field": map[string]any{"challenge_token": tok, "code": code, "device": testDevice, "user_id": "x"},
	} {
		t.Run(name, func(t *testing.T) {
			wantProblem(t, env.post(t, pathVerify, body), http.StatusBadRequest, "invalid_request")
		})
	}
	if attempts, consumed, _ := env.challengeByToken(t, tok); attempts != 0 || consumed {
		t.Fatal("a malformed verify request must not touch the challenge")
	}

	// A token-shaped User-Agent or request id is stripped, never stored, and never a 500.
	r := env.post(t, pathOTPStart, map[string]string{"email": newAddress("ua")}, "User-Agent", "evil vct_planted", "X-Request-Id", "vct_planted01")
	if r.status != http.StatusAccepted || strings.Contains(r.header.Get("X-Request-Id"), "vct_") {
		t.Fatalf("token-shaped headers: %d %s", r.status, r.raw)
	}
	// The session row stores the User-Agent, so the verify request carries a planted one too.
	res := env.post(t, pathVerify, map[string]any{"challenge_token": tok, "code": code, "device": testDevice},
		"User-Agent", "evil vat_planted")
	if res.status != http.StatusCreated {
		t.Fatalf("the challenge is still usable: %d", res.status)
	}
	if rowCount(t, env.d.Pool, `SELECT count(*) FROM sessions WHERE user_agent IS NULL`) != 1 {
		t.Fatal("a token-shaped User-Agent must not be stored on the session")
	}

	// Within the cooldown both eligibilities get the same 429.
	existing := newUser(t, env.q)
	for _, a := range []string{newAddress("cool"), existing.Email} {
		env.startOTP(t, a)
		r := env.startOTP(t, a)
		wantProblem(t, r, http.StatusTooManyRequests, "rate_limited")
		if ra, err := strconv.Atoi(r.header.Get("Retry-After")); err != nil || ra < 1 || ra > 60 {
			t.Fatalf("Retry-After %q", r.header.Get("Retry-After"))
		}
	}
}
