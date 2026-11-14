//go:build integration

package integration

import (
	"context"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/auth/otp"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/maintenance"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/pgtest"
)

func newRunner(t *testing.T, d *pgtest.DB, cfg maintenance.Config) *maintenance.Runner {
	t.Helper()
	cfg.Pool = d.Pool
	r, err := maintenance.New(cfg)
	if err != nil {
		t.Fatal(err)
	}
	return r
}

func resultOf(t *testing.T, results []maintenance.Result, job string) maintenance.Result {
	t.Helper()
	for _, r := range results {
		if r.Job == job {
			return r
		}
	}
	t.Fatalf("no result for job %s", job)
	return maintenance.Result{}
}

func noErrors(t *testing.T, results []maintenance.Result) {
	t.Helper()
	for _, r := range results {
		if r.Err != nil {
			t.Fatalf("job %s: %v", r.Job, r.Err)
		}
	}
}

// advisoryLocksHeld counts advisory locks held by any session of the test database.
func advisoryLocksHeld(t *testing.T, d *pgtest.DB) int {
	t.Helper()
	return rowCount(t, d.Pool, `SELECT count(*) FROM pg_locks l JOIN pg_stat_activity a ON a.pid = l.pid
		WHERE l.locktype = 'advisory' AND a.datname = current_database()`)
}

// AC-26 at run time, end to end: an abandoned password signup's pending hash is scrubbed by the
// cleanup runner once the challenge expires, and the challenge with its email goes 24 h later.
func TestCleanup_AC26_ScrubsTheExpiredPendingPasswordHash(t *testing.T) {
	env := newSignupEnv(t, nil)
	runner := newRunner(t, env.d, maintenance.Config{})
	expired, live := newAddress("abandoned"), newAddress("live")
	code := env.queueCode()
	ack := env.startPassword(t, expired, newPassword())
	liveAck := env.startPassword(t, live, newPassword())
	tok := ack.str("challenge_token")
	if _, _, pending := env.challengeByToken(t, tok); pending == nil {
		t.Fatal("setup: the pending hash is on the challenge")
	}

	mustExec(t, env.d.Pool, `UPDATE otp_challenges SET expires_at = now() - interval '1 second' WHERE token_hash = $1`, otp.HashToken(tok))
	results := runner.RunOnce(context.Background())
	noErrors(t, results)
	if r := resultOf(t, results, "otp_pending_password_hash"); !r.Ran || r.Rows != 1 {
		t.Fatalf("scrub job: %+v", r)
	}
	if _, _, pending := env.challengeByToken(t, tok); pending != nil {
		t.Fatal("AC-26: the expired challenge must no longer hold the password hash")
	}
	if _, _, pending := env.challengeByToken(t, liveAck.str("challenge_token")); pending == nil {
		t.Fatal("an open challenge keeps its hash")
	}
	wantProblem(t, env.verify(t, tok, code), http.StatusBadRequest, "invalid_code")
	if env.count(t, "users") != 0 || env.count(t, "sessions") != 0 {
		t.Fatal("no credential and no session from the abandoned attempt")
	}

	// 24 h after expiry the challenge goes, and its outbox row with it (cascade).
	mustExec(t, env.d.Pool, `UPDATE otp_challenges SET expires_at = now() - interval '24 hours 1 minute' WHERE token_hash = $1`, otp.HashToken(tok))
	results = runner.RunOnce(context.Background())
	noErrors(t, results)
	if rowCount(t, env.d.Pool, `SELECT count(*) FROM otp_challenges WHERE token_hash = $1`, otp.HashToken(tok)) != 0 {
		t.Fatal("the challenge is deleted 24 h after expiry")
	}
	if rowCount(t, env.d.Pool, `SELECT count(*) FROM email_outbox o WHERE NOT EXISTS (SELECT 1 FROM otp_challenges c WHERE c.id = o.challenge_id)`) != 0 {
		t.Fatal("its outbox row goes with it")
	}
	if rowCount(t, env.d.Pool, `SELECT count(*) FROM otp_challenges WHERE token_hash = $1`, otp.HashToken(liveAck.str("challenge_token"))) != 1 {
		t.Fatal("the open challenge stays")
	}
}

// Every TRD 6.10 retention threshold, a minute on either side.
func TestCleanup_RetentionBoundaries(t *testing.T) {
	d, q := migratedDB(t)
	ctx := context.Background()
	u := newUser(t, q)
	keep, drop := map[string]uuid.UUID{}, map[string]uuid.UUID{}

	challenge := func(expires string) uuid.UUID {
		p := challengeParams("login", "c-"+uuid.NewString()+"@example.test", "code")
		ch := newChallenge(t, q, p)
		mustExec(t, d.Pool, `UPDATE otp_challenges SET expires_at = now() - $2::interval, superseded_at = now() WHERE id = $1`, ch.ID, expires)
		return ch.ID
	}
	keep["challenge"], drop["challenge"] = challenge("23 hours 59 minutes"), challenge("24 hours 1 minute")

	mustExec(t, d.Pool, `INSERT INTO otp_cooldowns (purpose, email_hmac, last_issued_at) VALUES
		('login', '\x01', now() - interval '23 hours 59 minutes'), ('login', '\x02', now() - interval '24 hours 1 minute')`)

	outbox := func(status, finished string) uuid.UUID {
		p := outboxParams()
		p.UserID = &u.ID
		row, err := q.InsertOutboxEmail(ctx, p)
		if err != nil {
			t.Fatal(err)
		}
		mustExec(t, d.Pool, `UPDATE email_outbox SET status = $2, payload_ciphertext = NULL, finished_at = now() - $3::interval WHERE id = $1`,
			row.ID, status, finished)
		return row.ID
	}
	keep["outbox"], drop["outbox"] = outbox("sent", "6 days 23 hours"), outbox("failed", "7 days 1 hour")
	pastDeadline, err := q.InsertOutboxEmail(ctx, outboxParams())
	if err != nil {
		t.Fatal(err)
	}
	mustExec(t, d.Pool, `UPDATE email_outbox SET not_after = now() - interval '1 minute' WHERE id = $1`, pastDeadline.ID)

	session := func(revokedAgo, absoluteAgo string) uuid.UUID {
		s := newSession(t, q, u.ID)
		if revokedAgo != "" {
			mustExec(t, d.Pool, `UPDATE sessions SET revoked_at = now() - $2::interval, revoked_reason = 'logout' WHERE id = $1`, s.ID, revokedAgo)
		}
		if absoluteAgo != "" {
			mustExec(t, d.Pool, `UPDATE sessions SET absolute_expires_at = now() - $2::interval WHERE id = $1`, s.ID, absoluteAgo)
		}
		return s.ID
	}
	keep["revoked session"], drop["revoked session"] = session("29 days 23 hours", ""), session("30 days 1 hour", "")
	keep["expired session"], drop["expired session"] = session("", "29 days 23 hours"), session("", "30 days 1 hour")
	keep["active session"] = session("", "")

	live := keep["active session"]
	mustExec(t, d.Pool, `INSERT INTO refresh_tokens_consumed (token_hash, session_id, consumed_at, retain_until) VALUES
		('\xaa', $1, now(), now() + interval '1 minute'), ('\xbb', $1, now(), now() - interval '1 minute')`, live)
	mustExec(t, d.Pool, `INSERT INTO rate_limit_counters (key, window_start, count) VALUES
		('keep', now() - interval '47 hours 59 minutes', 1), ('drop', now() - interval '48 hours 1 minute', 1)`)
	mustExec(t, d.Pool, `INSERT INTO audit_events (occurred_at, action, outcome) VALUES (now() - interval '400 days', 'auth.logout', 'success')`)

	results := newRunner(t, d, maintenance.Config{}).RunOnce(ctx)
	noErrors(t, results)

	exists := func(table string, id uuid.UUID) bool {
		return rowCount(t, d.Pool, `SELECT count(*) FROM `+table+` WHERE id = $1`, id) == 1
	}
	tables := map[string]string{"challenge": "otp_challenges", "outbox": "email_outbox",
		"revoked session": "sessions", "expired session": "sessions", "active session": "sessions"}
	for name, id := range keep {
		if !exists(tables[name], id) {
			t.Errorf("%s inside its retention must be kept", name)
		}
	}
	for name, id := range drop {
		if exists(tables[name], id) {
			t.Errorf("%s past its retention must be deleted", name)
		}
	}
	for what, query := range map[string]string{
		"cooldown inside 24 h":        `SELECT count(*) FROM otp_cooldowns WHERE email_hmac = '\x01'`,
		"consumed token in retention": `SELECT count(*) FROM refresh_tokens_consumed WHERE token_hash = '\xaa'`,
		"counter inside 48 h":         `SELECT count(*) FROM rate_limit_counters WHERE key = 'keep'`,
		"audit event (never deleted)": `SELECT count(*) FROM audit_events`,
	} {
		if rowCount(t, d.Pool, query) != 1 {
			t.Errorf("%s must be kept", what)
		}
	}
	for what, query := range map[string]string{
		"cooldown past 24 h":     `SELECT count(*) FROM otp_cooldowns WHERE email_hmac = '\x02'`,
		"consumed token past it": `SELECT count(*) FROM refresh_tokens_consumed WHERE token_hash = '\xbb'`,
		"counter past 48 h":      `SELECT count(*) FROM rate_limit_counters WHERE key = 'drop'`,
	} {
		if rowCount(t, d.Pool, query) != 0 {
			t.Errorf("%s must be deleted", what)
		}
	}
	// The reaper backstop terminalized the pending row past its deadline; it is kept for 7 days.
	if rowCount(t, d.Pool, `SELECT count(*) FROM email_outbox WHERE id = $1 AND status = 'expired' AND payload_ciphertext IS NULL`, pastDeadline.ID) != 1 {
		t.Error("the outbox reaper backstop must expire and scrub a pending row past not_after")
	}
}

func TestCleanup_BatchesAreBoundedPerRun(t *testing.T) {
	d, _ := migratedDB(t)
	for i := range 5 {
		mustExec(t, d.Pool, `INSERT INTO rate_limit_counters (key, window_start, count) VALUES ($1, now() - interval '3 days', 1)`, "old-"+string(rune('a'+i)))
	}
	r := newRunner(t, d, maintenance.Config{BatchSize: 2, MaxBatches: 2})
	first := resultOf(t, r.RunOnce(context.Background()), "rate_limit_counters")
	if first.Rows != 4 || first.Batches != 2 {
		t.Fatalf("first run: %+v, want 4 rows in 2 batches", first)
	}
	second := resultOf(t, r.RunOnce(context.Background()), "rate_limit_counters")
	if second.Rows != 1 || rowCount(t, d.Pool, `SELECT count(*) FROM rate_limit_counters`) != 0 {
		t.Fatalf("second run: %+v", second)
	}
}

// pg_try_advisory_lock: a job whose lock another session holds is skipped, never run twice at
// once, and runs normally once the lock is free.
func TestCleanup_ConcurrentRunnersRunEachJobOnce(t *testing.T) {
	d, _ := migratedDB(t)
	ctx := context.Background()
	jobs := maintenance.Jobs()
	scrub := jobs[0]

	t.Run("a held lock skips the job", func(t *testing.T) {
		holder, err := d.Pool.Acquire(ctx)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := holder.Exec(ctx, `SELECT pg_advisory_lock($1)`, scrub.LockKey); err != nil {
			t.Fatal(err)
		}
		results := newRunner(t, d, maintenance.Config{}).RunOnce(ctx)
		if r := resultOf(t, results, scrub.Name); r.Ran || r.Err != nil {
			t.Fatalf("the job must be skipped while another session holds its lock: %+v", r)
		}
		if r := resultOf(t, results, "rate_limit_counters"); !r.Ran {
			t.Fatal("other jobs still run")
		}
		_, _ = holder.Exec(ctx, `SELECT pg_advisory_unlock($1)`, scrub.LockKey)
		holder.Release()
		if r := resultOf(t, newRunner(t, d, maintenance.Config{}).RunOnce(ctx), scrub.Name); !r.Ran {
			t.Fatal("once the lock is free the job runs")
		}
	})

	t.Run("simultaneous runners", func(t *testing.T) {
		// Slow the first job down so every runner reaches it while the winner still holds it.
		mustExec(t, d.Pool, `CREATE FUNCTION test_slow() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN PERFORM pg_sleep(0.5); RETURN NULL; END $$`)
		mustExec(t, d.Pool, `CREATE TRIGGER test_slow AFTER UPDATE ON otp_challenges FOR EACH STATEMENT EXECUTE FUNCTION test_slow()`)
		defer mustExec(t, d.Pool, `DROP TRIGGER test_slow ON otp_challenges`)
		const n = 4
		gate := make(chan struct{})
		all := make([][]maintenance.Result, n)
		var wg sync.WaitGroup
		for i := range n {
			wg.Add(1)
			go func() {
				defer wg.Done()
				r := newRunner(t, d, maintenance.Config{})
				<-gate
				all[i] = r.RunOnce(ctx)
			}()
		}
		close(gate)
		wg.Wait()
		ran := 0
		for _, results := range all {
			for _, r := range results {
				if r.Err != nil {
					t.Fatalf("runner error: %v", r.Err)
				}
				if r.Job == scrub.Name && r.Ran {
					ran++
				}
			}
		}
		if ran != 1 {
			t.Fatalf("%d runners ran %s at once, want exactly 1", ran, scrub.Name)
		}
		if advisoryLocksHeld(t, d) != 0 {
			t.Fatal("no advisory lock may stay held after the runs")
		}
	})
}

// The lock is released on failure and on cancellation, even mid-statement.
func TestCleanup_LockIsReleasedOnFailureAndCancellation(t *testing.T) {
	d, _ := migratedDB(t)
	ctx := context.Background()
	freeAgain := func(t *testing.T, key int64) {
		t.Helper()
		deadline := time.Now().Add(5 * time.Second)
		for time.Now().Before(deadline) {
			var got bool
			if err := d.Pool.QueryRow(ctx, `SELECT pg_try_advisory_lock($1)`, key).Scan(&got); err == nil && got {
				var released bool
				_ = d.Pool.QueryRow(ctx, `SELECT pg_advisory_unlock($1)`, key).Scan(&released)
				if advisoryLocksHeld(t, d) == 0 {
					return
				}
			}
			time.Sleep(50 * time.Millisecond)
		}
		t.Fatal("the job's advisory lock was not released")
	}
	jobs := maintenance.Jobs()
	counters := jobs[len(jobs)-1]

	t.Run("failure", func(t *testing.T) {
		mustExec(t, d.Pool, `INSERT INTO rate_limit_counters (key, window_start, count) VALUES ('old', now() - interval '3 days', 1)`)
		mustExec(t, d.Pool, `CREATE FUNCTION test_fail() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'forced'; END $$`)
		mustExec(t, d.Pool, `CREATE TRIGGER test_fail BEFORE DELETE ON rate_limit_counters FOR EACH ROW EXECUTE FUNCTION test_fail()`)
		defer mustExec(t, d.Pool, `DROP TRIGGER test_fail ON rate_limit_counters`)
		r := resultOf(t, newRunner(t, d, maintenance.Config{}).RunOnce(ctx), counters.Name)
		if !r.Ran || r.Err == nil || !strings.Contains(r.Err.Error(), "batch 1") {
			t.Fatalf("expected the job to fail: %+v", r)
		}
		freeAgain(t, counters.LockKey)
	})
	t.Run("cancellation mid-statement", func(t *testing.T) {
		mustExec(t, d.Pool, `CREATE FUNCTION test_hang() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN PERFORM pg_sleep(10); RETURN NULL; END $$`)
		mustExec(t, d.Pool, `CREATE TRIGGER test_hang AFTER UPDATE ON otp_challenges FOR EACH STATEMENT EXECUTE FUNCTION test_hang()`)
		defer mustExec(t, d.Pool, `DROP TRIGGER test_hang ON otp_challenges`)
		cctx, cancel := context.WithTimeout(ctx, 300*time.Millisecond)
		defer cancel()
		start := time.Now()
		results := newRunner(t, d, maintenance.Config{}).RunOnce(cctx)
		if time.Since(start) > 5*time.Second {
			t.Fatal("cancellation must interrupt the running statement")
		}
		if r := resultOf(t, results, jobs[0].Name); !r.Ran || r.Err == nil {
			t.Fatalf("expected the interrupted job to report an error: %+v", r)
		}
		freeAgain(t, jobs[0].LockKey)
	})
}
