// Package httpapi exposes the auth use cases over HTTP (TRD 01 section 5). Handlers decode and
// validate the request, call one use case, and map its result to the response contract. They
// never log request or response bodies (TRD 11.2); an internal error is logged with its request
// id only.
package httpapi

import (
	"errors"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/account"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/learning"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/lifecycle"
	"log/slog"
	"net/http"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/auth/otp"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/auth/password"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/auth/session"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/auth/signin"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/auth/signup"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/identity"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/clientip"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/db/sqlc"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/httpx"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/metrics"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/ratelimit"
)

// Handlers serves the auth endpoints.
type Handlers struct {
	Lifecycle *lifecycle.Service
	Learning  *learning.Service
	Account   *account.Service
	Signup    *signup.Service
	Signin    *signin.Service
	Password  *password.Service
	Sessions  *session.Service
	Limiter   *ratelimit.Limiter // records auth.rate_limited
	Metrics   *metrics.Metrics   // auth_rate_limited_total; nil disables
	IPs       *clientip.Resolver
	Log       *slog.Logger
}

// Mount registers the routes (TRD 5.3, endpoints 1 to 14).
func (h *Handlers) Mount(mux httpx.Router) {
	mux.HandleFunc("POST /v1/auth/signup/otp/start", h.signupOTPStart)
	mux.HandleFunc("POST /v1/auth/signup/password/start", h.signupPasswordStart)
	mux.HandleFunc("POST /v1/auth/signup/verify", h.signupVerify)
	mux.HandleFunc("POST /v1/auth/otp/start", h.otpStart)
	mux.HandleFunc("POST /v1/auth/otp/verify", h.otpVerify)
	mux.HandleFunc("POST /v1/auth/password/login", h.passwordLogin)
	mux.HandleFunc("POST /v1/auth/password/reset/start", h.resetStart)
	mux.HandleFunc("POST /v1/auth/password/reset/complete", h.resetComplete)
	mux.HandleFunc("POST /v1/me/password/set/start", h.authenticated(h.setStart))
	mux.HandleFunc("POST /v1/me/password/set", h.authenticated(h.setPassword))
	mux.HandleFunc("PUT /v1/me/password", h.authenticated(h.changePassword))
	mux.HandleFunc("POST /v1/auth/token/refresh", h.refresh)
	mux.HandleFunc("POST /v1/auth/logout", h.authenticated(h.logout))
	mux.HandleFunc("GET /v1/me", h.authenticated(h.me))
	mux.HandleFunc("POST /v1/me/deactivate", h.authenticated(h.deactivate))
	for _, action := range []string{"export", "delete", "reactivate"} {
		mux.HandleFunc("POST /v1/account-rights/"+action+"/start", h.rightsStart(action))
		mux.HandleFunc("POST /v1/account-rights/"+action+"/{operation_id}/complete", h.rightsAuthenticated(action, h.rightsComplete))
	}
	mux.HandleFunc("GET /v1/account-rights/exports/{operation_id}", h.rightsAuthenticated("export", h.rightsStatus))
	mux.HandleFunc("GET /v1/account-rights/exports/{operation_id}/download", h.rightsAuthenticated("export", h.rightsDownload))
	mux.HandleFunc("GET /v1/account-rights/deletions/{operation_id}", h.rightsAuthenticated("delete", h.rightsStatus))
	mux.HandleFunc("PUT /v1/me/profile", h.authenticated(h.updateProfile))
	mux.HandleFunc("POST /v1/me/email-change/start", h.authenticated(h.startEmailChange))
	mux.HandleFunc("POST /v1/me/email-change/{change_id}/complete", h.authenticated(h.completeEmailChange))
	mux.HandleFunc("GET /v1/me/sessions", h.authenticated(h.listSessions))
	mux.HandleFunc("DELETE /v1/me/sessions/{session_id}", h.authenticated(h.revokeSession))
	mux.HandleFunc("DELETE /v1/me/sessions", h.authenticated(h.logoutAll))
	mux.HandleFunc("GET /v1/learning/sync/state", h.authenticated(h.learningState))
	mux.HandleFunc("POST /v1/learning/sync/writers", h.authenticated(h.learningRegisterWriter))
	mux.HandleFunc("POST /v1/learning/sync/push", h.authenticated(h.learningPush))
	mux.HandleFunc("POST /v1/learning/sync/import", h.authenticated(h.learningImport))
	mux.HandleFunc("GET /v1/learning/sync/changes", h.authenticated(h.learningChanges))
	mux.HandleFunc("GET /v1/learning/sync/snapshot", h.authenticated(h.learningSnapshot))
}

// --- request and response shapes (TRD 5.2) ---------------------------------------------------

type emailRequest struct {
	Email string `json:"email"`
}

type passwordSignupRequest struct {
	Email    string `json:"email"`
	Password string `json:"password"`
}

type verifyRequest struct {
	ChallengeToken string          `json:"challenge_token"`
	Code           string          `json:"code"`
	Device         *session.Device `json:"device"`
}

type passwordLoginRequest struct {
	Email    string          `json:"email"`
	Password string          `json:"password"`
	Device   *session.Device `json:"device"`
}

type codePasswordRequest struct {
	ChallengeToken string `json:"challenge_token"`
	Code           string `json:"code"`
	NewPassword    string `json:"new_password"`
}

type changePasswordRequest struct {
	CurrentPassword string `json:"current_password"`
	NewPassword     string `json:"new_password"`
}

type refreshRequest struct {
	RefreshToken string `json:"refresh_token"`
}

type acknowledgement struct {
	ChallengeToken string    `json:"challenge_token"`
	ExpiresAt      time.Time `json:"expires_at"`
	ResendAfter    time.Time `json:"resend_after"`
}

type user struct {
	LifecycleRevision int64       `json:"lifecycle_revision"`
	Profile           profileBody `json:"profile"`
	ID                string      `json:"id"`
	Email             string      `json:"email"`
	EmailVerifiedAt   *time.Time  `json:"email_verified_at"`
	HasPassword       bool        `json:"has_password"`
	PasswordChangedAt *time.Time  `json:"password_changed_at"`
	Status            string      `json:"status"`
	Role              string      `json:"role"`
	CreatedAt         time.Time   `json:"created_at"`
}

type tokenResponse struct {
	SessionID        string    `json:"session_id"`
	AccessToken      string    `json:"access_token"`
	AccessExpiresAt  time.Time `json:"access_expires_at"`
	RefreshToken     string    `json:"refresh_token"`
	RefreshExpiresAt time.Time `json:"refresh_expires_at"`
	User             user      `json:"user"`
}

func ackBody(a otp.Acknowledgement) acknowledgement {
	return acknowledgement{ChallengeToken: a.ChallengeToken, ExpiresAt: a.ExpiresAt.UTC(), ResendAfter: a.ResendAfter.UTC()}
}

func userBody(u sqlc.User) user {
	return user{
		LifecycleRevision: u.LifecycleRevision,
		Profile:           profileBody{DisplayName: u.DisplayName, PreferredLanguage: u.PreferredLanguage, TimeZone: u.TimeZone, DailyGoal: u.DailyGoal, Revision: u.ProfileRevision},
		ID:                u.ID.String(), Email: u.Email, EmailVerifiedAt: utc(u.EmailVerifiedAt), HasPassword: u.PasswordHash != nil,
		PasswordChangedAt: utc(u.PasswordChangedAt), Status: u.Status, Role: u.Role, CreatedAt: u.CreatedAt.UTC(),
	}
}

func tokenBody(s session.Issued, u sqlc.User) tokenResponse {
	return tokenResponse{
		SessionID: s.SessionID.String(), AccessToken: s.AccessToken, AccessExpiresAt: s.AccessExpiresAt.UTC(),
		RefreshToken: s.RefreshToken, RefreshExpiresAt: s.RefreshExpiresAt.UTC(), User: userBody(u),
	}
}

func utc(t *time.Time) *time.Time {
	if t == nil {
		return nil
	}
	u := t.UTC()
	return &u
}

// --- handlers --------------------------------------------------------------------------------

func (h *Handlers) signupOTPStart(w http.ResponseWriter, r *http.Request) {
	var req emailRequest
	if err := httpx.DecodeJSON(w, r, &req); err != nil {
		h.fail(w, r, err)
		return
	}
	ack, err := h.Signup.StartOTP(r.Context(), req.Email, h.client(w, r))
	if err != nil {
		h.fail(w, r, err)
		return
	}
	httpx.WriteJSON(w, http.StatusAccepted, ackBody(ack))
}

func (h *Handlers) signupPasswordStart(w http.ResponseWriter, r *http.Request) {
	var req passwordSignupRequest
	if err := httpx.DecodeJSON(w, r, &req); err != nil {
		h.fail(w, r, err)
		return
	}
	ack, err := h.Signup.StartPassword(r.Context(), req.Email, req.Password, h.client(w, r))
	if err != nil {
		h.fail(w, r, err)
		return
	}
	httpx.WriteJSON(w, http.StatusAccepted, ackBody(ack))
}

func (h *Handlers) signupVerify(w http.ResponseWriter, r *http.Request) {
	var req verifyRequest
	if err := httpx.DecodeJSON(w, r, &req); err != nil {
		h.fail(w, r, err)
		return
	}
	if req.Device == nil {
		h.fail(w, r, session.ErrInvalidDevice)
		return
	}
	res, err := h.Signup.Verify(r.Context(), req.ChallengeToken, req.Code, *req.Device, h.client(w, r))
	if err != nil {
		h.fail(w, r, err)
		return
	}
	// The transaction has committed: only now do the tokens leave the server.
	httpx.WriteJSON(w, http.StatusCreated, tokenBody(res.Session, res.User))
}

// otpStart is endpoint 4: the same 202 for every email; only an account in good standing gets
// the login_code email.
func (h *Handlers) otpStart(w http.ResponseWriter, r *http.Request) {
	var req emailRequest
	if err := httpx.DecodeJSON(w, r, &req); err != nil {
		h.fail(w, r, err)
		return
	}
	ack, err := h.Signin.StartOTP(r.Context(), req.Email, h.signinClient(w, r))
	if err != nil {
		h.fail(w, r, err)
		return
	}
	httpx.WriteJSON(w, http.StatusAccepted, ackBody(ack))
}

// otpVerify is endpoint 5: 200 TokenResponse after the commit.
func (h *Handlers) otpVerify(w http.ResponseWriter, r *http.Request) {
	var req verifyRequest
	if err := httpx.DecodeJSON(w, r, &req); err != nil {
		h.fail(w, r, err)
		return
	}
	if req.Device == nil {
		h.fail(w, r, session.ErrInvalidDevice)
		return
	}
	res, err := h.Signin.VerifyOTP(r.Context(), req.ChallengeToken, req.Code, *req.Device, h.signinClient(w, r))
	if err != nil {
		h.fail(w, r, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, tokenBody(res.Session, res.User))
}

// passwordLogin is endpoint 6. A malformed email is a malformed request here (TRD 5.3 lists no
// invalid_email for this endpoint); every credential failure is the same 401.
func (h *Handlers) passwordLogin(w http.ResponseWriter, r *http.Request) {
	var req passwordLoginRequest
	if err := httpx.DecodeJSON(w, r, &req); err != nil {
		h.fail(w, r, err)
		return
	}
	if req.Device == nil {
		h.fail(w, r, session.ErrInvalidDevice)
		return
	}
	res, err := h.Signin.PasswordLogin(r.Context(), req.Email, req.Password, *req.Device, h.signinClient(w, r))
	if errors.Is(err, identity.ErrInvalidEmail) {
		err = httpx.ErrBadRequest
	}
	if err != nil {
		h.fail(w, r, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, tokenBody(res.Session, res.User))
}

func (h *Handlers) signinClient(w http.ResponseWriter, r *http.Request) signin.Client {
	return signin.Client{IP: h.IPs.ResolveRequest(r), UserAgent: UserAgent(r), RequestID: httpx.RequestID(w)}
}

// resetStart is endpoint 7: the same 202 for every email.
func (h *Handlers) resetStart(w http.ResponseWriter, r *http.Request) {
	var req emailRequest
	if err := httpx.DecodeJSON(w, r, &req); err != nil {
		h.fail(w, r, err)
		return
	}
	ack, err := h.Password.StartReset(r.Context(), req.Email, h.passwordClient(w, r))
	if err != nil {
		h.fail(w, r, err)
		return
	}
	httpx.WriteJSON(w, http.StatusAccepted, ackBody(ack))
}

// resetComplete is endpoint 8: 204 and no session (R7, AC-13).
func (h *Handlers) resetComplete(w http.ResponseWriter, r *http.Request) {
	var req codePasswordRequest
	if err := httpx.DecodeJSON(w, r, &req); err != nil {
		h.fail(w, r, err)
		return
	}
	err := h.Password.CompleteReset(r.Context(), req.ChallengeToken, req.Code, req.NewPassword, h.passwordClient(w, r))
	h.noContent(w, r, err)
}

// setStart is endpoint 12. It takes no body; any body is ignored.
func (h *Handlers) setStart(w http.ResponseWriter, r *http.Request, p session.Principal) {
	ack, err := h.Password.StartSet(r.Context(), p, h.passwordClient(w, r))
	if err != nil {
		h.fail(w, r, err)
		return
	}
	httpx.WriteJSON(w, http.StatusAccepted, ackBody(ack))
}

// setPassword is endpoint 13.
func (h *Handlers) setPassword(w http.ResponseWriter, r *http.Request, p session.Principal) {
	var req codePasswordRequest
	if err := httpx.DecodeJSON(w, r, &req); err != nil {
		h.fail(w, r, err)
		return
	}
	err := h.Password.Set(r.Context(), p, req.ChallengeToken, req.Code, req.NewPassword, h.passwordClient(w, r))
	h.noContent(w, r, err)
}

// changePassword is endpoint 14.
func (h *Handlers) changePassword(w http.ResponseWriter, r *http.Request, p session.Principal) {
	var req changePasswordRequest
	if err := httpx.DecodeJSON(w, r, &req); err != nil {
		h.fail(w, r, err)
		return
	}
	err := h.Password.Change(r.Context(), p, req.CurrentPassword, req.NewPassword, h.passwordClient(w, r))
	h.noContent(w, r, err)
}

func (h *Handlers) noContent(w http.ResponseWriter, r *http.Request, err error) {
	if err != nil {
		h.fail(w, r, err)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(http.StatusNoContent)
}

func (h *Handlers) passwordClient(w http.ResponseWriter, r *http.Request) password.Client {
	return password.Client{IP: h.IPs.ResolveRequest(r), UserAgent: UserAgent(r), RequestID: httpx.RequestID(w)}
}

// refresh is endpoint 9 (TRD 8.4). Every refused token gets the same 401.
func (h *Handlers) refresh(w http.ResponseWriter, r *http.Request) {
	var req refreshRequest
	if err := httpx.DecodeJSON(w, r, &req); err != nil {
		h.fail(w, r, err)
		return
	}
	res, err := h.Sessions.Refresh(r.Context(), req.RefreshToken, h.sessionClient(w, r))
	if err != nil {
		h.fail(w, r, err)
		return
	}
	// The rotation has committed: only now does the new pair leave the server.
	httpx.WriteJSON(w, http.StatusOK, tokenBody(res.Issued, res.User))
}

// logout is endpoint 10 (TRD 7.7): the current session only. A retry gets 401.
func (h *Handlers) logout(w http.ResponseWriter, r *http.Request, p session.Principal) {
	if err := h.Sessions.Logout(r.Context(), p, h.sessionClient(w, r)); err != nil {
		h.fail(w, r, err)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(http.StatusNoContent)
}

// me is endpoint 11.
func (h *Handlers) me(w http.ResponseWriter, r *http.Request, p session.Principal) {
	u, err := h.Sessions.CurrentUser(r.Context(), p)
	if err != nil {
		h.fail(w, r, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, userBody(u))
}

// authenticated is the bearer middleware (TRD 5.1, 8.1): every protected route goes through it,
// and nothing protected runs without a Principal.
func (h *Handlers) authenticated(next func(http.ResponseWriter, *http.Request, session.Principal)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		token, ok := bearerToken(r)
		if !ok {
			h.fail(w, r, session.ErrUnauthorized)
			return
		}
		p, err := h.Sessions.Authenticate(r.Context(), token, h.sessionClient(w, r))
		if err != nil {
			h.fail(w, r, err)
			return
		}
		next(w, r, p)
	}
}

// bearerToken extracts the token from "Authorization: Bearer <token>". The scheme is matched
// case-insensitively; anything else, including a second header, is no token.
func bearerToken(r *http.Request) (string, bool) {
	values := r.Header.Values("Authorization")
	if len(values) != 1 {
		return "", false
	}
	scheme, token, ok := strings.Cut(values[0], " ")
	if !ok || !strings.EqualFold(scheme, "Bearer") || token == "" || strings.ContainsAny(token, " \t") {
		return "", false
	}
	return token, true
}

func (h *Handlers) sessionClient(w http.ResponseWriter, r *http.Request) session.Client {
	return session.Client{IP: h.IPs.ResolveRequest(r).Addr, UserAgent: UserAgent(r), RequestID: httpx.RequestID(w)}
}

func (h *Handlers) client(w http.ResponseWriter, r *http.Request) signup.Client {
	return signup.Client{IP: h.IPs.ResolveRequest(r), UserAgent: UserAgent(r), RequestID: httpx.RequestID(w)}
}

// fail maps a use-case error to the TRD 5.3 error contract. Only the fixed code and title are
// returned; the error itself is logged for internal errors and never sent.
func (h *Handlers) fail(w http.ResponseWriter, r *http.Request, err error) {
	var policy *identity.PolicyError
	var limited *otp.RateLimitedError
	var reset *learning.ResetError
	var capacity *learning.CapacityError
	switch {
	case errors.Is(err, learning.ErrClosed):
		w.Header().Set("Retry-After", "60")
		httpx.WriteProblem(w, http.StatusServiceUnavailable, httpx.CodeSyncUnavailable)
	case errors.As(err, &reset):
		httpx.WriteProblem(w, http.StatusGone, httpx.CodeSyncResetRequired, map[string]any{"reason": reset.Reason, "epoch": reset.Epoch})
	case errors.Is(err, learning.ErrSequenceGap):
		httpx.WriteProblem(w, http.StatusConflict, httpx.CodeSequenceGap)
	case errors.As(err, &capacity):
		httpx.WriteProblem(w, http.StatusConflict, httpx.CodeCapacityChanged, map[string]any{
			"live_words": capacity.LiveWords, "content_bytes": capacity.ContentBytes, "last_seq": capacity.LastSeq})
	case errors.Is(err, httpx.ErrPayloadTooLarge):
		httpx.WriteProblem(w, http.StatusRequestEntityTooLarge, httpx.CodePayloadTooLarge)
	case errors.Is(err, lifecycle.ErrNotFound):
		httpx.WriteProblem(w, 404, httpx.CodeNotFound)
	case errors.Is(err, lifecycle.ErrConflict):
		httpx.WriteProblem(w, 409, httpx.CodeLifecycleConflict)
	case errors.Is(err, lifecycle.ErrNotReady):
		httpx.WriteProblem(w, 409, httpx.CodeExportNotReady)
	case errors.Is(err, lifecycle.ErrCanceled):
		httpx.WriteProblem(w, 409, httpx.CodeOperationCanceled)
	case errors.Is(err, lifecycle.ErrExpired):
		httpx.WriteProblem(w, 410, httpx.CodeExportExpired)
	case errors.Is(err, account.ErrInvalidProfile):
		httpx.WriteProblem(w, 422, httpx.CodeInvalidProfile)
	case errors.Is(err, account.ErrProfileConflict):
		httpx.WriteProblem(w, 409, httpx.CodeProfileConflict)
	case errors.Is(err, account.ErrEmailUnchanged):
		httpx.WriteProblem(w, 409, httpx.CodeEmailUnchanged)
	case errors.Is(err, account.ErrEmailUnavailable):
		httpx.WriteProblem(w, 409, httpx.CodeEmailUnavailable)
	case errors.Is(err, account.ErrChangeNotFound):
		httpx.WriteProblem(w, 404, httpx.CodeNotFound)
	case errors.Is(err, session.ErrSessionNotFound):
		httpx.WriteProblem(w, http.StatusNotFound, httpx.CodeNotFound)
	case errors.Is(err, session.ErrCurrentSession):
		httpx.WriteProblem(w, http.StatusConflict, httpx.CodeCurrentSessionNotAllowed)
	case errors.Is(err, session.ErrUnauthorized):
		w.Header().Set("WWW-Authenticate", "Bearer")
		httpx.WriteProblem(w, http.StatusUnauthorized, httpx.CodeUnauthorized)
	case errors.Is(err, httpx.ErrUnsupportedMediaType):
		httpx.WriteProblem(w, http.StatusUnsupportedMediaType, httpx.CodeUnsupportedMediaType)
	case errors.Is(err, httpx.ErrBadRequest), errors.Is(err, session.ErrInvalidDevice),
		errors.Is(err, identity.ErrInvalidPasswordEncoding):
		httpx.WriteProblem(w, http.StatusBadRequest, httpx.CodeInvalidRequest)
	case errors.Is(err, identity.ErrInvalidEmail):
		httpx.WriteProblem(w, http.StatusBadRequest, httpx.CodeInvalidEmail)
	case errors.As(err, &policy):
		violations := make([]string, len(policy.Violations))
		for i, v := range policy.Violations {
			violations[i] = string(v)
		}
		httpx.WriteProblem(w, http.StatusUnprocessableEntity, httpx.CodePasswordPolicyViolation,
			map[string]any{"violations": violations})
	case errors.As(err, &limited):
		// auth.rate_limited, once per rule, subject and window. A failure to record never
		// changes the 429.
		if rerr := h.Limiter.RecordDenial(r.Context(), limited, h.IPs.ResolveRequest(r).Addr, UserAgent(r), httpx.RequestID(w)); rerr != nil {
			h.Log.Error("rate-limit audit event not recorded", "request_id", httpx.RequestID(w), "error", rerr)
		}
		h.Metrics.RateLimited(limited.Rule)
		httpx.WriteRateLimited(w, limited.RetryAfter)
	case errors.Is(err, otp.ErrInvalidCode):
		httpx.WriteProblem(w, http.StatusBadRequest, httpx.CodeInvalidCode)
	case errors.Is(err, otp.ErrAttemptsExceeded):
		httpx.WriteProblem(w, http.StatusBadRequest, httpx.CodeCodeAttemptsExceeded)
	case errors.Is(err, signin.ErrInvalidCredentials):
		httpx.WriteProblem(w, http.StatusUnauthorized, httpx.CodeInvalidCredentials)
	case errors.Is(err, signin.ErrAccountUnavailable):
		httpx.WriteProblem(w, http.StatusForbidden, httpx.CodeAccountUnavailable)
	case errors.Is(err, password.ErrPasswordAlreadySet):
		httpx.WriteProblem(w, http.StatusConflict, httpx.CodePasswordAlreadySet)
	case errors.Is(err, password.ErrPasswordNotSet):
		httpx.WriteProblem(w, http.StatusConflict, httpx.CodePasswordNotSet)
	case errors.Is(err, password.ErrInvalidCurrentPassword):
		httpx.WriteProblem(w, http.StatusForbidden, httpx.CodeInvalidCurrentPassword)
	case errors.Is(err, signup.ErrSignupUnavailable):
		httpx.WriteProblem(w, http.StatusConflict, httpx.CodeSignupUnavailable)
	case errors.Is(err, identity.ErrBusy):
		w.Header().Set("Retry-After", "1")
		httpx.WriteProblem(w, http.StatusServiceUnavailable, httpx.CodeBusy)
	default:
		h.Log.Error("request failed", "request_id", httpx.RequestID(w), "error", err)
		httpx.WriteProblem(w, http.StatusInternalServerError, httpx.CodeInternal)
	}
}

// maxUserAgentRunes bounds what is stored in sessions and audit rows.
const maxUserAgentRunes = 256

// UserAgent returns a storable form of the User-Agent header: valid UTF-8 without control
// characters, at most 256 characters, and empty if it contains anything token-shaped, so a
// client cannot plant a secret-looking string in stored rows.
func UserAgent(r *http.Request) string {
	ua := r.Header.Get("User-Agent")
	if !utf8.ValidString(ua) {
		return ""
	}
	var b strings.Builder
	n := 0
	for _, c := range ua {
		if unicode.IsControl(c) {
			continue
		}
		if n == maxUserAgentRunes {
			break
		}
		b.WriteRune(c)
		n++
	}
	// Checked after stripping, so "v\x01at_..." cannot become "vat_..." once cleaned.
	out := strings.TrimSpace(b.String())
	if httpx.LooksLikeToken(out) {
		return ""
	}
	return out
}
