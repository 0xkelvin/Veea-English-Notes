//go:build integration

package integration

import (
	"context"
	"errors"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/db/sqlc"
)

func isNoRows(err error) bool { return errors.Is(err, pgx.ErrNoRows) }

// --- identity -----------------------------------------------------------------------------

func TestQuery_InsertUserIfAbsentNeverOverwrites(t *testing.T) {
	d, q := migratedDB(t)
	ctx := context.Background()
	now := time.Now()

	first, err := q.InsertUserIfAbsent(ctx, sqlc.InsertUserIfAbsentParams{
		ID: newID(), Email: "A@Example.test", EmailNormalized: "a@example.test",
		EmailVerifiedAt: &now, PasswordHash: ptr("$argon2id$first"), PasswordChangedAt: &now})
	if err != nil {
		t.Fatal(err)
	}
	_, err = q.InsertUserIfAbsent(ctx, sqlc.InsertUserIfAbsentParams{
		ID: newID(), Email: "a@example.test", EmailNormalized: "a@example.test",
		EmailVerifiedAt: &now, PasswordHash: ptr("$argon2id$attacker")})
	if !isNoRows(err) {
		t.Fatalf("duplicate signup must return no row, got %v", err)
	}
	got, err := q.GetUserByEmailNormalized(ctx, "a@example.test")
	if err != nil || got.ID != first.ID || *got.PasswordHash != "$argon2id$first" || !got.UpdatedAt.Equal(first.UpdatedAt) {
		t.Fatalf("existing account was modified: %+v %v", got, err)
	}
	if n := rowCount(t, d.Pool, `SELECT count(*) FROM users`); n != 1 {
		t.Fatalf("users = %d", n)
	}
}

func TestQuery_InsertUserIfAbsentConcurrent(t *testing.T) {
	d, _ := migratedDB(t)
	var wins atomic.Int32
	var wg sync.WaitGroup
	for i := 0; i < 12; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			now := time.Now()
			tx, q := inTx(t, d.Pool)
			_, err := q.InsertUserIfAbsent(context.Background(), sqlc.InsertUserIfAbsentParams{
				ID: newID(), Email: "race@example.test", EmailNormalized: "race@example.test", EmailVerifiedAt: &now})
			if err == nil {
				wins.Add(1)
			} else if !isNoRows(err) {
				t.Error(err)
			}
			_ = tx.Commit(context.Background())
		}()
	}
	wg.Wait()
	if wins.Load() != 1 || rowCount(t, d.Pool, `SELECT count(*) FROM users`) != 1 {
		t.Fatalf("exactly one signup must win, wins=%d", wins.Load())
	}
}

func TestQuery_UserPasswordWrites(t *testing.T) {
	_, q := migratedDB(t)
	ctx := context.Background()
	u := newUser(t, q)

	if n, err := q.SetUserPassword(ctx, sqlc.SetUserPasswordParams{ID: u.ID, PasswordHash: ptr("$h1")}); err != nil || n != 1 {
		t.Fatalf("set: %d %v", n, err)
	}
	got, _ := q.GetUserByID(ctx, u.ID)
	if *got.PasswordHash != "$h1" || got.PasswordChangedAt == nil {
		t.Fatalf("set did not write: %+v", got)
	}
	changedAt := *got.PasswordChangedAt

	// Rehash is compare-and-set and leaves password_changed_at alone.
	if n, _ := q.RehashUserPassword(ctx, sqlc.RehashUserPasswordParams{ID: u.ID, OldHash: ptr("$stale"), NewHash: ptr("$h2")}); n != 0 {
		t.Fatalf("rehash with a stale hash must not write, n=%d", n)
	}
	if n, _ := q.RehashUserPassword(ctx, sqlc.RehashUserPasswordParams{ID: u.ID, OldHash: ptr("$h1"), NewHash: ptr("$h2")}); n != 1 {
		t.Fatalf("rehash n=%d", n)
	}
	got, _ = q.GetUserByID(ctx, u.ID)
	if *got.PasswordHash != "$h2" || !got.PasswordChangedAt.Equal(changedAt) {
		t.Fatalf("rehash changed the wrong fields: %+v", got)
	}
}

func TestQuery_LockUserForNoKeyUpdateDoesNotBlockForeignKeyInserts(t *testing.T) {
	d, q := migratedDB(t)
	ctx := context.Background()
	u := newUser(t, q)

	tx, tq := inTx(t, d.Pool)
	if _, err := tq.LockUserForNoKeyUpdate(ctx, u.ID); err != nil {
		t.Fatal(err)
	}
	// TRD 7.1: inserts that reference the locked user (session, outbox, challenge) proceed.
	done := make(chan error, 1)
	go func() {
		c, cancel := context.WithTimeout(ctx, 3*time.Second)
		defer cancel()
		_, err := q.InsertSession(c, sessionParams(u.ID))
		done <- err
	}()
	if err := <-done; err != nil {
		t.Fatalf("session insert was blocked by FOR NO KEY UPDATE: %v", err)
	}

	// A second locker does wait for the first.
	second := make(chan struct{})
	go func() {
		tx2, q2 := inTx(t, d.Pool)
		_, _ = q2.LockUserForNoKeyUpdate(ctx, u.ID)
		_ = tx2.Rollback(ctx)
		close(second)
	}()
	select {
	case <-second:
		t.Fatal("second FOR NO KEY UPDATE did not wait")
	case <-time.After(300 * time.Millisecond):
	}
	_ = tx.Commit(ctx)
	select {
	case <-second:
	case <-time.After(3 * time.Second):
		t.Fatal("second locker never proceeded")
	}
}

// --- otp ----------------------------------------------------------------------------------

func TestQuery_ClaimOTPCooldown(t *testing.T) {
	d, q := migratedDB(t)
	ctx := context.Background()
	arg := sqlc.ClaimOTPCooldownParams{Purpose: "login", EmailHmac: []byte("hmac-1"), CooldownSeconds: 60}

	if _, err := q.ClaimOTPCooldown(ctx, arg); err != nil {
		t.Fatalf("first claim: %v", err)
	}
	if _, err := q.ClaimOTPCooldown(ctx, arg); !isNoRows(err) {
		t.Fatalf("claim inside the cooldown must return no row, got %v", err)
	}
	other := arg
	other.Purpose = "password_reset"
	if _, err := q.ClaimOTPCooldown(ctx, other); err != nil {
		t.Fatalf("another purpose is independent: %v", err)
	}
	mustExec(t, d.Pool, `UPDATE otp_cooldowns SET last_issued_at = now() - interval '61 seconds' WHERE purpose = 'login'`)
	if _, err := q.ClaimOTPCooldown(ctx, arg); err != nil {
		t.Fatalf("claim after the cooldown: %v", err)
	}
}

func TestQuery_ClaimOTPCooldownConcurrentFirstIssuance(t *testing.T) {
	d, _ := migratedDB(t)
	var wins atomic.Int32
	var wg sync.WaitGroup
	start := make(chan struct{})
	for i := 0; i < 20; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-start
			tx, q := inTx(t, d.Pool)
			_, err := q.ClaimOTPCooldown(context.Background(), sqlc.ClaimOTPCooldownParams{
				Purpose: "signup", EmailHmac: []byte("new-email"), CooldownSeconds: 60})
			switch {
			case err == nil:
				wins.Add(1)
			case !isNoRows(err):
				t.Error(err)
			}
			_ = tx.Commit(context.Background())
		}()
	}
	close(start)
	wg.Wait()
	if wins.Load() != 1 {
		t.Fatalf("exactly one concurrent first claim must win, got %d", wins.Load())
	}
}

func TestQuery_ChallengeAttemptsAndConsume(t *testing.T) {
	_, q := migratedDB(t)
	ctx := context.Background()

	p := challengeParams("signup", "attempts@example.test", "code")
	p.SignupMethod, p.PendingPasswordHash = ptr("password"), ptr("$argon2id$pending")
	c := newChallenge(t, q, p)

	locked, err := q.LockOTPChallengeByTokenHash(ctx, c.TokenHash)
	if err != nil || locked.ID != c.ID || locked.Attempts != 0 {
		t.Fatalf("lock: %+v %v", locked, err)
	}
	if _, err := q.LockOTPChallengeByTokenHash(ctx, []byte("unknown")); !isNoRows(err) {
		t.Fatalf("unknown token: %v", err)
	}
	for i := 1; i <= 2; i++ {
		if n, err := q.IncrementOTPChallengeAttempts(ctx, c.ID); err != nil || n != 1 {
			t.Fatal(n, err)
		}
	}
	if n, _ := q.ConsumeOTPChallenge(ctx, c.ID); n != 1 {
		t.Fatalf("consume n=%d", n)
	}
	if n, _ := q.ConsumeOTPChallenge(ctx, c.ID); n != 0 {
		t.Fatalf("a challenge must be consumable once, n=%d", n)
	}
	got, _ := q.LockOTPChallengeByTokenHash(ctx, c.TokenHash)
	if got.Attempts != 2 || got.ConsumedAt == nil || got.PendingPasswordHash != nil {
		t.Fatalf("unexpected state after consume: %+v", got)
	}
}

func TestQuery_SupersedeDropsPendingPasswordHash(t *testing.T) {
	d, q := migratedDB(t)
	p := challengeParams("signup", "supersede@example.test", "code")
	p.SignupMethod, p.PendingPasswordHash = ptr("password"), ptr("$argon2id$pending")
	c := newChallenge(t, q, p)
	if ids, err := q.SupersedeOpenOTPChallenges(context.Background(), sqlc.SupersedeOpenOTPChallengesParams{
		Purpose: "signup", EmailNormalized: "supersede@example.test"}); err != nil || len(ids) != 1 {
		t.Fatalf("%v %v", ids, err)
	}
	if n := rowCount(t, d.Pool, `SELECT count(*) FROM otp_challenges WHERE id = $1 AND pending_password_hash IS NULL AND superseded_at IS NOT NULL`, c.ID); n != 1 {
		t.Fatal("pending hash survived supersession")
	}
}

func TestQuery_OTPCleanup(t *testing.T) {
	d, q := migratedDB(t)
	ctx := context.Background()
	p := challengeParams("signup", "cleanup@example.test", "code")
	p.SignupMethod, p.PendingPasswordHash = ptr("password"), ptr("$argon2id$pending")
	c := newChallenge(t, q, p)

	mustExec(t, d.Pool, `UPDATE otp_challenges SET expires_at = now() - interval '1 minute' WHERE id = $1`, c.ID)
	if n, _ := q.ClearExpiredPendingPasswordHashes(ctx); n != 1 {
		t.Fatalf("clear n=%d", n)
	}
	if n, _ := q.DeleteExpiredOTPChallenges(ctx, 1000); n != 0 {
		t.Fatalf("a challenge must live 24 h past expiry, deleted %d", n)
	}
	mustExec(t, d.Pool, `UPDATE otp_challenges SET expires_at = now() - interval '25 hours' WHERE id = $1`, c.ID)
	if n, _ := q.DeleteExpiredOTPChallenges(ctx, 1000); n != 1 {
		t.Fatalf("delete n=%d", n)
	}
	mustExec(t, d.Pool, `INSERT INTO otp_cooldowns VALUES ('signup', '\x01', now() - interval '25 hours')`)
	if n, _ := q.DeleteStaleOTPCooldowns(ctx, 1000); n != 1 {
		t.Fatalf("cooldown cleanup n=%d", n)
	}
}

// --- sessions -----------------------------------------------------------------------------

func TestQuery_AuthenticateAccessToken(t *testing.T) {
	d, q := migratedDB(t)
	ctx := context.Background()
	u := newUser(t, q)
	s := newSession(t, q, u.ID)

	got, err := q.AuthenticateAccessToken(ctx, s.AccessTokenHash)
	if err != nil || got.SessionID != s.ID || got.UserID != u.ID || got.Status != "active" {
		t.Fatalf("valid token: %+v %v", got, err)
	}
	if _, err := q.AuthenticateAccessToken(ctx, []byte("unknown")); !isNoRows(err) {
		t.Fatalf("unknown token: %v", err)
	}

	cases := map[string]string{
		"revoked":         `UPDATE sessions SET revoked_at = now(), revoked_reason = 'logout' WHERE id = $1`,
		"access expired":  `UPDATE sessions SET access_expires_at = now() - interval '1 second' WHERE id = $1`,
		"absolute expiry": `UPDATE sessions SET absolute_expires_at = now() - interval '1 second' WHERE id = $1`,
	}
	for name, change := range cases {
		t.Run(name, func(t *testing.T) {
			x := newSession(t, q, u.ID)
			mustExec(t, d.Pool, change, x.ID)
			if _, err := q.AuthenticateAccessToken(ctx, x.AccessTokenHash); !isNoRows(err) {
				t.Fatalf("expected no row, got %v", err)
			}
		})
	}

	t.Run("inactive account", func(t *testing.T) {
		v := newUser(t, q)
		x := newSession(t, q, v.ID)
		mustExec(t, d.Pool, `UPDATE users SET status = 'suspended', resume_status = 'active', suspension_reason = 'other' WHERE id = $1`, v.ID)
		if _, err := q.AuthenticateAccessToken(ctx, x.AccessTokenHash); !isNoRows(err) {
			t.Fatalf("suspended user authenticated: %v", err)
		}
		owner, err := q.GetSessionOwnerStatus(ctx, x.AccessTokenHash)
		if err != nil || owner.Status != "suspended" || owner.RevokedAt != nil {
			t.Fatalf("owner status: %+v %v", owner, err)
		}
	})
	t.Run("unverified email", func(t *testing.T) {
		v := newUser(t, q)
		x := newSession(t, q, v.ID)
		mustExec(t, d.Pool, `UPDATE users SET email_verified_at = NULL WHERE id = $1`, v.ID)
		if _, err := q.AuthenticateAccessToken(ctx, x.AccessTokenHash); !isNoRows(err) {
			t.Fatalf("unverified user authenticated: %v", err)
		}
	})
}

func TestQuery_TouchSessionLastSeenIsThrottled(t *testing.T) {
	d, q := migratedDB(t)
	ctx := context.Background()
	s := newSession(t, q, newUser(t, q).ID)
	if n, _ := q.TouchSessionLastSeen(ctx, sqlc.TouchSessionLastSeenParams{ID: s.ID}); n != 0 {
		t.Fatalf("a fresh session must not be touched, n=%d", n)
	}
	mustExec(t, d.Pool, `UPDATE sessions SET last_seen_at = now() - interval '6 minutes' WHERE id = $1`, s.ID)
	if n, _ := q.TouchSessionLastSeen(ctx, sqlc.TouchSessionLastSeenParams{ID: s.ID}); n != 1 {
		t.Fatalf("a stale session must be touched, n=%d", n)
	}
}

func TestQuery_LockActingSessionForUpdate(t *testing.T) {
	d, q := migratedDB(t)
	ctx := context.Background()
	u, other := newUser(t, q), newUser(t, q)
	s := newSession(t, q, u.ID)

	if got, err := q.LockActingSessionForUpdate(ctx, sqlc.LockActingSessionForUpdateParams{ID: s.ID, UserID: u.ID}); err != nil || got.ID != s.ID {
		t.Fatalf("own session: %v", err)
	}
	if _, err := q.LockActingSessionForUpdate(ctx, sqlc.LockActingSessionForUpdateParams{ID: s.ID, UserID: other.ID}); !isNoRows(err) {
		t.Fatalf("another user's session must not lock: %v", err)
	}
	mustExec(t, d.Pool, `UPDATE sessions SET revoked_at = now(), revoked_reason = 'logout' WHERE id = $1`, s.ID)
	if _, err := q.LockActingSessionForUpdate(ctx, sqlc.LockActingSessionForUpdateParams{ID: s.ID, UserID: u.ID}); !isNoRows(err) {
		t.Fatalf("a revoked session must not lock: %v", err)
	}
}

// TRD 8.4: a second refresh with the same token waits on the row lock, then re-evaluates
// the WHERE against the rotated row and finds nothing (so it falls through to reuse handling).
func TestQuery_RefreshRotationRaceWaiterSeesNoRow(t *testing.T) {
	d, q := migratedDB(t)
	ctx := context.Background()
	u := newUser(t, q)
	s := newSession(t, q, u.ID)

	tx1, q1 := inTx(t, d.Pool)
	locked, err := q1.LockSessionByRefreshTokenHash(ctx, s.RefreshTokenHash)
	if err != nil || locked.ID != s.ID || locked.UserStatus != "active" {
		t.Fatalf("first lock: %v", err)
	}

	type result struct {
		err error
	}
	waiter := make(chan result, 1)
	go func() {
		tx2, q2 := inTx(t, d.Pool)
		_, err := q2.LockSessionByRefreshTokenHash(ctx, s.RefreshTokenHash)
		_ = tx2.Rollback(ctx)
		waiter <- result{err}
	}()
	select {
	case <-waiter:
		t.Fatal("second refresh did not wait for the row lock")
	case <-time.After(300 * time.Millisecond):
	}

	// Rotate in the first transaction, as in TRD 8.4 step 2.
	if err := q1.InsertConsumedRefreshToken(ctx, sqlc.InsertConsumedRefreshTokenParams{
		TokenHash: s.RefreshTokenHash, SessionID: s.ID, RetainUntil: locked.RefreshExpiresAt}); err != nil {
		t.Fatal(err)
	}
	if n, err := q1.RotateSession(ctx, sqlc.RotateSessionParams{
		ID: s.ID, AccessTokenHash: []byte("new-access"), AccessExpiresAt: time.Now().Add(15 * time.Minute),
		RefreshTokenHash: []byte("new-refresh"), RefreshExpiresAt: locked.RefreshExpiresAt}); err != nil || n != 1 {
		t.Fatalf("rotate: %d %v", n, err)
	}
	if err := tx1.Commit(ctx); err != nil {
		t.Fatal(err)
	}

	select {
	case r := <-waiter:
		if !isNoRows(r.err) {
			t.Fatalf("waiter must see no row after the rotation committed, got %v", r.err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("waiter never finished")
	}

	// The old token is now a reuse candidate and the new one is current.
	if got, err := q.FindConsumedRefreshToken(ctx, s.RefreshTokenHash); err != nil || got != s.ID {
		t.Fatalf("consumed lookup: %v %v", got, err)
	}
	if _, err := q.LockSessionByRefreshTokenHash(ctx, []byte("new-refresh")); err != nil {
		t.Fatalf("new token: %v", err)
	}
	if _, err := q.AuthenticateAccessToken(ctx, s.AccessTokenHash); !isNoRows(err) {
		t.Fatalf("old access token must stop working at once: %v", err)
	}
}

func TestQuery_ConsumedRefreshTokenRetentionCutoff(t *testing.T) {
	d, q := migratedDB(t)
	ctx := context.Background()
	s := newSession(t, q, newUser(t, q).ID)
	hash := []byte("consumed-1")

	if err := q.InsertConsumedRefreshToken(ctx, sqlc.InsertConsumedRefreshTokenParams{
		TokenHash: hash, SessionID: s.ID, RetainUntil: time.Now().Add(time.Hour)}); err != nil {
		t.Fatal(err)
	}
	if got, err := q.FindConsumedRefreshToken(ctx, hash); err != nil || got != s.ID {
		t.Fatalf("before the cutoff: %v %v", got, err)
	}
	mustExec(t, d.Pool, `UPDATE refresh_tokens_consumed SET retain_until = now() - interval '1 second'`)
	// The row still exists, but lookup enforces the cutoff itself.
	if rowCount(t, d.Pool, `SELECT count(*) FROM refresh_tokens_consumed`) != 1 {
		t.Fatal("row should still be present")
	}
	if _, err := q.FindConsumedRefreshToken(ctx, hash); !isNoRows(err) {
		t.Fatalf("past the cutoff the token must be unknown: %v", err)
	}
	if n, _ := q.DeleteExpiredConsumedRefreshTokens(ctx, 1000); n != 1 {
		t.Fatalf("cleanup n=%d", n)
	}
}

func TestQuery_Revocation(t *testing.T) {
	d, q := migratedDB(t)
	ctx := context.Background()
	u, other := newUser(t, q), newUser(t, q)
	a, b, c := newSession(t, q, u.ID), newSession(t, q, u.ID), newSession(t, q, u.ID)
	foreign := newSession(t, q, other.ID)

	reason := func(id [16]byte) string {
		var r *string
		_ = d.Pool.QueryRow(ctx, `SELECT revoked_reason FROM sessions WHERE id = $1`, id).Scan(&r)
		if r == nil {
			return ""
		}
		return *r
	}

	if n, _ := q.RevokeSession(ctx, sqlc.RevokeSessionParams{ID: foreign.ID, UserID: u.ID, Reason: ptr("logout")}); n != 0 {
		t.Fatal("RevokeSession must be scoped to the user")
	}
	if n, err := q.RevokeOtherSessionsForUser(ctx, sqlc.RevokeOtherSessionsForUserParams{
		UserID: u.ID, KeepSessionID: a.ID, Reason: ptr("password_change")}); err != nil || n != 2 {
		t.Fatalf("revoke others: %d %v", n, err)
	}
	if reason(a.ID) != "" || reason(b.ID) != "password_change" || reason(c.ID) != "password_change" || reason(foreign.ID) != "" {
		t.Fatal("revoke others touched the wrong sessions")
	}
	if n, _ := q.RevokeOtherSessionsForUser(ctx, sqlc.RevokeOtherSessionsForUserParams{
		UserID: u.ID, KeepSessionID: a.ID, Reason: ptr("password_change")}); n != 0 {
		t.Fatalf("revocation must be idempotent, n=%d", n)
	}
	if n, _ := q.RevokeAllSessionsForUser(ctx, sqlc.RevokeAllSessionsForUserParams{UserID: u.ID, Reason: ptr("password_reset")}); n != 1 {
		t.Fatalf("revoke all must only hit the remaining active session, n=%d", n)
	}
	if reason(a.ID) != "password_reset" || reason(b.ID) != "password_change" || reason(foreign.ID) != "" {
		t.Fatal("revoke all rewrote history or crossed users")
	}
	if n, _ := q.RevokeSession(ctx, sqlc.RevokeSessionParams{ID: foreign.ID, UserID: other.ID, Reason: ptr("logout")}); n != 1 {
		t.Fatal("owner must be able to revoke its session")
	}
	if n, _ := q.RevokeSession(ctx, sqlc.RevokeSessionParams{ID: foreign.ID, UserID: other.ID, Reason: ptr("logout")}); n != 0 {
		t.Fatal("second revoke must be a no-op")
	}
}

func TestQuery_SessionCap(t *testing.T) {
	d, q := migratedDB(t)
	ctx := context.Background()
	u := newUser(t, q)
	var ids [][16]byte
	for i := 0; i < 5; i++ {
		s := newSession(t, q, u.ID)
		// Session i was last seen i minutes ago, so session 0 is the most recent.
		mustExec(t, d.Pool, `UPDATE sessions SET last_seen_at = now() - make_interval(mins => $2) WHERE id = $1`, s.ID, i)
		ids = append(ids, s.ID)
	}
	if n, _ := q.CountActiveSessionsForUser(ctx, u.ID); n != 5 {
		t.Fatalf("active = %d", n)
	}
	if n, err := q.RevokeSessionsBeyondLimit(ctx, sqlc.RevokeSessionsBeyondLimitParams{UserID: u.ID, KeepCount: 3}); err != nil || n != 2 {
		t.Fatalf("evict: %d %v", n, err)
	}
	for i, id := range ids {
		var reason *string
		_ = d.Pool.QueryRow(ctx, `SELECT revoked_reason FROM sessions WHERE id = $1`, id).Scan(&reason)
		if evicted := i >= 3; evicted != (reason != nil && *reason == "session_limit") {
			t.Fatalf("session %d: wrong eviction state (reason=%v)", i, reason)
		}
	}
	if n, _ := q.CountActiveSessionsForUser(ctx, u.ID); n != 3 {
		t.Fatalf("active after eviction = %d", n)
	}
}

func TestQuery_StaleSessionCleanup(t *testing.T) {
	d, q := migratedDB(t)
	ctx := context.Background()
	u := newUser(t, q)
	old, recent, live := newSession(t, q, u.ID), newSession(t, q, u.ID), newSession(t, q, u.ID)
	mustExec(t, d.Pool, `UPDATE sessions SET revoked_at = now() - interval '31 days', revoked_reason = 'logout' WHERE id = $1`, old.ID)
	mustExec(t, d.Pool, `UPDATE sessions SET revoked_at = now() - interval '2 days', revoked_reason = 'logout' WHERE id = $1`, recent.ID)
	if n, err := q.DeleteStaleSessions(ctx, 1000); err != nil || n != 1 {
		t.Fatalf("delete stale: %d %v", n, err)
	}
	if rowCount(t, d.Pool, `SELECT count(*) FROM sessions WHERE id = ANY($1)`, [][16]byte{recent.ID, live.ID}) != 2 {
		t.Fatal("cleanup removed a session it should keep")
	}
}

// --- outbox -------------------------------------------------------------------------------

func TestQuery_OutboxLeaseAndSendBudget(t *testing.T) {
	d, q := migratedDB(t)
	ctx := context.Background()
	row, err := q.InsertOutboxEmail(ctx, outboxParams())
	if err != nil {
		t.Fatal(err)
	}

	claimed, err := q.ClaimOutboxBatch(ctx, sqlc.ClaimOutboxBatchParams{LeaseSeconds: 120, BatchSize: 10})
	if err != nil || len(claimed) != 1 || claimed[0].LeaseToken == nil || claimed[0].SendAttempts != 0 {
		t.Fatalf("claim must lease without consuming budget: %+v %v", claimed, err)
	}
	lease := claimed[0].LeaseToken
	if again, _ := q.ClaimOutboxBatch(ctx, sqlc.ClaimOutboxBatchParams{LeaseSeconds: 120, BatchSize: 10}); len(again) != 0 {
		t.Fatal("a row under a live lease must not be claimed again")
	}

	// Reservation needs a live lease with enough time left.
	if _, err := q.ReserveOutboxSend(ctx, sqlc.ReserveOutboxSendParams{ID: row.ID, LeaseToken: lease, MinRemainingSeconds: 500}); !isNoRows(err) {
		t.Fatalf("reserve with too little lease left: %v", err)
	}
	if _, err := q.ReserveOutboxSend(ctx, sqlc.ReserveOutboxSendParams{ID: row.ID, LeaseToken: ptr(newID()), MinRemainingSeconds: 45}); !isNoRows(err) {
		t.Fatalf("reserve with a foreign lease: %v", err)
	}
	if n, err := q.ReserveOutboxSend(ctx, sqlc.ReserveOutboxSendParams{ID: row.ID, LeaseToken: lease, MinRemainingSeconds: 45}); err != nil || n != 1 {
		t.Fatalf("reserve: %d %v", n, err)
	}

	// Results require the matching lease.
	finish := sqlc.FinishOutboxUnderLeaseParams{ID: row.ID, Status: "sent", LeaseToken: ptr(newID()), ProviderMessageID: ptr("msg-1")}
	if n, _ := q.FinishOutboxUnderLease(ctx, finish); n != 0 {
		t.Fatal("a foreign lease must not record a result")
	}
	// ... and an unexpired one, even when the token still matches.
	mustExec(t, d.Pool, `UPDATE email_outbox SET lease_expires_at = now() - interval '1 second' WHERE id = $1`, row.ID)
	finish.LeaseToken = lease
	if n, _ := q.FinishOutboxUnderLease(ctx, finish); n != 0 {
		t.Fatal("an expired lease must not record a result")
	}
	if n, _ := q.RescheduleOutboxUnderLease(ctx, sqlc.RescheduleOutboxUnderLeaseParams{ID: row.ID, LeaseToken: lease, BackoffSeconds: 30}); n != 0 {
		t.Fatal("an expired lease must not reschedule")
	}
	// A new claim after expiry gets a new token, and the old worker is locked out.
	reclaimed, _ := q.ClaimOutboxBatch(ctx, sqlc.ClaimOutboxBatchParams{LeaseSeconds: 120, BatchSize: 10})
	if len(reclaimed) != 1 || *reclaimed[0].LeaseToken == *lease || reclaimed[0].SendAttempts != 1 {
		t.Fatalf("reclaim: %+v", reclaimed)
	}
	if n, _ := q.FinishOutboxUnderLease(ctx, finish); n != 0 {
		t.Fatal("the stale worker must stay locked out")
	}
	finish.LeaseToken = reclaimed[0].LeaseToken
	if n, _ := q.FinishOutboxUnderLease(ctx, finish); n != 1 {
		t.Fatal("the current lease holder must be able to record the result")
	}
	var status string
	var payload []byte
	_ = d.Pool.QueryRow(ctx, `SELECT status, payload_ciphertext FROM email_outbox WHERE id = $1`, row.ID).Scan(&status, &payload)
	if status != "sent" || payload != nil {
		t.Fatalf("final state %q payload=%v", status, payload)
	}
	if n, _ := q.FinishOutboxUnderLease(ctx, finish); n != 0 {
		t.Fatal("a finished row must not be rewritten")
	}
}

func TestQuery_OutboxBudgetStopsAtFive(t *testing.T) {
	d, q := migratedDB(t)
	ctx := context.Background()
	row, _ := q.InsertOutboxEmail(ctx, outboxParams())
	for i := 1; i <= 5; i++ {
		claimed, _ := q.ClaimOutboxBatch(ctx, sqlc.ClaimOutboxBatchParams{LeaseSeconds: 120, BatchSize: 1})
		if len(claimed) != 1 {
			t.Fatalf("claim %d: %d rows", i, len(claimed))
		}
		n, err := q.ReserveOutboxSend(ctx, sqlc.ReserveOutboxSendParams{ID: row.ID, LeaseToken: claimed[0].LeaseToken, MinRemainingSeconds: 45})
		if err != nil || int(n) != i {
			t.Fatalf("reservation %d: %d %v", i, n, err)
		}
		// Ambiguous result with budget left: back to pending with the lease cleared.
		if i < 5 {
			if r, _ := q.RescheduleOutboxUnderLease(ctx, sqlc.RescheduleOutboxUnderLeaseParams{
				ID: row.ID, LeaseToken: claimed[0].LeaseToken, BackoffSeconds: 0, LastError: ptr("timeout")}); r != 1 {
				t.Fatalf("reschedule %d", i)
			}
		}
	}
	// The fifth reservation is held under a live lease: the reaper must leave it alone.
	if n, _ := q.ReapOutbox(ctx); n != 0 {
		t.Fatal("the reaper must not touch a row under a live lease")
	}
	// Simulate the worker crashing after reserving: the lease expires, nothing was recorded.
	mustExec(t, d.Pool, `UPDATE email_outbox SET lease_expires_at = now() - interval '1 second' WHERE id = $1`, row.ID)
	if claimed, _ := q.ClaimOutboxBatch(ctx, sqlc.ClaimOutboxBatchParams{LeaseSeconds: 120, BatchSize: 1}); len(claimed) != 0 {
		t.Fatal("an exhausted row must never be claimed again")
	}
	if n, _ := q.ReapOutbox(ctx); n != 1 {
		t.Fatalf("the reaper must terminalize the exhausted row, n=%d", n)
	}
	var status, lastError string
	var payload []byte
	_ = d.Pool.QueryRow(ctx, `SELECT status, last_error, payload_ciphertext FROM email_outbox WHERE id = $1`, row.ID).Scan(&status, &lastError, &payload)
	if status != "failed" || lastError != "send_budget_exhausted" || payload != nil {
		t.Fatalf("got %q %q payload=%v", status, lastError, payload)
	}
}

func TestQuery_OutboxReaperExpiresPastNotAfterAndCancelWorks(t *testing.T) {
	d, q := migratedDB(t)
	ctx := context.Background()

	late, _ := q.InsertOutboxEmail(ctx, outboxParams())
	mustExec(t, d.Pool, `UPDATE email_outbox SET not_after = now() - interval '1 second' WHERE id = $1`, late.ID)
	if claimed, _ := q.ClaimOutboxBatch(ctx, sqlc.ClaimOutboxBatchParams{LeaseSeconds: 120, BatchSize: 5}); len(claimed) != 0 {
		t.Fatal("a row past not_after must not be claimed")
	}
	if n, _ := q.ReapOutbox(ctx); n != 1 {
		t.Fatalf("reap n=%d", n)
	}
	var status string
	_ = d.Pool.QueryRow(ctx, `SELECT status FROM email_outbox WHERE id = $1`, late.ID).Scan(&status)
	if status != "expired" {
		t.Fatalf("status = %q", status)
	}

	u := newUser(t, q)
	cp := challengeParams("login", "cancel@example.test", "code")
	cp.UserID = &u.ID
	c := newChallenge(t, q, cp)
	p := outboxParams()
	p.UserID, p.ChallengeID = &u.ID, &c.ID
	row, _ := q.InsertOutboxEmail(ctx, p)
	claimed, _ := q.ClaimOutboxBatch(ctx, sqlc.ClaimOutboxBatchParams{LeaseSeconds: 120, BatchSize: 5})
	if len(claimed) != 1 {
		t.Fatalf("claimed %d", len(claimed))
	}
	if n, _ := q.CancelPendingOutboxForChallenge(ctx, &c.ID); n != 1 {
		t.Fatalf("cancel n=%d", n)
	}
	// The worker that was mid-send now finds its result rejected.
	if n, _ := q.FinishOutboxUnderLease(ctx, sqlc.FinishOutboxUnderLeaseParams{
		ID: row.ID, Status: "sent", LeaseToken: claimed[0].LeaseToken}); n != 0 {
		t.Fatal("a cancelled row must reject the worker's result")
	}
	var payload []byte
	_ = d.Pool.QueryRow(ctx, `SELECT status, payload_ciphertext FROM email_outbox WHERE id = $1`, row.ID).Scan(&status, &payload)
	if status != "cancelled" || payload != nil {
		t.Fatalf("status %q payload %v", status, payload)
	}
}

func TestQuery_OutboxReleaseLeaseAndCleanup(t *testing.T) {
	d, q := migratedDB(t)
	ctx := context.Background()
	row, _ := q.InsertOutboxEmail(ctx, outboxParams())
	claimed, _ := q.ClaimOutboxBatch(ctx, sqlc.ClaimOutboxBatchParams{LeaseSeconds: 120, BatchSize: 1})
	if n, _ := q.ReleaseOutboxLease(ctx, sqlc.ReleaseOutboxLeaseParams{ID: row.ID, LeaseToken: claimed[0].LeaseToken}); n != 1 {
		t.Fatal("release")
	}
	again, _ := q.ClaimOutboxBatch(ctx, sqlc.ClaimOutboxBatchParams{LeaseSeconds: 120, BatchSize: 1})
	if len(again) != 1 || again[0].SendAttempts != 0 {
		t.Fatalf("a released row must be claimable with its budget intact: %+v", again)
	}
	mustExec(t, d.Pool, `UPDATE email_outbox SET status = 'sent', payload_ciphertext = NULL, finished_at = now() - interval '8 days' WHERE id = $1`, row.ID)
	if n, _ := q.DeleteFinishedOutbox(ctx, 1000); n != 1 {
		t.Fatalf("cleanup n=%d", n)
	}
}

func TestQuery_OutboxClaimSkipsLockedRows(t *testing.T) {
	d, q := migratedDB(t)
	ctx := context.Background()
	for i := 0; i < 4; i++ {
		if _, err := q.InsertOutboxEmail(ctx, outboxParams()); err != nil {
			t.Fatal(err)
		}
	}
	// Two workers claim at the same time and must never receive the same row.
	var mu sync.Mutex
	seen := map[[16]byte]int{}
	var wg sync.WaitGroup
	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			rows, err := q.ClaimOutboxBatch(ctx, sqlc.ClaimOutboxBatchParams{LeaseSeconds: 120, BatchSize: 4})
			if err != nil {
				t.Error(err)
				return
			}
			mu.Lock()
			for _, r := range rows {
				seen[r.ID]++
			}
			mu.Unlock()
		}()
	}
	wg.Wait()
	if len(seen) != 4 {
		t.Fatalf("expected 4 distinct rows claimed, got %d", len(seen))
	}
	for id, n := range seen {
		if n != 1 {
			t.Fatalf("row %x claimed %d times", id, n)
		}
	}
	_ = d
}

// --- ratelimit, audit, platform -----------------------------------------------------------

func TestQuery_RateLimitCounters(t *testing.T) {
	d, q := migratedDB(t)
	ctx := context.Background()
	w1 := time.Date(2026, 1, 1, 10, 0, 0, 0, time.UTC)
	w2 := w1.Add(time.Hour)

	for want := int32(1); want <= 3; want++ {
		got, err := q.IncrementRateLimitCounter(ctx, sqlc.IncrementRateLimitCounterParams{Key: "otp_start:email:abc", WindowStart: w1})
		if err != nil || got != want {
			t.Fatalf("increment: got %d want %d (%v)", got, want, err)
		}
	}
	if got, _ := q.IncrementRateLimitCounter(ctx, sqlc.IncrementRateLimitCounterParams{Key: "otp_start:email:abc", WindowStart: w2}); got != 1 {
		t.Fatalf("a new window starts at 1, got %d", got)
	}
	total, err := q.GetRateLimitCount(ctx, sqlc.GetRateLimitCountParams{Key: "otp_start:email:abc", Since: w1})
	if err != nil || total != 4 {
		t.Fatalf("sum across windows: %d %v", total, err)
	}
	if total, _ := q.GetRateLimitCount(ctx, sqlc.GetRateLimitCountParams{Key: "otp_start:email:abc", Since: w2}); total != 1 {
		t.Fatalf("since filter: %d", total)
	}
	if total, _ := q.GetRateLimitCount(ctx, sqlc.GetRateLimitCountParams{Key: "unused", Since: w1}); total != 0 {
		t.Fatalf("unused key: %d", total)
	}
	if n, _ := q.DeleteOldRateLimitCounters(ctx, 1000); n != 2 {
		t.Fatalf("old windows must be deleted, n=%d", n)
	}
	_ = d
}

func TestQuery_RateLimitConcurrentIncrements(t *testing.T) {
	d, q := migratedDB(t)
	w := time.Now().UTC().Truncate(time.Hour)
	var wg sync.WaitGroup
	for i := 0; i < 25; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if _, err := q.IncrementRateLimitCounter(context.Background(),
				sqlc.IncrementRateLimitCounterParams{Key: "k", WindowStart: w}); err != nil {
				t.Error(err)
			}
		}()
	}
	wg.Wait()
	if n := rowCount(t, d.Pool, `SELECT count FROM rate_limit_counters WHERE key = 'k'`); n != 25 {
		t.Fatalf("lost updates: count = %d", n)
	}
}

func TestQuery_CleanupAdvisoryLockIsExclusive(t *testing.T) {
	d, _ := migratedDB(t)
	ctx := context.Background()
	c1, err := d.Pool.Acquire(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer c1.Release()
	c2, err := d.Pool.Acquire(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer c2.Release()
	q1, q2 := sqlc.New(c1), sqlc.New(c2)

	if ok, err := q1.TryCleanupAdvisoryLock(ctx, 42); err != nil || !ok {
		t.Fatalf("first lock: %v %v", ok, err)
	}
	if ok, _ := q2.TryCleanupAdvisoryLock(ctx, 42); ok {
		t.Fatal("a second instance must not get the lock")
	}
	if ok, _ := q1.ReleaseCleanupAdvisoryLock(ctx, 42); !ok {
		t.Fatal("release")
	}
	if ok, _ := q2.TryCleanupAdvisoryLock(ctx, 42); !ok {
		t.Fatal("lock must be available after release")
	}
}
