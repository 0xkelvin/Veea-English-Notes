//go:build integration

package integration

import (
	"bytes"
	"context"
	"encoding/hex"
	"fmt"
	"log/slog"
	mrand "math/rand/v2"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/notify"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/db/sqlc"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/pgtest"
)

// Test keys. Throwaway values, never used outside tests.
var (
	outboxKey1 = bytes.Repeat([]byte{0x11}, 32)
	outboxKey2 = bytes.Repeat([]byte{0x22}, 32)
)

// syncBuffer is a concurrency-safe log sink, so tests can assert what the worker logged.
type syncBuffer struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (s *syncBuffer) Write(p []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.b.Write(p)
}
func (s *syncBuffer) String() string { s.mu.Lock(); defer s.mu.Unlock(); return s.b.String() }

type outboxEnv struct {
	d      *pgtest.DB
	q      *sqlc.Queries
	keys   *notify.Keyring
	box    *notify.Outbox
	fake   *notify.FakeSender
	logs   *syncBuffer
	codes  []string // every code enqueued, for the log hygiene check
	user   sqlc.User
	worker *notify.Worker
}

func newOutboxEnv(t *testing.T, cfg notify.WorkerConfig) *outboxEnv {
	t.Helper()
	d, q := migratedDB(t)
	keys, err := notify.NewKeyring(notify.Key{ID: 1, Key: outboxKey1})
	if err != nil {
		t.Fatal(err)
	}
	env := &outboxEnv{d: d, q: q, keys: keys, box: notify.NewOutbox(keys), fake: &notify.FakeSender{}, logs: &syncBuffer{}}
	env.user = newUser(t, q)
	cfg.Logger = slog.New(slog.NewJSONHandler(env.logs, &slog.HandlerOptions{Level: slog.LevelDebug}))
	env.worker = env.newWorker(t, d.Pool, cfg)
	t.Cleanup(func() { env.assertCleanLogs(t) })
	return env
}

func (e *outboxEnv) newWorker(t *testing.T, pool *pgxpool.Pool, cfg notify.WorkerConfig) *notify.Worker {
	t.Helper()
	if cfg.Logger == nil {
		cfg.Logger = slog.New(slog.NewJSONHandler(e.logs, nil))
	}
	w, err := notify.NewWorker(pool, e.keys, e.fake, cfg)
	if err != nil {
		t.Fatal(err)
	}
	return w
}

// codeFixture inserts an open login challenge and its code email in one transaction, the way
// otp.Service.Start does, without its limits and cooldown, so worker tests control every row.
// It returns the outbox and challenge ids and the code.
func (e *outboxEnv) codeFixture(t *testing.T) (outboxID, challengeID uuid.UUID, code string) {
	t.Helper()
	ctx := context.Background()
	codeUser := newUser(t, e.q)
	code = fmt.Sprintf("%06d", 100000+mrand.IntN(900000)) // distinctive, so a leak is detectable
	e.codes = append(e.codes, code)

	tx, err := e.d.Pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx)
	p := challengeParams("login", codeUser.EmailNormalized, "code")
	p.UserID = &codeUser.ID
	ch, err := sqlc.New(tx).InsertOTPChallenge(ctx, p)
	if err != nil {
		t.Fatal(err)
	}
	id, err := e.box.Enqueue(ctx, tx, notify.Message{
		Template: notify.TemplateLoginCode, To: codeUser.Email, UserID: &codeUser.ID,
		ChallengeID: &ch.ID, NotAfter: &ch.ExpiresAt, Payload: notify.Payload{Code: code}})
	if err != nil {
		t.Fatal(err)
	}
	if err := tx.Commit(ctx); err != nil {
		t.Fatal(err)
	}
	return id, ch.ID, code
}

func (e *outboxEnv) noticeFixture(t *testing.T) uuid.UUID {
	t.Helper()
	ctx := context.Background()
	tx, err := e.d.Pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx)
	id, err := e.box.Enqueue(ctx, tx, notify.Message{
		Template: notify.TemplatePasswordChanged, To: e.user.Email, UserID: &e.user.ID,
		Payload: notify.Payload{DeviceName: "Test phone", OccurredAt: time.Date(2026, 11, 14, 8, 0, 0, 0, time.UTC)}})
	if err != nil {
		t.Fatal(err)
	}
	if err := tx.Commit(ctx); err != nil {
		t.Fatal(err)
	}
	return id
}

type outboxRow struct {
	status, lastError      string
	sendAttempts           int
	payloadNull, leaseNull bool
	providerID             string
	nextAttemptInSeconds   float64
}

func (e *outboxEnv) row(t *testing.T, id uuid.UUID) outboxRow {
	t.Helper()
	var r outboxRow
	var lastError, providerID *string
	err := e.d.Pool.QueryRow(context.Background(), `
		SELECT status, last_error, send_attempts, payload_ciphertext IS NULL, lease_token IS NULL,
		       provider_message_id, extract(epoch FROM next_attempt_at - now())::float8
		FROM email_outbox WHERE id = $1`, id).Scan(&r.status, &lastError, &r.sendAttempts, &r.payloadNull,
		&r.leaseNull, &providerID, &r.nextAttemptInSeconds)
	if err != nil {
		t.Fatal(err)
	}
	if lastError != nil {
		r.lastError = *lastError
	}
	if providerID != nil {
		r.providerID = *providerID
	}
	return r
}

func (e *outboxEnv) runOnce(t *testing.T) notify.Stats {
	t.Helper()
	s, err := e.worker.RunOnce(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	return s
}

// makeDue moves a retry forward so the next cycle picks it up.
func (e *outboxEnv) makeDue(t *testing.T, id uuid.UUID) {
	t.Helper()
	mustExec(t, e.d.Pool, `UPDATE email_outbox SET next_attempt_at = now() WHERE id = $1`, id)
}

// assertCleanLogs: logs and stored errors never contain codes, key material or payloads.
func (e *outboxEnv) assertCleanLogs(t *testing.T) {
	logs := e.logs.String()
	var stored strings.Builder
	rows, err := e.d.Pool.Query(context.Background(), `SELECT coalesce(last_error, '') || ' ' || coalesce(provider_message_id, '') FROM email_outbox`)
	if err == nil {
		for rows.Next() {
			var s string
			_ = rows.Scan(&s)
			stored.WriteString(s + "\n")
		}
		rows.Close()
	}
	for _, code := range e.codes {
		if strings.Contains(logs, code) || strings.Contains(stored.String(), code) {
			t.Errorf("an OTP code appears in logs or stored errors")
		}
	}
	for _, secret := range []string{hex.EncodeToString(outboxKey1), hex.EncodeToString(outboxKey1)[:16], `"code":`} {
		if strings.Contains(logs, secret) {
			t.Errorf("logs contain %q", secret)
		}
	}
}

// --- enqueue ------------------------------------------------------------------------------

func TestOutbox_EnqueueEncryptsAndIsTransactionScoped(t *testing.T) {
	env := newOutboxEnv(t, notify.WorkerConfig{})
	ctx := context.Background()
	id, chID, code := env.codeFixture(t)

	var sealed []byte
	var keyID int16
	var notAfterMatches bool
	err := env.d.Pool.QueryRow(ctx, `
		SELECT o.payload_ciphertext, o.payload_key_id, o.not_after = c.expires_at
		FROM email_outbox o JOIN otp_challenges c ON c.id = o.challenge_id WHERE o.id = $1`, id).Scan(&sealed, &keyID, &notAfterMatches)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(sealed, []byte(code)) || bytes.Contains(sealed, []byte("code")) {
		t.Fatal("the stored payload is not encrypted")
	}
	if keyID != 1 || !notAfterMatches {
		t.Fatalf("key id %d, not_after equals challenge expiry: %v", keyID, notAfterMatches)
	}
	// The ciphertext is bound to its row id.
	if _, err := env.keys.Open(chID, keyID, sealed); err == nil {
		t.Fatal("the payload opened under a different row id")
	}

	// A notification gets not_after = created_at + 24 h on the database clock.
	nid := env.noticeFixture(t)
	var hours float64
	_ = env.d.Pool.QueryRow(ctx, `SELECT extract(epoch FROM not_after - created_at) / 3600 FROM email_outbox WHERE id = $1`, nid).Scan(&hours)
	if hours != 24 {
		t.Fatalf("notification deadline = %v h after creation, want 24", hours)
	}

	// Rolled back with its transaction: no row.
	tx, _ := env.d.Pool.Begin(ctx)
	rolled, err := env.box.Enqueue(ctx, tx, notify.Message{
		Template: notify.TemplatePasswordAdded, To: env.user.Email, UserID: &env.user.ID,
		Payload: notify.Payload{DeviceName: "x", OccurredAt: time.Now()}})
	if err != nil {
		t.Fatal(err)
	}
	_ = tx.Rollback(ctx)
	if n := rowCount(t, env.d.Pool, `SELECT count(*) FROM email_outbox WHERE id = $1`, rolled); n != 0 {
		t.Fatal("an email enqueued in a rolled-back transaction must not exist")
	}

	// Invalid messages are refused before anything is written.
	tx2, _ := env.d.Pool.Begin(ctx)
	defer tx2.Rollback(ctx)
	if _, err := env.box.Enqueue(ctx, tx2, notify.Message{Template: notify.TemplateLoginCode, To: env.user.Email,
		Payload: notify.Payload{Code: "123456"}}); err == nil {
		t.Fatal("a code email without a challenge must be refused")
	}
}

// --- delivery -----------------------------------------------------------------------------

func TestOutbox_DeliversAndScrubs(t *testing.T) {
	env := newOutboxEnv(t, notify.WorkerConfig{})
	id, _, code := env.codeFixture(t)
	nid := env.noticeFixture(t)

	s := env.runOnce(t)
	if s.Claimed != 2 || s.Sent != 2 {
		t.Fatalf("stats: %+v", s)
	}
	sent := env.fake.Sent()
	if len(sent) != 2 {
		t.Fatalf("sent %d", len(sent))
	}
	byID := map[uuid.UUID]notify.Email{sent[0].ID: sent[0], sent[1].ID: sent[1]}
	codeMail, ok := byID[id]
	var recipient string
	if err := env.d.Pool.QueryRow(context.Background(), `SELECT to_email FROM email_outbox WHERE id=$1`, id).Scan(&recipient); err != nil {
		t.Fatal(err)
	}
	if !ok || codeMail.To != recipient || !strings.Contains(codeMail.Text, code) || !strings.Contains(codeMail.HTML, code) {
		t.Fatalf("code email: %+v", codeMail)
	}
	if notice := byID[nid]; !strings.Contains(notice.Text, "Test phone") || !strings.Contains(notice.Text, "reset your password") {
		t.Fatalf("notification: %+v", notice)
	}

	for _, rid := range []uuid.UUID{id, nid} {
		r := env.row(t, rid)
		if r.status != "sent" || !r.payloadNull || !r.leaseNull || r.sendAttempts != 1 || r.providerID != "fake-"+rid.String() || r.lastError != "" {
			t.Fatalf("row after delivery: %+v", r)
		}
	}
	// Nothing left to do.
	if s := env.runOnce(t); s.Claimed != 0 || env.fake.Calls() != 2 {
		t.Fatalf("a sent row must not be sent again: %+v", s)
	}
}

func TestOutbox_RetryableErrorBacksOffThenDelivers(t *testing.T) {
	env := newOutboxEnv(t, notify.WorkerConfig{})
	env.fake.Respond = func(_ context.Context, e notify.Email, call int) (string, error) {
		if call == 1 {
			return "", notify.Retryable("throttled")
		}
		return "msg-2", nil
	}
	id, _, code := env.codeFixture(t)

	if s := env.runOnce(t); s.Retried != 1 {
		t.Fatalf("stats: %+v", s)
	}
	r := env.row(t, id)
	if r.status != "pending" || r.sendAttempts != 1 || r.payloadNull || !r.leaseNull || r.lastError != "retryable:throttled" {
		t.Fatalf("after a retryable error: %+v", r)
	}
	if r.nextAttemptInSeconds < 25 || r.nextAttemptInSeconds > 31 {
		t.Fatalf("first backoff should be 30 s, next attempt in %.1f s", r.nextAttemptInSeconds)
	}
	if s := env.runOnce(t); s.Claimed != 0 {
		t.Fatal("a row in backoff must not be claimed")
	}

	env.makeDue(t, id)
	if s := env.runOnce(t); s.Sent != 1 {
		t.Fatalf("stats: %+v", s)
	}
	r = env.row(t, id)
	if r.status != "sent" || r.sendAttempts != 2 || !r.payloadNull || r.providerID != "msg-2" {
		t.Fatalf("after success: %+v", r)
	}
	// Both attempts carried the same payload: a retry never makes a new code.
	sent := env.fake.Sent()
	if !strings.Contains(sent[0].Text, code) || sent[0].Text != sent[1].Text {
		t.Fatal("the retry must send the identical email")
	}
}

// TRD 8.3: an uncertain outcome is retried, so the recipient may get the same email twice.
func TestOutbox_AmbiguousTimeoutIsRetriedWithTheSamePayload(t *testing.T) {
	env := newOutboxEnv(t, notify.WorkerConfig{SendTimeout: 200 * time.Millisecond})
	env.fake.Respond = func(ctx context.Context, e notify.Email, call int) (string, error) {
		if call == 1 {
			<-ctx.Done() // the provider hangs, as if it accepted but never answered
			return "", ctx.Err()
		}
		return "msg", nil
	}
	id, _, _ := env.codeFixture(t)

	start := time.Now()
	if s := env.runOnce(t); s.Retried != 1 {
		t.Fatalf("stats: %+v", s)
	}
	if time.Since(start) > 5*time.Second {
		t.Fatal("the send timeout was not enforced")
	}
	if r := env.row(t, id); r.status != "pending" || r.lastError != "ambiguous:timeout" || r.sendAttempts != 1 {
		t.Fatalf("after a timeout: %+v", r)
	}
	env.makeDue(t, id)
	env.runOnce(t)
	if r := env.row(t, id); r.status != "sent" || r.sendAttempts != 2 {
		t.Fatalf("after the retry: %+v", r)
	}
	sent := env.fake.Sent()
	if len(sent) != 2 || sent[0].Text != sent[1].Text || sent[0].ID != sent[1].ID {
		t.Fatal("the duplicate must be the same email with the same idempotency id")
	}
}

func TestOutbox_UnclassifiedErrorIsTreatedAsAmbiguous(t *testing.T) {
	env := newOutboxEnv(t, notify.WorkerConfig{})
	env.fake.Respond = func(context.Context, notify.Email, int) (string, error) {
		return "", fmt.Errorf("provider said: 500 internal, request id abc, code %s", "999999")
	}
	id, _, _ := env.codeFixture(t)
	env.runOnce(t)
	r := env.row(t, id)
	if r.status != "pending" || r.lastError != "ambiguous:unclassified" {
		t.Fatalf("got %+v", r)
	}
	if strings.Contains(env.logs.String(), "999999") || strings.Contains(r.lastError, "provider said") {
		t.Fatal("the provider's error text leaked into logs or last_error")
	}
}

func TestOutbox_PermanentErrorFailsWithoutRetry(t *testing.T) {
	env := newOutboxEnv(t, notify.WorkerConfig{})
	env.fake.Respond = func(context.Context, notify.Email, int) (string, error) {
		return "", notify.Permanent("smtp_rcpt_550")
	}
	id, _, _ := env.codeFixture(t)
	if s := env.runOnce(t); s.Failed != 1 {
		t.Fatalf("stats: %+v", s)
	}
	r := env.row(t, id)
	if r.status != "failed" || !r.payloadNull || !r.leaseNull || r.lastError != "permanent:smtp_rcpt_550" || r.sendAttempts != 1 {
		t.Fatalf("got %+v", r)
	}
	env.makeDue(t, id)
	env.runOnce(t)
	if env.fake.Calls() != 1 {
		t.Fatal("a permanent failure must never be retried")
	}
}

func TestOutbox_FiveSendBudget(t *testing.T) {
	env := newOutboxEnv(t, notify.WorkerConfig{})
	env.fake.Respond = func(context.Context, notify.Email, int) (string, error) {
		return "", notify.Ambiguous("no_reply")
	}
	id, _, _ := env.codeFixture(t)
	for i := 1; i <= notify.MaxSends; i++ {
		env.makeDue(t, id)
		s := env.runOnce(t)
		if env.fake.Calls() != i {
			t.Fatalf("cycle %d: provider calls = %d", i, env.fake.Calls())
		}
		if i < notify.MaxSends && (s.Retried != 1 || env.row(t, id).status != "pending") {
			t.Fatalf("cycle %d: expected a retry, stats %+v", i, s)
		}
		if i == notify.MaxSends {
			// The fifth result itself makes the row terminal. The reaper is only the crash backstop.
			if s.Failed != 1 || s.Reaped != 0 {
				t.Fatalf("fifth cycle: %+v", s)
			}
		}
	}
	r := env.row(t, id)
	if r.status != "failed" || r.lastError != "send_budget_exhausted" || r.sendAttempts != 5 || !r.payloadNull || !r.leaseNull {
		t.Fatalf("got %+v", r)
	}
	for i := 0; i < 3; i++ {
		env.makeDue(t, id)
		env.runOnce(t)
	}
	if env.fake.Calls() != notify.MaxSends {
		t.Fatalf("provider called %d times, budget is %d", env.fake.Calls(), notify.MaxSends)
	}
}

// --- challenge re-check -------------------------------------------------------------------

func TestOutbox_ClosedChallengeIsCancelledWithoutSending(t *testing.T) {
	cases := map[string]string{
		"consumed":   `UPDATE otp_challenges SET consumed_at = now() WHERE id = $1`,
		"superseded": `UPDATE otp_challenges SET superseded_at = now() WHERE id = $1`,
		// The outbox deadline is still in the future here, so only the re-check catches it.
		"expired": `UPDATE otp_challenges SET expires_at = now() - interval '1 second' WHERE id = $1`,
	}
	for name, change := range cases {
		t.Run(name, func(t *testing.T) {
			env := newOutboxEnv(t, notify.WorkerConfig{})
			id, chID, _ := env.codeFixture(t)
			// Close the challenge without cancelling its email, as a race with the worker would.
			mustExec(t, env.d.Pool, change, chID)

			if s := env.runOnce(t); s.Cancelled != 1 || s.Sent != 0 {
				t.Fatalf("stats: %+v", s)
			}
			if env.fake.Calls() != 0 {
				t.Fatal("an email for a closed challenge must not be sent")
			}
			r := env.row(t, id)
			if r.status != "cancelled" || !r.payloadNull || !r.leaseNull || r.sendAttempts != 0 || r.lastError != "challenge_closed" {
				t.Fatalf("got %+v", r)
			}
		})
	}
}

func TestOutbox_CancelForChallengeScrubsInTheCallersTransaction(t *testing.T) {
	env := newOutboxEnv(t, notify.WorkerConfig{})
	ctx := context.Background()
	id, chID, _ := env.codeFixture(t)

	tx, _ := env.d.Pool.Begin(ctx)
	if n, err := env.box.CancelForChallenge(ctx, tx, chID); err != nil || n != 1 {
		t.Fatalf("cancel: %d %v", n, err)
	}
	_ = tx.Rollback(ctx)
	if r := env.row(t, id); r.status != "pending" {
		t.Fatal("a rolled-back cancel must leave the row pending")
	}

	tx, _ = env.d.Pool.Begin(ctx)
	_, _ = env.box.CancelForChallenge(ctx, tx, chID)
	_ = tx.Commit(ctx)
	if r := env.row(t, id); r.status != "cancelled" || !r.payloadNull {
		t.Fatalf("got %+v", r)
	}
	env.runOnce(t)
	if env.fake.Calls() != 0 {
		t.Fatal("a cancelled row must not be sent")
	}
}

// --- leases -------------------------------------------------------------------------------

// The worker's lease is taken away while the provider call is in flight. Its result write must
// change nothing, and the row is sent again later: the documented duplicate.
func TestOutbox_StaleLeaseResultIsDiscarded(t *testing.T) {
	env := newOutboxEnv(t, notify.WorkerConfig{})
	var id uuid.UUID
	env.fake.Respond = func(_ context.Context, _ notify.Email, call int) (string, error) {
		if call == 1 {
			mustExec(t, env.d.Pool, `UPDATE email_outbox SET lease_expires_at = now() - interval '1 second' WHERE id = $1`, id)
		}
		return fmt.Sprintf("msg-%d", call), nil
	}
	id, _, _ = env.codeFixture(t)

	if s := env.runOnce(t); s.StaleResults != 1 || s.Sent != 0 {
		t.Fatalf("stats: %+v", s)
	}
	r := env.row(t, id)
	if r.status != "pending" || r.sendAttempts != 1 || r.payloadNull || r.providerID != "" {
		t.Fatalf("a stale result must not be recorded: %+v", r)
	}
	if !strings.Contains(env.logs.String(), id.String()) {
		t.Fatal("the discarded result should be logged by row id")
	}

	if s := env.runOnce(t); s.Sent != 1 {
		t.Fatalf("stats: %+v", s)
	}
	r = env.row(t, id)
	if r.status != "sent" || r.sendAttempts != 2 || r.providerID != "msg-2" {
		t.Fatalf("got %+v", r)
	}
	if env.worker.Totals().StaleResults != 1 {
		t.Fatal("the stale-result counter must count it")
	}
}

func TestOutbox_ReclaimedByAnotherWorkerIsNotOverwritten(t *testing.T) {
	env := newOutboxEnv(t, notify.WorkerConfig{})
	var id uuid.UUID
	env.fake.Respond = func(_ context.Context, _ notify.Email, call int) (string, error) {
		if call == 1 {
			// Another worker took a fresh lease on the row in the meantime.
			mustExec(t, env.d.Pool, `UPDATE email_outbox SET lease_token = gen_random_uuid(), lease_expires_at = now() + interval '2 minutes' WHERE id = $1`, id)
		}
		return "msg", nil
	}
	id, _, _ = env.codeFixture(t)
	if s := env.runOnce(t); s.StaleResults != 1 {
		t.Fatalf("stats: %+v", s)
	}
	if r := env.row(t, id); r.status != "pending" || r.leaseNull {
		t.Fatalf("the other worker's lease must be left alone: %+v", r)
	}
}

// A skipped claim (too little lease left to reserve) gives the row back with its budget intact.
func TestOutbox_SkippedClaimsDoNotSpendTheBudget(t *testing.T) {
	env := newOutboxEnv(t, notify.WorkerConfig{})
	id, _, _ := env.codeFixture(t)
	starved := env.newWorker(t, env.d.Pool, notify.WorkerConfig{Lease: 2 * time.Second, MinLeaseForSend: 5 * time.Second, SendTimeout: time.Second})

	for i := 0; i < 5; i++ {
		s, err := starved.RunOnce(context.Background())
		if err != nil {
			t.Fatal(err)
		}
		if s.Claimed != 1 || s.Released != 1 {
			t.Fatalf("round %d: %+v", i, s)
		}
	}
	if env.fake.Calls() != 0 {
		t.Fatal("no send may happen without a reservation")
	}
	r := env.row(t, id)
	if r.status != "pending" || r.sendAttempts != 0 || !r.leaseNull || r.payloadNull {
		t.Fatalf("got %+v", r)
	}
	// A normal worker then delivers it with the full budget.
	if s := env.runOnce(t); s.Sent != 1 {
		t.Fatalf("stats: %+v", s)
	}
}

func TestOutbox_ShutdownReleasesClaimedRowsAndFinishesInFlightSends(t *testing.T) {
	env := newOutboxEnv(t, notify.WorkerConfig{})
	ids := []uuid.UUID{}
	for i := 0; i < 3; i++ {
		id, _, _ := env.codeFixture(t)
		ids = append(ids, id)
	}
	ctx, cancel := context.WithCancel(context.Background())
	started := make(chan struct{})
	env.fake.Respond = func(sendCtx context.Context, _ notify.Email, call int) (string, error) {
		if call == 1 {
			close(started)
			time.Sleep(200 * time.Millisecond) // shutdown arrives while this send is in flight
			if sendCtx.Err() != nil {
				return "", sendCtx.Err()
			}
		}
		return "msg", nil
	}
	w := env.newWorker(t, env.d.Pool, notify.WorkerConfig{Concurrency: 1})
	done := make(chan struct{})
	go func() { _ = w.Run(ctx); close(done) }()
	select {
	case <-started:
	case <-time.After(10 * time.Second):
		cancel()
		t.Fatal("the worker never started a send")
	}
	cancel()
	select {
	case <-done:
	case <-time.After(10 * time.Second):
		t.Fatal("the worker did not stop")
	}

	sent, released := 0, 0
	for _, id := range ids {
		r := env.row(t, id)
		switch {
		case r.status == "sent" && r.sendAttempts == 1:
			sent++
		case r.status == "pending" && r.sendAttempts == 0 && r.leaseNull:
			released++
		default:
			t.Fatalf("unexpected row state after shutdown: %+v", r)
		}
	}
	if sent != 1 || released != 2 || env.fake.Calls() != 1 {
		t.Fatalf("sent=%d released=%d calls=%d: the in-flight send must finish and record, the rest must be released", sent, released, env.fake.Calls())
	}
}

// --- crash recovery -----------------------------------------------------------------------

// A worker reserves the fifth send and dies before recording. Nothing may send a sixth time.
func TestOutbox_RecoveryAfterTheLastReservation(t *testing.T) {
	env := newOutboxEnv(t, notify.WorkerConfig{})
	ctx := context.Background()
	id, _, _ := env.codeFixture(t)
	mustExec(t, env.d.Pool, `UPDATE email_outbox SET send_attempts = 4 WHERE id = $1`, id)

	// The doomed worker: claim and reserve, then nothing.
	claimed, err := env.q.ClaimOutboxBatch(ctx, sqlc.ClaimOutboxBatchParams{LeaseSeconds: 120, BatchSize: 1})
	if err != nil || len(claimed) != 1 {
		t.Fatalf("claim: %v %d", err, len(claimed))
	}
	if n, err := env.q.ReserveOutboxSend(ctx, sqlc.ReserveOutboxSendParams{ID: id, LeaseToken: claimed[0].LeaseToken, MinRemainingSeconds: 45}); err != nil || n != 5 {
		t.Fatalf("reserve: %d %v", n, err)
	}

	// While its lease is live, a healthy worker leaves the row alone.
	if s := env.runOnce(t); s.Claimed != 0 || s.Reaped != 0 {
		t.Fatalf("stats while the lease is live: %+v", s)
	}
	// The lease runs out. The reaper terminalizes the row, and no send happens.
	mustExec(t, env.d.Pool, `UPDATE email_outbox SET lease_expires_at = now() - interval '1 second' WHERE id = $1`, id)
	if s := env.runOnce(t); s.Reaped != 1 || s.Claimed != 0 {
		t.Fatalf("stats after expiry: %+v", s)
	}
	if env.fake.Calls() != 0 {
		t.Fatal("a sixth send happened")
	}
	r := env.row(t, id)
	if r.status != "failed" || r.lastError != "send_budget_exhausted" || !r.payloadNull || r.sendAttempts != 5 {
		t.Fatalf("got %+v", r)
	}
}

func TestOutbox_PastDeadlineIsExpiredNotSent(t *testing.T) {
	env := newOutboxEnv(t, notify.WorkerConfig{})
	id, _, _ := env.codeFixture(t)
	mustExec(t, env.d.Pool, `UPDATE email_outbox SET not_after = now() - interval '1 second' WHERE id = $1`, id)
	if s := env.runOnce(t); s.Reaped != 1 || s.Claimed != 0 {
		t.Fatalf("stats: %+v", s)
	}
	r := env.row(t, id)
	if r.status != "expired" || r.lastError != "not_after_passed" || !r.payloadNull {
		t.Fatalf("got %+v", r)
	}
	if env.fake.Calls() != 0 {
		t.Fatal("an expired email must not be sent")
	}
}

// --- payload problems ---------------------------------------------------------------------

func TestOutbox_UndecryptablePayloadFails(t *testing.T) {
	cases := map[string]func(env *outboxEnv, id uuid.UUID){
		"unknown key id": func(env *outboxEnv, id uuid.UUID) {
			mustExec(t, env.d.Pool, `UPDATE email_outbox SET payload_key_id = 99 WHERE id = $1`, id)
		},
		"ciphertext moved from another row": func(env *outboxEnv, id uuid.UUID) {
			other, _, _ := env.codeFixture(t)
			mustExec(t, env.d.Pool, `UPDATE email_outbox SET payload_ciphertext = (SELECT payload_ciphertext FROM email_outbox WHERE id = $2) WHERE id = $1`, id, other)
			mustExec(t, env.d.Pool, `UPDATE email_outbox SET status = 'cancelled', payload_ciphertext = NULL WHERE id = $1`, other)
		},
		"tampered ciphertext": func(env *outboxEnv, id uuid.UUID) {
			mustExec(t, env.d.Pool, `UPDATE email_outbox SET payload_ciphertext = overlay(payload_ciphertext placing '\xff' from 20 for 1) WHERE id = $1`, id)
		},
	}
	for name, corrupt := range cases {
		t.Run(name, func(t *testing.T) {
			env := newOutboxEnv(t, notify.WorkerConfig{})
			id, _, _ := env.codeFixture(t)
			corrupt(env, id)
			env.runOnce(t)
			if env.fake.Calls() != 0 {
				t.Fatal("an undecryptable row must not be sent")
			}
			r := env.row(t, id)
			if r.status != "failed" || r.lastError != "decrypt_error" || !r.payloadNull || r.sendAttempts != 0 {
				t.Fatalf("got %+v", r)
			}
		})
	}
}

func TestOutbox_KeyRotationStillDeliversOldRows(t *testing.T) {
	env := newOutboxEnv(t, notify.WorkerConfig{})
	id, _, code := env.codeFixture(t) // sealed with key 1

	rotated, err := notify.NewKeyring(notify.Key{ID: 2, Key: outboxKey2}, notify.Key{ID: 1, Key: outboxKey1})
	if err != nil {
		t.Fatal(err)
	}
	w, err := notify.NewWorker(env.d.Pool, rotated, env.fake, notify.WorkerConfig{Logger: slog.New(slog.NewJSONHandler(env.logs, nil))})
	if err != nil {
		t.Fatal(err)
	}
	if s, _ := w.RunOnce(context.Background()); s.Sent != 1 {
		t.Fatalf("stats: %+v", s)
	}
	if !strings.Contains(env.fake.Sent()[0].Text, code) || env.row(t, id).status != "sent" {
		t.Fatal("a row sealed with the previous key must still be delivered")
	}
}

// --- concurrency --------------------------------------------------------------------------

func TestOutbox_ConcurrentWorkersSendEachRowOnce(t *testing.T) {
	env := newOutboxEnv(t, notify.WorkerConfig{})
	var ids []uuid.UUID
	for i := 0; i < 12; i++ {
		id, _, _ := env.codeFixture(t)
		ids = append(ids, id)
	}
	workers := []*notify.Worker{
		env.newWorker(t, env.d.Pool, notify.WorkerConfig{BatchSize: 5}),
		env.newWorker(t, env.d.Pool, notify.WorkerConfig{BatchSize: 5}),
		env.newWorker(t, env.d.Pool, notify.WorkerConfig{BatchSize: 5}),
	}
	var wg sync.WaitGroup
	for round := 0; round < 3; round++ {
		for _, w := range workers {
			wg.Add(1)
			go func(w *notify.Worker) {
				defer wg.Done()
				if _, err := w.RunOnce(context.Background()); err != nil {
					t.Error(err)
				}
			}(w)
		}
		wg.Wait()
	}
	perRow := map[uuid.UUID]int{}
	for _, e := range env.fake.Sent() {
		perRow[e.ID]++
	}
	for _, id := range ids {
		if perRow[id] != 1 {
			t.Fatalf("row %s sent %d times", id, perRow[id])
		}
		if r := env.row(t, id); r.status != "sent" || r.sendAttempts != 1 {
			t.Fatalf("row %s: %+v", id, r)
		}
	}
}
