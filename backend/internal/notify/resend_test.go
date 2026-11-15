package notify

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/google/uuid"
)

const resendTestKey = "re_synthetic_test_key"
const resendTestMessageID = "c52caa27-8db3-4599-980f-6b748117fac1"

type resendTestTransport func(*http.Request) (*http.Response, error)

func (f resendTestTransport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func resendTestEmail() Email {
	return Email{ID: uuid.New(), To: "person@example.test", Subject: "Test subject", Text: "OTP 835726", HTML: "<p>OTP 835726</p>"}
}

func resendTestSender(t *testing.T, h http.HandlerFunc) *ResendSender {
	t.Helper()
	srv := httptest.NewServer(h)
	t.Cleanup(srv.Close)
	s, err := NewResendSender(resendTestKey, "sender@example.test")
	if err != nil {
		t.Fatal(err)
	}
	s.endpoint = srv.URL + "/emails"
	t.Cleanup(s.client.CloseIdleConnections)
	return s
}

func TestResend_AcceptedRequest(t *testing.T) {
	e := resendTestEmail()
	var calls atomic.Int32
	s := resendTestSender(t, func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		if r.Method != http.MethodPost || r.URL.Path != "/emails" || r.Header.Get("Authorization") != "Bearer "+resendTestKey ||
			r.Header.Get("Idempotency-Key") != e.ID.String() || r.Header.Get("Content-Type") != "application/json" {
			t.Error("incorrect Resend request method, path or headers")
		}
		var body struct {
			From, Subject, Text, HTML string
			To                        []string
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.From != "sender@example.test" ||
			len(body.To) != 1 || body.To[0] != e.To || body.Subject != e.Subject || body.Text != e.Text || body.HTML != e.HTML {
			t.Error("incorrect Resend email JSON")
		}
		fmt.Fprintf(w, `{"id":%q}`, resendTestMessageID)
	})
	s.client.Transport = resendTestTransport(func(r *http.Request) (*http.Response, error) {
		if r.GetBody != nil {
			t.Error("Transport can replay a reserved send")
		}
		return http.DefaultTransport.RoundTrip(r)
	})
	id, err := s.Send(context.Background(), e)
	if err != nil || id != resendTestMessageID || calls.Load() != 1 {
		t.Fatalf("id=%q err=%v calls=%d", id, err, calls.Load())
	}
}

func TestResend_OutcomeClassesAndSafeErrors(t *testing.T) {
	const sensitive = "835726 re_secret_key person@example.test <p>private payload</p>"
	cases := []struct {
		name   string
		status int
		body   string
		class  Class
		code   string
	}{
		{"validation", 400, sensitive, ClassPermanent, "resend_rejected"},
		{"authentication", 401, sensitive, ClassPermanent, "resend_rejected"},
		{"unverified domain", 403, sensitive, ClassPermanent, "resend_rejected"},
		{"invalid endpoint", 404, sensitive, ClassPermanent, "resend_rejected"},
		{"invalid content", 422, sensitive, ClassPermanent, "resend_rejected"},
		{"throttled", 429, sensitive, ClassRetryable, "resend_throttled"},
		{"daily quota", 429, `{"name":"daily_quota_exceeded"}`, ClassRetryable, "resend_throttled"},
		{"monthly quota", 429, `{"name":"monthly_quota_exceeded"}`, ClassRetryable, "resend_throttled"},
		{"concurrent key", 409, `{"name":"concurrent_idempotent_requests","message":"` + sensitive + `"}`, ClassRetryable, "resend_concurrent_request"},
		{"changed payload", 409, `{"name":"invalid_idempotent_request","message":"` + sensitive + `"}`, ClassPermanent, "resend_idempotency_conflict"},
		{"unknown conflict", 409, `{"name":"` + sensitive + `"}`, ClassAmbiguous, "resend_unknown_conflict"},
		{"malformed conflict", 409, `<html>` + sensitive, ClassAmbiguous, "resend_invalid_response"},
		{"server error", 500, sensitive, ClassAmbiguous, "resend_server_or_timeout"},
		{"unavailable", 503, sensitive, ClassAmbiguous, "resend_server_or_timeout"},
		{"request timeout", 408, sensitive, ClassAmbiguous, "resend_server_or_timeout"},
		{"invalid JSON", 200, sensitive, ClassAmbiguous, "resend_invalid_response"},
		{"no id", 200, `{}`, ClassAmbiguous, "resend_invalid_response"},
		{"unsafe id", 200, `{"id":"` + sensitive + `"}`, ClassAmbiguous, "resend_invalid_response"},
		{"null id", 200, `{"id":"00000000-0000-0000-0000-000000000000"}`, ClassAmbiguous, "resend_invalid_response"},
		{"error in success", 200, `{"id":"` + resendTestMessageID + `","name":"validation_error"}`, ClassAmbiguous, "resend_invalid_response"},
		{"trailing data", 200, `{"id":"` + resendTestMessageID + `"} {}`, ClassAmbiguous, "resend_invalid_response"},
		{"oversized response", 200, strings.Repeat("x", resendResponseLimit+1), ClassAmbiguous, "resend_invalid_response"},
		{"unexpected status", 304, "", ClassAmbiguous, "resend_unexpected_status"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			var calls atomic.Int32
			s := resendTestSender(t, func(w http.ResponseWriter, r *http.Request) {
				calls.Add(1)
				w.WriteHeader(c.status)
				_, _ = io.WriteString(w, c.body)
			})
			id, err := s.Send(context.Background(), resendTestEmail())
			class, code := classify(err)
			if err == nil || id != "" || class != c.class || code != c.code || calls.Load() != 1 {
				t.Fatalf("id=%q err=%v class=%q code=%q calls=%d", id, err, class, code, calls.Load())
			}
			for _, secret := range strings.Fields(sensitive) {
				if strings.Contains(err.Error(), secret) {
					t.Fatal("provider-controlled data leaked into an error")
				}
			}
		})
	}
}

// The stand-in accepts the first request before withholding its response. The retry must
// retrieve that acceptance using exactly the same key and body, with only one logical send.
func TestResend_TimeoutThenRetryKeepsKeyAndPayload(t *testing.T) {
	var mu sync.Mutex
	var key string
	var payload []byte
	calls, accepted := 0, 0
	s := resendTestSender(t, func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		mu.Lock()
		calls++
		first := calls == 1
		if first {
			key, payload = r.Header.Get("Idempotency-Key"), body
			accepted++
		} else if r.Header.Get("Idempotency-Key") != key || !bytes.Equal(body, payload) {
			t.Error("retry changed the idempotency key or payload")
		}
		mu.Unlock()
		if first {
			<-r.Context().Done()
			return
		}
		fmt.Fprintf(w, `{"id":%q}`, resendTestMessageID)
	})
	e := resendTestEmail()
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	_, err := s.Send(ctx, e)
	if class, code := classify(err); err == nil || class != ClassAmbiguous || code != "resend_timeout" {
		t.Fatalf("timeout: %v", err)
	}
	id, err := s.Send(context.Background(), e)
	if err != nil || id != resendTestMessageID {
		t.Fatalf("retry: id=%q err=%v", id, err)
	}
	mu.Lock()
	defer mu.Unlock()
	if calls != 2 || accepted != 1 || key != e.ID.String() {
		t.Fatalf("calls=%d logical acceptances=%d key=%q", calls, accepted, key)
	}
}

func TestResend_DoesNotFollowRedirects(t *testing.T) {
	var forwarded atomic.Int32
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { forwarded.Add(1) }))
	defer target.Close()
	for _, status := range []int{301, 302, 303, 307, 308} {
		t.Run(fmt.Sprint(status), func(t *testing.T) {
			s := resendTestSender(t, func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Location", target.URL)
				w.WriteHeader(status)
			})
			_, err := s.Send(context.Background(), resendTestEmail())
			if class, _ := classify(err); err == nil || class != ClassAmbiguous || forwarded.Load() != 0 {
				t.Fatalf("redirect: err=%v forwarded=%d", err, forwarded.Load())
			}
		})
	}
}

func TestResend_TransportOutcomes(t *testing.T) {
	t.Run("connection refused before sending", func(t *testing.T) {
		ln, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		addr := ln.Addr().String()
		_ = ln.Close()
		s, _ := NewResendSender(resendTestKey, "sender@example.test")
		s.endpoint = "http://" + addr + "/emails"
		_, err = s.Send(context.Background(), resendTestEmail())
		if class, code := classify(err); err == nil || class != ClassRetryable || code != "resend_connect" {
			t.Fatalf("connect: %v", err)
		}
	})
	t.Run("connection reset after request", func(t *testing.T) {
		s := resendTestSender(t, func(w http.ResponseWriter, r *http.Request) {
			_, _ = io.Copy(io.Discard, r.Body)
			conn, _, err := w.(http.Hijacker).Hijack()
			if err != nil {
				t.Error(err)
				return
			}
			_ = conn.Close()
		})
		_, err := s.Send(context.Background(), resendTestEmail())
		if class, code := classify(err); err == nil || class != ClassAmbiguous || code != "resend_transport" {
			t.Fatalf("reset: %v", err)
		}
	})
	t.Run("canceled", func(t *testing.T) {
		s := resendTestSender(t, func(w http.ResponseWriter, r *http.Request) { t.Error("canceled send reached provider") })
		ctx, cancel := context.WithCancel(context.Background())
		cancel()
		_, err := s.Send(ctx, resendTestEmail())
		if class, code := classify(err); err == nil || class != ClassAmbiguous || code != "resend_canceled" {
			t.Fatalf("canceled: %v", err)
		}
	})
}

func TestResend_LocalValidationAndFormatting(t *testing.T) {
	for _, key := range []string{"", "re_", "wrong_prefix", "re_private\nvalue", "re_private value"} {
		if _, err := NewResendSender(key, "sender@example.test"); err == nil || strings.Contains(err.Error(), "private") {
			t.Fatal("key validation failed or leaked its input")
		}
	}
	for _, from := range []string{"not-an-email", "Veea <sender@example.test>", "sender@example.test\r\nBcc:x@example.test"} {
		if _, err := NewResendSender(resendTestKey, from); err == nil || strings.Contains(err.Error(), from) {
			t.Fatal("From validation failed or leaked its input")
		}
	}
	s := resendTestSender(t, func(w http.ResponseWriter, r *http.Request) { t.Error("invalid email reached provider") })
	if strings.Contains(fmt.Sprintf("%v %+v %#v", s, s, s), resendTestKey) {
		t.Fatal("formatted sender leaks API key")
	}
	for _, mutate := range []func(*Email){
		func(e *Email) { e.ID = uuid.Nil },
		func(e *Email) { e.To = "invalid-recipient" },
		func(e *Email) { e.Subject = "\r\nprivate" },
	} {
		e := resendTestEmail()
		mutate(&e)
		_, err := s.Send(context.Background(), e)
		if class, _ := classify(err); err == nil || class != ClassPermanent {
			t.Fatalf("invalid email: %v", err)
		}
	}
}
