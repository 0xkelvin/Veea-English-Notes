package metrics

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func scrape(t *testing.T, m *Metrics) string {
	t.Helper()
	rec := httptest.NewRecorder()
	m.Handler().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/metrics", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("GET /metrics: %d", rec.Code)
	}
	b, _ := io.ReadAll(rec.Body)
	return string(b)
}

func TestEveryTRDMetricIsExported(t *testing.T) {
	m := New()
	m.OTPStarted("login", "code")
	m.OTPVerified("login", "success")
	m.SignupCompleted("otp")
	m.PasswordLogin("success")
	m.RateLimited("otp_start_cooldown")
	m.SessionsRevoked("logout", 2)
	m.RefreshReuse()
	m.EmailSend("login_code", "sent")
	m.StaleResult()
	m.TxRetry("40P01")
	m.Argon2Wait(3 * time.Millisecond)
	m.RegisterOutboxPending(func(context.Context) (int64, error) { return 7, nil })
	out := scrape(t, m)
	for _, want := range []string{
		`auth_otp_started_total{delivery="code",purpose="login"} 1`,
		`auth_otp_verified_total{purpose="login",result="success"} 1`,
		`auth_signup_completed_total{method="otp"} 1`,
		`auth_password_login_total{result="success"} 1`,
		`auth_rate_limited_total{rule="otp_start_cooldown"} 1`,
		`auth_sessions_revoked_total{reason="logout"} 2`,
		`auth_refresh_reuse_total 1`,
		`email_send_total{result="sent",template="login_code"} 1`,
		`email_outbox_stale_result_total 1`,
		`email_outbox_pending 7`,
		`db_tx_retries_total{reason="deadlock"} 1`,
		`argon2_wait_seconds_count 1`,
		`go_goroutines`,
	} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %s", want)
		}
	}
}

// AC-22 for metrics: a label can only ever be a short lowercase code.
func TestLabelsCannotCarryPersonalDataOrTokens(t *testing.T) {
	m := New()
	for _, hostile := range []string{
		"learner@example.test", "192.0.2.10", "2001:db8::1", "vat_" + strings.Repeat("a", 43), "Bearer x",
		"invalid code 123456", strings.Repeat("a", 41), "", "UPPER", "ä",
	} {
		m.RateLimited(hostile)
		m.PasswordLogin(hostile)
		m.SessionsRevoked(hostile, 1)
	}
	out := scrape(t, m)
	for _, leak := range []string{"@", "192.0.2", "2001:db8", "vat_", "Bearer", "123456", "UPPER"} {
		if strings.Contains(out, leak) {
			t.Errorf("a label carries %q", leak)
		}
	}
	if !strings.Contains(out, `auth_rate_limited_total{rule="other"} 10`) {
		t.Errorf("hostile values must collapse into \"other\":\n%s", out)
	}
	m.TxRetry("42P01")
	if !strings.Contains(scrape(t, m), `db_tx_retries_total{reason="other"} 1`) {
		t.Error("unknown SQLSTATEs map to other")
	}
}

func TestNilMetricsAreSafe(t *testing.T) {
	var m *Metrics
	m.OTPStarted("a", "b")
	m.OTPVerified("a", "b")
	m.SignupCompleted("a")
	m.PasswordLogin("a")
	m.RateLimited("a")
	m.SessionsRevoked("a", 1)
	m.RefreshReuse()
	m.EmailSend("a", "b")
	m.StaleResult()
	m.TxRetry("40001")
	m.Argon2Wait(time.Second)
	m.RegisterOutboxPending(nil)
	m.LifecycleAccepted("delete")
	m.AccountJob("delete", "completed")
	m.RegisterDeletionBacklog(nil)
}

func TestPendingGaugeRegistersOnce(t *testing.T) {
	m := New()
	m.RegisterOutboxPending(func(context.Context) (int64, error) { return 3, nil })
	m.RegisterOutboxPending(func(context.Context) (int64, error) { return 9, nil }) // no panic, ignored
	if !strings.Contains(scrape(t, m), "email_outbox_pending 3") {
		t.Fatal("the first registration wins")
	}
}

func TestPendingGaugeReportsAFailedReadAsMinusOne(t *testing.T) {
	m := New()
	m.RegisterOutboxPending(func(context.Context) (int64, error) { return 0, context.DeadlineExceeded })
	if !strings.Contains(scrape(t, m), "email_outbox_pending -1") {
		t.Fatal("a failed count must be visible, not a silent zero")
	}
}

func TestDeletionBacklogGauge(t *testing.T) {
	m := New()
	m.RegisterDeletionBacklog(func(context.Context) (float64, error) { return 90000, nil })
	m.RegisterDeletionBacklog(func(context.Context) (float64, error) { return 1, nil }) // ignored
	m.LifecycleAccepted("someone@example.test")
	m.AccountJob("delete", "completed")
	out := scrape(t, m)
	for _, want := range []string{"account_deletion_oldest_pending_seconds 90000",
		`account_lifecycle_accepted_total{action="other"} 1`, `account_jobs_total{job="delete",result="completed"} 1`} {
		if !strings.Contains(out, want) {
			t.Fatalf("missing %s in:\n%s", want, out)
		}
	}
	f := New()
	f.RegisterDeletionBacklog(func(context.Context) (float64, error) { return 0, context.DeadlineExceeded })
	if !strings.Contains(scrape(t, f), "account_deletion_oldest_pending_seconds -1") {
		t.Fatal("a failed read must be visible, not a silent zero")
	}
}

func TestAdminMetrics(t *testing.T) {
	m := New()
	m.AdminAction("suspend", "success")
	m.RegisterActiveSuperAdmins(func(context.Context) (int64, error) { return 2, nil })
	m.RegisterActiveSuperAdmins(func(context.Context) (int64, error) { return 9, nil }) // ignored
	out := scrape(t, m)
	for _, want := range []string{`admin_actions_total{action="suspend",result="success"} 1`, `admin_active_super_admins 2`} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %s", want)
		}
	}
	var nilM *Metrics
	nilM.AdminAction("view", "success")
	nilM.RegisterActiveSuperAdmins(func(context.Context) (int64, error) { return 1, nil })
}

func TestMonitoringSeriesForTRD08(t *testing.T) {
	m := New()
	m.InitEmailSend([]string{"login_code", "Not A Code"})
	m.RegisterSuperAdminBootstrapped(func(context.Context) (bool, error) { return true, nil })
	out := scrape(t, m)
	for _, want := range []string{
		`email_send_total{result="sent",template="login_code"} 0`,
		`email_send_total{result="permanent",template="login_code"} 0`,
		`email_send_total{result="ambiguous",template="login_code"} 0`,
		`email_send_total{result="retryable",template="other"} 0`,
		`admin_super_admin_bootstrapped 1`,
	} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %s", want)
		}
	}
	for want, done := range map[string]func(context.Context) (bool, error){
		`admin_super_admin_bootstrapped 0`:  func(context.Context) (bool, error) { return false, nil },
		`admin_super_admin_bootstrapped -1`: func(context.Context) (bool, error) { return false, context.DeadlineExceeded },
	} {
		m := New()
		m.RegisterSuperAdminBootstrapped(done)
		if !strings.Contains(scrape(t, m), want) {
			t.Errorf("missing %s", want)
		}
	}
	var nilM *Metrics
	nilM.InitEmailSend([]string{"x"})
	nilM.RegisterSuperAdminBootstrapped(nil)
}
