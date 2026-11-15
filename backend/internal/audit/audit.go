// Package audit writes the append-only audit trail of TRD 01 sections 6.8 and 11.1. It is the
// only package that writes audit_events (TRD 2.2).
//
// Events are written on the caller's connection or transaction, so a success event commits with
// the state change it describes (TRD 7.1 rule 2) and a failure event commits with the attempt
// counter it accompanies (rule 3).
//
// No event may carry a password, code, token, token hash or ciphertext (TRD 11.1). Record
// enforces what it can: metadata keys that name a secret and values that look like a token are
// refused, so a mistake fails loudly in tests instead of persisting.
package audit

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/netip"
	"strings"

	"github.com/google/uuid"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/db/sqlc"
)

// Outcomes, matching the audit_events.outcome CHECK constraint.
const (
	Success = "success"
	Failure = "failure"
)

// Event is one audit row.
type Event struct {
	Action       string // for example "auth.otp.start"
	Outcome      string // Success or Failure
	Reason       string // optional, a fixed code such as "invalid_code"
	ActorUserID  *uuid.UUID
	TargetUserID *uuid.UUID
	SessionID    *uuid.UUID
	EmailHMAC    []byte // stands in for the email; never the address itself
	IP           netip.Addr
	UserAgent    string
	RequestID    string
	// Metadata holds short, non-secret facts, for example {"delivery": "none"}.
	Metadata map[string]string
}

// ErrUnsafeEvent is returned when an event would store something that looks like a secret.
var ErrUnsafeEvent = errors.New("audit: event would store a secret")

// Redacted replaces a client-supplied text field that looks like a token.
const Redacted = "[redacted]"

// forbiddenKeys are metadata keys that name a secret (TRD 11.1, 11.2).
var forbiddenKeys = []string{"password", "code", "token", "hash", "payload", "ciphertext", "secret", "key"}

// tokenPrefixes mark the service's bearer secrets (TRD 4.1, 8.1).
var tokenPrefixes = []string{"vct_", "vat_", "vrt_", "vop_"}

// Record inserts e through db, which is a transaction or the pool.
func Record(ctx context.Context, db sqlc.DBTX, e Event) error {
	if err := e.check(); err != nil {
		return err
	}
	// The user agent and request id come from the client. A token-shaped value there is not a
	// programming error but hostile or careless input, so it is redacted rather than refused:
	// refusing would let any client turn every audited request into a 500.
	if looksSecret(e.UserAgent) {
		e.UserAgent = Redacted
	}
	if looksSecret(e.RequestID) {
		e.RequestID = Redacted
	}
	meta := []byte("{}")
	if len(e.Metadata) > 0 {
		b, err := json.Marshal(e.Metadata)
		if err != nil {
			return errors.New("audit: encode metadata")
		}
		meta = b
	}
	p := sqlc.InsertAuditEventParams{
		Action: e.Action, Outcome: e.Outcome, ActorUserID: e.ActorUserID, TargetUserID: e.TargetUserID,
		SessionID: e.SessionID, EmailHmac: e.EmailHMAC, Metadata: meta,
		Reason: optional(e.Reason), UserAgent: optional(e.UserAgent), RequestID: optional(e.RequestID),
	}
	if e.IP.IsValid() {
		ip := e.IP
		p.Ip = &ip
	}
	if err := sqlc.New(db).InsertAuditEvent(ctx, p); err != nil {
		return fmt.Errorf("audit: insert %s: %w", e.Action, err)
	}
	return nil
}

// check refuses malformed events and secret-looking metadata, which are programming errors.
func (e Event) check() error {
	if e.Action == "" || !isCode(e.Action, ".") {
		return errors.New("audit: action must be dotted lowercase words")
	}
	if e.Outcome != Success && e.Outcome != Failure {
		return errors.New("audit: outcome must be success or failure")
	}
	if e.Reason != "" && !isCode(e.Reason, "") {
		return errors.New("audit: reason must be a lowercase code")
	}
	for k, v := range e.Metadata {
		if err := checkMetadata(k, v); err != nil {
			return err
		}
	}
	return nil
}

func checkMetadata(k, v string) error {
	if !isCode(k, "") {
		return errors.New("audit: metadata keys must be lowercase codes")
	}
	for _, f := range forbiddenKeys {
		if strings.Contains(k, f) {
			return fmt.Errorf("%w: metadata key names a secret", ErrUnsafeEvent)
		}
	}
	if looksSecret(v) {
		return fmt.Errorf("%w: metadata value looks like a token", ErrUnsafeEvent)
	}
	return nil
}

func optional(s string) *string {
	if s == "" {
		return nil
	}
	return &s
}

// isCode reports whether s is lowercase letters, digits and underscores, optionally separated by
// sep (for dotted action names).
func isCode(s, sep string) bool {
	if s == "" || len(s) > 64 {
		return false
	}
	for _, r := range s {
		switch {
		case r >= 'a' && r <= 'z', r >= '0' && r <= '9', r == '_':
		case sep != "" && string(r) == sep:
		default:
			return false
		}
	}
	return true
}

func looksSecret(s string) bool {
	lower := strings.ToLower(s)
	for _, p := range tokenPrefixes {
		if strings.Contains(lower, p) {
			return true
		}
	}
	return false
}
