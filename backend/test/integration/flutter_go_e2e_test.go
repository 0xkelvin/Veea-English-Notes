//go:build integration && fluttere2e

package integration

import (
	"context"
	"encoding/json"
	"fmt"
	"github.com/google/uuid"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/notify"
)

// TestFlutterGo_EndToEnd hosts the production router against a disposable,
// migrated local PostgreSQL database and the real SMTP outbox/Mailpit. The
// control surface exists ONLY in this tagged test, bound to loopback. It is
// never registered by app.New or compiled into cmd/api.
func TestFlutterGo_EndToEnd(t *testing.T) {
	smtp, mailpit := os.Getenv("VEEA_TEST_SMTP_ADDR"), os.Getenv("VEEA_TEST_MAILPIT_API")
	if smtp == "" || mailpit == "" {
		t.Fatal("fluttere2e requires the local SMTP and Mailpit API variables")
	}
	if !strings.HasPrefix(mailpit, "http://127.0.0.1:") {
		t.Fatal("Mailpit must be loopback")
	}
	e := newSignupEnv(t, nil)
	defer mustExec(t, e.d.Pool, `UPDATE learning_sync_control SET open=false, changed_at=now()`)
	if rowCount(t, e.d.Pool, `SELECT count(*) FROM learning_sync_control WHERE open`) != 0 {
		t.Fatal("migration must ship closed")
	}
	sender, err := notify.NewSMTPSender(smtp, "no-reply@veea.local")
	if err != nil {
		t.Fatal(err)
	}
	keys, err := notify.NewKeyring(notify.Key{ID: 1, Key: outboxKey1})
	if err != nil {
		t.Fatal(err)
	}
	worker, err := notify.NewWorker(e.d.Pool, keys, sender, notify.WorkerConfig{PollInterval: 20 * time.Millisecond})
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	var wg sync.WaitGroup
	wg.Add(1)
	go func() { defer wg.Done(); _ = worker.Run(ctx) }()
	t.Cleanup(func() { cancel(); wg.Wait() })

	// Synthetic content only; neither publishing nor plan controls exist in production HTTP.
	a, b, c := uuid.New(), uuid.New(), uuid.New()
	e.publishPack(t, "e2e_premium", "premium", 1, a, b)
	e.publishPack(t, "e2e_premium", "premium", 2, a, b, c)
	mux := http.NewServeMux()
	mux.HandleFunc("POST /cartridge-plan", func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			UserID  uuid.UUID `json:"user_id"`
			Premium bool      `json:"premium"`
		}
		if json.NewDecoder(r.Body).Decode(&body) != nil || body.UserID == uuid.Nil {
			w.WriteHeader(400)
			return
		}
		_, err := e.d.Pool.Exec(r.Context(), `DELETE FROM entitlement_grants WHERE user_id=$1`, body.UserID)
		if err == nil && body.Premium {
			_, err = e.d.Pool.Exec(r.Context(), `INSERT INTO entitlement_grants(id,user_id,plan,source,starts_at,ends_at,granted_by,reason_code,ticket_ref) VALUES ($1,$2,'premium','manual',clock_timestamp()-interval '1 minute',clock_timestamp()+interval '1 hour',$3,'other','E2E-10')`, uuid.New(), body.UserID, uuid.New())
		}
		if err != nil {
			w.WriteHeader(500)
			return
		}
		w.WriteHeader(200)
	})
	mux.HandleFunc("POST /expire-access", func(w http.ResponseWriter, r *http.Request) {
		var b struct {
			SessionID string `json:"session_id"`
		}
		if json.NewDecoder(r.Body).Decode(&b) != nil {
			w.WriteHeader(400)
			return
		}
		_, err := e.d.Pool.Exec(r.Context(), `UPDATE sessions SET access_expires_at = now() - interval '1 second' WHERE id=$1`, b.SessionID)
		if err != nil {
			w.WriteHeader(500)
			return
		}
		_, _ = w.Write([]byte(`{}`))
	})
	mux.HandleFunc("GET /session-state", func(w http.ResponseWriter, r *http.Request) {
		var rotation int64
		var revoked *string
		err := e.d.Pool.QueryRow(r.Context(), `SELECT rotation_counter, revoked_reason FROM sessions WHERE id=$1`, r.URL.Query().Get("session_id")).Scan(&rotation, &revoked)
		if err != nil {
			w.WriteHeader(404)
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"rotation": rotation, "revoked_reason": revoked})
	})
	// This restore fence exists only in the tagged, loopback fixture. No production route.
	mux.HandleFunc("POST /restore-fixture-fence", func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			UserID uuid.UUID `json:"user_id"`
		}
		if json.NewDecoder(r.Body).Decode(&body) != nil || body.UserID == uuid.Nil {
			w.WriteHeader(400)
			return
		}
		tx, err := e.d.Pool.Begin(r.Context())
		if err != nil {
			w.WriteHeader(500)
			return
		}
		defer tx.Rollback(r.Context())
		for _, stmt := range []string{`UPDATE learning_sync_control SET open=false,changed_at=clock_timestamp()`,
			`UPDATE learning_sync_heads SET epoch=gen_random_uuid() WHERE user_id=$1`,
			`UPDATE learning_sync_writers SET retired_at=clock_timestamp() WHERE user_id=$1`,
			`UPDATE sessions SET revoked_at=clock_timestamp(),revoked_reason='account_inactive' WHERE user_id=$1`} {
			args := []any{}
			if strings.Contains(stmt, "$1") {
				args = append(args, body.UserID)
			}
			if _, err = tx.Exec(r.Context(), stmt, args...); err != nil {
				w.WriteHeader(500)
				return
			}
		}
		if err = tx.Commit(r.Context()); err != nil {
			w.WriteHeader(500)
			return
		}
		w.WriteHeader(200)
	})
	mux.HandleFunc("POST /open-fixture-sync", func(w http.ResponseWriter, r *http.Request) {
		// This database is owned by pgtest.New(t), not any running service.
		_, err := e.d.Pool.Exec(r.Context(), `UPDATE learning_sync_control SET open=true, changed_at=now()`)
		if err != nil {
			w.WriteHeader(500)
			return
		}
		_, _ = w.Write([]byte(`{}`))
	})
	runner := e.rightsRunner(t)
	mux.HandleFunc("POST /purge", func(w http.ResponseWriter, r *http.Request) {
		for range 20 {
			results := runner.RunOnce(r.Context())
			for _, result := range results {
				if result.Err != nil {
					w.WriteHeader(500)
					return
				}
			}
			if rowCount(t, e.d.Pool, `SELECT count(*) FROM account_operations WHERE state='pending'`) == 0 {
				_, _ = w.Write([]byte(`{}`))
				return
			}
		}
		w.WriteHeader(500)
	})
	mux.HandleFunc("POST /elapse-cooldowns", func(w http.ResponseWriter, r *http.Request) {
		_, err := e.d.Pool.Exec(r.Context(), `UPDATE otp_cooldowns SET last_issued_at = now() - interval '2 minutes'`)
		if err != nil {
			w.WriteHeader(500)
			return
		}
		_, _ = w.Write([]byte(`{}`))
	})
	control := httptest.NewServer(mux)
	defer control.Close()
	report := os.Getenv("VEEA_FLUTTER_E2E_REPORT")
	if report == "" {
		report = filepath.Join(t.TempDir(), "flutter-go.jsonl")
	}
	out, err := os.Create(report)
	if err != nil {
		t.Fatal(err)
	}
	defer out.Close()
	root, err := filepath.Abs("../../..")
	if err != nil {
		t.Fatal(err)
	}
	cmd := exec.CommandContext(ctx, "flutter", "test", "test/e2e/go_account_e2e_test.dart", "--reporter", "json")
	cmd.Dir = root
	cmd.Env = append(os.Environ(), "VEEA_FLUTTER_GO_URL="+e.srv.URL, "VEEA_FLUTTER_CONTROL_URL="+control.URL, "VEEA_TEST_MAILPIT_API="+mailpit)
	cmd.Stdout, cmd.Stderr = out, out
	if err := cmd.Run(); err != nil {
		t.Fatalf("Flutter E2E failed; sanitized test assertions and report at %s", report)
	}
	// Restore and assert the local fixture gate before disposing its DB.
	mustExec(t, e.d.Pool, `UPDATE learning_sync_control SET open=false, changed_at=now()`)
	if rowCount(t, e.d.Pool, `SELECT count(*) FROM learning_sync_control WHERE open`) != 0 {
		t.Fatal("fixture gate left open")
	}
	for _, prefix := range []string{"vat_", "vrt_", "vct_", "vop_"} {
		if strings.Contains(e.logs.String(), prefix) {
			t.Errorf("backend logs contain a credential prefix")
		}
	}
	t.Log(fmt.Sprintf("Flutter exercised real Go/OpenAPI + PostgreSQL + SMTP/Mailpit; report: %s", report))
}
