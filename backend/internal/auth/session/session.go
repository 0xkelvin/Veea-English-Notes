// Package session issues sessions (TRD 01 sections 6.5, 8.1 and 8.6). It holds only the
// transaction-scoped issuance primitive shared by every sign-in path; refresh, logout and the
// authentication middleware are Ticket 08.
//
// Tokens are opaque: "vat_" or "vrt_" followed by 32 random bytes in base64url. They are
// generated before the transaction (TRD 7.1 rule 5) and only their SHA-256 is stored. The
// plaintext tokens leave this package once, in Issued, for the response written after commit.
package session

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"net/netip"
	"strconv"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/audit"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/db/sqlc"
)

// Lifetimes and cap (TRD 8.1, 8.6, R11).
const (
	AccessTTL      = 15 * time.Minute
	RefreshIdleTTL = 30 * 24 * time.Hour
	AbsoluteTTL    = 90 * 24 * time.Hour
	MaxActive      = 20
)

// Token prefixes (TRD 8.1).
const (
	AccessPrefix  = "vat_"
	RefreshPrefix = "vrt_"
)

const tokenBytes = 32

// Method is how the session was obtained, matching the sessions.auth_method CHECK.
type Method string

const (
	MethodSignupOTP      Method = "signup_otp"
	MethodSignupPassword Method = "signup_password"
	MethodOTP            Method = "otp"
	MethodPassword       Method = "password"
)

func (m Method) valid() bool {
	switch m {
	case MethodSignupOTP, MethodSignupPassword, MethodOTP, MethodPassword:
		return true
	}
	return false
}

// Device is the client-supplied device description (TRD 5.2).
type Device struct {
	Name     string `json:"name"`
	Platform string `json:"platform"`
}

// ErrInvalidDevice is returned for a device that fails TRD 5.2. It names no value.
var ErrInvalidDevice = errors.New("session: invalid device")

// Validate checks the name (1 to 64 characters, no control characters, not blank) and the
// platform (ios, android, web, other).
func (d Device) Validate() error {
	n := utf8.RuneCountInString(d.Name)
	if !utf8.ValidString(d.Name) || n < 1 || n > 64 || strings.TrimSpace(d.Name) == "" {
		return ErrInvalidDevice
	}
	for _, r := range d.Name {
		if unicode.IsControl(r) {
			return ErrInvalidDevice
		}
	}
	switch d.Platform {
	case "ios", "android", "web", "other":
		return nil
	}
	return ErrInvalidDevice
}

// Pending holds a new session's id and tokens, generated before the transaction. A retried
// transaction reuses it, which is safe because the failed attempt committed nothing.
type Pending struct {
	id                      uuid.UUID
	access, refresh         string
	accessHash, refreshHash []byte
}

// NewPending generates a session id and its token pair. r nil means crypto/rand.
func NewPending(r io.Reader) (Pending, error) {
	if r == nil {
		r = rand.Reader
	}
	id, err := uuid.NewV7()
	if err != nil {
		return Pending{}, errors.New("session: generate id")
	}
	access, err := newToken(r, AccessPrefix)
	if err != nil {
		return Pending{}, err
	}
	refresh, err := newToken(r, RefreshPrefix)
	if err != nil {
		return Pending{}, err
	}
	return Pending{id: id, access: access, refresh: refresh,
		accessHash: HashToken(access), refreshHash: HashToken(refresh)}, nil
}

func newToken(r io.Reader, prefix string) (string, error) {
	var b [tokenBytes]byte
	if _, err := io.ReadFull(r, b[:]); err != nil {
		return "", errors.New("session: read randomness for a token")
	}
	return prefix + base64.RawURLEncoding.EncodeToString(b[:]), nil
}

// HashToken is the stored form of an access or refresh token: SHA-256 of the whole string.
func HashToken(token string) []byte {
	h := sha256.Sum256([]byte(token))
	return h[:]
}

// Request describes the session to create.
type Request struct {
	UserID    uuid.UUID
	Method    Method
	Device    Device
	UserAgent string // already sanitized by the HTTP layer
	IP        netip.Addr
	RequestID string
}

// Issued is a committed-to-be session. The tokens must be returned to the client only after the
// transaction that inserted it commits.
type Issued struct {
	SessionID         uuid.UUID
	AccessToken       string
	AccessExpiresAt   time.Time
	RefreshToken      string
	RefreshExpiresAt  time.Time
	AbsoluteExpiresAt time.Time
	// Evicted is how many older sessions the cap revoked.
	Evicted int64
	method  Method
}

// AuthMethod is how the session was obtained (empty for a rotated pair).
func (i Issued) AuthMethod() Method { return i.method }

// Issue inserts a session for req.UserID on tx (TRD 8.6).
//
// The caller must already hold the user at lock level L3: a FOR NO KEY UPDATE lock taken with
// LockUserForNoKeyUpdate, or the row it inserted in this transaction (signup). That serializes
// every issuance for the user, so the cap count and the eviction are consistent. Issue then
// takes L4b (cap eviction) and L5 (the insert and the revocation audit event), in that order.
//
// Expiry times use the database clock. The cap keeps the 19 most recently seen active sessions
// before adding the new one, revoking the rest with reason session_limit.
func Issue(ctx context.Context, tx pgx.Tx, p Pending, req Request) (Issued, error) {
	if p.id == uuid.Nil || p.access == "" {
		return Issued{}, errors.New("session: pending tokens are required")
	}
	if req.UserID == uuid.Nil || !req.Method.valid() {
		return Issued{}, errors.New("session: user and a known method are required")
	}
	if err := req.Device.Validate(); err != nil {
		return Issued{}, err
	}
	q := sqlc.New(tx)
	now, err := q.DatabaseNow(ctx)
	if err != nil {
		return Issued{}, fmt.Errorf("session: read database time: %w", err)
	}

	// L4b: cap eviction.
	active, err := q.CountActiveSessionsForUser(ctx, req.UserID)
	if err != nil {
		return Issued{}, fmt.Errorf("session: count active: %w", err)
	}
	var evicted int64
	if active >= MaxActive {
		if evicted, err = q.RevokeSessionsBeyondLimit(ctx, sqlc.RevokeSessionsBeyondLimitParams{
			UserID: req.UserID, KeepCount: MaxActive - 1}); err != nil {
			return Issued{}, fmt.Errorf("session: evict: %w", err)
		}
	}

	// L5: the new session, then the revocation audit if the cap evicted any.
	out := Issued{
		SessionID: p.id, AccessToken: p.access, RefreshToken: p.refresh,
		// refresh_expires_at = least(now + 30 days, absolute_expires_at) (TRD 8.5).
		AccessExpiresAt: now.Add(AccessTTL), RefreshExpiresAt: earliest(now.Add(RefreshIdleTTL), now.Add(AbsoluteTTL)),
		AbsoluteExpiresAt: now.Add(AbsoluteTTL), Evicted: evicted, method: req.Method,
	}
	params := sqlc.InsertSessionParams{
		ID: p.id, UserID: req.UserID, AuthMethod: string(req.Method),
		AccessTokenHash: p.accessHash, AccessExpiresAt: out.AccessExpiresAt,
		RefreshTokenHash: p.refreshHash, RefreshExpiresAt: out.RefreshExpiresAt,
		AbsoluteExpiresAt: out.AbsoluteExpiresAt, DeviceName: req.Device.Name, Platform: req.Device.Platform,
	}
	if req.UserAgent != "" {
		params.UserAgent = &req.UserAgent
	}
	if req.IP.IsValid() {
		ip := req.IP
		params.CreatedIp = &ip
	}
	if _, err := q.InsertSession(ctx, params); err != nil {
		return Issued{}, fmt.Errorf("session: insert: %w", err)
	}
	if evicted > 0 {
		if err := audit.Record(ctx, tx, audit.Event{
			Action: "auth.session.revoke", Outcome: audit.Success, TargetUserID: &req.UserID,
			SessionID: &p.id, IP: req.IP, UserAgent: req.UserAgent, RequestID: req.RequestID,
			Metadata: map[string]string{"reason": "session_limit", "count": strconv.FormatInt(evicted, 10)},
		}); err != nil {
			return Issued{}, err
		}
	}
	return out, nil
}
