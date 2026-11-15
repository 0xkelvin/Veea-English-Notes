//go:build integration

package integration

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"regexp"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/app"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/identity"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/notify"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/metrics"
)

func scrapeMetrics(t *testing.T, m *metrics.Metrics) string {
	t.Helper()
	rec := httptest.NewRecorder()
	m.Handler().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/metrics", nil))
	b, _ := io.ReadAll(rec.Body)
	return string(b)
}

// metricValue reads one sample, for example `auth_signup_completed_total{method="otp"}`. A sample
// that was never written reads as 0.
func metricValue(t *testing.T, out, sample string) float64 {
	t.Helper()
	for _, line := range strings.Split(out, "\n") {
		if strings.HasPrefix(line, sample+" ") {
			v, err := strconv.ParseFloat(strings.TrimSpace(strings.TrimPrefix(line, sample)), 64)
			if err != nil {
				t.Fatalf("parse %q: %v", line, err)
			}
			return v
		}
	}
	return 0
}

func wantMetric(t *testing.T, m *metrics.Metrics, sample string, want float64) {
	t.Helper()
	if got := metricValue(t, scrapeMetrics(t, m), sample); got != want {
		t.Fatalf("%s = %v, want %v", sample, got, want)
	}
}

var ipLabel = regexp.MustCompile(`="[0-9]{1,3}(\.[0-9]{1,3}){3}"|="[0-9a-f:]*::[0-9a-f:]*"`)

// TRD 11.3 through the router: each metric moves once per committed outcome, and no label ever
// carries an email, an IP address or a token.
func TestMetrics_RecordedThroughTheRouter(t *testing.T) {
	env := newSignupEnv(t, nil)
	m := env.metrics

	addr := newAddress("metrics")
	code := env.queueCode()
	ack := env.startOTP(t, addr)
	existing, pw := env.passwordUser(t)
	env.startOTP(t, existing.Email)
	wantMetric(t, m, `auth_otp_started_total{delivery="code",purpose="signup"}`, 1)
	wantMetric(t, m, `auth_otp_started_total{delivery="none",purpose="signup"}`, 1)
	wantMetric(t, m, `email_outbox_pending`, 1)

	env.verify(t, ack.str("challenge_token"), wrongCode(code))
	wantMetric(t, m, `auth_otp_verified_total{purpose="signup",result="invalid_code"}`, 1)
	if r := env.verify(t, ack.str("challenge_token"), code); r.status != http.StatusCreated {
		t.Fatalf("signup verify: %d", r.status)
	}
	wantMetric(t, m, `auth_otp_verified_total{purpose="signup",result="success"}`, 1)
	wantMetric(t, m, `auth_signup_completed_total{method="otp"}`, 1)
	wantMetric(t, m, `email_outbox_pending`, 0) // the redeemed challenge's email was cancelled

	env.startOTP(t, addr+"x")
	if _, err := env.worker.RunOnce(context.Background()); err != nil {
		t.Fatal(err)
	}
	wantMetric(t, m, `email_send_total{result="sent",template="signup_code"}`, 1)

	login := env.login(t, existing.Email, pw)
	env.login(t, existing.Email, newPassword())
	wantMetric(t, m, `auth_password_login_total{result="success"}`, 1)
	wantMetric(t, m, `auth_password_login_total{result="invalid_credentials"}`, 1)

	env.startOTP(t, existing.Email) // within the cooldown
	wantMetric(t, m, `auth_rate_limited_total{rule="otp_start_cooldown"}`, 1)

	refreshed := env.refresh(t, login.str("refresh_token"))
	env.refresh(t, login.str("refresh_token")) // reuse
	wantMetric(t, m, `auth_refresh_reuse_total`, 1)
	wantMetric(t, m, `auth_sessions_revoked_total{reason="refresh_reuse"}`, 1)
	_ = refreshed

	a, b := env.issue(t, existing, "Phone"), env.issue(t, existing, "Tablet")
	want204(t, env.change(t, a.AccessToken, pw, newPassword()))
	wantMetric(t, m, `auth_sessions_revoked_total{reason="password_change"}`, 1)
	wantProblem(t, env.logout(t, b.AccessToken), http.StatusUnauthorized, "unauthorized") // already revoked
	want204(t, env.logout(t, a.AccessToken))
	wantMetric(t, m, `auth_sessions_revoked_total{reason="logout"}`, 1)

	// A rolled-back OTP sign-in counts as rejected, and its revocations and session never count.
	u := newUser(t, env.q)
	lcode := env.queueCode()
	lack := env.otpLoginStart(t, u.Email)
	mustExec(t, env.d.Pool, `UPDATE users SET status = 'suspended', resume_status = 'active', suspension_reason = 'other' WHERE id = $1`, u.ID)
	env.otpLoginVerify(t, lack.str("challenge_token"), lcode)
	wantMetric(t, m, `auth_otp_verified_total{purpose="login",result="rejected"}`, 1)

	out := scrapeMetrics(t, m)
	for _, leak := range []string{"@", "example.test", "vat_", "vrt_", "vct_", strings.ToLower(addr)} {
		if strings.Contains(out, leak) {
			t.Fatalf("metrics output contains %q", leak)
		}
	}
	if ipLabel.MatchString(out) {
		t.Fatal("a metric label carries an IP address")
	}
}

// db_tx_retries_total moves when a transaction is retried (TRD 7.1 rule 7), here forced once.
func TestMetrics_TransactionRetries(t *testing.T) {
	env := newSignupEnv(t, nil)
	mustExec(t, env.d.Pool, `CREATE SEQUENCE test_retry_once`)
	mustExec(t, env.d.Pool, `CREATE FUNCTION test_fail_once() RETURNS trigger LANGUAGE plpgsql AS $$
		BEGIN IF nextval('test_retry_once') = 1 THEN RAISE EXCEPTION 'forced' USING ERRCODE = '40001'; END IF; RETURN NEW; END $$`)
	mustExec(t, env.d.Pool, `CREATE TRIGGER test_fail_once BEFORE INSERT ON audit_events FOR EACH ROW EXECUTE FUNCTION test_fail_once()`)
	wantStatus(t, env.startOTP(t, newAddress("retry")), http.StatusAccepted)
	wantMetric(t, env.metrics, `db_tx_retries_total{reason="serialization"}`, 1)
	env.retries.Store(0) // the env's no-retry assertion is about unforced runs
}

// argon2_wait_seconds is fed by the real hasher's ObserveWait, built by app.New from the Argon2
// parameters (VEEA_ARGON2_*).
func TestMetrics_Argon2WaitFromTheDefaultHasher(t *testing.T) {
	d, _ := migratedDB(t)
	m := metrics.New()
	h, err := app.New(app.Options{
		Pool: d.Pool, ReadyTimeout: time.Second,
		EmailHMACKeys: [][]byte{bytes.Repeat([]byte{0x42}, 32)}, OTPKeys: [][]byte{otpTestKey},
		OutboxKeys: []notify.Key{{ID: 1, Key: outboxKey1}}, Metrics: m,
		Argon2: identity.Params{MemoryKiB: 64, Time: 1, Threads: 1, SaltLen: 16, KeyLen: 32}, Rules: generousRules(),
	})
	if err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(h)
	defer srv.Close()
	for i := range 3 {
		body := fmt.Sprintf(`{"email":"argon-%d-%s@example.test","password":"%s"}`, i, uuid.NewString()[:6], newPassword())
		res, err := http.Post(srv.URL+pathPasswordStart, "application/json", strings.NewReader(body))
		if err != nil {
			t.Fatal(err)
		}
		res.Body.Close()
		if res.StatusCode != http.StatusAccepted {
			t.Fatalf("password signup: %d", res.StatusCode)
		}
	}
	if n := metricValue(t, scrapeMetrics(t, m), `argon2_wait_seconds_count`); n < 3 {
		t.Fatalf("argon2_wait_seconds_count = %v, want at least 3", n)
	}
}

// email_outbox_stale_result_total and email_send_total come from the worker hooks.
func TestMetrics_OutboxWorkerHooks(t *testing.T) {
	m := metrics.New()
	env := newOutboxEnv(t, notify.WorkerConfig{OnSend: m.EmailSend, OnStale: m.StaleResult})
	var id uuid.UUID
	env.fake.Respond = func(_ context.Context, _ notify.Email, call int) (string, error) {
		switch call {
		case 1:
			mustExec(t, env.d.Pool, `UPDATE email_outbox SET lease_expires_at = now() - interval '1 second' WHERE id = $1`, id)
			return "msg-1", nil
		case 2:
			return "", notify.Ambiguous("timeout")
		}
		return "msg-3", nil
	}
	id, _, _ = env.codeFixture(t)
	env.runOnce(t) // sent, but the lease was gone: stale
	env.makeDue(t, id)
	env.runOnce(t) // ambiguous
	env.makeDue(t, id)
	env.runOnce(t) // sent
	out := scrapeMetrics(t, m)
	for sample, want := range map[string]float64{
		`email_outbox_stale_result_total`:                            1,
		`email_send_total{result="sent",template="login_code"}`:      2,
		`email_send_total{result="ambiguous",template="login_code"}`: 1,
	} {
		if got := metricValue(t, out, sample); got != want {
			t.Errorf("%s = %v, want %v", sample, got, want)
		}
	}
}

// Review finding 3: set and reset check the verify limits before Argon2id (Prechecked), and the
// refusal is still counted as rate_limited for their purpose.
func TestMetrics_PrecheckedVerifyLimitsAreCounted(t *testing.T) {
	rules := generousRules()
	rules.PasswordSignupStartIP.Limit = 10_000
	rules.VerifyIP.Limit = 1
	env := newSignupEnv(t, rules)
	u, _ := env.passwordUser(t)
	ack := env.resetStart(t, u.Email)
	env.resetComplete(t, ack.str("challenge_token"), "000000", newPassword())
	wantProblem(t, env.resetComplete(t, ack.str("challenge_token"), "000000", newPassword()), http.StatusTooManyRequests, "rate_limited")
	wantMetric(t, env.metrics, `auth_otp_verified_total{purpose="password_reset",result="rate_limited"}`, 1)
	wantMetric(t, env.metrics, `auth_otp_verified_total{purpose="password_reset",result="invalid_code"}`, 1)
}
