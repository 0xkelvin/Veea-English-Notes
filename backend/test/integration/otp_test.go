//go:build integration

package integration

import (
	"bytes"
	"context"
	crand "crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"fmt"
	"log/slog"
	mrand "math/rand/v2"
	"net/netip"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/auth/otp"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/identity"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/notify"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/clientip"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/db/sqlc"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/pgtest"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/ratelimit"
)

// Throwaway OTP key, never used outside tests.
var otpTestKey = bytes.Repeat([]byte{0x33}, 32)

// codeRandom is the deterministic Random of TRD 12.3. Start reads the 32 token bytes first and
// then 4 bytes per code candidate, so a queued 4-byte word below 10^6 becomes the code as is.
// Everything else comes from crypto/rand. Tests use it to know the code of a delivery = 'none'
// challenge, which exists nowhere else.
type codeRandom struct {
	mu   sync.Mutex
	next []uint32
}

func (r *codeRandom) Read(p []byte) (int, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if len(p) == 4 && len(r.next) > 0 {
		binary.BigEndian.PutUint32(p, r.next[0])
		r.next = r.next[1:]
		return 4, nil
	}
	return crand.Read(p)
}

func (r *codeRandom) queue(code string) {
	n, err := strconv.Atoi(code)
	if err != nil || len(code) != 6 {
		panic("queue a 6-digit code")
	}
	r.mu.Lock()
	r.next = append(r.next, uint32(n))
	r.mu.Unlock()
}

type otpEnv struct {
	d       *pgtest.DB
	q       *sqlc.Queries
	svc     *otp.Service
	codes   *otp.CodeKeys
	hmac    *identity.EmailHMAC
	fake    *notify.FakeSender
	worker  *notify.Worker
	random  *codeRandom
	logs    *syncBuffer
	retries atomic.Int64

	mu      sync.Mutex
	secrets []string // every code and token issued, for the hygiene check
}

// generousRules lifts the TRD 10 limits out of the way; tests of a limit set their own.
func generousRules() *ratelimit.Rules {
	r := ratelimit.DefaultRules()
	for _, rule := range []*ratelimit.Rule{&r.StartEmailHourly, &r.StartEmailDaily, &r.StartIP, &r.VerifyFailEmail, &r.VerifyIP} {
		rule.Limit = 10_000
	}
	return &r
}

func newOTPEnv(t *testing.T, rules *ratelimit.Rules) *otpEnv {
	t.Helper()
	d, q := migratedDB(t)
	codes, err := otp.NewCodeKeys(otpTestKey)
	if err != nil {
		t.Fatal(err)
	}
	keys, err := notify.NewKeyring(notify.Key{ID: 1, Key: outboxKey1})
	if err != nil {
		t.Fatal(err)
	}
	if rules == nil {
		rules = generousRules()
	}
	env := &otpEnv{d: d, q: q, codes: codes, hmac: testEmailHMAC(t), fake: &notify.FakeSender{},
		random: &codeRandom{}, logs: &syncBuffer{}}
	log := slog.New(slog.NewJSONHandler(env.logs, &slog.HandlerOptions{Level: slog.LevelDebug}))
	env.svc, err = otp.NewService(otp.Config{
		Pool: d.Pool, Codes: codes, EmailHMAC: env.hmac, Outbox: notify.NewOutbox(keys), Rules: rules,
		Random: env.random, Logger: log, OnTxRetry: func(string) { env.retries.Add(1) },
	})
	if err != nil {
		t.Fatal(err)
	}
	env.worker, err = notify.NewWorker(d.Pool, keys, env.fake, notify.WorkerConfig{Logger: log})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		env.assertNoSecrets(t)
		// TRD 12.3: with the 7.1 lock order no transaction is ever retried.
		if n := env.retries.Load(); n != 0 {
			t.Errorf("%d transactions were retried after a deadlock or serialization failure", n)
		}
	})
	return env
}

func testIP() clientip.Result {
	a := netip.MustParseAddr("192.0.2.10") // TEST-NET-1
	return clientip.Result{Addr: a, Bucket: clientip.Bucket(a), Source: clientip.SourcePeer}
}

func randomCode() string { return fmt.Sprintf("%06d", 100000+mrand.IntN(900000)) }

// wrongCode returns a different valid-looking code.
func wrongCode(code string) string {
	n, _ := strconv.Atoi(code)
	return fmt.Sprintf("%06d", (n+1)%1_000_000)
}

func (e *otpEnv) remember(secrets ...string) {
	e.mu.Lock()
	e.secrets = append(e.secrets, secrets...)
	e.mu.Unlock()
}

// start issues a challenge with a known code and fails the test on error.
func (e *otpEnv) start(t *testing.T, req otp.StartRequest) (otp.Acknowledgement, string) {
	t.Helper()
	code := randomCode()
	e.random.queue(code)
	ack, err := e.svc.Start(context.Background(), req)
	if err != nil {
		t.Fatalf("start: %v", err)
	}
	e.remember(code, ack.ChallengeToken)
	return ack, code
}

func (e *otpEnv) user(t *testing.T) (sqlc.User, identity.Email) {
	t.Helper()
	u := newUser(t, e.q)
	return u, email(t, u.Email)
}

func loginStart(addr identity.Email) otp.StartRequest {
	return otp.StartRequest{Purpose: otp.PurposeLogin, Email: addr, Check: accountEligibility(addr), IP: testIP(), RequestID: "req-test"}
}

func loginVerify(token, code string) otp.VerifyRequest {
	return otp.VerifyRequest{Purpose: otp.PurposeLogin, Token: token, Code: code, IP: testIP(), RequestID: "req-test"}
}

// --- eligibility checks, as the flow tickets will write them (TRD 3.3) ----------------------

func accountEligibility(addr identity.Email) otp.Eligibility {
	return func(ctx context.Context, tx pgx.Tx) (otp.Target, error) {
		u, err := sqlc.New(tx).GetUserByEmailNormalized(ctx, addr.Normalized)
		if errors.Is(err, pgx.ErrNoRows) {
			return otp.Target{}, nil
		}
		if err != nil {
			return otp.Target{}, err
		}
		if u.Status != "active" || u.EmailVerifiedAt == nil {
			return otp.Target{}, nil
		}
		return otp.Target{Eligible: true, UserID: &u.ID, To: u.Email}, nil
	}
}

func signupEligibility(addr identity.Email, pendingHash string) otp.Eligibility {
	return func(ctx context.Context, tx pgx.Tx) (otp.Target, error) {
		_, err := sqlc.New(tx).GetUserByEmailNormalized(ctx, addr.Normalized)
		switch {
		case errors.Is(err, pgx.ErrNoRows):
			return otp.Target{Eligible: true, PendingPasswordHash: pendingHash}, nil
		case err != nil:
			return otp.Target{}, err
		}
		// The account exists: the hash was computed for equal timing and is now discarded.
		return otp.Target{PendingPasswordHash: pendingHash}, nil
	}
}

func setPasswordEligibility(u sqlc.User, s sqlc.Session) otp.Eligibility {
	return func(context.Context, pgx.Tx) (otp.Target, error) {
		return otp.Target{Eligible: true, UserID: &u.ID, SessionID: &s.ID, To: u.Email}, nil
	}
}

// --- flow callbacks ------------------------------------------------------------------------

// flowProbe records AfterAccept calls. Its steps insert a session for the challenge's user, as
// an OTP sign-in would, so tests can see whether the flow's writes committed.
type flowProbe struct {
	calls atomic.Int32
	mu    sync.Mutex
	last  otp.Accepted
	ids   []uuid.UUID
}

func (p *flowProbe) record(a otp.Accepted) {
	p.calls.Add(1)
	p.mu.Lock()
	p.last = a
	p.mu.Unlock()
}

// commit inserts a session (when the challenge has a user) and lets everything commit.
func (p *flowProbe) commit() otp.AfterAccept {
	return func(ctx context.Context, tx pgx.Tx, a otp.Accepted) error {
		p.record(a)
		return p.insertSession(ctx, tx, a)
	}
}

// fail inserts a session, then ends the flow with result.
func (p *flowProbe) fail(result error) otp.AfterAccept {
	return func(ctx context.Context, tx pgx.Tx, a otp.Accepted) error {
		p.record(a)
		if err := p.insertSession(ctx, tx, a); err != nil {
			return err
		}
		return result
	}
}

func (p *flowProbe) insertSession(ctx context.Context, tx pgx.Tx, a otp.Accepted) error {
	if a.UserID == nil {
		return nil
	}
	params := sessionParams(*a.UserID)
	if _, err := sqlc.New(tx).InsertSession(ctx, params); err != nil {
		return err
	}
	p.mu.Lock()
	p.ids = append(p.ids, params.ID)
	p.mu.Unlock()
	return nil
}

func (p *flowProbe) sessionIDs() []uuid.UUID {
	p.mu.Lock()
	defer p.mu.Unlock()
	return append([]uuid.UUID(nil), p.ids...)
}

func neverCalled(t *testing.T) otp.AfterAccept {
	return func(context.Context, pgx.Tx, otp.Accepted) error {
		t.Error("the flow must not run for a rejected code")
		return errors.New("unexpected accept")
	}
}

// --- state readers -------------------------------------------------------------------------

type challengeRow struct {
	id                       uuid.UUID
	purpose, delivery, email string
	attempts, maxAttempts    int
	consumed, superseded     bool
	userID, sessionID        *uuid.UUID
	pendingHash              *string
	codeHash                 []byte
	expiresInSeconds         float64
}

func (e *otpEnv) challenge(t *testing.T, token string) challengeRow {
	t.Helper()
	var c challengeRow
	err := e.d.Pool.QueryRow(context.Background(), `
		SELECT id, purpose, delivery, email, attempts, max_attempts, consumed_at IS NOT NULL,
		       superseded_at IS NOT NULL, user_id, session_id, pending_password_hash, code_hash,
		       extract(epoch FROM expires_at - created_at)::float8
		FROM otp_challenges WHERE token_hash = $1`, otp.HashToken(token)).Scan(
		&c.id, &c.purpose, &c.delivery, &c.email, &c.attempts, &c.maxAttempts, &c.consumed, &c.superseded,
		&c.userID, &c.sessionID, &c.pendingHash, &c.codeHash, &c.expiresInSeconds)
	if err != nil {
		t.Fatalf("read challenge: %v", err)
	}
	return c
}

type outboxState struct {
	status      string
	payloadNull bool
}

func (e *otpEnv) outboxFor(t *testing.T, challengeID uuid.UUID) []outboxState {
	t.Helper()
	rows, err := e.d.Pool.Query(context.Background(),
		`SELECT status, payload_ciphertext IS NULL FROM email_outbox WHERE challenge_id = $1 ORDER BY created_at`, challengeID)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var out []outboxState
	for rows.Next() {
		var s outboxState
		if err := rows.Scan(&s.status, &s.payloadNull); err != nil {
			t.Fatal(err)
		}
		out = append(out, s)
	}
	return out
}

func (e *otpEnv) failureReasons(t *testing.T, action string) []string {
	t.Helper()
	rows, err := e.d.Pool.Query(context.Background(),
		`SELECT coalesce(reason, '') FROM audit_events WHERE action = $1 AND outcome = 'failure' ORDER BY id`, action)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var r string
		if err := rows.Scan(&r); err != nil {
			t.Fatal(err)
		}
		out = append(out, r)
	}
	return out
}

// failureCount is the per-email verify-failure counter (TRD 10), summed over windows.
func (e *otpEnv) failureCount(t *testing.T, addr identity.Email) int {
	t.Helper()
	return rowCount(t, e.d.Pool, `SELECT coalesce(sum(count), 0)::int FROM rate_limit_counters WHERE key = $1`,
		"otp_verify_fail_email_1h:email:"+e.hmac.CurrentHex(addr))
}

// expireCooldown makes the next start for (purpose, email) allowed again.
func (e *otpEnv) expireCooldown(t *testing.T, purpose otp.Purpose, addr identity.Email) {
	t.Helper()
	mustExec(t, e.d.Pool, `UPDATE otp_cooldowns SET last_issued_at = now() - interval '61 seconds'
		WHERE purpose = $1 AND email_hmac = $2`, string(purpose), e.hmac.Current(addr))
}

func rateLimited(err error, rule string) bool {
	var rl *otp.RateLimitedError
	return errors.As(err, &rl) && rl.Rule == rule && rl.RetryAfter >= 1
}

var nonWord = `[^0-9A-Za-z]`

// assertNoSecrets: no issued code or token appears in logs, audit rows, challenge text columns
// or outbox errors (TRD 11.1, 11.2, AC-22). Codes are matched as whole words, so a run of digits
// inside a UUID or a hex digest does not count.
func (e *otpEnv) assertNoSecrets(t *testing.T) {
	ctx := context.Background()
	var b strings.Builder
	b.WriteString(e.logs.String())
	for _, query := range []string{
		`SELECT concat_ws(' ', purpose, signup_method, pending_password_hash, email, email_normalized, delivery) FROM otp_challenges`,
		`SELECT concat_ws(' ', action, outcome, reason, user_agent, request_id, metadata::text) FROM audit_events`,
		`SELECT concat_ws(' ', to_email, last_error, provider_message_id) FROM email_outbox`,
		`SELECT key FROM rate_limit_counters`,
	} {
		rows, err := e.d.Pool.Query(ctx, query)
		if err != nil {
			t.Errorf("hygiene query: %v", err)
			return
		}
		for rows.Next() {
			var s string
			_ = rows.Scan(&s)
			b.WriteString("\n" + s)
		}
		rows.Close()
	}
	hay := b.String()
	e.mu.Lock()
	defer e.mu.Unlock()
	for _, s := range e.secrets {
		if strings.HasPrefix(s, otp.TokenPrefix) {
			if strings.Contains(hay, s) || strings.Contains(hay, s[4:20]) {
				t.Errorf("a challenge token appears in logs or stored rows")
			}
			continue
		}
		if regexp.MustCompile(`(^|` + nonWord + `)` + s + `(` + nonWord + `|$)`).MatchString(hay) {
			t.Errorf("an OTP code appears in logs or stored rows")
		}
	}
	if strings.Contains(hay, otp.TokenPrefix) {
		t.Errorf("something token-shaped appears in logs or stored rows")
	}
}

// =============================================================================================
// Start
// =============================================================================================

func TestOTP_StartIssuesChallengeWithEncryptedEmail(t *testing.T) {
	env := newOTPEnv(t, nil)
	u, addr := env.user(t)
	ack, code := env.start(t, loginStart(addr))

	if !strings.HasPrefix(ack.ChallengeToken, "vct_") || len(ack.ChallengeToken) != 47 {
		t.Fatalf("challenge token has the wrong shape")
	}
	if d := ack.ResendAfter.Sub(ack.ExpiresAt); d != -9*time.Minute {
		t.Fatalf("resend_after should be 60 s after issue and expiry 10 min after; gap %s", d)
	}

	c := env.challenge(t, ack.ChallengeToken)
	if c.purpose != "login" || c.delivery != "code" || c.attempts != 0 || c.maxAttempts != 5 ||
		c.userID == nil || *c.userID != u.ID || c.sessionID != nil || c.consumed || c.superseded {
		t.Fatalf("unexpected challenge %+v", c)
	}
	if c.expiresInSeconds != 600 {
		t.Fatalf("lifetime %v s, want 600 on the database clock", c.expiresInSeconds)
	}
	if !bytes.Equal(c.codeHash, env.codes.Hash(c.id, code)) {
		t.Fatal("code_hash must be HMAC(VEEA_OTP_KEY, id || code)")
	}
	tokenHash := sha256.Sum256([]byte(ack.ChallengeToken))
	if rowCount(t, env.d.Pool, `SELECT count(*) FROM otp_challenges WHERE token_hash = $1`, tokenHash[:]) != 1 {
		t.Fatal("token_hash must be SHA-256 of the token")
	}

	// One pending, encrypted email, due no later than the challenge expiry.
	var ciphertext []byte
	var notAfterMatches bool
	err := env.d.Pool.QueryRow(context.Background(), `
		SELECT o.payload_ciphertext, o.not_after = c.expires_at FROM email_outbox o JOIN otp_challenges c ON c.id = o.challenge_id
		WHERE o.challenge_id = $1 AND o.status = 'pending' AND o.template = 'login_code' AND o.user_id = $2 AND o.to_email = $3`,
		c.id, u.ID, u.Email).Scan(&ciphertext, &notAfterMatches)
	if err != nil {
		t.Fatalf("expected one pending login_code email: %v", err)
	}
	if !notAfterMatches || bytes.Contains(ciphertext, []byte(code)) {
		t.Fatal("the email must expire with the challenge and carry only ciphertext")
	}
	// Cooldown and audit rows hold digests, never the address.
	if rowCount(t, env.d.Pool, `SELECT count(*) FROM otp_cooldowns WHERE purpose = 'login' AND email_hmac = $1`, env.hmac.Current(addr)) != 1 {
		t.Fatal("expected the cooldown claim")
	}
	if rowCount(t, env.d.Pool, `SELECT count(*) FROM audit_events WHERE action = 'auth.otp.start' AND outcome = 'success'
		AND target_user_id = $1 AND email_hmac = $2 AND metadata->>'delivery' = 'code' AND ip = '192.0.2.10'`, u.ID, env.hmac.Current(addr)) != 1 {
		t.Fatal("expected one success audit event with delivery=code")
	}

	// The worker delivers exactly that code to the account address.
	if s := runWorker(t, env); s.Sent != 1 {
		t.Fatalf("worker sent %d", s.Sent)
	}
	sent := env.fake.Sent()
	if len(sent) != 1 || sent[0].To != u.Email || !strings.Contains(sent[0].Text, code) {
		t.Fatal("expected the login code mailed to the account")
	}
}

func runWorker(t *testing.T, env *otpEnv) notify.Stats {
	t.Helper()
	s, err := env.worker.RunOnce(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func TestOTP_IneligibleStartIsInertAndLooksTheSame(t *testing.T) {
	env := newOTPEnv(t, nil)

	t.Run("login for an unknown email", func(t *testing.T) {
		addr := email(t, "nobody-"+uuid.NewString()+"@example.test")
		ack, _ := env.start(t, loginStart(addr))
		if !strings.HasPrefix(ack.ChallengeToken, "vct_") || ack.ExpiresAt.IsZero() || ack.ResendAfter.IsZero() {
			t.Fatal("an ineligible start must return the same acknowledgement shape")
		}
		c := env.challenge(t, ack.ChallengeToken)
		if c.delivery != "none" || c.userID != nil || c.sessionID != nil || c.pendingHash != nil {
			t.Fatalf("ineligible challenge must be inert, got %+v", c)
		}
		if len(env.outboxFor(t, c.id)) != 0 {
			t.Fatal("no email may be queued for an ineligible request")
		}
		if rowCount(t, env.d.Pool, `SELECT count(*) FROM audit_events WHERE action = 'auth.otp.start'
			AND metadata->>'delivery' = 'none' AND target_user_id IS NULL`) != 1 {
			t.Fatal("expected a success audit event with delivery=none and no target")
		}
	})

	t.Run("password signup for an existing account discards the hash", func(t *testing.T) {
		u, addr := env.user(t)
		before := rowCount(t, env.d.Pool, `SELECT count(*) FROM users`)
		ack, _ := env.start(t, otp.StartRequest{Purpose: otp.PurposeSignup, SignupMethod: otp.SignupPassword,
			Email: addr, Check: signupEligibility(addr, "$argon2id$v=19$m=19456,t=2,p=1$c2FsdA$aGFzaA"), IP: testIP()})
		c := env.challenge(t, ack.ChallengeToken)
		if c.delivery != "none" || c.pendingHash != nil || c.userID != nil {
			t.Fatalf("an existing-account signup must store no hash and no binding, got %+v", c)
		}
		if len(env.outboxFor(t, c.id)) != 0 || rowCount(t, env.d.Pool, `SELECT count(*) FROM users`) != before {
			t.Fatal("no email and no account change for an existing-account signup")
		}
		var updated time.Time
		if err := env.d.Pool.QueryRow(context.Background(), `SELECT updated_at FROM users WHERE id = $1`, u.ID).Scan(&updated); err != nil || !updated.Equal(u.UpdatedAt) {
			t.Fatal("the existing account must not be touched")
		}
	})

	if s := runWorker(t, env); s.Sent != 0 || env.fake.Calls() != 0 {
		t.Fatal("nothing may be mailed for ineligible requests")
	}
}

func TestOTP_ConcurrentFirstIssuance(t *testing.T) {
	for _, eligible := range []bool{true, false} {
		t.Run(fmt.Sprintf("eligible=%v", eligible), func(t *testing.T) {
			env := newOTPEnv(t, nil)
			var addr identity.Email
			if eligible {
				_, addr = env.user(t)
			} else {
				addr = email(t, "first-"+uuid.NewString()+"@example.test")
			}
			const n = 20
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			startGate := make(chan struct{})
			results := make([]error, n)
			acks := make([]otp.Acknowledgement, n)
			var wg sync.WaitGroup
			for i := range n {
				wg.Add(1)
				go func() {
					defer wg.Done()
					<-startGate
					acks[i], results[i] = env.svc.Start(ctx, loginStart(addr))
				}()
			}
			close(startGate)
			wg.Wait()

			ok, limited := 0, 0
			for i, err := range results {
				switch {
				case err == nil:
					ok++
					env.remember(acks[i].ChallengeToken)
				case rateLimited(err, otp.RuleCooldown):
					limited++
				default:
					t.Fatalf("unexpected error: %v", err)
				}
			}
			if ok != 1 || limited != n-1 {
				t.Fatalf("got %d issued and %d cooldown denials, want 1 and %d", ok, limited, n-1)
			}
			if got := rowCount(t, env.d.Pool, `SELECT count(*) FROM otp_challenges WHERE email_normalized = $1`, addr.Normalized); got != 1 {
				t.Fatalf("%d challenge rows, want 1", got)
			}
			wantMail := 0
			if eligible {
				wantMail = 1
			}
			if got := rowCount(t, env.d.Pool, `SELECT count(*) FROM email_outbox`); got != wantMail {
				t.Fatalf("%d outbox rows, want %d", got, wantMail)
			}
		})
	}
}

func TestOTP_RolledBackIssuanceLeavesNothingAndReleasesTheCooldown(t *testing.T) {
	env := newOTPEnv(t, nil)
	_, addr := env.user(t)
	ctx := context.Background()
	nothingLeft := func(t *testing.T) {
		t.Helper()
		for table, n := range map[string]int{
			"otp_challenges": rowCount(t, env.d.Pool, `SELECT count(*) FROM otp_challenges`),
			"email_outbox":   rowCount(t, env.d.Pool, `SELECT count(*) FROM email_outbox`),
			"otp_cooldowns":  rowCount(t, env.d.Pool, `SELECT count(*) FROM otp_cooldowns`),
			"audit_events":   rowCount(t, env.d.Pool, `SELECT count(*) FROM audit_events`),
		} {
			if n != 0 {
				t.Fatalf("%s has %d rows after a rolled-back start", table, n)
			}
		}
	}

	t.Run("failure after the email was enqueued", func(t *testing.T) {
		// The audit insert is the last statement of the start transaction (TRD 7.2 step 7), so
		// failing it rolls back the claim, the challenge and the enqueued email together.
		mustExec(t, env.d.Pool, `CREATE FUNCTION test_fail_audit() RETURNS trigger LANGUAGE plpgsql
			AS $$ BEGIN RAISE EXCEPTION 'forced failure'; END $$`)
		mustExec(t, env.d.Pool, `CREATE TRIGGER test_fail_audit BEFORE INSERT ON audit_events
			FOR EACH ROW EXECUTE FUNCTION test_fail_audit()`)
		env.random.queue(randomCode())
		if _, err := env.svc.Start(ctx, loginStart(addr)); err == nil {
			t.Fatal("expected the forced failure")
		}
		nothingLeft(t)
		mustExec(t, env.d.Pool, `DROP TRIGGER test_fail_audit ON audit_events`)
	})

	t.Run("failure in the eligibility check", func(t *testing.T) {
		req := loginStart(addr)
		req.Check = func(context.Context, pgx.Tx) (otp.Target, error) {
			return otp.Target{}, errors.New("users unavailable")
		}
		if _, err := env.svc.Start(ctx, req); err == nil {
			t.Fatal("expected the eligibility error")
		}
		nothingLeft(t)
	})

	// The claim went with the rollback, so a retry right away is not held by the cooldown.
	ack, _ := env.start(t, loginStart(addr))
	if c := env.challenge(t, ack.ChallengeToken); len(env.outboxFor(t, c.id)) != 1 {
		t.Fatal("the retried start must issue normally")
	}
}

func TestOTP_StartLimitsAreCountedBeforeTheTransaction(t *testing.T) {
	rules := generousRules()
	rules.StartEmailHourly.Limit = 2
	env := newOTPEnv(t, rules)
	_, addr := env.user(t)
	env.start(t, loginStart(addr))
	env.expireCooldown(t, otp.PurposeLogin, addr)
	env.start(t, loginStart(addr))
	env.expireCooldown(t, otp.PurposeLogin, addr)
	_, err := env.svc.Start(context.Background(), loginStart(addr))
	if !rateLimited(err, "otp_start_email_1h") {
		t.Fatalf("third start in the hour: %v, want rate_limited otp_start_email_1h", err)
	}
	if got := rowCount(t, env.d.Pool, `SELECT count(*) FROM otp_challenges`); got != 2 {
		t.Fatalf("%d challenges, want 2: a limited start must not open the transaction", got)
	}
	// Within the cooldown the answer is the same 429 for an unknown email (AC-27).
	unknown := email(t, "unknown-"+uuid.NewString()+"@example.test")
	env.start(t, loginStart(unknown))
	if _, err := env.svc.Start(context.Background(), loginStart(unknown)); !rateLimited(err, otp.RuleCooldown) {
		t.Fatalf("second start within 60 s: %v, want the cooldown", err)
	}
}

func TestOTP_ResendSupersedesAndOnlyTheNewCodeIsMailed(t *testing.T) {
	env := newOTPEnv(t, nil)
	_, addr := env.user(t)
	first, firstCode := env.start(t, loginStart(addr))
	env.expireCooldown(t, otp.PurposeLogin, addr)
	second, secondCode := env.start(t, loginStart(addr))

	old := env.challenge(t, first.ChallengeToken)
	if !old.superseded {
		t.Fatal("the first challenge must be superseded")
	}
	if got := env.outboxFor(t, old.id); len(got) != 1 || got[0].status != "cancelled" || !got[0].payloadNull {
		t.Fatalf("the superseded email must be cancelled and scrubbed in the start transaction, got %+v", got)
	}

	runWorker(t, env)
	sent := env.fake.Sent()
	if len(sent) != 1 || !strings.Contains(sent[0].Text, secondCode) || strings.Contains(sent[0].Text, firstCode) {
		t.Fatal("only the newest code may be mailed")
	}

	// The old code no longer works and the rejection is not counted (TRD 7.3 V2).
	if err := env.svc.Verify(context.Background(), loginVerify(first.ChallengeToken, firstCode), neverCalled(t)); !errors.Is(err, otp.ErrInvalidCode) {
		t.Fatalf("superseded code: %v, want invalid_code", err)
	}
	if env.challenge(t, first.ChallengeToken).attempts != 0 || env.failureCount(t, addr) != 0 {
		t.Fatal("a superseded challenge is unusable, not a counted failure")
	}
	var probe flowProbe
	if err := env.svc.Verify(context.Background(), loginVerify(second.ChallengeToken, secondCode), probe.commit()); err != nil {
		t.Fatalf("the newest code must work: %v", err)
	}
}

// =============================================================================================
// Verify
// =============================================================================================

func TestOTP_VerifyCommitsConsumptionWithTheFlow(t *testing.T) {
	env := newOTPEnv(t, nil)
	u, addr := env.user(t)
	ack, code := env.start(t, loginStart(addr))
	c := env.challenge(t, ack.ChallengeToken)

	var probe flowProbe
	if err := env.svc.Verify(context.Background(), loginVerify(ack.ChallengeToken, code), probe.commit()); err != nil {
		t.Fatal(err)
	}
	a := probe.last
	if probe.calls.Load() != 1 || a.ChallengeID != c.id || a.Purpose != otp.PurposeLogin || a.UserID == nil || *a.UserID != u.ID ||
		a.Email.Normalized != addr.Normalized || !bytes.Equal(a.EmailHMAC, env.hmac.Current(addr)) {
		t.Fatalf("unexpected accepted challenge %+v", a)
	}
	if got := env.challenge(t, ack.ChallengeToken); !got.consumed || got.attempts != 0 {
		t.Fatalf("challenge must be consumed without an attempt, got %+v", got)
	}
	if got := env.outboxFor(t, c.id); len(got) != 1 || got[0].status != "cancelled" || !got[0].payloadNull {
		t.Fatalf("the unsent code email must be cancelled with the redemption, got %+v", got)
	}
	if rowCount(t, env.d.Pool, `SELECT count(*) FROM sessions WHERE id = $1`, probe.sessionIDs()[0]) != 1 {
		t.Fatal("the flow's writes must commit with the consumption")
	}
	// Single use (AC-21).
	if err := env.svc.Verify(context.Background(), loginVerify(ack.ChallengeToken, code), neverCalled(t)); !errors.Is(err, otp.ErrInvalidCode) {
		t.Fatalf("reuse: %v, want invalid_code", err)
	}
	if runWorker(t, env).Sent != 0 {
		t.Fatal("a redeemed challenge's email must never be sent")
	}
}

func TestOTP_RollbackAfterValidRedemptionUndoesEverything(t *testing.T) {
	env := newOTPEnv(t, nil)
	_, addr := env.user(t)
	ack, code := env.start(t, loginStart(addr))
	c := env.challenge(t, ack.ChallengeToken)
	errUnavailable := errors.New("account_unavailable")

	t.Run("Rollback with a failure audit", func(t *testing.T) {
		var probe flowProbe
		err := env.svc.Verify(context.Background(), loginVerify(ack.ChallengeToken, code), probe.fail(otp.Rollback("account_unavailable", errUnavailable)))
		if !errors.Is(err, errUnavailable) || probe.calls.Load() != 1 {
			t.Fatalf("got %v, want the flow's error", err)
		}
		if got := env.challenge(t, ack.ChallengeToken); got.consumed || got.attempts != 0 {
			t.Fatalf("the consumption must roll back and no attempt be charged, got %+v", got)
		}
		if rowCount(t, env.d.Pool, `SELECT count(*) FROM sessions WHERE id = $1`, probe.sessionIDs()[0]) != 0 {
			t.Fatal("the flow's writes must roll back with the consumption")
		}
		if got := env.outboxFor(t, c.id); len(got) != 1 || got[0].status != "pending" || got[0].payloadNull {
			t.Fatalf("the cancellation must roll back too, got %+v", got)
		}
		// T-fail: only the failure audit event commits.
		if got := env.failureReasons(t, "auth.otp.verify"); len(got) != 1 || got[0] != "account_unavailable" {
			t.Fatalf("failure audit reasons %v", got)
		}
		if env.failureCount(t, addr) != 0 {
			t.Fatal("a post-accept failure is not a wrong code")
		}
	})

	t.Run("plain error rolls back without an audit event", func(t *testing.T) {
		var probe flowProbe
		boom := errors.New("internal")
		if err := env.svc.Verify(context.Background(), loginVerify(ack.ChallengeToken, code), probe.fail(boom)); !errors.Is(err, boom) {
			t.Fatalf("got %v", err)
		}
		if env.challenge(t, ack.ChallengeToken).consumed || len(env.failureReasons(t, "auth.otp.verify")) != 1 {
			t.Fatal("a plain error must roll back and add no audit event")
		}
	})

	// The same code still works once the cause is gone (TRD 7.5).
	var probe flowProbe
	if err := env.svc.Verify(context.Background(), loginVerify(ack.ChallengeToken, code), probe.commit()); err != nil {
		t.Fatalf("the code must remain usable after a rollback: %v", err)
	}
	if !env.challenge(t, ack.ChallengeToken).consumed {
		t.Fatal("expected the challenge consumed now")
	}
}

func TestOTP_CommitFailureKeepsTheConsumption(t *testing.T) {
	env := newOTPEnv(t, nil)
	addr := email(t, "Signup-"+uuid.NewString()+"@Example.test")
	ack, code := env.start(t, otp.StartRequest{Purpose: otp.PurposeSignup, SignupMethod: otp.SignupOTP,
		Email: addr, Check: signupEligibility(addr, ""), IP: testIP()})
	c := env.challenge(t, ack.ChallengeToken)
	if c.delivery != "code" || c.email != addr.Display {
		t.Fatalf("eligible signup challenge %+v", c)
	}
	if got := rowCount(t, env.d.Pool, `SELECT count(*) FROM email_outbox WHERE challenge_id = $1 AND template = 'signup_code' AND user_id IS NULL`, c.id); got != 1 {
		t.Fatal("expected a signup_code email with no user")
	}

	// The account appeared meanwhile (TRD 7.3): the flow keeps the consumption and answers 409.
	errUnavailable := errors.New("signup_unavailable")
	var probe flowProbe
	err := env.svc.Verify(context.Background(), otp.VerifyRequest{Purpose: otp.PurposeSignup, Token: ack.ChallengeToken, Code: code, IP: testIP()},
		probe.fail(otp.CommitFailure("account_exists", errUnavailable)))
	if !errors.Is(err, errUnavailable) {
		t.Fatalf("got %v", err)
	}
	if got := env.challenge(t, ack.ChallengeToken); !got.consumed {
		t.Fatal("the consumption must stay committed")
	}
	if got := env.outboxFor(t, c.id); got[0].status != "cancelled" || !got[0].payloadNull {
		t.Fatalf("the pending email must be cancelled, got %+v", got)
	}
	if got := env.failureReasons(t, "auth.signup.verify"); len(got) != 1 || got[0] != "account_exists" {
		t.Fatalf("failure audit reasons %v", got)
	}
}

func TestOTP_PasswordSignupHashLeavesTheRowOnRedemption(t *testing.T) {
	env := newOTPEnv(t, nil)
	addr := email(t, "pw-"+uuid.NewString()+"@example.test")
	const pending = "$argon2id$v=19$m=19456,t=2,p=1$c2FsdHNhbHQ$aGFzaGhhc2g"
	ack, code := env.start(t, otp.StartRequest{Purpose: otp.PurposeSignup, SignupMethod: otp.SignupPassword,
		Email: addr, Check: signupEligibility(addr, pending), IP: testIP()})
	if c := env.challenge(t, ack.ChallengeToken); c.pendingHash == nil || *c.pendingHash != pending {
		t.Fatal("an eligible password signup keeps its hash on the challenge until redemption")
	}
	var probe flowProbe
	if err := env.svc.Verify(context.Background(), otp.VerifyRequest{Purpose: otp.PurposeSignup, Token: ack.ChallengeToken, Code: code, IP: testIP()},
		probe.commit()); err != nil {
		t.Fatal(err)
	}
	if probe.last.PendingPasswordHash != pending || probe.last.SignupMethod != otp.SignupPassword {
		t.Fatal("the flow receives the pending hash in memory")
	}
	if c := env.challenge(t, ack.ChallengeToken); c.pendingHash != nil {
		t.Fatal("the hash must be cleared from the row by the consumption")
	}
}

func TestOTP_FailedAttemptsAreCommitted(t *testing.T) {
	env := newOTPEnv(t, nil)
	_, addr := env.user(t)
	ack, code := env.start(t, loginStart(addr))

	if err := env.svc.Verify(context.Background(), loginVerify(ack.ChallengeToken, wrongCode(code)), neverCalled(t)); !errors.Is(err, otp.ErrInvalidCode) {
		t.Fatalf("wrong code: %v", err)
	}
	// A brand new pool sees the attempt, so it was committed before the error returned.
	fresh, err := pgxpool.New(context.Background(), env.d.URL)
	if err != nil {
		t.Fatal(err)
	}
	defer fresh.Close()
	if n := rowCount(t, fresh, `SELECT attempts FROM otp_challenges WHERE token_hash = $1`, otp.HashToken(ack.ChallengeToken)); n != 1 {
		t.Fatalf("attempts = %d on a new connection, want 1", n)
	}
	if n := rowCount(t, fresh, `SELECT count(*) FROM audit_events WHERE action = 'auth.otp.verify' AND outcome = 'failure' AND reason = 'invalid_code'`); n != 1 {
		t.Fatal("the failure audit event commits with the attempt")
	}
	if env.failureCount(t, addr) != 1 {
		t.Fatal("C: the per-email failure counter is incremented after the commit")
	}
	if c := env.challenge(t, ack.ChallengeToken); c.consumed {
		t.Fatal("a wrong code consumes nothing")
	}
}

func TestOTP_ExhaustedAfterFiveFailures(t *testing.T) {
	env := newOTPEnv(t, nil)
	_, addr := env.user(t)
	ack, code := env.start(t, loginStart(addr))
	for i := range 5 {
		if err := env.svc.Verify(context.Background(), loginVerify(ack.ChallengeToken, wrongCode(code)), neverCalled(t)); !errors.Is(err, otp.ErrInvalidCode) {
			t.Fatalf("failure %d: %v, want invalid_code", i+1, err)
		}
	}
	// The right code no longer works (AC-21), and the exhausted check costs no attempt.
	if err := env.svc.Verify(context.Background(), loginVerify(ack.ChallengeToken, code), neverCalled(t)); !errors.Is(err, otp.ErrAttemptsExceeded) {
		t.Fatalf("right code after 5 failures: %v, want code_attempts_exceeded", err)
	}
	if c := env.challenge(t, ack.ChallengeToken); c.attempts != 5 || c.consumed {
		t.Fatalf("attempts %d, consumed %v", c.attempts, c.consumed)
	}
	want := []string{"invalid_code", "invalid_code", "invalid_code", "invalid_code", "invalid_code", "attempts_exceeded"}
	if got := env.failureReasons(t, "auth.otp.verify"); fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("audit reasons %v, want %v", got, want)
	}
	if env.failureCount(t, addr) != 5 {
		t.Fatalf("failure counter %d, want 5: the exhausted rejection is not counted", env.failureCount(t, addr))
	}
}

func TestOTP_ExpiredChallengeIsUnusable(t *testing.T) {
	env := newOTPEnv(t, nil)
	_, addr := env.user(t)
	ack, code := env.start(t, loginStart(addr))
	mustExec(t, env.d.Pool, `UPDATE otp_challenges SET expires_at = now() - interval '1 second' WHERE token_hash = $1`, otp.HashToken(ack.ChallengeToken))
	if err := env.svc.Verify(context.Background(), loginVerify(ack.ChallengeToken, code), neverCalled(t)); !errors.Is(err, otp.ErrInvalidCode) {
		t.Fatalf("expired: %v, want invalid_code", err)
	}
	if c := env.challenge(t, ack.ChallengeToken); c.attempts != 0 || c.consumed {
		t.Fatal("an expired challenge is unusable: not counted, not consumed")
	}
}

func TestOTP_UnknownOrMalformedTokenIsInvalidCode(t *testing.T) {
	env := newOTPEnv(t, nil)
	for _, tok := range []string{"vct_" + strings.Repeat("A", 43), "", "not-a-token", strings.Repeat("x", 4096)} {
		if err := env.svc.Verify(context.Background(), loginVerify(tok, "123456"), neverCalled(t)); !errors.Is(err, otp.ErrInvalidCode) {
			t.Fatalf("token %.10q: %v, want invalid_code", tok, err)
		}
	}
	if got := env.failureReasons(t, "auth.otp.verify"); len(got) != 4 {
		t.Fatalf("each rejection writes a failure audit event, got %v", got)
	}
}

func TestOTP_WrongPurposeIsInvalidAndNotCounted(t *testing.T) {
	env := newOTPEnv(t, nil)
	_, addr := env.user(t)
	ack, code := env.start(t, loginStart(addr))
	for _, p := range []otp.Purpose{otp.PurposePasswordReset, otp.PurposeSignup} {
		err := env.svc.Verify(context.Background(), otp.VerifyRequest{Purpose: p, Token: ack.ChallengeToken, Code: code, IP: testIP()}, neverCalled(t))
		if !errors.Is(err, otp.ErrInvalidCode) {
			t.Fatalf("%s endpoint with a login challenge: %v, want invalid_code", p, err)
		}
	}
	if c := env.challenge(t, ack.ChallengeToken); c.attempts != 0 || c.consumed {
		t.Fatal("a wrong-purpose presentation is unusable, not a counted failure")
	}
	var probe flowProbe
	if err := env.svc.Verify(context.Background(), loginVerify(ack.ChallengeToken, code), probe.commit()); err != nil {
		t.Fatalf("the right endpoint still works: %v", err)
	}
}

func TestOTP_SetPasswordIsBoundToTheCallersUserAndSession(t *testing.T) {
	env := newOTPEnv(t, nil)
	u, addr := env.user(t)
	s1, s2 := newSession(t, env.q, u.ID), newSession(t, env.q, u.ID)
	other := newUser(t, env.q)
	ack, code := env.start(t, otp.StartRequest{Purpose: otp.PurposeSetPassword, Email: addr, Check: setPasswordEligibility(u, s1), IP: testIP()})
	c := env.challenge(t, ack.ChallengeToken)
	if c.userID == nil || *c.userID != u.ID || c.sessionID == nil || *c.sessionID != s1.ID {
		t.Fatalf("set_password challenge must be bound to user and session, got %+v", c)
	}
	if rowCount(t, env.d.Pool, `SELECT count(*) FROM audit_events WHERE action = 'auth.password.set.start' AND actor_user_id = $1 AND session_id = $2`, u.ID, s1.ID) != 1 {
		t.Fatal("the start audit event names the acting user and session")
	}

	verify := func(user, session uuid.UUID, then otp.AfterAccept) error {
		return env.svc.Verify(context.Background(), otp.VerifyRequest{Purpose: otp.PurposeSetPassword, Token: ack.ChallengeToken, Code: code,
			UserID: &user, SessionID: &session, IP: testIP()}, then)
	}
	if err := verify(u.ID, s2.ID, neverCalled(t)); !errors.Is(err, otp.ErrInvalidCode) {
		t.Fatalf("another session of the same user: %v, want invalid_code", err)
	}
	if err := verify(other.ID, s1.ID, neverCalled(t)); !errors.Is(err, otp.ErrInvalidCode) {
		t.Fatalf("another user: %v, want invalid_code", err)
	}
	if c := env.challenge(t, ack.ChallengeToken); c.attempts != 0 {
		t.Fatal("a wrong binding is unusable, not a counted failure")
	}
	// Without the caller binding the request is a programming error, not a code rejection.
	if err := env.svc.Verify(context.Background(), otp.VerifyRequest{Purpose: otp.PurposeSetPassword, Token: ack.ChallengeToken, Code: code, IP: testIP()},
		neverCalled(t)); err == nil || errors.Is(err, otp.ErrInvalidCode) {
		t.Fatalf("missing binding: %v", err)
	}
	var probe flowProbe
	if err := verify(u.ID, s1.ID, probe.commit()); err != nil {
		t.Fatalf("the bound caller: %v", err)
	}
	if *probe.last.SessionID != s1.ID {
		t.Fatal("the flow receives the bound session")
	}
}

// TRD 4.4 and 12.3 (TestDeliveryNone_NeverAuthenticates): the correct stored code of an inert
// challenge behaves exactly like a wrong code on a real one.
func TestOTP_DeliveryNoneNeverRedeems(t *testing.T) {
	env := newOTPEnv(t, nil)
	unknown := email(t, "none-"+uuid.NewString()+"@example.test")
	_, existing := env.user(t)
	type inertCase struct {
		name  string
		addr  identity.Email
		start otp.StartRequest
		req   func(token, code string) otp.VerifyRequest
		act   string
	}
	cases := []inertCase{
		{"login for an unknown email", unknown, loginStart(unknown), loginVerify, "auth.otp.verify"},
		{"signup for an existing account", existing,
			otp.StartRequest{Purpose: otp.PurposeSignup, SignupMethod: otp.SignupOTP, Email: existing, Check: signupEligibility(existing, ""), IP: testIP()},
			func(token, code string) otp.VerifyRequest {
				return otp.VerifyRequest{Purpose: otp.PurposeSignup, Token: token, Code: code, IP: testIP()}
			}, "auth.signup.verify"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			ack, storedCode := env.start(t, c.start)
			ch := env.challenge(t, ack.ChallengeToken)
			if ch.delivery != "none" || !env.codes.Match(ch.id, storedCode, ch.codeHash) {
				t.Fatal("setup: expected an inert challenge whose stored code the test knows")
			}
			if len(env.outboxFor(t, ch.id)) != 0 {
				t.Fatal("no email for an inert challenge")
			}
			for i := range 5 {
				if err := env.svc.Verify(context.Background(), c.req(ack.ChallengeToken, storedCode), neverCalled(t)); !errors.Is(err, otp.ErrInvalidCode) {
					t.Fatalf("try %d with the stored code: %v, want invalid_code", i+1, err)
				}
			}
			if err := env.svc.Verify(context.Background(), c.req(ack.ChallengeToken, storedCode), neverCalled(t)); !errors.Is(err, otp.ErrAttemptsExceeded) {
				t.Fatalf("sixth try: %v, want code_attempts_exceeded", err)
			}
			if got := env.challenge(t, ack.ChallengeToken); got.attempts != 5 || got.consumed {
				t.Fatalf("attempts %d consumed %v: accounting must match a wrong code", got.attempts, got.consumed)
			}
			if env.failureCount(t, c.addr) != 5 {
				t.Fatalf("per-email failures %d, want 5", env.failureCount(t, c.addr))
			}
			reasons := env.failureReasons(t, c.act)
			if len(reasons) != 6 || reasons[0] != "invalid_code" || reasons[5] != "attempts_exceeded" {
				t.Fatalf("audit reasons %v", reasons)
			}
		})
	}
	// The table constraint is the backstop (TRD 4.4 "belt and braces").
	var id uuid.UUID
	if err := env.d.Pool.QueryRow(context.Background(), `SELECT id FROM otp_challenges WHERE delivery = 'none' LIMIT 1`).Scan(&id); err != nil {
		t.Fatal(err)
	}
	_, err := env.d.Pool.Exec(context.Background(), `UPDATE otp_challenges SET consumed_at = now() WHERE id = $1`, id)
	wantPgError(t, err, pgCheck, "otp_none_inert")
	if rowCount(t, env.d.Pool, `SELECT count(*) FROM sessions`) != 0 {
		t.Fatal("no session may exist")
	}
}

func TestOTP_ConcurrentRedemptionSucceedsOnce(t *testing.T) {
	env := newOTPEnv(t, nil)
	_, addr := env.user(t)
	ack, code := env.start(t, loginStart(addr))

	const n = 20
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	var probe flowProbe
	gate := make(chan struct{})
	results := make([]error, n)
	var wg sync.WaitGroup
	for i := range n {
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-gate
			results[i] = env.svc.Verify(ctx, loginVerify(ack.ChallengeToken, code), probe.commit())
		}()
	}
	close(gate)
	wg.Wait()
	ok := 0
	for _, err := range results {
		switch {
		case err == nil:
			ok++
		case errors.Is(err, otp.ErrInvalidCode):
		default:
			t.Fatalf("unexpected error: %v", err)
		}
	}
	if ok != 1 || probe.calls.Load() != 1 {
		t.Fatalf("%d successes and %d flow runs, want exactly one of each", ok, probe.calls.Load())
	}
	if rowCount(t, env.d.Pool, `SELECT count(*) FROM sessions`) != 1 {
		t.Fatal("exactly one session")
	}
	if c := env.challenge(t, ack.ChallengeToken); c.attempts != 0 {
		t.Fatal("losers saw a consumed challenge: unusable, not counted")
	}
}

// TRD 12.3 TestConcurrent_VerifyVsStartSupersede: they serialize on the challenge row. Exactly
// one of them closes the old challenge and its email, never both, and nothing deadlocks.
func TestOTP_VerifyRacingASupersedingStart(t *testing.T) {
	env := newOTPEnv(t, nil)
	_, addr := env.user(t)
	for round := range 10 {
		ack, code := env.start(t, loginStart(addr))
		env.expireCooldown(t, otp.PurposeLogin, addr)
		old := env.challenge(t, ack.ChallengeToken)

		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		gate := make(chan struct{})
		var verifyErr, startErr error
		var newAck otp.Acknowledgement
		var probe flowProbe
		var wg sync.WaitGroup
		wg.Add(2)
		go func() {
			defer wg.Done()
			<-gate
			verifyErr = env.svc.Verify(ctx, loginVerify(ack.ChallengeToken, code), probe.commit())
		}()
		go func() { defer wg.Done(); <-gate; newAck, startErr = env.svc.Start(ctx, loginStart(addr)) }()
		close(gate)
		wg.Wait()
		cancel()
		if startErr != nil {
			t.Fatalf("round %d: start: %v", round, startErr)
		}
		env.remember(newAck.ChallengeToken)

		got := env.challenge(t, ack.ChallengeToken)
		mail := env.outboxFor(t, old.id)
		if len(mail) != 1 || mail[0].status != "cancelled" || !mail[0].payloadNull {
			t.Fatalf("round %d: the old email must end cancelled exactly once, got %+v", round, mail)
		}
		switch {
		case verifyErr == nil:
			if !got.consumed || got.superseded {
				t.Fatalf("round %d: verify won, so the challenge is consumed and not superseded: %+v", round, got)
			}
		case errors.Is(verifyErr, otp.ErrInvalidCode):
			if got.consumed || !got.superseded {
				t.Fatalf("round %d: start won, so the challenge is superseded and not consumed: %+v", round, got)
			}
		default:
			t.Fatalf("round %d: verify: %v", round, verifyErr)
		}
		env.expireCooldown(t, otp.PurposeLogin, addr)
	}
}

func TestOTP_VerifyFailureLimitIsCheckedBeforeTheTransaction(t *testing.T) {
	rules := generousRules()
	rules.VerifyFailEmail.Limit = 3
	env := newOTPEnv(t, rules)
	_, addr := env.user(t)
	ack, code := env.start(t, loginStart(addr))
	for range 3 {
		if err := env.svc.Verify(context.Background(), loginVerify(ack.ChallengeToken, wrongCode(code)), neverCalled(t)); !errors.Is(err, otp.ErrInvalidCode) {
			t.Fatal(err)
		}
	}
	audits := rowCount(t, env.d.Pool, `SELECT count(*) FROM audit_events`)
	// P: further verifies for this email are refused before any transaction, even with the
	// right code, and nothing is recorded on the challenge.
	if err := env.svc.Verify(context.Background(), loginVerify(ack.ChallengeToken, code), neverCalled(t)); !rateLimited(err, "otp_verify_fail_email_1h") {
		t.Fatalf("got %v, want rate_limited otp_verify_fail_email_1h", err)
	}
	if c := env.challenge(t, ack.ChallengeToken); c.attempts != 3 || c.consumed {
		t.Fatalf("the pre-check must not touch the challenge: %+v", c)
	}
	if rowCount(t, env.d.Pool, `SELECT count(*) FROM audit_events`) != audits {
		t.Fatal("the pre-check opens no transaction")
	}
	if env.failureCount(t, addr) != 3 {
		t.Fatal("the pre-check counts nothing")
	}
}
