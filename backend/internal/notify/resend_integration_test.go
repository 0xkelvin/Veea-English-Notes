//go:build integration

package notify

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/db/sqlc"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/pgtest"
)

// Exercise the real worker and PostgreSQL reservation/result writes against the HTTP adapter.
// A timed-out acceptance is retried by a new worker/sender, preserving row id and rendered body.
func TestResendWorker_TimeoutRetryPreservesReservationAndIdempotency(t *testing.T) {
	d := pgtest.New(t)
	ctx := context.Background()
	q := sqlc.New(d.Pool)
	u, err := q.InsertUserIfAbsent(ctx, sqlc.InsertUserIfAbsentParams{
		ID: uuid.New(), Email: "resend@example.test", EmailNormalized: "resend@example.test",
	})
	if err != nil {
		t.Fatal(err)
	}
	keys, err := NewKeyring(Key{ID: 1, Key: bytes.Repeat([]byte{0x31}, KeyBytes)})
	if err != nil {
		t.Fatal(err)
	}
	tx, err := d.Pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx)
	id, err := NewOutbox(keys).Enqueue(ctx, tx, Message{
		Template: TemplatePasswordAdded, To: u.Email, UserID: &u.ID,
		Payload: Payload{DeviceName: "Synthetic device", OccurredAt: time.Now()},
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := tx.Commit(ctx); err != nil {
		t.Fatal(err)
	}
	var mu sync.Mutex
	var firstBody []byte
	calls := 0
	var logs bytes.Buffer
	sender := resendTestSender(t, func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		mu.Lock()
		calls++
		first := calls == 1
		if r.Header.Get("Idempotency-Key") != id.String() {
			t.Error("worker did not pass its outbox row id")
		}
		if first {
			firstBody = body
		} else if !bytes.Equal(firstBody, body) {
			t.Error("retry changed the rendered email")
		}
		mu.Unlock()
		if first {
			<-r.Context().Done()
			return
		}
		fmt.Fprintf(w, `{"id":%q}`, resendTestMessageID)
	})
	makeWorker := func(s Sender) *Worker {
		t.Helper()
		w, err := NewWorker(d.Pool, keys, s, WorkerConfig{
			SendTimeout: time.Second, MinLeaseForSend: 2 * time.Second, Lease: 5 * time.Second,
			Backoff: []time.Duration{0}, Logger: slog.New(slog.NewJSONHandler(&logs, nil)),
		})
		if err != nil {
			t.Fatal(err)
		}
		return w
	}
	check := func(wantStatus string, attempts int, wantPayload bool, providerID, lastError string) {
		t.Helper()
		var status, provider, reason string
		var sends int
		var payload, leaseCleared bool
		err := d.Pool.QueryRow(ctx, `SELECT status, send_attempts, payload_ciphertext IS NOT NULL,
			lease_token IS NULL AND lease_expires_at IS NULL, coalesce(provider_message_id, ''), coalesce(last_error, '')
			FROM email_outbox WHERE id = $1`, id).Scan(&status, &sends, &payload, &leaseCleared, &provider, &reason)
		if err != nil || status != wantStatus || sends != attempts || payload != wantPayload || !leaseCleared || provider != providerID || reason != lastError {
			t.Fatalf("status=%s attempts=%d payload=%v leaseCleared=%v provider=%s reason=%s err=%v", status, sends, payload, leaseCleared, provider, reason, err)
		}
	}
	stats, err := makeWorker(sender).RunOnce(ctx)
	if err != nil || stats.Retried != 1 || stats.Sent != 0 {
		t.Fatalf("first cycle: %+v %v", stats, err)
	}
	check("pending", 1, true, "", "ambiguous:resend_timeout")
	restarted, err := NewResendSender(resendTestKey, "sender@example.test")
	if err != nil {
		t.Fatal(err)
	}
	restarted.endpoint = sender.endpoint
	defer restarted.client.CloseIdleConnections()
	stats, err = makeWorker(restarted).RunOnce(ctx)
	if err != nil || stats.Sent != 1 || stats.Retried != 0 {
		t.Fatalf("retry cycle: %+v %v", stats, err)
	}
	check("sent", 2, false, resendTestMessageID, "")
	mu.Lock()
	defer mu.Unlock()
	if calls != 2 {
		t.Fatalf("two durable reservations must produce exactly two HTTP calls, got %d", calls)
	}
	for _, secret := range []string{resendTestKey, u.Email, "Synthetic device", string(firstBody)} {
		if bytes.Contains(logs.Bytes(), []byte(secret)) {
			t.Fatal("worker logs exposed credentials or email content")
		}
	}
}
