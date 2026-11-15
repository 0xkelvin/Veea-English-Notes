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
	"mime"
	"net/http"
	"reflect"
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

// Router is what a module registers its routes on. *http.ServeMux satisfies it; tests use a
// recorder to list every registered pattern.
type Router interface {
	HandleFunc(pattern string, handler func(http.ResponseWriter, *http.Request))
}

// Mount registers a module's routes on the router.
type Mount func(r Router)

// NewHandler returns the router with the liveness and readiness endpoints plus every mounted
// module's routes, all behind the request-id middleware.
func NewHandler(db Pinger, readyTimeout time.Duration, mounts ...Mount) http.Handler {
	mux := http.NewServeMux()
	registerAll(mux, db, readyTimeout, mounts)
	return requestID(problemFallback(mux))
}

// probeMethods are tried to tell a wrong method (405) from an unknown path (404).
var probeMethods = []string{http.MethodGet, http.MethodPost, http.MethodPut, http.MethodPatch, http.MethodDelete}

// problemFallback answers what no route serves with a problem document instead of the standard
// library's plain-text 404 and 405 (TRD 5.1: every error is application/problem+json). HEAD is
// refused too: http.ServeMux would otherwise serve HEAD for every GET route, which the contract
// does not list.
func problemFallback(mux *http.ServeMux) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if _, pattern := mux.Handler(r); pattern != "" && r.Method != http.MethodHead {
			mux.ServeHTTP(w, r)
			return
		}
		var allowed []string
		for _, m := range probeMethods {
			probe := r.Clone(r.Context())
			probe.Method = m
			if _, pattern := mux.Handler(probe); pattern != "" {
				allowed = append(allowed, m)
			}
		}
		if len(allowed) == 0 {
			WriteProblem(w, http.StatusNotFound, CodeNotFound)
			return
		}
		w.Header().Set("Allow", strings.Join(allowed, ", "))
		WriteProblem(w, http.StatusMethodNotAllowed, CodeMethodNotAllowed)
	})
}

// Patterns lists every "METHOD /path" pattern NewHandler would register for mounts, in
// registration order. The contract test compares it with api/openapi.yaml.
func Patterns(mounts ...Mount) []string {
	var rec patternRecorder
	registerAll(&rec, nil, 0, mounts)
	return rec
}

type patternRecorder []string

func (p *patternRecorder) HandleFunc(pattern string, _ func(http.ResponseWriter, *http.Request)) {
	*p = append(*p, pattern)
}

func registerAll(mux Router, db Pinger, readyTimeout time.Duration, mounts []Mount) {
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
var tokenPrefixes = []string{"vct_", "vat_", "vrt_", "vop_"}

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
	CodeInvalidProfile           = "invalid_profile"
	CodeProfileConflict          = "profile_conflict"
	CodeEmailUnchanged           = "email_unchanged"
	CodeEmailUnavailable         = "email_unavailable"
	CodeInvalidRequest           = "invalid_request"
	CodeInvalidEmail             = "invalid_email"
	CodePasswordPolicyViolation  = "password_policy_violation"
	CodeInvalidCode              = "invalid_code"
	CodeCodeAttemptsExceeded     = "code_attempts_exceeded"
	CodeSignupUnavailable        = "signup_unavailable"
	CodeRateLimited              = "rate_limited"
	CodeUnauthorized             = "unauthorized"
	CodeInvalidCredentials       = "invalid_credentials"
	CodeAccountUnavailable       = "account_unavailable"
	CodePasswordAlreadySet       = "password_already_set"
	CodePasswordNotSet           = "password_not_set"
	CodeInvalidCurrentPassword   = "invalid_current_password"
	CodeBusy                     = "busy"
	CodeLifecycleConflict        = "lifecycle_conflict"
	CodeExportNotReady           = "export_not_ready"
	CodeOperationCanceled        = "operation_canceled"
	CodeExportExpired            = "export_expired"
	CodeSyncUnavailable          = "sync_unavailable"
	CodeSyncResetRequired        = "sync_reset_required"
	CodeSequenceGap              = "sequence_gap"
	CodeCapacityChanged          = "capacity_changed"
	CodePayloadTooLarge          = "payload_too_large"
	CodeInternal                 = "internal_error"
	CodeNotReady                 = "not_ready"
	CodeNotFound                 = "not_found"
	CodeCurrentSessionNotAllowed = "current_session_not_allowed"
	CodeMethodNotAllowed         = "method_not_allowed"
	CodeUnsupportedMediaType     = "unsupported_media_type"
	CodeForbidden                = "forbidden"
	CodeTargetNotPermitted       = "target_not_permitted"
	CodeRoleConflict             = "role_conflict"
	CodeStatusConflict           = "status_conflict"
	CodeLastSuperAdmin           = "last_super_admin"
	CodeEntitlementConflict      = "entitlement_conflict"
	CodeInvalidExpiry            = "invalid_expiry"
)

var titles = map[string]string{
	CodeSyncUnavailable:          "Sync is not available right now.",
	CodeSyncResetRequired:        "This device must download a new snapshot before syncing.",
	CodeSequenceGap:              "A change is missing before this request.",
	CodeCapacityChanged:          "The account's capacity changed. Confirm the import again.",
	CodePayloadTooLarge:          "The request is too large.",
	CodeLifecycleConflict:        "The account state changed. Request a new proof.",
	CodeExportNotReady:           "The export is not ready.",
	CodeOperationCanceled:        "This operation was canceled.",
	CodeExportExpired:            "The export download expired.",
	CodeInvalidProfile:           "The profile values are not valid.",
	CodeProfileConflict:          "The profile changed. Reload it before saving.",
	CodeEmailUnchanged:           "This is already the current sign-in address.",
	CodeEmailUnavailable:         "This email cannot be used for this change.",
	CodeInvalidRequest:           "The request is malformed.",
	CodeInvalidEmail:             "The email address is not valid.",
	CodePasswordPolicyViolation:  "The password does not meet the policy.",
	CodeInvalidCode:              "The code is not valid.",
	CodeCodeAttemptsExceeded:     "Too many attempts for this code. Request a new one.",
	CodeSignupUnavailable:        "This email cannot be used for a new account. Sign in instead.",
	CodeRateLimited:              "Too many requests. Try again later.",
	CodeUnauthorized:             "Authentication is required.",
	CodeInvalidCredentials:       "The email or password is not correct.",
	CodeAccountUnavailable:       "This account cannot sign in.",
	CodePasswordAlreadySet:       "This account already has a password.",
	CodePasswordNotSet:           "This account has no password yet. Set one first.",
	CodeInvalidCurrentPassword:   "The current password was not accepted.",
	CodeBusy:                     "The service is busy. Try again shortly.",
	CodeInternal:                 "Something went wrong.",
	CodeNotReady:                 "Not ready",
	CodeNotFound:                 "No such resource.",
	CodeCurrentSessionNotAllowed: "Use sign out to end the current session.",
	CodeMethodNotAllowed:         "This method is not allowed here.",
	CodeUnsupportedMediaType:     "Send the request body as application/json.",
	CodeForbidden:                "This account cannot use the admin API.",
	CodeTargetNotPermitted:       "This action is not permitted on this account.",
	CodeRoleConflict:             "The role changed. Reload the account before retrying.",
	CodeStatusConflict:           "The account status does not allow this action.",
	CodeLastSuperAdmin:           "Another active Super Admin is required first.",
	CodeEntitlementConflict:      "The plan changed. Reload the account before retrying.",
	CodeInvalidExpiry:            "The grant must end in the future and within 366 days.",
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

// ErrPayloadTooLarge is returned by DecodeJSONLimit for a body over its limit: 413.
var ErrPayloadTooLarge = errors.New("httpx: payload too large")

// ErrUnsupportedMediaType is returned by DecodeJSON when Content-Type is missing or is not
// application/json. Handlers answer 415 unsupported_media_type.
var ErrUnsupportedMediaType = errors.New("httpx: unsupported media type")

// DecodeJSON decodes the body into dst, a pointer to a struct, as strictly as api/openapi.yaml
// describes request bodies:
//   - Content-Type application/json (parameters such as charset allowed), else
//     ErrUnsupportedMediaType; every other failure is ErrBadRequest;
//   - at most MaxBodyBytes, exactly one JSON object, no trailing data;
//   - keys spelled exactly as the struct's json tags (encoding/json alone would also accept
//     "EMAIL" for "email"), no duplicate keys at any depth, no unknown keys;
//   - every tagged field present (all request fields are required), also in nested objects.
func DecodeJSON(w http.ResponseWriter, r *http.Request, dst any) error {
	if mt, _, err := mime.ParseMediaType(r.Header.Get("Content-Type")); err != nil || mt != "application/json" {
		return ErrUnsupportedMediaType
	}
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, MaxBodyBytes))
	if err != nil {
		return ErrBadRequest
	}
	return DecodeObject(body, dst)
}

// DecodeJSONLimit is DecodeJSON with a larger body limit for the documented bulk routes. A body
// over limit is ErrPayloadTooLarge rather than ErrBadRequest.
func DecodeJSONLimit(w http.ResponseWriter, r *http.Request, dst any, limit int64) error {
	if mt, _, err := mime.ParseMediaType(r.Header.Get("Content-Type")); err != nil || mt != "application/json" {
		return ErrUnsupportedMediaType
	}
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, limit))
	if err != nil {
		var tooLarge *http.MaxBytesError
		if errors.As(err, &tooLarge) {
			return ErrPayloadTooLarge
		}
		return ErrBadRequest
	}
	return DecodeObject(body, dst)
}

// DecodeObject applies DecodeJSON's strict object rules to raw bytes already read, for nested
// objects whose shape depends on a discriminator.
func DecodeObject(body []byte, dst any) error {
	t := reflect.TypeOf(dst)
	if t == nil || t.Kind() != reflect.Pointer || t.Elem().Kind() != reflect.Struct {
		return errors.New("httpx: DecodeJSON needs a pointer to a struct")
	}
	if err := checkObject(body, t.Elem()); err != nil {
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

// checkObject verifies that raw is one JSON object whose keys are exactly the json tags of t:
// each present once, none missing, none extra, with nested struct fields checked the same way.
func checkObject(raw []byte, t reflect.Type) error {
	dec := json.NewDecoder(bytes.NewReader(raw))
	if tok, err := dec.Token(); err != nil || tok != json.Delim('{') {
		return ErrBadRequest
	}
	fields := map[string]reflect.Type{}
	for i := range t.NumField() {
		f := t.Field(i)
		name, _, _ := strings.Cut(f.Tag.Get("json"), ",")
		if name == "" || name == "-" {
			continue
		}
		ft := f.Type
		if ft.Kind() == reflect.Pointer {
			ft = ft.Elem()
		}
		fields[name] = ft
	}
	seen := map[string]bool{}
	for dec.More() {
		tok, err := dec.Token()
		key, ok := tok.(string)
		if err != nil || !ok || seen[key] {
			return ErrBadRequest // malformed, or a duplicate key
		}
		seen[key] = true
		ft, known := fields[key]
		if !known {
			return ErrBadRequest // unknown, or spelled with another case
		}
		var value json.RawMessage
		if err := dec.Decode(&value); err != nil {
			return ErrBadRequest
		}
		if ft.Kind() == reflect.Struct && len(value) > 0 && value[0] == '{' {
			if err := checkObject(value, ft); err != nil {
				return err
			}
		}
	}
	if len(seen) != len(fields) {
		return ErrBadRequest // a required field is missing
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
