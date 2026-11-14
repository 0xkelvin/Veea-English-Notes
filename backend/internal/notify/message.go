package notify

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/mail"
	"strings"
	"time"

	"github.com/google/uuid"
)

// Template names, matching the email_outbox.template CHECK constraint (TRD 6.7).
type Template string

const (
	TemplateSignupCode      Template = "signup_code"
	TemplateLoginCode       Template = "login_code"
	TemplateResetCode       Template = "reset_code"
	TemplateSetPasswordCode Template = "set_password_code"
	TemplatePasswordAdded   Template = "password_added"
	TemplatePasswordChanged Template = "password_changed"
	TemplatePasswordReset   Template = "password_reset_done"
)

// IsCode reports whether the template carries an OTP code and is tied to a challenge.
func (t Template) IsCode() bool {
	switch t {
	case TemplateSignupCode, TemplateLoginCode, TemplateResetCode, TemplateSetPasswordCode:
		return true
	}
	return false
}

func (t Template) valid() bool {
	switch t {
	case TemplatePasswordAdded, TemplatePasswordChanged, TemplatePasswordReset:
		return true
	}
	return t.IsCode()
}

// Payload holds the template variables. It is what gets encrypted. Code templates use Code.
// Security notifications use DeviceName and OccurredAt and carry no secret (TRD 8.2), but are
// encrypted anyway for uniformity.
type Payload struct {
	Code       string    `json:"code,omitempty"`
	DeviceName string    `json:"device_name,omitempty"`
	OccurredAt time.Time `json:"occurred_at,omitempty"`
}

// String hides the payload, so formatting a Payload with %v or a logger never prints a code.
func (Payload) String() string { return "notify.Payload{redacted}" }

// GoString hides the payload from %#v too.
func (Payload) GoString() string { return "notify.Payload{redacted}" }

// Message is one email to enqueue.
type Message struct {
	Template Template
	To       string // the account's display email (users.email or otp_challenges.email)
	UserID   *uuid.UUID
	// ChallengeID links a code email to its OTP challenge. Required for code templates, absent
	// for notifications. The worker re-checks the challenge before sending.
	ChallengeID *uuid.UUID
	// NotAfter is the delivery deadline. Required for code templates: pass the challenge's
	// expires_at. Leave nil for notifications: the database sets created_at + 24 h.
	NotAfter *time.Time
	Payload  Payload
}

// Validation errors. They name the problem, never the value.
var (
	ErrInvalidMessage = errors.New("notify: invalid message")
)

func invalid(reason string) error { return fmt.Errorf("%w: %s", ErrInvalidMessage, reason) }

// validate checks the message shape for its template.
func (m Message) validate() error {
	if !m.Template.valid() {
		return invalid("unknown template")
	}
	if err := validAddress(m.To); err != nil {
		return err
	}
	if m.Template.IsCode() {
		if m.ChallengeID == nil {
			return invalid("code email needs a challenge id")
		}
		if m.NotAfter == nil {
			return invalid("code email needs a deadline (the challenge expiry)")
		}
		if !validCode(m.Payload.Code) {
			return invalid("code must be 6 decimal digits")
		}
		if m.Payload.DeviceName != "" || !m.Payload.OccurredAt.IsZero() {
			return invalid("code email carries only a code")
		}
		return nil
	}
	if m.ChallengeID != nil {
		return invalid("notification must not be linked to a challenge")
	}
	if m.UserID == nil {
		return invalid("notification needs a user id")
	}
	if m.Payload.Code != "" {
		return invalid("notification must not carry a code")
	}
	if m.Payload.OccurredAt.IsZero() {
		return invalid("notification needs the time of the event")
	}
	if strings.TrimSpace(m.Payload.DeviceName) == "" || len(m.Payload.DeviceName) > 64 || hasControl(m.Payload.DeviceName) {
		return invalid("notification needs a device name of 1 to 64 printable characters")
	}
	return nil
}

func validCode(c string) bool {
	if len(c) != 6 {
		return false
	}
	for i := 0; i < len(c); i++ {
		if c[i] < '0' || c[i] > '9' {
			return false
		}
	}
	return true
}

// validAddress accepts a bare address only, which also rules out header injection.
func validAddress(a string) error {
	if a == "" || len(a) > 254 || hasControl(a) {
		return invalid("recipient is not a valid address")
	}
	parsed, err := mail.ParseAddress(a)
	if err != nil || parsed.Name != "" || parsed.Address != a {
		return invalid("recipient is not a valid address")
	}
	return nil
}

func hasControl(s string) bool {
	for _, r := range s {
		if r < 0x20 || r == 0x7f {
			return true
		}
	}
	return false
}

func encodePayload(p Payload) ([]byte, error) {
	b, err := json.Marshal(p)
	if err != nil {
		return nil, errors.New("notify: encode payload")
	}
	return b, nil
}

func decodePayload(b []byte) (Payload, error) {
	var p Payload
	if err := json.Unmarshal(b, &p); err != nil {
		return Payload{}, errors.New("notify: decode payload")
	}
	return p, nil
}
