//go:build integration

package integration

import (
	"context"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"
	"testing/fstest"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/migrate"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/pgtest"
	"github.com/0xkelvin/Veea-English-Notes/backend/migrations"
)

var cleanupIndexes = []string{
	"email_outbox_challenge", "email_outbox_finished", "otp_cooldowns_last_issued",
	"rate_limit_counters_window", "refresh_tokens_consumed_session", "sessions_absolute_expires",
	"sessions_revoked_at",
}

// migrationsUpTo is the embedded set limited to versions <= max, to reproduce an older schema.
func migrationsUpTo(t *testing.T, max int) fs.FS {
	t.Helper()
	files, err := fs.Glob(migrations.FS, "*.sql")
	if err != nil {
		t.Fatal(err)
	}
	out := fstest.MapFS{}
	for _, f := range files {
		v, err := strconv.Atoi(f[:5])
		if err != nil {
			t.Fatalf("migration %s has no numeric prefix", f)
		}
		if v <= max {
			raw, err := fs.ReadFile(migrations.FS, f)
			if err != nil {
				t.Fatal(err)
			}
			out[f] = &fstest.MapFile{Data: raw}
		}
	}
	return out
}

func indexesValid(t *testing.T, d *pgtest.DB, names []string) {
	t.Helper()
	for _, name := range names {
		if rowCount(t, d.Pool, `SELECT count(*) FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
			WHERE c.relname = $1 AND i.indisvalid AND i.indisready`, name) != 1 {
			t.Errorf("index %s is missing or not valid", name)
		}
	}
}

// Upgrade path: a database at version 6 with existing rows migrates to version 7, only 00007
// runs, the data is untouched, and every new index is valid.
func TestMigrations_UpgradeFromVersion6KeepsDataAndAddsIndexes(t *testing.T) {
	d := pgtest.NewEmpty(t)
	ctx := context.Background()
	res, err := migrate.Up(ctx, d.URL, migrationsUpTo(t, 6))
	if err != nil || res.Current != 6 {
		t.Fatalf("migrate to 6: %+v %v", res, err)
	}
	seedCleanupData(t, d, 500)
	before := tableCounts(t, d)

	res, err = migrate.Up(ctx, d.URL, migrationsUpTo(t, 7))
	if err != nil || res.Current != 7 || len(res.Applied) != 1 || res.Applied[0] != 7 {
		t.Fatalf("upgrade: %+v %v", res, err)
	}
	if after := tableCounts(t, d); after != before {
		t.Fatalf("row counts changed by the migration: %v -> %v", before, after)
	}
	indexesValid(t, d, cleanupIndexes)
	requireNames(t, publicNames(t, d,
		`SELECT indexname FROM pg_indexes WHERE schemaname = 'public' AND indexname NOT LIKE '%\_pkey'`), func() []string {
		var out []string
		for _, idx := range expectedIndexes {
			if !strings.HasPrefix(idx, "account_operations_") && !strings.HasPrefix(idx, "deletion_ledger_") && idx != "audit_events_retention" && idx != "erased_addresses_expires" && idx != "otp_challenges_user" && idx != "email_changes_expires" && idx != "email_changes_one_pending" && idx != "otp_challenges_change" && idx != "otp_challenges_change_open" && !strings.HasPrefix(idx, "learning_") && !strings.HasPrefix(idx, "vocabulary_items_") {
				out = append(out, idx)
			}
		}
		return out
	}())
}

// From an empty database every version applies in order and the new indexes are valid.
func TestMigrations_EmptyDatabaseGetsTheCleanupIndexes(t *testing.T) {
	d := pgtest.NewEmpty(t)
	if _, err := migrate.Up(context.Background(), d.URL, migrations.FS); err != nil {
		t.Fatal(err)
	}
	indexesValid(t, d, cleanupIndexes)
}

func tableCounts(t *testing.T, d *pgtest.DB) string {
	t.Helper()
	var b strings.Builder
	for _, table := range []string{"users", "sessions", "refresh_tokens_consumed", "otp_challenges", "otp_cooldowns", "email_outbox", "rate_limit_counters"} {
		b.WriteString(table + "=" + strconv.Itoa(rowCount(t, d.Pool, `SELECT count(*) FROM `+table)) + " ")
	}
	return b.String()
}

// seedCleanupData writes n rows per cleanup table, 10 % of them past their retention, shaped like
// a cleanup backlog: with n = 20,000 every table has 2,000 eligible rows, twice a batch, so the
// planner sees a batch that fills its LIMIT. Sessions have that many revoked and that many
// absolutely expired.
func seedCleanupData(t *testing.T, d *pgtest.DB, n int) {
	t.Helper()
	mustExec(t, d.Pool, `INSERT INTO users (id, email, email_normalized, email_verified_at)
		VALUES ('00000000-0000-7000-8000-000000000001', 'seed@example.test', 'seed@example.test', now())`)
	mustExec(t, d.Pool, `INSERT INTO sessions (id, user_id, auth_method, access_token_hash, access_expires_at,
		refresh_token_hash, refresh_expires_at, absolute_expires_at, device_name, platform, revoked_at, revoked_reason)
		SELECT gen_random_uuid(), '00000000-0000-7000-8000-000000000001', 'password',
		       decode(md5('a' || i), 'hex'), now() + interval '15 minutes',
		       decode(md5('r' || i), 'hex'), now() + interval '30 days',
		       CASE WHEN i % 10 = 0 THEN now() - interval '40 days' ELSE now() + interval '60 days' END,
		       'Seed', 'ios',
		       CASE WHEN i % 10 = 1 THEN now() - interval '40 days' END,
		       CASE WHEN i % 10 = 1 THEN 'logout' END
		FROM generate_series(1, $1) AS i`, n)
	mustExec(t, d.Pool, `INSERT INTO refresh_tokens_consumed (token_hash, session_id, consumed_at, retain_until)
		SELECT decode(md5('c' || i), 'hex'), (SELECT id FROM sessions ORDER BY id OFFSET (i % 50) LIMIT 1), now(),
		       CASE WHEN i % 10 = 0 THEN now() - interval '1 hour' ELSE now() + interval '1 day' END
		FROM generate_series(1, $1) AS i`, n)
	mustExec(t, d.Pool, `INSERT INTO otp_challenges (id, token_hash, purpose, signup_method, pending_password_hash,
		email, email_normalized, code_hash, delivery, max_attempts, expires_at)
		SELECT gen_random_uuid(), decode(md5('t' || i), 'hex'), 'signup', 'password', '$synthetic-pending-hash',
		       'c' || i || '@example.test', 'c' || i || '@example.test', decode(md5('h' || i), 'hex'), 'code', 5,
		       CASE WHEN i % 10 = 0 THEN now() - interval '2 days' ELSE now() + interval '1 hour' END
		FROM generate_series(1, $1) AS i`, n)
	mustExec(t, d.Pool, `INSERT INTO otp_cooldowns (purpose, email_hmac, last_issued_at)
		SELECT 'login', decode(md5('k' || i), 'hex'),
		       CASE WHEN i % 10 = 0 THEN now() - interval '2 days' ELSE now() - interval '1 hour' END
		FROM generate_series(1, $1) AS i`, n)
	mustExec(t, d.Pool, `INSERT INTO email_outbox (id, challenge_id, to_email, template, status, not_after, finished_at, send_attempts)
		SELECT gen_random_uuid(), CASE WHEN i % 4 = 0 THEN (SELECT id FROM otp_challenges ORDER BY id OFFSET (i % 50) LIMIT 1) END,
		       'seed@example.test', 'login_code', CASE WHEN i % 10 = 1 THEN 'pending' ELSE 'sent' END,
		       CASE WHEN i % 20 = 1 THEN now() - interval '1 minute' ELSE now() + interval '1 day' END,
		       CASE WHEN i % 10 = 1 THEN NULL WHEN i % 10 = 0 THEN now() - interval '8 days' ELSE now() - interval '1 hour' END,
		       CASE WHEN i % 20 = 11 THEN 5 ELSE 0 END
		FROM generate_series(1, $1) AS i`, n)
	mustExec(t, d.Pool, `INSERT INTO rate_limit_counters (key, window_start, count)
		SELECT 'seed:' || i, CASE WHEN i % 10 = 0 THEN now() - interval '3 days' ELSE now() - interval '1 hour' END, 1
		FROM generate_series(1, $1) AS i`, n)
	for _, table := range []string{"sessions", "refresh_tokens_consumed", "otp_challenges", "otp_cooldowns", "email_outbox", "rate_limit_counters"} {
		mustExec(t, d.Pool, `ANALYZE `+table)
	}
}

// querySQL returns a named query from internal/platform/db/queries, with sqlc's named
// parameters turned into $1, so the plans below are for the exact SQL the cleanup runs.
func querySQL(t *testing.T, file, name string) string {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("..", "..", "internal", "platform", "db", "queries", file))
	if err != nil {
		t.Fatal(err)
	}
	src := string(raw)
	i := strings.Index(src, "-- name: "+name+" ")
	if i < 0 {
		t.Fatalf("query %s not found in %s", name, file)
	}
	body := src[i:]
	body = body[strings.Index(body, "\n")+1:]
	if j := strings.Index(body, "\n-- name: "); j >= 0 {
		body = body[:j]
	}
	var lines []string
	for _, l := range strings.Split(body, "\n") {
		if !strings.HasPrefix(strings.TrimSpace(l), "--") {
			lines = append(lines, l)
		}
	}
	q := strings.TrimSuffix(strings.TrimSpace(strings.Join(lines, "\n")), ";")
	return regexp.MustCompile(`@[a-z_]+`).ReplaceAllString(q, "$$1")
}

// plan returns the text plan of query. EXPLAIN without ANALYZE does not run the statement.
func plan(t *testing.T, d *pgtest.DB, query string, args ...any) string {
	t.Helper()
	rows, err := d.Pool.Query(context.Background(), "EXPLAIN (FORMAT TEXT) "+query, args...)
	if err != nil {
		t.Fatalf("explain: %v\n%s", err, query)
	}
	defer rows.Close()
	var b strings.Builder
	for rows.Next() {
		var line string
		if err := rows.Scan(&line); err != nil {
			t.Fatal(err)
		}
		b.WriteString(line + "\n")
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	return b.String()
}

// EXPLAIN on representative data: each cleanup statement and each cascade lookup can use its
// index. On the version-6 schema the same statements are sequential scans.
func TestMigrations_CleanupQueriesUseTheirIndexes(t *testing.T) {
	cases := []struct {
		name, file, query string
		indexes           []string
		args              []any
	}{
		{"stale sessions", "sessions.sql", "DeleteStaleSessions", []string{"sessions_revoked_at", "sessions_absolute_expires", "Tid Scan"}, []any{1000}},
		{"old rate-limit windows", "ratelimit.sql", "DeleteOldRateLimitCounters", []string{"rate_limit_counters_window", "Tid Scan"}, []any{1000}},
		{"stale cooldowns", "otp.sql", "DeleteStaleOTPCooldowns", []string{"otp_cooldowns_last_issued", "Tid Scan"}, []any{1000}},
		{"finished outbox rows", "outbox.sql", "DeleteFinishedOutbox", []string{"email_outbox_finished", "Tid Scan"}, []any{1000}},
		{"expired challenges (existing index)", "otp.sql", "DeleteExpiredOTPChallenges", []string{"otp_challenges_expires", "Tid Scan"}, []any{1000}},
		{"expired consumed tokens (existing index)", "sessions.sql", "DeleteExpiredConsumedRefreshTokens", []string{"refresh_tokens_consumed_retain", "Tid Scan"}, []any{1000}},
		{"pending password scrub (existing index)", "otp.sql", "ClearExpiredPendingPasswordHashes", []string{"otp_challenges_expires"}, nil},
		{"outbox reaper (existing index)", "outbox.sql", "ReapOutbox", []string{"email_outbox_due"}, nil},
		// Either email_outbox_challenge or the pending-only email_outbox_due is a good plan here
		// (the planner picks by which is smaller); only a sequential scan would be wrong.
		{"cancel a challenge's email", "outbox.sql", "CancelPendingOutboxForChallenge", nil, []any{"00000000-0000-7000-8000-00000000abcd"}},
	}
	cascades := []struct{ name, query, index string }{
		{"session delete cascade", `DELETE FROM refresh_tokens_consumed WHERE session_id = $1`, "refresh_tokens_consumed_session"},
		{"challenge delete cascade", `DELETE FROM email_outbox WHERE challenge_id = $1`, "email_outbox_challenge"},
	}

	t.Run("version 7", func(t *testing.T) {
		d := pgtest.NewEmpty(t)
		if _, err := migrate.Up(context.Background(), d.URL, migrations.FS); err != nil {
			t.Fatal(err)
		}
		seedCleanupData(t, d, 20_000)
		for _, c := range cases {
			p := plan(t, d, querySQL(t, c.file, c.query), c.args...)
			for _, idx := range c.indexes {
				if !strings.Contains(p, idx) {
					t.Errorf("%s: the plan does not use %s:\n%s", c.name, idx, p)
				}
			}
			if strings.Contains(p, "Seq Scan") {
				t.Errorf("%s: the plan still has a sequential scan:\n%s", c.name, p)
			}
			if c.query == "DeleteExpiredOTPChallenges" && strings.Contains(p, "Sort") {
				t.Errorf("%s: the expiry index should also supply batch ordering:\n%s", c.name, p)
			}
			t.Logf("%s:\n%s", c.name, p)
		}
		for _, c := range cascades {
			p := plan(t, d, c.query, "00000000-0000-7000-8000-00000000abcd")
			if !strings.Contains(p, c.index) {
				t.Errorf("%s: the plan does not use %s:\n%s", c.name, c.index, p)
			}
			t.Logf("%s:\n%s", c.name, p)
		}
	})

	t.Run("version 6 for comparison", func(t *testing.T) {
		d := pgtest.NewEmpty(t)
		if _, err := migrate.Up(context.Background(), d.URL, migrationsUpTo(t, 6)); err != nil {
			t.Fatal(err)
		}
		seedCleanupData(t, d, 20_000)
		for _, c := range cases[:4] {
			p := plan(t, d, querySQL(t, c.file, c.query), c.args...)
			t.Logf("%s before 00007:\n%s", c.name, p)
			if !strings.Contains(p, "Seq Scan") {
				t.Errorf("%s: expected a sequential scan before 00007:\n%s", c.name, p)
			}
		}
	})
}
