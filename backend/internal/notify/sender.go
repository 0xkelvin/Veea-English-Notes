package notify

import (
	"context"
	"errors"
	"strings"

	"github.com/google/uuid"
)

// Email is what a Sender delivers.
type Email struct {
	// ID is the outbox row id. Senders pass it as the provider idempotency key where the provider
	// supports one, and SMTP puts it in the Message-ID (TRD 8.3 step 5).
	ID      uuid.UUID
	To      string
	Subject string
	Text    string
	HTML    string
}

// Sender delivers one email. The production provider is still open (TRD R12). Any implementation
// must:
//   - return the provider's message id on acceptance;
//   - classify failures with Permanent or Retryable when it knows the outcome. Any other error,
//     including a context deadline, is treated as Ambiguous: the provider may have accepted the
//     email, so the worker retries within the send budget (TRD 8.3 "Outcome classes");
//   - never put the message body in an error.
type Sender interface {
	Send(ctx context.Context, e Email) (providerMessageID string, err error)
}

// Class is the outcome class of a failed send.
type Class string

const (
	// ClassPermanent: definite failure, never retried (invalid recipient, content rejected).
	ClassPermanent Class = "permanent"
	// ClassRetryable: definite non-delivery, safe to retry (throttled, refused before sending).
	ClassRetryable Class = "retryable"
	// ClassAmbiguous: the provider may have accepted it (timeout after the request was written,
	// 5xx, unparsable response). Retried, so a duplicate is possible and accepted.
	ClassAmbiguous Class = "ambiguous"
)

// SendError is a classified send failure. Code is a short machine-readable reason, for example
// "smtp_550" or "throttled". Only Class and Code are ever stored (email_outbox.last_error).
type SendError struct {
	Class Class
	Code  string
}

func (e *SendError) Error() string { return "notify: send failed: " + string(e.Class) + ":" + e.Code }

// Permanent returns a permanent failure with code.
func Permanent(code string) error { return &SendError{Class: ClassPermanent, Code: code} }

// Retryable returns a definite non-delivery with code.
func Retryable(code string) error { return &SendError{Class: ClassRetryable, Code: code} }

// Ambiguous returns an uncertain outcome with code.
func Ambiguous(code string) error { return &SendError{Class: ClassAmbiguous, Code: code} }

// classify turns any Sender error into a class and a safe code for last_error. Unknown errors
// are ambiguous: assuming a definite failure could lose an email the provider never received,
// and assuming success could hide one it rejected.
func classify(err error) (Class, string) {
	var se *SendError
	if errors.As(err, &se) {
		return se.Class, safeCode(se.Code)
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return ClassAmbiguous, "timeout"
	}
	if errors.Is(err, context.Canceled) {
		return ClassAmbiguous, "canceled"
	}
	return ClassAmbiguous, "unclassified"
}

// safeCode keeps last_error to lowercase letters, digits and underscores, at most 40 characters,
// so a provider can never smuggle message text (or a code) into the database.
func safeCode(c string) string {
	c = strings.ToLower(c)
	var b strings.Builder
	for _, r := range c {
		if b.Len() >= 40 {
			break
		}
		if (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') || r == '_' {
			b.WriteRune(r)
		}
	}
	if b.Len() == 0 {
		return "error"
	}
	return b.String()
}

// lastError is the stored form: "<class>:<code>".
func lastError(c Class, code string) string { return string(c) + ":" + code }
