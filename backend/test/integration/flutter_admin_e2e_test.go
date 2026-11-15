//go:build integration && fluttere2e

package integration

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/google/uuid"
)

// TestFlutterGo_AdminConsole runs the TRD 07 console's Dart end-to-end suite against the
// production router (with the OpenAPI response checker) and a disposable, migrated local
// PostgreSQL. The fixture surface below exists only in this tagged test, bound to loopback; it
// creates synthetic accounts and reads their state, and it is never part of app.New or cmd/api.
// Every admin action the suite takes goes through the real /v1/admin routes.
func TestFlutterGo_AdminConsole(t *testing.T) {
	e := newSignupEnv(t, nil)
	mux := http.NewServeMux()
	mux.HandleFunc("POST /fixture-account", func(w http.ResponseWriter, r *http.Request) {
		var b struct {
			Role     string `json:"role"`
			Status   string `json:"status"`
			Sessions int    `json:"sessions"`
		}
		if json.NewDecoder(r.Body).Decode(&b) != nil || b.Sessions < 0 || b.Sessions > 5 {
			w.WriteHeader(400)
			return
		}
		u, pw := e.passwordUser(t)
		if b.Role != "" && b.Role != "user" {
			mustExec(t, e.d.Pool, `UPDATE users SET role = $2 WHERE id = $1`, u.ID, b.Role)
		}
		for i := range b.Sessions {
			e.issue(t, u, fmt.Sprintf("Phone %d", i+1))
		}
		switch b.Status {
		case "", "active":
		case "suspended":
			mustExec(t, e.d.Pool, `UPDATE users SET status = 'suspended', resume_status = 'active', suspension_reason = 'other' WHERE id = $1`, u.ID)
		case "pending_deletion":
			mustExec(t, e.d.Pool, `UPDATE users SET status = 'pending_deletion' WHERE id = $1`, u.ID)
		default:
			w.WriteHeader(400)
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]string{"id": u.ID.String(), "email": u.Email, "password": pw})
	})
	mux.HandleFunc("GET /account-state", func(w http.ResponseWriter, r *http.Request) {
		id, err := uuid.Parse(r.URL.Query().Get("id"))
		if err != nil {
			w.WriteHeader(400)
			return
		}
		var status, role string
		var live int
		if err := e.d.Pool.QueryRow(r.Context(), `SELECT status, role, (SELECT count(*) FROM sessions s WHERE s.user_id = u.id
			AND s.revoked_at IS NULL AND s.absolute_expires_at > now()) FROM users u WHERE id = $1`, id).Scan(&status, &role, &live); err != nil {
			w.WriteHeader(404)
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"status": status, "role": role, "live_sessions": live})
	})
	mux.HandleFunc("POST /expire-access", func(w http.ResponseWriter, r *http.Request) {
		var b struct {
			SessionID string `json:"session_id"`
		}
		if json.NewDecoder(r.Body).Decode(&b) != nil {
			w.WriteHeader(400)
			return
		}
		if _, err := e.d.Pool.Exec(r.Context(), `UPDATE sessions SET access_expires_at = now() - interval '1 second' WHERE id = $1`, b.SessionID); err != nil {
			w.WriteHeader(500)
			return
		}
		_, _ = w.Write([]byte(`{}`))
	})
	control := httptest.NewServer(mux)
	defer control.Close()

	report := os.Getenv("VEEA_ADMIN_E2E_REPORT")
	if report == "" {
		report = filepath.Join(t.TempDir(), "admin-console.jsonl")
	}
	out, err := os.Create(report)
	if err != nil {
		t.Fatal(err)
	}
	defer out.Close()
	dir, err := filepath.Abs("../../../admin_console")
	if err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command("flutter", "test", "test/e2e/admin_console_e2e_test.dart", "--reporter", "json")
	cmd.Dir = dir
	cmd.Env = append(os.Environ(), "VEEA_ADMIN_E2E_API="+e.srv.URL, "VEEA_ADMIN_E2E_CONTROL="+control.URL)
	cmd.Stdout, cmd.Stderr = out, out
	if err := cmd.Run(); err != nil {
		t.Fatalf("admin console E2E failed; report at %s", report)
	}
	for _, prefix := range []string{"vat_", "vrt_", "vct_", "vop_"} {
		if strings.Contains(e.logs.String(), prefix) {
			t.Errorf("backend logs contain a credential prefix")
		}
	}
	t.Logf("admin console exercised the real Go router + OpenAPI checker + PostgreSQL; report: %s", report)
}
