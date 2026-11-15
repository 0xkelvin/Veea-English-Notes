// Package metrics exposes the runtime metrics of TRD 01 §11.3 for Prometheus, on the internal
// listener VEEA_METRICS_ADDR. Alerting on them is Phase 5.
//
// Label hygiene (AC-22): every label value goes through label(), which keeps only short
// lowercase codes ([a-z0-9_], at most 40 characters) and turns anything else into "other". An
// email, an IP address, a token or a free-form error string can therefore never become a label,
// even by mistake. Callers pass fixed codes: purposes, deliveries, methods, results, rule names,
// revocation reasons, templates.
//
// Every method is safe on a nil *Metrics, so services work unchanged without metrics.
package metrics

import (
	"context"
	"net/http"
	"sync"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/collectors"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

// Metrics holds the collectors on a private registry.
type Metrics struct {
	reg         *prometheus.Registry
	pendingOnce sync.Once
	backlogOnce sync.Once
	adminOnce   sync.Once
	bootOnce    sync.Once

	otpStarted      *prometheus.CounterVec
	otpVerified     *prometheus.CounterVec
	signupCompleted *prometheus.CounterVec
	passwordLogin   *prometheus.CounterVec
	rateLimited     *prometheus.CounterVec
	sessionsRevoked *prometheus.CounterVec
	refreshReuse    prometheus.Counter
	emailSend       *prometheus.CounterVec
	staleResults    prometheus.Counter
	txRetries       *prometheus.CounterVec
	argon2Wait      prometheus.Histogram
	lifecycle       *prometheus.CounterVec
	accountJobs     *prometheus.CounterVec
	learningPush    *prometheus.CounterVec
	learningItems   *prometheus.CounterVec
	learningReset   *prometheus.CounterVec
	adminActions    *prometheus.CounterVec
}

// New registers every TRD 11.3 metric plus the Go runtime and process collectors.
func New() *Metrics {
	reg := prometheus.NewRegistry()
	f := func(c prometheus.Collector) prometheus.Collector { reg.MustRegister(c); return c }
	m := &Metrics{reg: reg}
	m.otpStarted = f(prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "auth_otp_started_total", Help: "OTP starts that issued a challenge, by purpose and delivery (code or none)."},
		[]string{"purpose", "delivery"})).(*prometheus.CounterVec)
	m.otpVerified = f(prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "auth_otp_verified_total", Help: "OTP redemptions by purpose and result."},
		[]string{"purpose", "result"})).(*prometheus.CounterVec)
	m.signupCompleted = f(prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "auth_signup_completed_total", Help: "Accounts created by a verified signup, by method."},
		[]string{"method"})).(*prometheus.CounterVec)
	m.passwordLogin = f(prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "auth_password_login_total", Help: "Password sign-in attempts by result."},
		[]string{"result"})).(*prometheus.CounterVec)
	m.rateLimited = f(prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "auth_rate_limited_total", Help: "Requests refused with 429, by rule."},
		[]string{"rule"})).(*prometheus.CounterVec)
	m.sessionsRevoked = f(prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "auth_sessions_revoked_total", Help: "Sessions revoked, by reason."},
		[]string{"reason"})).(*prometheus.CounterVec)
	m.refreshReuse = f(prometheus.NewCounter(prometheus.CounterOpts{
		Name: "auth_refresh_reuse_total", Help: "Refresh tokens presented again within retention (TRD 8.4)."})).(prometheus.Counter)
	m.emailSend = f(prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "email_send_total", Help: "Provider send calls by template and result (sent, permanent, retryable, ambiguous)."},
		[]string{"template", "result"})).(*prometheus.CounterVec)
	m.staleResults = f(prometheus.NewCounter(prometheus.CounterOpts{
		Name: "email_outbox_stale_result_total", Help: "Outbox result writes discarded because the lease was gone (TRD 8.3)."})).(prometheus.Counter)
	m.txRetries = f(prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "db_tx_retries_total", Help: "Transactions retried after a deadlock or serialization failure (TRD 7.1 rule 7)."},
		[]string{"reason"})).(*prometheus.CounterVec)
	m.argon2Wait = f(prometheus.NewHistogram(prometheus.HistogramOpts{
		Name: "argon2_wait_seconds", Help: "Time spent waiting for an Argon2id slot (TRD 9.2).",
		Buckets: []float64{0.001, 0.005, 0.01, 0.05, 0.1, 0.25, 0.5, 1, 2}})).(prometheus.Histogram)
	m.lifecycle = f(prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "account_lifecycle_accepted_total", Help: "Committed owner lifecycle transitions and accepted rights operations, by action (TRD 04)."},
		[]string{"action"})).(*prometheus.CounterVec)
	m.accountJobs = f(prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "account_jobs_total", Help: "Durable export/deletion job transactions, by job and result (TRD 04)."},
		[]string{"job", "result"})).(*prometheus.CounterVec)
	m.learningPush = f(prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "learning_sync_push_total", Help: "Vocabulary push and import requests that reached the owner lock, by route and result (TRD 05)."},
		[]string{"route", "result"})).(*prometheus.CounterVec)
	m.learningItems = f(prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "learning_sync_items_total", Help: "Committed vocabulary mutation results, by op and outcome (TRD 05)."},
		[]string{"op", "outcome"})).(*prometheus.CounterVec)
	m.learningReset = f(prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "learning_sync_reset_total", Help: "410 sync_reset_required answers, by reason (TRD 05)."},
		[]string{"reason"})).(*prometheus.CounterVec)
	m.adminActions = f(prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "admin_actions_total", Help: "Admin API requests that reached their transaction, by action and result (TRD 06)."},
		[]string{"action", "result"})).(*prometheus.CounterVec)
	reg.MustRegister(collectors.NewGoCollector(), collectors.NewProcessCollector(collectors.ProcessCollectorOpts{}))
	return m
}

// Handler serves the registry in the Prometheus text format.
func (m *Metrics) Handler() http.Handler {
	mux := http.NewServeMux()
	// At most two scrapes at once, each bounded: email_outbox_pending runs a query on the API pool.
	mux.Handle("GET /metrics", promhttp.HandlerFor(m.reg, promhttp.HandlerOpts{MaxRequestsInFlight: 2, Timeout: 5 * time.Second}))
	return mux
}

// RegisterOutboxPending exports email_outbox_pending, read with count when scraped. Only the
// first call registers; later calls (a second app.New with the same Metrics) are no-ops rather
// than a duplicate-registration panic.
func (m *Metrics) RegisterOutboxPending(count func(ctx context.Context) (int64, error)) {
	if m == nil || count == nil {
		return
	}
	m.pendingOnce.Do(func() { m.registerPending(count) })
}

func (m *Metrics) registerPending(count func(ctx context.Context) (int64, error)) {
	m.reg.MustRegister(prometheus.NewGaugeFunc(prometheus.GaugeOpts{
		Name: "email_outbox_pending", Help: "Outbox rows still pending."}, func() float64 {
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		n, err := count(ctx)
		if err != nil {
			return -1 // visible as an impossible value rather than a silent zero
		}
		return float64(n)
	}))
}

// label keeps a value only if it is a short lowercase code.
func label(v string) string {
	if v == "" || len(v) > 40 {
		return "other"
	}
	for _, r := range v {
		if (r < 'a' || r > 'z') && (r < '0' || r > '9') && r != '_' {
			return "other"
		}
	}
	return v
}

// OTPStarted counts a committed start.
func (m *Metrics) OTPStarted(purpose, delivery string) {
	if m != nil {
		m.otpStarted.WithLabelValues(label(purpose), label(delivery)).Inc()
	}
}

// OTPVerified counts a redemption by result.
func (m *Metrics) OTPVerified(purpose, result string) {
	if m != nil {
		m.otpVerified.WithLabelValues(label(purpose), label(result)).Inc()
	}
}

// SignupCompleted counts a created account.
func (m *Metrics) SignupCompleted(method string) {
	if m != nil {
		m.signupCompleted.WithLabelValues(label(method)).Inc()
	}
}

// PasswordLogin counts a password sign-in attempt.
func (m *Metrics) PasswordLogin(result string) {
	if m != nil {
		m.passwordLogin.WithLabelValues(label(result)).Inc()
	}
}

// RateLimited counts a 429.
func (m *Metrics) RateLimited(rule string) {
	if m != nil {
		m.rateLimited.WithLabelValues(label(rule)).Inc()
	}
}

// SessionsRevoked adds n committed revocations.
func (m *Metrics) SessionsRevoked(reason string, n int64) {
	if m != nil && n > 0 {
		m.sessionsRevoked.WithLabelValues(label(reason)).Add(float64(n))
	}
}

// RefreshReuse counts a detected reuse.
func (m *Metrics) RefreshReuse() {
	if m != nil {
		m.refreshReuse.Inc()
	}
}

// EmailSend counts one provider call.
func (m *Metrics) EmailSend(template, result string) {
	if m != nil {
		m.emailSend.WithLabelValues(label(template), label(result)).Inc()
	}
}

// StaleResult counts a discarded outbox result write.
func (m *Metrics) StaleResult() {
	if m != nil {
		m.staleResults.Inc()
	}
}

// TxRetry counts a retried transaction by SQLSTATE.
func (m *Metrics) TxRetry(sqlstate string) {
	if m == nil {
		return
	}
	reason := "other"
	switch sqlstate {
	case "40P01":
		reason = "deadlock"
	case "40001":
		reason = "serialization"
	}
	m.txRetries.WithLabelValues(reason).Inc()
}

// Argon2Wait observes a hashing-slot wait.
func (m *Metrics) Argon2Wait(d time.Duration) {
	if m != nil {
		m.argon2Wait.Observe(d.Seconds())
	}
}

// LifecycleAccepted counts one committed transition or newly accepted rights operation.
func (m *Metrics) LifecycleAccepted(action string) {
	if m != nil {
		m.lifecycle.WithLabelValues(label(action)).Inc()
	}
}

// AccountJob counts one committed job outcome, or a failed job transaction (result error).
func (m *Metrics) AccountJob(job, result string) {
	if m != nil {
		m.accountJobs.WithLabelValues(label(job), label(result)).Inc()
	}
}

// RegisterDeletionBacklog exports account_deletion_oldest_pending_seconds, the age of the
// oldest accepted deletion whose purge has not completed, read when scraped. The TRD 04
// target is 24 h; alerting on it belongs to deployment. Only the first call registers.
func (m *Metrics) RegisterDeletionBacklog(age func(ctx context.Context) (float64, error)) {
	if m == nil || age == nil {
		return
	}
	m.backlogOnce.Do(func() {
		m.reg.MustRegister(prometheus.NewGaugeFunc(prometheus.GaugeOpts{
			Name: "account_deletion_oldest_pending_seconds", Help: "Age of the oldest accepted, unfinished account purge (0 when none)."}, func() float64 {
			ctx, cancel := context.WithTimeout(context.Background(), time.Second)
			defer cancel()
			v, err := age(ctx)
			if err != nil {
				return -1 // visible as an impossible value rather than a silent zero
			}
			return v
		}))
	})
}

// LearningPush counts one push or import that committed or was refused under the owner lock.
func (m *Metrics) LearningPush(route, result string) {
	if m != nil {
		m.learningPush.WithLabelValues(label(route), label(result)).Inc()
	}
}

// LearningItem counts one committed mutation result.
func (m *Metrics) LearningItem(op, outcome string) {
	if m != nil {
		m.learningItems.WithLabelValues(label(op), label(outcome)).Inc()
	}
}

// LearningReset counts one 410 sync_reset_required.
func (m *Metrics) LearningReset(reason string) {
	if m != nil {
		m.learningReset.WithLabelValues(label(reason)).Inc()
	}
}

// AdminAction counts one admin request after its transaction ended: result is success, noop,
// denied or conflict (TRD 06 §9.3).
func (m *Metrics) AdminAction(action, result string) {
	if m != nil {
		m.adminActions.WithLabelValues(label(action), label(result)).Inc()
	}
}

// RegisterActiveSuperAdmins exports admin_active_super_admins, read when scraped. The TRD 06
// invariant keeps it at 1 or more; a 0 means a direct database edit. Only the first call
// registers.
func (m *Metrics) RegisterActiveSuperAdmins(count func(ctx context.Context) (int64, error)) {
	if m == nil || count == nil {
		return
	}
	m.adminOnce.Do(func() {
		m.reg.MustRegister(prometheus.NewGaugeFunc(prometheus.GaugeOpts{
			Name: "admin_active_super_admins", Help: "Active, verified accounts with the super_admin role."}, func() float64 {
			ctx, cancel := context.WithTimeout(context.Background(), time.Second)
			defer cancel()
			n, err := count(ctx)
			if err != nil {
				return -1
			}
			return float64(n)
		}))
	})
}

// RegisterSuperAdminBootstrapped exports admin_super_admin_bootstrapped: 1 once the first Super
// Admin bootstrap has committed (a durable marker, TRD 08), 0 before, -1 when the read fails. It
// lets the "no active Super Admin" alert stay silent on a fresh deployment. First call registers.
func (m *Metrics) RegisterSuperAdminBootstrapped(done func(ctx context.Context) (bool, error)) {
	if m == nil || done == nil {
		return
	}
	m.bootOnce.Do(func() {
		m.reg.MustRegister(prometheus.NewGaugeFunc(prometheus.GaugeOpts{
			Name: "admin_super_admin_bootstrapped", Help: "1 after the first Super Admin bootstrap committed, else 0; -1 on read failure."}, func() float64 {
			ctx, cancel := context.WithTimeout(context.Background(), time.Second)
			defer cancel()
			ok, err := done(ctx)
			switch {
			case err != nil:
				return -1
			case ok:
				return 1
			}
			return 0
		}))
	})
}

// EmailResults are the result label values of email_send_total: "sent" or the sender's error
// class (notify.Class).
var EmailResults = []string{"sent", "permanent", "retryable", "ambiguous"}

// InitEmailSend creates every email_send_total{template,result} series at 0, so a delivery
// failure right after a restart is an increase from 0 (not a series' first sample, which
// increase() cannot see) and "no failures" is a real 0 rather than a missing series (TRD 08).
func (m *Metrics) InitEmailSend(templates []string) {
	if m == nil {
		return
	}
	for _, t := range templates {
		for _, r := range EmailResults {
			m.emailSend.WithLabelValues(label(t), r)
		}
	}
}
