//go:build integration

package integration

import (
	"context"
	"io/fs"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/db/sqlc"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/migrate"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/pgtest"
	"github.com/0xkelvin/Veea-English-Notes/backend/migrations"
)

var expectedTables = []string{
	"account_export_chunks", "account_operations", "apple_iap_control", "apple_pro_purchases", "audit_events", "cartridge_entries", "cartridge_installations", "cartridge_versions", "cartridges", "deletion_ledger", "email_changes", "email_outbox", "entitlement_grants", "erased_addresses",
	"learning_mutations", "learning_sync_control", "learning_sync_heads", "learning_sync_writers", "otp_challenges", "otp_cooldowns",
	"rate_limit_counters", "rbac_bootstrap", "refresh_tokens_consumed", "sessions", "users", "vocabulary_items",
}

var expectedIndexes = []string{ // sorted, as publicNames returns them; 00007 added the cleanup indexes
	"account_operations_expires", "account_operations_jobs", "account_operations_one_delete", "account_operations_owner", "account_operations_token_hash_key", "apple_pro_purchases_environment_transaction_id_key", "apple_pro_purchases_user", "audit_events_action", "audit_events_retention", "audit_events_target", "deletion_ledger_retain", "deletion_ledger_user_id_key", "email_changes_expires", "email_changes_one_pending", "email_outbox_challenge",
	"email_outbox_due", "email_outbox_finished", "entitlement_grants_one_open", "entitlement_grants_owner", "entitlement_grants_retention", "erased_addresses_expires", "learning_mutations_expiry", "learning_sync_writers_lru", "learning_sync_writers_retired", "otp_challenges_change", "otp_challenges_change_open", "otp_challenges_expires",
	"otp_challenges_one_open", "otp_challenges_token_hash_key", "otp_challenges_user", "otp_cooldowns_last_issued",
	"rate_limit_counters_window", "refresh_tokens_consumed_retain", "refresh_tokens_consumed_session",
	"sessions_absolute_expires", "sessions_access_token_hash_key", "sessions_refresh_token_hash_key",
	"sessions_revoked_at", "sessions_user_active", "users_active_super_admins", "users_admin_order", "users_email_normalized_key", "users_email_pattern", "vocabulary_items_feed", "vocabulary_items_tombstones",
}

// latestVersion is the number of the newest migration file.
const latestVersion = 16

func publicNames(t *testing.T, d *pgtest.DB, query string) []string {
	t.Helper()
	rows, err := d.Pool.Query(context.Background(), query)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var s string
		if err := rows.Scan(&s); err != nil {
			t.Fatal(err)
		}
		out = append(out, s)
	}
	sort.Strings(out)
	return out
}

func requireNames(t *testing.T, got, want []string) {
	t.Helper()
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Fatalf("got  %v\nwant %v", got, want)
	}
}

// --- Migrations ---------------------------------------------------------------------------

func TestMigrations_CleanDatabaseAppliesEveryVersion(t *testing.T) {
	d := pgtest.NewEmpty(t)
	ctx := context.Background()

	res, err := migrate.Up(ctx, d.URL, migrations.FS)
	if err != nil {
		t.Fatal(err)
	}
	if len(res.Applied) != latestVersion || res.Current != latestVersion {
		t.Fatalf("expected versions 1 to %d, got %+v", latestVersion, res)
	}
	for i, v := range res.Applied {
		if v != int64(i+1) {
			t.Fatalf("migrations applied out of order: %v", res.Applied)
		}
	}

	requireNames(t, publicNames(t, d,
		`SELECT tablename FROM pg_tables WHERE schemaname = 'public' AND tablename <> 'goose_db_version'`),
		expectedTables)
	requireNames(t, publicNames(t, d,
		`SELECT indexname FROM pg_indexes WHERE schemaname = 'public' AND indexname NOT LIKE '%\_pkey'`),
		expectedIndexes)
}

func TestMigrations_RepeatedRunIsANoOp(t *testing.T) {
	d := pgtest.NewEmpty(t)
	ctx := context.Background()
	if _, err := migrate.Up(ctx, d.URL, migrations.FS); err != nil {
		t.Fatal(err)
	}
	res, err := migrate.Up(ctx, d.URL, migrations.FS)
	if err != nil || len(res.Applied) != 0 || res.Current != latestVersion {
		t.Fatalf("second run: %+v %v", res, err)
	}
	st, err := migrate.Status(ctx, d.URL, migrations.FS)
	if err != nil || st.Pending != 0 || st.Current != latestVersion {
		t.Fatalf("status: %+v %v", st, err)
	}
}

// Every statement must use IF NOT EXISTS (TRD 6.1), so replaying a file against an
// already-migrated database must not fail.
func TestMigrations_StatementsAreReplayable(t *testing.T) {
	d, _ := migratedDB(t)
	files, err := fs.Glob(migrations.FS, "*.sql")
	if err != nil || len(files) != latestVersion {
		t.Fatalf("expected %d migration files, got %v %v", latestVersion, files, err)
	}
	for _, f := range files {
		raw, err := fs.ReadFile(migrations.FS, f)
		if err != nil {
			t.Fatal(err)
		}
		var sql []string
		for _, line := range strings.Split(string(raw), "\n") {
			if !strings.HasPrefix(strings.TrimSpace(line), "-- +goose") {
				sql = append(sql, line)
			}
		}
		// No arguments, so pgx uses the simple protocol and runs the whole file.
		if _, err := d.Pool.Exec(context.Background(), strings.Join(sql, "\n")); err != nil {
			t.Errorf("%s is not replayable: %v", f, err)
		}
	}
}

func TestMigrations_AreUpOnlyAndOrdered(t *testing.T) {
	files, _ := fs.Glob(migrations.FS, "*.sql")
	want := []string{"00001_users.sql", "00002_otp.sql", "00003_sessions.sql",
		"00004_email_outbox.sql", "00005_audit_events.sql", "00006_rate_limit_counters.sql",
		"00007_cleanup_indexes.sql", "00008_session_management.sql", "00009_account_profile_email_change.sql", "00010_account_lifecycle.sql", "00011_learning_sync.sql", "00012_rbac_admin.sql", "00013_rbac_bootstrap_marker.sql", "00014_entitlements.sql", "00015_cartridges.sql", "00016_apple_pro_purchases.sql"}
	requireNames(t, files, want)
	for _, f := range files {
		raw, _ := fs.ReadFile(migrations.FS, f)
		if strings.Contains(string(raw), "+goose Down") {
			t.Errorf("%s has a Down section; migrations are up-only", f)
		}
		if !strings.Contains(string(raw), "+goose Up") {
			t.Errorf("%s has no Up annotation", f)
		}
	}
}

func TestMigrations_TemplateCloneHasSchema(t *testing.T) {
	d, _ := migratedDB(t)
	requireNames(t, publicNames(t, d,
		`SELECT tablename FROM pg_tables WHERE schemaname = 'public' AND tablename <> 'goose_db_version'`),
		expectedTables)
}

// --- users --------------------------------------------------------------------------------

func TestSchema_Users(t *testing.T) {
	d, q := migratedDB(t)
	ctx := context.Background()
	u := newUser(t, q)

	t.Run("normalized email is unique", func(t *testing.T) {
		_, err := d.Pool.Exec(ctx, `INSERT INTO users (id, email, email_normalized) VALUES ($1, 'x', $2)`,
			newID(), u.EmailNormalized)
		wantPgError(t, err, pgUnique, "users_email_normalized_key")
	})
	t.Run("defaults", func(t *testing.T) {
		if u.Status != "active" || u.Role != "user" || u.PasswordHash != nil || u.PasswordChangedAt != nil {
			t.Fatalf("unexpected defaults: %+v", u)
		}
	})
	t.Run("status and role are restricted", func(t *testing.T) {
		_, err := d.Pool.Exec(ctx, `INSERT INTO users (id, email, email_normalized, status) VALUES ($1, 'a', 'a', 'banned')`, newID())
		wantPgError(t, err, pgCheck, "users_status_check")
		_, err = d.Pool.Exec(ctx, `INSERT INTO users (id, email, email_normalized, role) VALUES ($1, 'b', 'b', 'root')`, newID())
		wantPgError(t, err, pgCheck, "users_role_check")
	})
	t.Run("normalized email is limited to 254 octets", func(t *testing.T) {
		_, err := d.Pool.Exec(ctx, `INSERT INTO users (id, email, email_normalized) VALUES ($1, 'c', $2)`,
			newID(), strings.Repeat("a", 255))
		wantPgError(t, err, pgCheck, "users_email_len")
		mustExec(t, d.Pool, `INSERT INTO users (id, email, email_normalized) VALUES ($1, 'c', $2)`,
			newID(), strings.Repeat("a", 254))
	})
	t.Run("email columns are required", func(t *testing.T) {
		_, err := d.Pool.Exec(ctx, `INSERT INTO users (id, email) VALUES ($1, 'd')`, newID())
		wantPgError(t, err, pgNotNull, "")
	})
}

// --- otp_challenges and otp_cooldowns -----------------------------------------------------

func TestSchema_OTPChallenges(t *testing.T) {
	d, q := migratedDB(t)
	ctx := context.Background()
	u := newUser(t, q)

	insert := func(p sqlc.InsertOTPChallengeParams) error {
		_, err := q.InsertOTPChallenge(ctx, p)
		return err
	}

	t.Run("token hash is unique", func(t *testing.T) {
		a := challengeParams("login", "dup-token@example.test", "code")
		a.UserID = &u.ID
		newChallenge(t, q, a)
		b := challengeParams("login", "dup-token-2@example.test", "code")
		b.TokenHash = a.TokenHash
		wantPgError(t, insert(b), pgUnique, "otp_challenges_token_hash_key")
	})
	t.Run("purpose and delivery are restricted", func(t *testing.T) {
		wantPgError(t, insert(challengeParams("magic", "p1@example.test", "code")), pgCheck, "otp_challenges_purpose_check")
		wantPgError(t, insert(challengeParams("login", "p2@example.test", "sms")), pgCheck, "otp_challenges_delivery_check")
	})
	t.Run("signup_method is required exactly for signup", func(t *testing.T) {
		p := challengeParams("signup", "m1@example.test", "code")
		p.SignupMethod = nil
		wantPgError(t, insert(p), pgCheck, "otp_signup_method")
		p = challengeParams("login", "m2@example.test", "code")
		p.SignupMethod = ptr("otp")
		wantPgError(t, insert(p), pgCheck, "otp_signup_method")
		p = challengeParams("signup", "m3@example.test", "code")
		p.SignupMethod = ptr("email")
		wantPgError(t, insert(p), pgCheck, "otp_challenges_signup_method_check")
	})
	t.Run("pending password hash only for password signups", func(t *testing.T) {
		// Password signup may hold one.
		ok := challengeParams("signup", "h1@example.test", "code")
		ok.SignupMethod, ok.PendingPasswordHash = ptr("password"), ptr("$argon2id$pending")
		newChallenge(t, q, ok)
		// OTP signup may not.
		bad := challengeParams("signup", "h2@example.test", "code")
		bad.PendingPasswordHash = ptr("$argon2id$pending")
		wantPgError(t, insert(bad), pgCheck, "otp_pending_pw")
		// A non-signup purpose has a NULL signup_method. The TRD wording of this check
		// (signup_method = 'password') is NULL there and would let the row through.
		bad = challengeParams("login", "h3@example.test", "code")
		bad.UserID, bad.PendingPasswordHash = &u.ID, ptr("$argon2id$pending")
		wantPgError(t, insert(bad), pgCheck, "otp_pending_pw")
	})
	t.Run("delivery none is inert", func(t *testing.T) {
		// A plain ineligible challenge is fine.
		newChallenge(t, q, challengeParams("login", "n0@example.test", "none"))

		consumed := challengeParams("login", "n1@example.test", "none")
		c := newChallenge(t, q, consumed)
		_, err := q.ConsumeOTPChallenge(ctx, c.ID)
		wantPgError(t, err, pgCheck, "otp_none_inert")

		bound := challengeParams("login", "n2@example.test", "none")
		bound.UserID = &u.ID
		wantPgError(t, insert(bound), pgCheck, "otp_none_inert")

		withSession := challengeParams("set_password", "n3@example.test", "none")
		withSession.SessionID = ptr(newID())
		wantPgError(t, insert(withSession), pgCheck, "otp_none_inert")

		withHash := challengeParams("signup", "n4@example.test", "none")
		withHash.SignupMethod, withHash.PendingPasswordHash = ptr("password"), ptr("$argon2id$pending")
		wantPgError(t, insert(withHash), pgCheck, "otp_none_inert")
	})
	t.Run("one open challenge per purpose and email", func(t *testing.T) {
		const email = "open@example.test"
		first := newChallenge(t, q, challengeParams("signup", email, "code"))
		wantPgError(t, insert(challengeParams("signup", email, "code")), pgUnique, "otp_challenges_one_open")

		// Another purpose, or another email, is independent.
		other := challengeParams("password_reset", email, "code")
		other.UserID = &u.ID
		newChallenge(t, q, other)
		newChallenge(t, q, challengeParams("signup", "open-2@example.test", "code"))

		// Superseding frees the slot, and so does consuming.
		if ids, err := q.SupersedeOpenOTPChallenges(ctx, sqlc.SupersedeOpenOTPChallengesParams{
			Purpose: "signup", EmailNormalized: email}); err != nil || len(ids) != 1 || ids[0] != first.ID {
			t.Fatalf("supersede: %v %v", ids, err)
		}
		second := newChallenge(t, q, challengeParams("signup", email, "code"))
		if n, err := q.ConsumeOTPChallenge(ctx, second.ID); err != nil || n != 1 {
			t.Fatalf("consume: %d %v", n, err)
		}
		newChallenge(t, q, challengeParams("signup", email, "code"))
	})
	t.Run("deleting the user deletes its challenges", func(t *testing.T) {
		v := newUser(t, q)
		p := challengeParams("login", "cascade@example.test", "code")
		p.UserID = &v.ID
		newChallenge(t, q, p)
		mustExec(t, d.Pool, `DELETE FROM users WHERE id = $1`, v.ID)
		if n := rowCount(t, d.Pool, `SELECT count(*) FROM otp_challenges WHERE id = $1`, p.ID); n != 0 {
			t.Fatalf("challenge survived its user: %d", n)
		}
	})
	t.Run("session_id has no foreign key", func(t *testing.T) {
		p := challengeParams("set_password", "nofk@example.test", "code")
		p.UserID, p.SessionID = &u.ID, ptr(newID())
		newChallenge(t, q, p)
	})
}

func TestSchema_OTPCooldownsPrimaryKey(t *testing.T) {
	d, _ := migratedDB(t)
	ctx := context.Background()
	mustExec(t, d.Pool, `INSERT INTO otp_cooldowns VALUES ('signup', '\x01', now())`)
	_, err := d.Pool.Exec(ctx, `INSERT INTO otp_cooldowns VALUES ('signup', '\x01', now())`)
	wantPgError(t, err, pgUnique, "otp_cooldowns_pkey")
	mustExec(t, d.Pool, `INSERT INTO otp_cooldowns VALUES ('login', '\x01', now())`)
}

// --- sessions and refresh_tokens_consumed -------------------------------------------------

func TestSchema_Sessions(t *testing.T) {
	d, q := migratedDB(t)
	ctx := context.Background()
	u := newUser(t, q)
	insert := func(mod func(*sqlc.InsertSessionParams)) error {
		p := sessionParams(u.ID)
		if mod != nil {
			mod(&p)
		}
		_, err := q.InsertSession(ctx, p)
		return err
	}

	t.Run("token hashes are unique", func(t *testing.T) {
		s := newSession(t, q, u.ID)
		wantPgError(t, insert(func(p *sqlc.InsertSessionParams) { p.AccessTokenHash = s.AccessTokenHash }),
			pgUnique, "sessions_access_token_hash_key")
		wantPgError(t, insert(func(p *sqlc.InsertSessionParams) { p.RefreshTokenHash = s.RefreshTokenHash }),
			pgUnique, "sessions_refresh_token_hash_key")
	})
	t.Run("restricted columns", func(t *testing.T) {
		wantPgError(t, insert(func(p *sqlc.InsertSessionParams) { p.AuthMethod = "magic" }), pgCheck, "sessions_auth_method_check")
		wantPgError(t, insert(func(p *sqlc.InsertSessionParams) { p.Platform = "toaster" }), pgCheck, "sessions_platform_check")
	})
	t.Run("device name is 1 to 64 characters", func(t *testing.T) {
		wantPgError(t, insert(func(p *sqlc.InsertSessionParams) { p.DeviceName = "" }), pgCheck, "sessions_device_name_check")
		wantPgError(t, insert(func(p *sqlc.InsertSessionParams) { p.DeviceName = strings.Repeat("d", 65) }), pgCheck, "sessions_device_name_check")
		if err := insert(func(p *sqlc.InsertSessionParams) { p.DeviceName = strings.Repeat("d", 64) }); err != nil {
			t.Fatal(err)
		}
	})
	t.Run("revoked_reason is restricted", func(t *testing.T) {
		s := newSession(t, q, u.ID)
		_, err := d.Pool.Exec(ctx, `UPDATE sessions SET revoked_at = now(), revoked_reason = 'bored' WHERE id = $1`, s.ID)
		wantPgError(t, err, pgCheck, "sessions_revoked_reason_check")
		for _, reason := range []string{"logout", "password_set", "password_change", "password_reset",
			"refresh_reuse", "session_limit", "account_inactive", "user_revoked", "logout_all"} {
			s := newSession(t, q, u.ID)
			mustExec(t, d.Pool, `UPDATE sessions SET revoked_at = now(), revoked_reason = $2 WHERE id = $1`, s.ID, reason)
		}
	})
	t.Run("a session needs an existing user", func(t *testing.T) {
		wantPgError(t, insert(func(p *sqlc.InsertSessionParams) { p.UserID = newID() }), pgForeignKey, "sessions_user_id_fkey")
	})
	t.Run("defaults", func(t *testing.T) {
		s := newSession(t, q, u.ID)
		if s.RotationCounter != 0 || s.RevokedAt != nil {
			t.Fatalf("unexpected defaults: %+v", s)
		}
	})
}

func TestSchema_ConsumedRefreshTokens(t *testing.T) {
	d, q := migratedDB(t)
	ctx := context.Background()
	u := newUser(t, q)
	s := newSession(t, q, u.ID)

	if err := q.InsertConsumedRefreshToken(ctx, sqlc.InsertConsumedRefreshTokenParams{
		TokenHash: []byte("old-1"), SessionID: s.ID, RetainUntil: time.Now().Add(time.Hour)}); err != nil {
		t.Fatal(err)
	}
	err := q.InsertConsumedRefreshToken(ctx, sqlc.InsertConsumedRefreshTokenParams{
		TokenHash: []byte("old-1"), SessionID: s.ID, RetainUntil: time.Now().Add(time.Hour)})
	wantPgError(t, err, pgUnique, "refresh_tokens_consumed_pkey")

	err = q.InsertConsumedRefreshToken(ctx, sqlc.InsertConsumedRefreshTokenParams{
		TokenHash: []byte("old-2"), SessionID: newID(), RetainUntil: time.Now().Add(time.Hour)})
	wantPgError(t, err, pgForeignKey, "refresh_tokens_consumed_session_id_fkey")

	// Deleting the user deletes its sessions and their consumed tokens.
	mustExec(t, d.Pool, `DELETE FROM users WHERE id = $1`, u.ID)
	if n := rowCount(t, d.Pool, `SELECT count(*) FROM refresh_tokens_consumed`); n != 0 {
		t.Fatalf("consumed tokens survived the user: %d", n)
	}
}

// --- email_outbox -------------------------------------------------------------------------

func outboxParams() sqlc.InsertOutboxEmailParams {
	return sqlc.InsertOutboxEmailParams{
		ID: newID(), ToEmail: "someone@example.test", Template: "login_code",
		PayloadCiphertext: []byte("ciphertext"), PayloadKeyID: ptr(int16(1)), NotAfter: ptr(time.Now().Add(10 * time.Minute)),
	}
}

func TestSchema_EmailOutbox(t *testing.T) {
	d, q := migratedDB(t)
	ctx := context.Background()
	u := newUser(t, q)

	t.Run("defaults", func(t *testing.T) {
		row, err := q.InsertOutboxEmail(ctx, outboxParams())
		if err != nil {
			t.Fatal(err)
		}
		if row.Status != "pending" || row.SendAttempts != 0 || row.LeaseToken != nil {
			t.Fatalf("unexpected defaults: %+v", row)
		}
	})
	t.Run("template and status are restricted", func(t *testing.T) {
		p := outboxParams()
		p.Template = "spam"
		_, err := q.InsertOutboxEmail(ctx, p)
		wantPgError(t, err, pgCheck, "email_outbox_template_check")
		row, _ := q.InsertOutboxEmail(ctx, outboxParams())
		_, err = d.Pool.Exec(ctx, `UPDATE email_outbox SET status = 'lost' WHERE id = $1`, row.ID)
		wantPgError(t, err, pgCheck, "email_outbox_status_check")
	})
	t.Run("send budget is capped at five", func(t *testing.T) {
		row, _ := q.InsertOutboxEmail(ctx, outboxParams())
		mustExec(t, d.Pool, `UPDATE email_outbox SET send_attempts = 5 WHERE id = $1`, row.ID)
		_, err := d.Pool.Exec(ctx, `UPDATE email_outbox SET send_attempts = 6 WHERE id = $1`, row.ID)
		wantPgError(t, err, pgCheck, "email_outbox_send_attempts_check")
		_, err = d.Pool.Exec(ctx, `UPDATE email_outbox SET send_attempts = -1 WHERE id = $1`, row.ID)
		wantPgError(t, err, pgCheck, "email_outbox_send_attempts_check")
	})
	t.Run("only pending rows may keep a payload", func(t *testing.T) {
		row, _ := q.InsertOutboxEmail(ctx, outboxParams())
		for _, status := range []string{"sent", "failed", "expired", "cancelled"} {
			_, err := d.Pool.Exec(ctx, `UPDATE email_outbox SET status = $2 WHERE id = $1`, row.ID, status)
			wantPgError(t, err, pgCheck, "outbox_payload_only_pending")
		}
		// Terminalizing and scrubbing in one statement is what the worker does.
		mustExec(t, d.Pool, `UPDATE email_outbox SET status = 'sent', payload_ciphertext = NULL WHERE id = $1`, row.ID)
		// A non-pending row cannot be given a payload back.
		_, err := d.Pool.Exec(ctx, `UPDATE email_outbox SET payload_ciphertext = '\x01' WHERE id = $1`, row.ID)
		wantPgError(t, err, pgCheck, "outbox_payload_only_pending")
	})
	t.Run("not_after is required", func(t *testing.T) {
		_, err := d.Pool.Exec(ctx, `INSERT INTO email_outbox (id, to_email, template) VALUES ($1, 'x@example.test', 'login_code')`, newID())
		wantPgError(t, err, pgNotNull, "")
	})
	t.Run("rows follow their challenge and user", func(t *testing.T) {
		c := challengeParams("login", "outbox-cascade@example.test", "code")
		c.UserID = &u.ID
		newChallenge(t, q, c)
		p := outboxParams()
		p.UserID, p.ChallengeID = &u.ID, &c.ID
		if _, err := q.InsertOutboxEmail(ctx, p); err != nil {
			t.Fatal(err)
		}
		mustExec(t, d.Pool, `DELETE FROM otp_challenges WHERE id = $1`, c.ID)
		if n := rowCount(t, d.Pool, `SELECT count(*) FROM email_outbox WHERE id = $1`, p.ID); n != 0 {
			t.Fatalf("outbox row survived its challenge: %d", n)
		}

		p = outboxParams()
		p.UserID = &u.ID
		if _, err := q.InsertOutboxEmail(ctx, p); err != nil {
			t.Fatal(err)
		}
		mustExec(t, d.Pool, `DELETE FROM users WHERE id = $1`, u.ID)
		if n := rowCount(t, d.Pool, `SELECT count(*) FROM email_outbox WHERE id = $1`, p.ID); n != 0 {
			t.Fatalf("outbox row survived its user: %d", n)
		}
	})
	t.Run("unknown references are rejected", func(t *testing.T) {
		p := outboxParams()
		p.ChallengeID = ptr(uuid.New())
		_, err := q.InsertOutboxEmail(ctx, p)
		wantPgError(t, err, pgForeignKey, "email_outbox_challenge_id_fkey")
	})
}

// --- audit_events and rate_limit_counters -------------------------------------------------

func TestSchema_AuditEvents(t *testing.T) {
	d, q := migratedDB(t)
	ctx := context.Background()
	u := newUser(t, q)

	if err := q.InsertAuditEvent(ctx, sqlc.InsertAuditEventParams{
		Action: "auth.password.change", Outcome: "success", TargetUserID: &u.ID, ActorUserID: &u.ID,
		Metadata: []byte(`{"count":1}`)}); err != nil {
		t.Fatal(err)
	}
	err := q.InsertAuditEvent(ctx, sqlc.InsertAuditEventParams{Action: "x", Outcome: "maybe", Metadata: []byte(`{}`)})
	wantPgError(t, err, pgCheck, "audit_events_outcome_check")
	err = q.InsertAuditEvent(ctx, sqlc.InsertAuditEventParams{Action: "x", Outcome: "success", Metadata: []byte(`not json`)})
	if err == nil {
		t.Fatal("invalid JSON metadata was accepted")
	}

	// Identifiers are not foreign keys: events for unknown users are fine and the trail
	// outlives the user.
	if err := q.InsertAuditEvent(ctx, sqlc.InsertAuditEventParams{
		Action: "auth.otp.verify", Outcome: "failure", TargetUserID: ptr(newID()), Metadata: []byte(`{}`)}); err != nil {
		t.Fatal(err)
	}
	mustExec(t, d.Pool, `DELETE FROM users WHERE id = $1`, u.ID)
	events, err := q.ListAuditEventsForTarget(ctx, sqlc.ListAuditEventsForTargetParams{TargetUserID: &u.ID, RowLimit: 10})
	if err != nil || len(events) != 1 {
		t.Fatalf("audit trail did not outlive the user: %d %v", len(events), err)
	}
	if _, err := d.Pool.Exec(ctx, `UPDATE audit_events SET id = 1 WHERE id = $1`, events[0].ID); err == nil {
		t.Fatal("identity column accepted a manual value")
	}
}

func TestSchema_RateLimitCountersPrimaryKey(t *testing.T) {
	d, _ := migratedDB(t)
	mustExec(t, d.Pool, `INSERT INTO rate_limit_counters VALUES ('k', '2026-01-01T00:00:00Z', 1)`)
	_, err := d.Pool.Exec(context.Background(), `INSERT INTO rate_limit_counters VALUES ('k', '2026-01-01T00:00:00Z', 1)`)
	wantPgError(t, err, pgUnique, "rate_limit_counters_pkey")
	mustExec(t, d.Pool, `INSERT INTO rate_limit_counters VALUES ('k', '2026-01-01T01:00:00Z', 1)`)
}
