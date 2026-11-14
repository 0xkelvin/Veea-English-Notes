// Package httpx holds the HTTP server wiring shared by all modules: the router, request ids,
// JSON and RFC 9457 problem responses, and strict request decoding (TRD 01 §5.1).
package httpx

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"
)

// Pinger reports whether a dependency is reachable.
type Pinger interface {
	Ping(ctx context.Context) error
}

// HeaderRequestID carries the request id on every response.
const HeaderRequestID = "X-Request-Id"

// Mount registers a module's routes on the router.
type Mount func(mux *http.ServeMux)

// NewHandler returns the router with the liveness and readiness endpoints plus every mounted
// module's routes, all behind the request-id middleware.
func NewHandler(db Pinger, readyTimeout time.Duration, mounts ...Mount) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		WriteJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	})
	mux.HandleFunc("GET /readyz", func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), readyTimeout)
		defer cancel()
		if err := db.Ping(ctx); err != nil {
			// The cause is deliberately not returned to the caller.
			WriteProblem(w, http.StatusServiceUnavailable, CodeNotReady)
			return
		}
		WriteJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	})
	for _, m := range mounts {
		m(mux)
	}
	return requestID(mux)
}

// requestID sets X-Request-Id on every response, reusing a well-formed inbound value.
func requestID(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		id := r.Header.Get(HeaderRequestID)
		if !validRequestID(id) {
			id = newRequestID()
		}
		w.Header().Set(HeaderRequestID, id)
		next.ServeHTTP(w, r)
	})
}

// RequestID returns the id the middleware assigned to the response being written.
func RequestID(w http.ResponseWriter) string { return w.Header().Get(HeaderRequestID) }

// tokenPrefixes are the service's bearer-token prefixes (TRD 8.1, 4.1). An inbound request id
// that looks like a token is replaced, so it can never be echoed, logged or stored.
var tokenPrefixes = []string{"vct_", "vat_", "vrt_"}

func validRequestID(s string) bool {
	if len(s) < 8 || len(s) > 64 {
		return false
	}
	for _, c := range s {
		switch {
		case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c >= '0' && c <= '9', c == '-', c == '_':
		default:
			return false
		}
	}
	return !LooksLikeToken(s)
}

// LooksLikeToken reports whether s contains a challenge, access or refresh token prefix,
// case-insensitively.
func LooksLikeToken(s string) bool {
	lower := strings.ToLower(s)
	for _, p := range tokenPrefixes {
		if strings.Contains(lower, p) {
			return true
		}
	}
	return false
}

func newRequestID() string {
	var b [12]byte
	_, _ = rand.Read(b[:])
	return hex.EncodeToString(b[:])
}

// WriteJSON writes v as JSON. Responses are never cacheable: several carry tokens.
func WriteJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

// Stable error codes (TRD 5.3). Client-facing titles come only from the titles table, never
// from an error value (TRD 11.2).
const (
	CodeInvalidRequest          = "invalid_request"
	CodeInvalidEmail            = "invalid_email"
	CodePasswordPolicyViolation = "password_policy_violation"
	CodeInvalidCode             = "invalid_code"
	CodeCodeAttemptsExceeded    = "code_attempts_exceeded"
	CodeSignupUnavailable       = "signup_unavailable"
	CodeRateLimited             = "rate_limited"
	CodeUnauthorized            = "unauthorized"
	CodeInvalidCredentials      = "invalid_credentials"
	CodeAccountUnavailable      = "account_unavailable"
	CodePasswordAlreadySet      = "password_already_set"
	CodePasswordNotSet          = "password_not_set"
	CodeInvalidCurrentPassword  = "invalid_current_password"
	CodeBusy                    = "busy"
	CodeInternal                = "internal_error"
	CodeNotReady                = "not_ready"
)

var titles = map[string]string{
	CodeInvalidRequest:          "The request is malformed.",
	CodeInvalidEmail:            "The email address is not valid.",
	CodePasswordPolicyViolation: "The password does not meet the policy.",
	CodeInvalidCode:             "The code is not valid.",
	CodeCodeAttemptsExceeded:    "Too many attempts for this code. Request a new one.",
	CodeSignupUnavailable:       "This email cannot be used for a new account. Sign in instead.",
	CodeRateLimited:             "Too many requests. Try again later.",
	CodeUnauthorized:            "Authentication is required.",
	CodeInvalidCredentials:      "The email or password is not correct.",
	CodeAccountUnavailable:      "This account cannot sign in.",
	CodePasswordAlreadySet:      "This account already has a password.",
	CodePasswordNotSet:          "This account has no password yet. Set one first.",
	CodeInvalidCurrentPassword:  "The current password was not accepted.",
	CodeBusy:                    "The service is busy. Try again shortly.",
	CodeInternal:                "Something went wrong.",
	CodeNotReady:                "Not ready",
}

// WriteProblem writes an RFC 9457 problem document with a stable code and the request id.
// extra adds extension members, such as "violations".
func WriteProblem(w http.ResponseWriter, status int, code string, extra ...map[string]any) {
	title, ok := titles[code]
	if !ok {
		code, title = CodeInternal, titles[CodeInternal]
	}
	body := map[string]any{"type": "about:blank", "title": title, "status": status, "code": code,
		"request_id": RequestID(w)}
	for _, e := range extra {
		for k, v := range e {
			if _, taken := body[k]; !taken {
				body[k] = v
			}
		}
	}
	w.Header().Set("Content-Type", "application/problem+json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}

// WriteRateLimited writes 429 rate_limited with Retry-After in whole seconds (TRD 5.1).
func WriteRateLimited(w http.ResponseWriter, retryAfterSeconds int) {
	w.Header().Set("Retry-After", strconv.Itoa(max(1, retryAfterSeconds)))
	WriteProblem(w, http.StatusTooManyRequests, CodeRateLimited)
}

// MaxBodyBytes bounds every JSON request body.
const MaxBodyBytes = 16 << 10

// ErrBadRequest is returned by DecodeJSON for any body that is not exactly one JSON object of
// the expected shape. It deliberately carries no detail, so no part of the body is echoed.
var ErrBadRequest = errors.New("httpx: malformed request body")

// DecodeJSON decodes the body into dst strictly: at most MaxBodyBytes, a single JSON object,
// no unknown fields, no trailing data.
func DecodeJSON(w http.ResponseWriter, r *http.Request, dst any) error {
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, MaxBodyBytes))
	if err != nil {
		return ErrBadRequest
	}
	dec := json.NewDecoder(bytes.NewReader(body))
	dec.DisallowUnknownFields()
	if err := dec.Decode(dst); err != nil {
		return ErrBadRequest
	}
	if dec.More() {
		return ErrBadRequest
	}
	if _, err := dec.Token(); !errors.Is(err, io.EOF) {
		return ErrBadRequest
	}
	return nil
}

// NewServer wraps the handler in an http.Server with conservative timeouts.
func NewServer(addr string, h http.Handler) *http.Server {
	return &http.Server{
		Addr:              addr,
		Handler:           h,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       60 * time.Second,
		MaxHeaderBytes:    16 << 10,
	}
}
