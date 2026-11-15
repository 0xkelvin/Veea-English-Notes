//go:build integration

package integration

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/admin"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/migrate"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/pgtest"
)

// TRD 08: the database-backed gauges the alert rules read, against real PostgreSQL and the
// production registry wiring (app.New). Rule behavior itself is tested with promtool.
func TestMonitoring_GaugesBehindTheAlertRules(t *testing.T) {
	e := newSignupEnv(t, nil)
	g := func(name string) float64 { return metricValue(t, scrapeMetrics(t, e.metrics), name) }
	want := func(name string, v float64) {
		t.Helper()
		if got := g(name); got != v {
			t.Fatalf("%s = %v, want %v", name, got, v)
		}
	}
	out := scrapeMetrics(t, e.metrics)
	for _, name := range []string{"admin_active_super_admins", "admin_super_admin_bootstrapped",
		"account_deletion_oldest_pending_seconds", "email_outbox_pending"} {
		if !strings.Contains(out, "\n"+name+" ") {
			t.Fatalf("%s is not exported as a healthy zero on a fresh database", name)
		}
	}
	// Fresh deployment: no Super Admin, and not bootstrapped, so the alert stays silent.
	want("admin_active_super_admins", 0)
	want("admin_super_admin_bootstrapped", 0)
	want("account_deletion_oldest_pending_seconds", 0)
	want("email_outbox_pending", 0)

	u := newUser(t, e.q)
	if _, err := admin.Bootstrap(context.Background(), e.d.Pool, admin.BootstrapRequest{UserID: &u.ID, Mode: admin.ModeFirst}); err != nil {
		t.Fatal(err)
	}
	want("admin_active_super_admins", 1)
	want("admin_super_admin_bootstrapped", 1)
	var first time.Time
	if err := e.d.Pool.QueryRow(context.Background(), `SELECT first_bootstrapped_at FROM rbac_bootstrap`).Scan(&first); err != nil {
		t.Fatal(err)
	}
	// Break-glass and API promotions keep the first time.
	v := newUser(t, e.q)
	if _, err := admin.Bootstrap(context.Background(), e.d.Pool, admin.BootstrapRequest{UserID: &v.ID, Mode: admin.ModeBreakGlass, ReasonCode: "lost_access"}); err != nil {
		t.Fatal(err)
	}
	if rowCount(t, e.d.Pool, `SELECT count(*) FROM rbac_bootstrap WHERE first_bootstrapped_at = $1`, first) != 1 {
		t.Fatal("the marker must keep the first bootstrap time")
	}
	// The invariant broken behind the API's back: the marker is durable, so the alert can fire.
	mustExec(t, e.d.Pool, `UPDATE users SET role = 'user' WHERE role = 'super_admin'`)
	want("admin_active_super_admins", 0)
	want("admin_super_admin_bootstrapped", 1)

	// An accepted deletion whose purge has not finished, 25 hours old.
	d := newUser(t, e.q)
	p, r := e.rightsStart(t, "delete", d.Email)
	wantStatus(t, r, 202)
	wantStatus(t, e.rightsComplete(t, p), 202)
	mustExec(t, e.d.Pool, `UPDATE account_operations SET accepted_at = now() - interval '25 hours' WHERE id = $1`, p.id)
	if age := g("account_deletion_oldest_pending_seconds"); age <= 86400 || age > 90500 {
		t.Fatalf("purge backlog age %v, want just over 24 h", age)
	}
	e.finishRightsJobs(t)
	want("account_deletion_oldest_pending_seconds", 0) // completed: a healthy zero again

	// A failing read is the -1 sentinel, never a fake healthy value.
	mustExec(t, e.d.Pool, `ALTER TABLE rbac_bootstrap RENAME TO test_missing_marker`)
	want("admin_super_admin_bootstrapped", -1)
	mustExec(t, e.d.Pool, `ALTER TABLE test_missing_marker RENAME TO rbac_bootstrap`)
	want("admin_super_admin_bootstrapped", 1)
}

// A promotion to super_admin through the API also writes the marker (backstop for databases
// whose first Super Admin was created outside the CLI).
func TestMonitoring_PromotionWritesTheMarker(t *testing.T) {
	e := newSignupEnv(t, nil)
	_, s := e.staff(t, "super_admin") // fixture SQL: no marker yet
	if rowCount(t, e.d.Pool, `SELECT count(*) FROM rbac_bootstrap`) != 0 {
		t.Fatal("fixture must start without a marker")
	}
	u := e.withRole(t, "user")
	wantStatus(t, e.adminRole(t, s.AccessToken, u.ID, "admin", 0), 200)
	if rowCount(t, e.d.Pool, `SELECT count(*) FROM rbac_bootstrap`) != 0 {
		t.Fatal("only a super_admin grant writes the marker")
	}
	wantStatus(t, e.adminRole(t, s.AccessToken, u.ID, "super_admin", 1), 200)
	wantMetric(t, e.metrics, "admin_super_admin_bootstrapped", 1)
}

func TestMigrations_BootstrapMarkerBackfillFrom12(t *testing.T) {
	for _, bootstrapped := range []bool{false, true} {
		d := pgtest.NewEmpty(t)
		ctx := context.Background()
		if _, err := migrate.Up(ctx, d.URL, migrationsUpTo(t, 12)); err != nil {
			t.Fatal(err)
		}
		seedCleanupData(t, d, 50)
		if bootstrapped {
			id := newID()
			mustExec(t, d.Pool, `INSERT INTO users (id, email, email_normalized, email_verified_at, role)
				VALUES ($1, 'root@example.test', 'root@example.test', now(), 'super_admin')`, id)
			mustExec(t, d.Pool, `INSERT INTO audit_events (occurred_at, action, outcome, target_user_id)
				VALUES ('2026-11-01T00:00:00Z', 'admin.role.bootstrap', 'success', $1)`, id)
		}
		before := tableCounts(t, d)
		r, err := migrate.Up(ctx, d.URL, migrationsUpTo(t, 13))
		if err != nil || r.Current != 13 || len(r.Applied) != 1 || before != tableCounts(t, d) {
			t.Fatalf("upgrade: %+v %v", r, err)
		}
		n := rowCount(t, d.Pool, `SELECT count(*) FROM rbac_bootstrap`)
		if bootstrapped && rowCount(t, d.Pool, `SELECT count(*) FROM rbac_bootstrap WHERE first_bootstrapped_at = '2026-11-01T00:00:00Z'`) != 1 {
			t.Fatal("a bootstrapped database must be backfilled with the first bootstrap time")
		}
		if !bootstrapped && n != 0 {
			t.Fatal("a database never bootstrapped must stay unmarked")
		}
		_, err = d.Pool.Exec(ctx, `INSERT INTO rbac_bootstrap (id, first_bootstrapped_at) VALUES (2, now())`)
		wantPgError(t, err, pgCheck, "rbac_bootstrap_id_check")
		if _, err := migrate.Up(ctx, d.URL, migrationsUpTo(t, 13)); err != nil {
			t.Fatal("replay:", err)
		}
	}
}
