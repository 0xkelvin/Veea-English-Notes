//go:build integration

package integration

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"net/http"
	"strconv"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/auth/session"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/db/sqlc"
)

const (
	pathRefresh = "/v1/auth/token/refresh"
	pathLogout  = "/v1/auth/logout"
	pathMe      = "/v1/me"
)

// issue creates a synthetic session for u through the Ticket 07 primitive, inside a
// transaction holding the user at L3, and returns its tokens.
func (e *signupEnv) issue(t *testing.T, u sqlc.User, device string) session.Issued {
	t.Helper()
	ctx := context.Background()
	p, err := session.NewPending(nil)
	if err != nil {
		t.Fatal(err)
	}
	tx, err := e.d.Pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx)
	if _, err := sqlc.New(tx).LockUserForNoKeyUpdate(ctx, u.ID); err != nil {
		t.Fatal(err)
	}
	s, err := session.Issue(ctx, tx, p, session.Request{UserID: u.ID, Method: session.MethodPassword,
		Device: session.Device{Name: device, Platform: "ios"}, RequestID: "req-fixture"})
	if err != nil {
		t.Fatal(err)
	}
	if err := tx.Commit(ctx); err != nil {
		t.Fatal(err)
	}
	e.remember(s.AccessToken, s.RefreshToken)
	return s
}

func (e *signupEnv) get(t *testing.T, path string, headers ...string) response {
	t.Helper()
	req, err := http.NewRequest(http.MethodGet, e.srv.URL+path, nil)
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i+1 < len(headers); i += 2 {
		req.Header.Add(headers[i], headers[i+1])
	}
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	var buf bytes.Buffer
	_, _ = buf.ReadFrom(res.Body)
	out := response{status: res.StatusCode, header: res.Header, raw: buf.Bytes()}
	_ = json.Unmarshal(out.raw, &out.body)
	return out
}

func bearer(token string) []string { return []string{"Authorization", "Bearer " + token} }

func (e *signupEnv) me(t *testing.T, access string) response {
	t.Helper()
	return e.get(t, pathMe, bearer(access)...)
}

func (e *signupEnv) refresh(t *testing.T, refresh string) response {
	t.Helper()
	return e.post(t, pathRefresh, map[string]string{"refresh_token": refresh})
}

func (e *signupEnv) logout(t *testing.T, access string) response {
	t.Helper()
	return e.post(t, pathLogout, "", bearer(access)...)
}

func wantUnauthorized(t *testing.T, r response) {
	t.Helper()
	wantProblem(t, r, http.StatusUnauthorized, "unauthorized")
	if r.header.Get("WWW-Authenticate") != "Bearer" {
		t.Fatalf("401 must carry WWW-Authenticate: Bearer, got %q", r.header.Get("WWW-Authenticate"))
	}
}

type sessionState struct {
	revoked                 bool
	reason                  string
	rotations               int
	accessHash, refreshHash []byte
}

func (e *signupEnv) sessionRow(t *testing.T, id uuid.UUID) sessionState {
	t.Helper()
	var s sessionState
	var reason *string
	if err := e.d.Pool.QueryRow(context.Background(), `SELECT revoked_at IS NOT NULL, revoked_reason, rotation_counter,
		access_token_hash, refresh_token_hash FROM sessions WHERE id = $1`, id).
		Scan(&s.revoked, &reason, &s.rotations, &s.accessHash, &s.refreshHash); err != nil {
		t.Fatal(err)
	}
	if reason != nil {
		s.reason = *reason
	}
	return s
}

// avoidMinuteBoundary waits for a fresh minute on the database clock when fewer than 15 s are
// left, so a test that fills a one-minute window cannot straddle two of them.
func avoidMinuteBoundary(t *testing.T, e *signupEnv) {
	t.Helper()
	var sec float64
	_ = e.d.Pool.QueryRow(context.Background(), `SELECT extract(second FROM now())::float8`).Scan(&sec)
	if sec > 45 {
		time.Sleep(time.Duration((61-sec)*float64(time.Second)) + 100*time.Millisecond)
	}
}

// =============================================================================================
// GET /v1/me and the bearer middleware (TRD 8.1)
// =============================================================================================

func TestMe_ReturnsTheAuthenticatedAccount(t *testing.T) {
	env := newSignupEnv(t, nil)
	u := newUser(t, env.q)
	s := env.issue(t, u, "Phone")
	mustExec(t, env.d.Pool, `UPDATE sessions SET last_seen_at = now() - interval '10 minutes' WHERE id = $1`, s.SessionID)

	r := env.me(t, s.AccessToken)
	if r.status != http.StatusOK || r.str("id") != u.ID.String() || r.str("email") != u.Email ||
		r.body["has_password"] != false || r.str("status") != "active" || r.str("role") != "user" ||
		r.header.Get("Cache-Control") != "no-store" {
		t.Fatalf("GET /v1/me: %d %s", r.status, r.raw)
	}
	if rowCount(t, env.d.Pool, `SELECT count(*) FROM sessions WHERE id = $1 AND last_seen_at > now() - interval '1 minute'`, s.SessionID) != 1 {
		t.Fatal("an authenticated request refreshes a stale last_seen_at")
	}
}

// TRD 5.1: every non-public route answers 401 without a valid access token.
func TestAuth_ProtectedRoutesRequireAnAccessToken(t *testing.T) {
	env := newSignupEnv(t, nil)
	u := newUser(t, env.q)
	s := env.issue(t, u, "Phone")
	for name, headers := range map[string][]string{
		"no header":         nil,
		"basic scheme":      {"Authorization", "Basic dXNlcjpwYXNz"},
		"unknown token":     bearer("vat_" + uuid.NewString()),
		"refresh as access": bearer(s.RefreshToken),
		"two headers":       {"Authorization", "Bearer " + s.AccessToken, "Authorization", "Bearer " + s.AccessToken},
	} {
		t.Run(name, func(t *testing.T) {
			wantUnauthorized(t, env.get(t, pathMe, headers...))
			r := env.post(t, pathLogout, "", headers...)
			wantUnauthorized(t, r)
		})
	}
	if env.sessionRow(t, s.SessionID).revoked {
		t.Fatal("failed authentications must not revoke anything")
	}
}

func TestAuth_ExpiryRevocationAndAccountStateAreChecked(t *testing.T) {
	env := newSignupEnv(t, nil)
	cases := []struct {
		name, mutate string
		revokedAs    string // expected revoked_reason afterwards, "" for none
	}{
		{"access expired", `UPDATE sessions SET access_expires_at = now() - interval '1 second' WHERE id = $1`, ""},
		{"absolute expired", `UPDATE sessions SET absolute_expires_at = now() - interval '1 second' WHERE id = $1`, ""},
		{"revoked", `UPDATE sessions SET revoked_at = now(), revoked_reason = 'logout' WHERE id = $1`, "logout"},
		{"account suspended", `UPDATE users SET status = 'suspended' WHERE id = (SELECT user_id FROM sessions WHERE id = $1)`, "account_inactive"},
		{"email unverified", `UPDATE users SET email_verified_at = NULL WHERE id = (SELECT user_id FROM sessions WHERE id = $1)`, "account_inactive"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			u := newUser(t, env.q)
			s, other := env.issue(t, u, "Phone"), env.issue(t, u, "Tablet")
			if r := env.me(t, s.AccessToken); r.status != http.StatusOK {
				t.Fatalf("setup: %d", r.status)
			}
			mustExec(t, env.d.Pool, c.mutate, s.SessionID)
			wantUnauthorized(t, env.me(t, s.AccessToken))
			if got := env.sessionRow(t, s.SessionID); got.reason != c.revokedAs {
				t.Fatalf("revoked_reason %q, want %q", got.reason, c.revokedAs)
			}
			// Phase 1 revokes only the presenting session for an inactive account (TRD 8.7).
			if env.sessionRow(t, other.SessionID).revoked {
				t.Fatal("the other session must not be revoked by this request")
			}
		})
	}
}

// =============================================================================================
// Refresh (TRD 8.4, 8.5)
// =============================================================================================

func TestRefresh_RotatesAndRetiresTheOldPair(t *testing.T) {
	env := newSignupEnv(t, nil)
	u := newUser(t, env.q)
	s := env.issue(t, u, "Phone")
	var oldRefreshExpiry time.Time
	_ = env.d.Pool.QueryRow(context.Background(), `SELECT refresh_expires_at FROM sessions WHERE id = $1`, s.SessionID).Scan(&oldRefreshExpiry)

	r := env.refresh(t, s.RefreshToken)
	if r.status != http.StatusOK || r.str("session_id") != s.SessionID.String() || r.header.Get("Cache-Control") != "no-store" {
		t.Fatalf("refresh: %d %s", r.status, r.raw)
	}
	access, refresh := r.str("access_token"), r.str("refresh_token")
	if access == s.AccessToken || refresh == s.RefreshToken || len(access) != 47 || len(refresh) != 47 {
		t.Fatal("a refresh returns a new pair")
	}
	if user, _ := r.body["user"].(map[string]any); user == nil || user["id"] != u.ID.String() {
		t.Fatalf("the token response includes the user: %s", r.raw)
	}

	// The old access token stops working with the commit; the new one works.
	wantUnauthorized(t, env.me(t, s.AccessToken))
	if got := env.me(t, access); got.status != http.StatusOK {
		t.Fatalf("new access token: %d", got.status)
	}
	// Only hashes are stored: the session row has the new hashes, and the consumed row keeps
	// the old refresh hash until the old token's own recorded expiry.
	row := env.sessionRow(t, s.SessionID)
	ah, rh := sha256.Sum256([]byte(access)), sha256.Sum256([]byte(refresh))
	if row.revoked || row.rotations != 1 || !bytes.Equal(row.accessHash, ah[:]) || !bytes.Equal(row.refreshHash, rh[:]) {
		t.Fatalf("session after rotation: %+v", row)
	}
	oh := sha256.Sum256([]byte(s.RefreshToken))
	if rowCount(t, env.d.Pool, `SELECT count(*) FROM refresh_tokens_consumed WHERE token_hash = $1 AND session_id = $2 AND retain_until = $3`,
		oh[:], s.SessionID, oldRefreshExpiry) != 1 {
		t.Fatal("the consumed token must be retained until its own recorded refresh expiry")
	}
	// The new refresh token rotates again.
	if again := env.refresh(t, refresh); again.status != http.StatusOK || env.sessionRow(t, s.SessionID).rotations != 2 {
		t.Fatalf("second rotation: %d", again.status)
	}
	if rowCount(t, env.d.Pool, `SELECT count(*) FROM audit_events WHERE action = 'auth.session.refresh'`) != 0 {
		t.Fatal("successful refreshes are not audited (TRD 11.1)")
	}
}

// TRD 8.5 and 12.3 TestRefresh_RetentionUsesRecordedExpiry / _CappedByAbsoluteExpiry.
func TestRefresh_RetentionAndNewExpiryFollowTheRecordedValues(t *testing.T) {
	env := newSignupEnv(t, nil)
	u := newUser(t, env.q)
	s := env.issue(t, u, "Phone")
	// A token late in its life, on a session close to its absolute expiry.
	mustExec(t, env.d.Pool, `UPDATE sessions SET refresh_expires_at = date_trunc('second', now()) + interval '1 hour',
		absolute_expires_at = date_trunc('second', now()) + interval '2 hours' WHERE id = $1`, s.SessionID)
	var recorded, absolute time.Time
	_ = env.d.Pool.QueryRow(context.Background(), `SELECT refresh_expires_at, absolute_expires_at FROM sessions WHERE id = $1`, s.SessionID).
		Scan(&recorded, &absolute)

	r := env.refresh(t, s.RefreshToken)
	if r.status != http.StatusOK {
		t.Fatalf("refresh: %d", r.status)
	}
	oh := sha256.Sum256([]byte(s.RefreshToken))
	var retain time.Time
	_ = env.d.Pool.QueryRow(context.Background(), `SELECT retain_until FROM refresh_tokens_consumed WHERE token_hash = $1`, oh[:]).Scan(&retain)
	if !retain.Equal(recorded) {
		t.Fatalf("retain_until %s, want the recorded expiry %s (not consumed_at + 30 days)", retain, recorded)
	}
	if got, err := time.Parse(time.RFC3339Nano, r.str("refresh_expires_at")); err != nil || !got.Equal(absolute) {
		t.Fatalf("new refresh expiry %q, want least(now + 30 days, absolute) = %s", r.str("refresh_expires_at"), absolute)
	}
}

// TRD 5.4 and 8.4: a retry after a lost response is reuse. The session is revoked, the pair
// issued by the lost response dies with it, and the user's other sessions are untouched.
func TestRefresh_LostResponseRetryRevokesOnlyThatSession(t *testing.T) {
	env := newSignupEnv(t, nil)
	u := newUser(t, env.q)
	s, other := env.issue(t, u, "Phone"), env.issue(t, u, "Tablet")

	lost := env.refresh(t, s.RefreshToken) // the client never sees this response
	if lost.status != http.StatusOK {
		t.Fatalf("first refresh: %d", lost.status)
	}
	wantUnauthorized(t, env.refresh(t, s.RefreshToken))

	if row := env.sessionRow(t, s.SessionID); !row.revoked || row.reason != "refresh_reuse" || row.rotations != 1 {
		t.Fatalf("session after reuse: %+v", row)
	}
	wantUnauthorized(t, env.me(t, lost.str("access_token")))
	wantUnauthorized(t, env.refresh(t, lost.str("refresh_token")))
	// Other devices did not leak (R4).
	if r := env.me(t, other.AccessToken); r.status != http.StatusOK {
		t.Fatalf("other session: %d", r.status)
	}
	if r := env.refresh(t, other.RefreshToken); r.status != http.StatusOK {
		t.Fatalf("other session refresh: %d", r.status)
	}
	if rowCount(t, env.d.Pool, `SELECT count(*) FROM audit_events WHERE action = 'auth.session.refresh' AND outcome = 'failure'
		AND reason = 'refresh_reuse' AND session_id = $1 AND target_user_id = $2`, s.SessionID, u.ID) != 1 ||
		rowCount(t, env.d.Pool, `SELECT count(*) FROM audit_events WHERE action = 'auth.session.revoke'
		AND metadata->>'reason' = 'refresh_reuse' AND metadata->>'count' = '1'`) != 1 {
		t.Fatal("expected the reuse failure and the revocation audit events")
	}
}

// TRD 12.3 TestConcurrent_RefreshSameToken: at most one request rotates; the others are
// reuse, which revokes the session and so also kills the winner's new pair.
func TestRefresh_ConcurrentSameTokenRotatesAtMostOnceAndRevokes(t *testing.T) {
	env := newSignupEnv(t, nil)
	for round := range 3 {
		u := newUser(t, env.q)
		s := env.issue(t, u, "Phone")
		const n = 10
		results := make([]response, n)
		gate := make(chan struct{})
		var wg sync.WaitGroup
		for i := range n {
			wg.Add(1)
			go func() {
				defer wg.Done()
				<-gate
				results[i] = env.refresh(t, s.RefreshToken)
			}()
		}
		close(gate)
		wg.Wait()

		var winners []response
		for _, r := range results {
			switch r.status {
			case http.StatusOK:
				winners = append(winners, r)
			case http.StatusUnauthorized:
			default:
				t.Fatalf("round %d: unexpected %d %s", round, r.status, r.raw)
			}
		}
		row := env.sessionRow(t, s.SessionID)
		if len(winners) > 1 || row.rotations > 1 {
			t.Fatalf("round %d: %d rotations reported, %d recorded; at most one may rotate", round, len(winners), row.rotations)
		}
		if rowCount(t, env.d.Pool, `SELECT count(*) FROM refresh_tokens_consumed WHERE session_id = $1`, s.SessionID) > 1 {
			t.Fatalf("round %d: more than one consumed row", round)
		}
		if !row.revoked || row.reason != "refresh_reuse" {
			t.Fatalf("round %d: the losers' reuse must revoke the session, got %+v", round, row)
		}
		for _, w := range winners {
			wantUnauthorized(t, env.me(t, w.str("access_token")))
			wantUnauthorized(t, env.refresh(t, w.str("refresh_token")))
		}
	}
}

// TRD 8.5: past retain_until a consumed token is just unknown, even while its row still exists.
func TestRefresh_PastRetentionIsAPlain401WithoutRevocation(t *testing.T) {
	env := newSignupEnv(t, nil)
	u := newUser(t, env.q)
	s := env.issue(t, u, "Phone")
	r := env.refresh(t, s.RefreshToken)
	if r.status != http.StatusOK {
		t.Fatalf("refresh: %d", r.status)
	}
	oh := sha256.Sum256([]byte(s.RefreshToken))
	mustExec(t, env.d.Pool, `UPDATE refresh_tokens_consumed SET retain_until = now() - interval '1 second' WHERE token_hash = $1`, oh[:])

	wantUnauthorized(t, env.refresh(t, s.RefreshToken))
	if row := env.sessionRow(t, s.SessionID); row.revoked {
		t.Fatal("a token past retention must not revoke the session")
	}
	if rowCount(t, env.d.Pool, `SELECT count(*) FROM refresh_tokens_consumed WHERE token_hash = $1`, oh[:]) != 1 {
		t.Fatal("setup: the consumed row must still be present (cleanup not run)")
	}
	if got := env.me(t, r.str("access_token")); got.status != http.StatusOK {
		t.Fatalf("the current pair keeps working: %d", got.status)
	}
	if rowCount(t, env.d.Pool, `SELECT count(*) FROM audit_events WHERE action LIKE 'auth.session.%'`) != 0 {
		t.Fatal("an unknown token writes no audit event")
	}
}

func TestRefresh_UnknownTokensGetTheSameGeneric401(t *testing.T) {
	env := newSignupEnv(t, nil)
	u := newUser(t, env.q)
	s := env.issue(t, u, "Phone")
	var bodies []string
	for _, tok := range []string{"vrt_" + uuid.NewString(), s.AccessToken, "", "garbage", "vrt_"} {
		r := env.refresh(t, tok)
		wantUnauthorized(t, r)
		bodies = append(bodies, string(bytes.Replace(r.raw, []byte(r.str("request_id")), nil, 1)))
	}
	for _, b := range bodies[1:] {
		if b != bodies[0] {
			t.Fatalf("401 bodies differ:\n%s\n%s", bodies[0], b)
		}
	}
	wantProblem(t, env.post(t, pathRefresh, `{"refresh_token":"x","extra":1}`), http.StatusBadRequest, "invalid_request")
	if env.sessionRow(t, s.SessionID).revoked || env.count(t, "audit_events") != 0 {
		t.Fatal("unknown tokens revoke nothing and write nothing")
	}
}

func TestRefresh_RefusedForRevokedExpiredOrInactiveSessions(t *testing.T) {
	env := newSignupEnv(t, nil)
	cases := []struct {
		name, mutate, auditReason, revokedAs string
	}{
		{"revoked", `UPDATE sessions SET revoked_at = now(), revoked_reason = 'logout' WHERE id = $1`, "session_revoked", "logout"},
		{"idle expired", `UPDATE sessions SET refresh_expires_at = now() - interval '1 second' WHERE id = $1`, "session_expired", ""},
		{"absolute expired", `UPDATE sessions SET absolute_expires_at = now() - interval '1 second' WHERE id = $1`, "session_expired", ""},
		{"account suspended", `UPDATE users SET status = 'suspended' WHERE id = (SELECT user_id FROM sessions WHERE id = $1)`, "account_inactive", "account_inactive"},
		// AC-4: an account without a verified email cannot refresh either.
		{"email unverified", `UPDATE users SET email_verified_at = NULL WHERE id = (SELECT user_id FROM sessions WHERE id = $1)`, "account_inactive", "account_inactive"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			u := newUser(t, env.q)
			s := env.issue(t, u, "Phone")
			mustExec(t, env.d.Pool, c.mutate, s.SessionID)
			wantUnauthorized(t, env.refresh(t, s.RefreshToken))
			row := env.sessionRow(t, s.SessionID)
			if row.reason != c.revokedAs || row.rotations != 0 {
				t.Fatalf("session %+v, want revoked_reason %q and no rotation", row, c.revokedAs)
			}
			if rowCount(t, env.d.Pool, `SELECT count(*) FROM refresh_tokens_consumed WHERE session_id = $1`, s.SessionID) != 0 {
				t.Fatal("a refused refresh consumes nothing")
			}
			if rowCount(t, env.d.Pool, `SELECT count(*) FROM audit_events WHERE action = 'auth.session.refresh'
				AND reason = $1 AND session_id = $2`, c.auditReason, s.SessionID) != 1 {
				t.Fatalf("expected a %s refresh failure event", c.auditReason)
			}
		})
	}
}

// One transaction: if the rotation fails at either write, nothing changes and the presented
// pair keeps working.
func TestRefresh_FailedRotationRollsBackAndKeepsTheOriginalToken(t *testing.T) {
	env := newSignupEnv(t, nil)
	mustExec(t, env.d.Pool, `CREATE FUNCTION test_fail() RETURNS trigger LANGUAGE plpgsql
		AS $$ BEGIN RAISE EXCEPTION 'forced rotation failure'; END $$`)
	for name, trigger := range map[string]string{
		"consumed insert fails": `CREATE TRIGGER test_fail BEFORE INSERT ON refresh_tokens_consumed FOR EACH ROW EXECUTE FUNCTION test_fail()`,
		"session update fails": `CREATE TRIGGER test_fail BEFORE UPDATE ON sessions FOR EACH ROW
			WHEN (OLD.refresh_token_hash IS DISTINCT FROM NEW.refresh_token_hash) EXECUTE FUNCTION test_fail()`,
	} {
		t.Run(name, func(t *testing.T) {
			u := newUser(t, env.q)
			s := env.issue(t, u, "Phone")
			before := env.sessionRow(t, s.SessionID)
			mustExec(t, env.d.Pool, trigger)

			r := env.refresh(t, s.RefreshToken)
			wantProblem(t, r, http.StatusInternalServerError, "internal_error")
			if r.body["access_token"] != nil || bytes.Contains(r.raw, []byte("forced")) {
				t.Fatalf("a failed rotation returns no tokens and no detail: %s", r.raw)
			}
			after := env.sessionRow(t, s.SessionID)
			if after.rotations != 0 || after.revoked || !bytes.Equal(after.refreshHash, before.refreshHash) ||
				rowCount(t, env.d.Pool, `SELECT count(*) FROM refresh_tokens_consumed WHERE session_id = $1`, s.SessionID) != 0 {
				t.Fatalf("the rotation must roll back completely: %+v", after)
			}

			mustExec(t, env.d.Pool, `DROP TRIGGER test_fail ON `+map[bool]string{true: "refresh_tokens_consumed", false: "sessions"}[name == "consumed insert fails"])
			if got := env.me(t, s.AccessToken); got.status != http.StatusOK {
				t.Fatalf("the original access token keeps working: %d", got.status)
			}
			if got := env.refresh(t, s.RefreshToken); got.status != http.StatusOK {
				t.Fatalf("the original refresh token keeps working: %d %s", got.status, got.raw)
			}
		})
	}
}

// =============================================================================================
// Logout (TRD 7.7, AC-18)
// =============================================================================================

func TestLogout_EndsOnlyTheCurrentDevice(t *testing.T) {
	env := newSignupEnv(t, nil)
	u := newUser(t, env.q)
	a, b := env.issue(t, u, "Phone"), env.issue(t, u, "Tablet")

	r := env.logout(t, a.AccessToken)
	if r.status != http.StatusNoContent || len(r.raw) != 0 {
		t.Fatalf("logout: %d %s", r.status, r.raw)
	}
	if row := env.sessionRow(t, a.SessionID); !row.revoked || row.reason != "logout" {
		t.Fatalf("session A: %+v", row)
	}
	wantUnauthorized(t, env.me(t, a.AccessToken))
	wantUnauthorized(t, env.refresh(t, a.RefreshToken))
	if env.sessionRow(t, a.SessionID).reason != "logout" {
		t.Fatal("refreshing a logged-out session must not change its revocation")
	}
	// Device B is untouched.
	if got := env.me(t, b.AccessToken); got.status != http.StatusOK {
		t.Fatalf("B: %d", got.status)
	}
	if got := env.refresh(t, b.RefreshToken); got.status != http.StatusOK {
		t.Fatalf("B refresh: %d", got.status)
	}
	// A retry gets 401, which the client treats as done (TRD 5.3 endpoint 10).
	wantUnauthorized(t, env.logout(t, a.AccessToken))
	if rowCount(t, env.d.Pool, `SELECT count(*) FROM audit_events WHERE action = 'auth.logout' AND session_id = $1`, a.SessionID) != 1 ||
		rowCount(t, env.d.Pool, `SELECT count(*) FROM audit_events WHERE action = 'auth.session.revoke' AND metadata->>'reason' = 'logout'`) != 1 {
		t.Fatal("expected one auth.logout and one revocation event")
	}
}

// =============================================================================================
// Session rate limits (TRD 10)
// =============================================================================================

func TestSessionLimits_AreCountedPerSession(t *testing.T) {
	rules := generousRules()
	rules.PasswordSignupStartIP.Limit = 10_000
	rules.RefreshSession.Limit = 2
	rules.RequestSession.Limit = 3
	env := newSignupEnv(t, rules)
	u := newUser(t, env.q)
	a, b := env.issue(t, u, "Phone"), env.issue(t, u, "Tablet")
	avoidMinuteBoundary(t, env)

	t.Run("authenticated requests", func(t *testing.T) {
		for i := range 3 {
			if r := env.me(t, a.AccessToken); r.status != http.StatusOK {
				t.Fatalf("request %d: %d", i+1, r.status)
			}
		}
		r := env.me(t, a.AccessToken)
		wantProblem(t, r, http.StatusTooManyRequests, "rate_limited")
		if ra, err := strconv.Atoi(r.header.Get("Retry-After")); err != nil || ra < 1 || ra > 60 {
			t.Fatalf("Retry-After %q", r.header.Get("Retry-After"))
		}
		if got := env.me(t, b.AccessToken); got.status != http.StatusOK {
			t.Fatalf("another session has its own budget: %d", got.status)
		}
	})

	t.Run("refresh", func(t *testing.T) {
		tok := b.RefreshToken
		for i := range 2 {
			r := env.refresh(t, tok)
			if r.status != http.StatusOK {
				t.Fatalf("refresh %d: %d", i+1, r.status)
			}
			tok = r.str("refresh_token")
		}
		r := env.refresh(t, tok)
		wantProblem(t, r, http.StatusTooManyRequests, "rate_limited")
		if r.header.Get("Retry-After") == "" {
			t.Fatal("429 needs Retry-After")
		}
		// A limited refresh rotates nothing, so the token is still current afterwards.
		if row := env.sessionRow(t, b.SessionID); row.rotations != 2 || row.revoked {
			t.Fatalf("session after a limited refresh: %+v", row)
		}
	})
}
