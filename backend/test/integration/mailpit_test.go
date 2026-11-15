//go:build integration

package integration

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/notify"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/clientip"
)

// TestOutbox_DeliversThroughMailpit sends one OTP email through the real SMTP sender into a
// local Mailpit and reads it back from Mailpit's API. It needs:
//
//	VEEA_TEST_SMTP_ADDR=127.0.0.1:1025
//	VEEA_TEST_MAILPIT_API=http://127.0.0.1:8025
//
// (scripts/test-mailpit.sh start). Without them it skips. Both must be loopback.
func TestOutbox_DeliversThroughMailpit(t *testing.T) {
	smtpAddr, api := os.Getenv("VEEA_TEST_SMTP_ADDR"), os.Getenv("VEEA_TEST_MAILPIT_API")
	if smtpAddr == "" || api == "" {
		t.Skip("VEEA_TEST_SMTP_ADDR and VEEA_TEST_MAILPIT_API are not set; skipping the Mailpit test")
	}
	if u, err := url.Parse(api); err != nil || !loopback(u.Hostname()) {
		t.Fatal("VEEA_TEST_MAILPIT_API must point at a loopback Mailpit")
	}

	env := newOutboxEnv(t, notify.WorkerConfig{})
	sender, err := notify.NewSMTPSender(smtpAddr, "no-reply@veea.local")
	if err != nil {
		t.Fatal(err)
	}
	w, err := notify.NewWorker(env.d.Pool, env.keys, sender, notify.WorkerConfig{})
	if err != nil {
		t.Fatal(err)
	}
	id, _, code := env.codeFixture(t)

	s, err := w.RunOnce(context.Background())
	if err != nil || s.Sent != 1 {
		t.Fatalf("stats %+v, err %v", s, err)
	}
	r := env.row(t, id)
	wantMsgID := "<" + id.String() + "@veea.local>"
	if r.status != "sent" || r.providerID != wantMsgID || !r.payloadNull {
		t.Fatalf("row: %+v", r)
	}

	// Find it in Mailpit by recipient, then read the full message.
	var search struct {
		Messages []struct {
			ID        string
			MessageID string
			Subject   string
		}
	}
	var recipient string
	if err := env.d.Pool.QueryRow(context.Background(), `SELECT to_email FROM email_outbox WHERE id=$1`, id).Scan(&recipient); err != nil {
		t.Fatal(err)
	}
	query := url.Values{"query": {fmt.Sprintf("to:%q", recipient)}}
	getJSON(t, api+"/api/v1/search?"+query.Encode(), &search)
	if len(search.Messages) != 1 {
		t.Fatalf("expected one message for the recipient in Mailpit, got %d", len(search.Messages))
	}
	m := search.Messages[0]
	if "<"+m.MessageID+">" != wantMsgID && m.MessageID != wantMsgID {
		t.Fatalf("Message-ID %q, want %s", m.MessageID, wantMsgID)
	}
	if m.Subject != "Your Veea sign-in code" {
		t.Fatalf("subject %q", m.Subject)
	}
	var full struct {
		Text string
		HTML string
	}
	getJSON(t, api+"/api/v1/message/"+m.ID, &full)
	if !strings.Contains(full.Text, code) || !strings.Contains(full.HTML, code) || !strings.Contains(full.Text, "10 minutes") {
		t.Fatalf("the delivered body is not the rendered code email:\n%s", full.Text)
	}
}

func loopback(host string) bool {
	if host == "localhost" {
		return true
	}
	r := clientip.New(nil).Resolve(host+":0", nil)
	return r.Addr.IsValid() && r.Addr.IsLoopback()
}

func getJSON(t *testing.T, u string, out any) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("GET %s: %s", u, resp.Status)
	}
	if err := json.NewDecoder(resp.Body).Decode(out); err != nil {
		t.Fatal(err)
	}
}
