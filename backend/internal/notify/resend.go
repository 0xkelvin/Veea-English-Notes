package notify

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"strings"

	"github.com/google/uuid"
)

const resendEndpoint = "https://api.resend.com/emails"
const resendResponseLimit = 64 * 1024

// ResendSender sends through the Resend Email API (TRD 01 R12). Each Send makes one HTTP
// attempt; only the outbox worker retries. Its context supplies the worker's send timeout.
type ResendSender struct {
	apiKey   string
	from     string
	endpoint string
	client   *http.Client
}

// NewResendSender validates local settings without contacting Resend. The From address must
// belong to a verified sending domain in Resend; that is a deployment check, not a startup call.
func NewResendSender(apiKey, from string) (*ResendSender, error) {
	if !strings.HasPrefix(apiKey, "re_") || len(apiKey) <= 3 {
		return nil, errors.New("notify: Resend API key is required and must start with re_")
	}
	for _, c := range apiKey {
		if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '-') {
			return nil, errors.New("notify: Resend API key contains invalid characters")
		}
	}
	if err := validAddress(from); err != nil {
		return nil, errors.New("notify: sender address must be a bare email address")
	}
	return &ResendSender{
		apiKey: apiKey, from: from, endpoint: resendEndpoint,
		client: &http.Client{
			// Never forward credentials or the email body to a redirect target, or make an
			// extra provider call outside the worker's durable reservation.
			CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
		},
	}, nil
}

// Formatting a sender must not reveal its credentials.
func (*ResendSender) String() string   { return "notify.ResendSender{redacted}" }
func (*ResendSender) GoString() string { return "notify.ResendSender{redacted}" }

// Send implements Sender. Resend remembers Idempotency-Key for 24 hours. Both the row id and
// rendered payload stay unchanged on retry; changing From or templates during pending retries
// can cause invalid_idempotent_request, which must never be bypassed with a new key.
// See https://resend.com/docs/dashboard/emails/idempotency-keys and /docs/api-reference/errors.
func (s *ResendSender) Send(ctx context.Context, e Email) (string, error) {
	if e.ID == uuid.Nil {
		return "", Permanent("resend_missing_outbox_id")
	}
	if err := validAddress(e.To); err != nil {
		return "", Permanent("invalid_recipient")
	}
	if strings.TrimSpace(e.Subject) == "" || hasControl(e.Subject) {
		return "", Permanent("resend_invalid_subject")
	}
	data, err := json.Marshal(struct {
		From    string   `json:"from"`
		To      []string `json:"to"`
		Subject string   `json:"subject"`
		Text    string   `json:"text"`
		HTML    string   `json:"html"`
	}{s.from, []string{e.To}, e.Subject, e.Text, e.HTML})
	if err != nil {
		return "", Permanent("resend_encode")
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, s.endpoint, bytes.NewReader(data))
	if err != nil {
		return "", Permanent("resend_request")
	}
	req.Header.Set("Authorization", "Bearer "+s.apiKey)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Idempotency-Key", e.ID.String())
	// Go's Transport may replay requests with Idempotency-Key on a broken reused connection
	// if GetBody is set. Disable body replay: one reserved Send must mean at most one attempt.
	req.GetBody = nil
	resp, err := s.client.Do(req)
	if err != nil {
		switch {
		case errors.Is(err, context.DeadlineExceeded):
			return "", Ambiguous("resend_timeout")
		case errors.Is(err, context.Canceled):
			return "", Ambiguous("resend_canceled")
		}
		var op *net.OpError
		if errors.As(err, &op) && op.Op == "dial" {
			return "", Retryable("resend_connect")
		}
		// Never return a transport error or provider text: either may contain secrets.
		return "", Ambiguous("resend_transport")
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusTooManyRequests {
		return "", Retryable("resend_throttled")
	}
	if resp.StatusCode >= 500 || resp.StatusCode == http.StatusRequestTimeout {
		return "", Ambiguous("resend_server_or_timeout")
	}
	if resp.StatusCode >= 400 && resp.StatusCode < 500 && resp.StatusCode != http.StatusConflict {
		return "", Permanent("resend_rejected")
	}
	if (resp.StatusCode < 200 || resp.StatusCode >= 300) && resp.StatusCode != http.StatusConflict {
		return "", Ambiguous("resend_unexpected_status")
	}
	// Bound reads and discard response messages. Only an allowlisted error name or a valid
	// UUID message id can leave this adapter, never echoed email content or credentials.
	body, err := io.ReadAll(io.LimitReader(resp.Body, resendResponseLimit+1))
	defer clear(body)
	var result struct {
		ID   string `json:"id"`
		Name string `json:"name"`
	}
	if err != nil || len(body) > resendResponseLimit || json.Unmarshal(body, &result) != nil {
		return "", Ambiguous("resend_invalid_response")
	}
	if resp.StatusCode == http.StatusConflict {
		switch result.Name {
		case "concurrent_idempotent_requests":
			return "", Retryable("resend_concurrent_request")
		case "invalid_idempotent_request":
			return "", Permanent("resend_idempotency_conflict")
		default:
			return "", Ambiguous("resend_unknown_conflict")
		}
	}
	id, err := uuid.Parse(result.ID)
	if err != nil || id == uuid.Nil || result.Name != "" {
		return "", Ambiguous("resend_invalid_response")
	}
	return id.String(), nil
}
