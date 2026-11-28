// Package monitoring holds the TRD 08 Prometheus rules (prometheus/). This test ties them to
// the metrics the service really exports, so a renamed metric or label breaks the build
// instead of silencing an alert. promtool behavior is tested by scripts/test-alert-rules.sh.
package monitoring

import (
	"bufio"
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"regexp"
	"slices"
	"strings"
	"testing"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/notify"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/metrics"
)

// exported scrapes a registry wired like cmd/api and app.New, and returns its metric names.
func exported(t *testing.T) (map[string]bool, string) {
	t.Helper()
	m := metrics.New()
	m.InitEmailSend(notify.TemplateNames())
	m.RegisterOutboxPending(func(context.Context) (int64, error) { return 0, nil })
	m.RegisterDeletionBacklog(func(context.Context) (float64, error) { return 0, nil })
	m.RegisterActiveSuperAdmins(func(context.Context) (int64, error) { return 1, nil })
	m.RegisterSuperAdminBootstrapped(func(context.Context) (bool, error) { return true, nil })
	rec := httptest.NewRecorder()
	m.Handler().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/metrics", nil))
	body, _ := io.ReadAll(rec.Body)
	names := map[string]bool{}
	for _, line := range strings.Split(string(body), "\n") {
		if f := strings.Fields(line); len(f) >= 3 && f[0] == "#" && f[1] == "TYPE" {
			names[f[2]] = true
		}
	}
	return names, string(body)
}

// expressions returns the text of every expr in the rule file.
func expressions(t *testing.T) []string {
	t.Helper()
	f, err := os.Open("prometheus/veea-alerts.yml")
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	var out []string
	var cur *strings.Builder
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		switch {
		case strings.HasPrefix(line, "expr:"):
			cur = &strings.Builder{}
			cur.WriteString(strings.TrimPrefix(line, "expr:"))
			out = append(out, "")
		case cur != nil && (strings.HasPrefix(line, "for:") || strings.HasPrefix(line, "labels:")):
			out[len(out)-1] = cur.String()
			cur = nil
		case cur != nil:
			cur.WriteString(" " + line)
		}
	}
	if len(out) == 0 {
		t.Fatal("no expressions found")
	}
	return out
}

var serviceMetric = regexp.MustCompile(`\b(?:admin|account|email|auth|db|argon2|learning|apple)_[a-z0-9_]+\b`)
var nameAlternation = regexp.MustCompile(`__name__=~"([^"]+)"`)
var resultMatcher = regexp.MustCompile(`result=~?"([^"]+)"`)

func TestRulesReferenceOnlyExportedMetricsAndLabels(t *testing.T) {
	have, scrape := exported(t)
	used := map[string]bool{}
	for _, expr := range expressions(t) {
		for _, n := range serviceMetric.FindAllString(expr, -1) {
			used[n] = true
		}
		for _, m := range nameAlternation.FindAllStringSubmatch(expr, -1) {
			for _, n := range strings.Split(m[1], "|") {
				used[n] = true
			}
		}
		for _, m := range resultMatcher.FindAllStringSubmatch(expr, -1) {
			for _, v := range strings.Split(m[1], "|") {
				if strings.Contains(expr, "apple_purchase_verification_total") {
					if !strings.Contains(scrape, `apple_purchase_verification_total{operation="claim",result="`+v+`"}`) {
						t.Errorf("purchase metric does not export result=%q", v)
					}
				} else if !slices.Contains(metrics.EmailResults, v) {
					t.Errorf("rule matches result=%q, which email_send_total never carries (%v)", v, metrics.EmailResults)
				}
			}
		}
		if !strings.Contains(expr, `job="veea-api"`) {
			t.Errorf("every expression must select the veea-api job: %s", expr)
		}
	}
	for n := range used {
		if !have[n] {
			t.Errorf("rules reference %s, which the service does not export", n)
		}
	}
	for _, want := range []string{"admin_active_super_admins", "admin_super_admin_bootstrapped",
		"account_deletion_oldest_pending_seconds", "email_outbox_pending", "email_send_total", "apple_purchase_verification_total"} {
		if !used[want] {
			t.Errorf("no rule uses %s", want)
		}
	}
}
