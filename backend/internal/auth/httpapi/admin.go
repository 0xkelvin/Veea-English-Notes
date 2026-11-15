package httpapi

import (
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/google/uuid"
	"golang.org/x/text/unicode/norm"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/admin"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/auth/session"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/entitlements"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/identity"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/identity/accounts"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/db/sqlc"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/httpx"
)

// mountAdmin registers the TRD 06 routes. Every one is authenticated, then requireStaff, then
// revalidated again by the service inside its transaction.
func (h *Handlers) mountAdmin(mux httpx.Router) {
	mux.HandleFunc("GET /v1/admin/users", h.authenticated(h.requireStaff("search", h.adminListUsers)))
	mux.HandleFunc("GET /v1/admin/users/{user_id}", h.authenticated(h.requireStaff("view", h.adminGetUser)))
	mux.HandleFunc("GET /v1/admin/users/{user_id}/sessions", h.authenticated(h.requireStaff("sessions_view", h.adminListSessions)))
	mux.HandleFunc("GET /v1/admin/users/{user_id}/audit", h.authenticated(h.requireStaff("audit_view", h.adminAuditHistory)))
	mux.HandleFunc("POST /v1/admin/users/{user_id}/session-revocations", h.authenticated(h.requireStaff("sessions_revoke", h.adminRevokeSessions)))
	mux.HandleFunc("POST /v1/admin/users/{user_id}/lifecycle-transitions", h.authenticated(h.requireStaff("transition", h.adminTransition)))
	mux.HandleFunc("PUT /v1/admin/users/{user_id}/role", h.authenticated(h.requireStaff("role_change", h.adminChangeRole)))
	mux.HandleFunc("PUT /v1/admin/users/{user_id}/entitlement", h.authenticated(h.requireStaff("plan_change", h.adminChangePlan)))
}

// requireStaff is a fast pre-check on the authenticated role. It is not the authorization
// decision: the service rechecks the actor's role in its own transaction.
func (h *Handlers) requireStaff(op string, next func(http.ResponseWriter, *http.Request, session.Principal)) func(http.ResponseWriter, *http.Request, session.Principal) {
	return func(w http.ResponseWriter, r *http.Request, p session.Principal) {
		if !admin.IsStaff(p.Role) {
			if err := h.Admin.RecordDenied(r.Context(), p, op, admin.ErrForbidden, nil, h.sessionClient(w, r)); err != nil {
				h.Log.Error("admin denial not recorded", "request_id", httpx.RequestID(w), "error", err)
			}
			h.Metrics.AdminAction(op, "denied")
			h.fail(w, r, admin.ErrForbidden)
			return
		}
		next(w, r, p)
	}
}

// --- request parsing ---------------------------------------------------------------------------

func pathUserID(r *http.Request) (uuid.UUID, bool) {
	raw := r.PathValue("user_id")
	id, err := uuid.Parse(raw)
	return id, err == nil && len(raw) == 36 && id != uuid.Nil && r.URL.RawQuery == "" && !r.URL.ForceQuery
}

var limitPattern = regexp.MustCompile(`^[1-9][0-9]{0,2}$`)

func parseAdminFilter(r *http.Request) (admin.Filter, error) {
	f := admin.Filter{Limit: 50}
	vals, err := url.ParseQuery(r.URL.RawQuery)
	if err != nil {
		return f, httpx.ErrBadRequest
	}
	for k, v := range vals {
		if len(v) != 1 {
			return f, httpx.ErrBadRequest
		}
		switch k {
		case "email", "email_prefix", "role", "status", "limit", "page_token":
		default:
			return f, httpx.ErrBadRequest
		}
	}
	if vals.Has("email") && vals.Has("email_prefix") {
		return f, httpx.ErrBadRequest
	}
	if vals.Has("email") {
		e, err := identity.NormalizeEmail(vals.Get("email"))
		if err != nil {
			return f, err
		}
		f.Email = &e
	}
	if vals.Has("email_prefix") {
		raw := vals.Get("email_prefix")
		if !utf8.ValidString(raw) || strings.IndexFunc(raw, unicode.IsControl) >= 0 {
			return f, httpx.ErrBadRequest
		}
		p := norm.NFC.String(strings.ToLower(norm.NFC.String(raw)))
		if utf8.RuneCountInString(p) < 3 || len(p) > 254 {
			return f, httpx.ErrBadRequest
		}
		f.EmailPrefix = &p
	}
	if vals.Has("role") {
		v := vals.Get("role")
		if accounts.Rank(v) == 0 {
			return f, httpx.ErrBadRequest
		}
		f.Role = &v
	}
	if vals.Has("status") {
		v := vals.Get("status")
		switch v {
		case accounts.StatusActive, accounts.StatusDeactivated, accounts.StatusSuspended, accounts.StatusPendingDeletion:
		default:
			return f, httpx.ErrBadRequest
		}
		f.Status = &v
	}
	if vals.Has("limit") {
		v := vals.Get("limit")
		n, err := strconv.Atoi(v)
		if !limitPattern.MatchString(v) || err != nil || n > 100 {
			return f, httpx.ErrBadRequest
		}
		f.Limit = n
	}
	if vals.Has("page_token") {
		if f.PageToken = vals.Get("page_token"); f.PageToken == "" {
			return f, httpx.ErrBadRequest
		}
	}
	return f, nil
}

func adminReason(kind, code string, ticket *string) (admin.Reason, bool) {
	if !admin.ValidReason(kind, code) || (ticket != nil && !admin.ValidTicketRef(*ticket)) {
		return admin.Reason{}, false
	}
	return admin.Reason{Code: code, TicketRef: ticket}, true
}

// --- response shapes (TRD 06 §6.3 to §6.5) -----------------------------------------------------

type adminListItem struct {
	ID             uuid.UUID  `json:"id"`
	Email          string     `json:"email"`
	Status         string     `json:"status"`
	Role           string     `json:"role"`
	CreatedAt      time.Time  `json:"created_at"`
	StateChangedAt *time.Time `json:"state_changed_at"`
}

type adminSuspension struct {
	ReasonCode        string     `json:"reason_code"`
	TicketRef         *string    `json:"ticket_ref"`
	SuspendedAt       *time.Time `json:"suspended_at"`
	SuspendedByUserID *uuid.UUID `json:"suspended_by_user_id"`
	ResumeStatus      string     `json:"resume_status"`
}

type adminPendingDeletion struct {
	AcceptedAt *time.Time `json:"accepted_at"`
}

type adminSessionsSummary struct {
	LiveCount  int64      `json:"live_count"`
	LastSeenAt *time.Time `json:"last_seen_at"`
}

type adminUser struct {
	ID                uuid.UUID             `json:"id"`
	Email             string                `json:"email"`
	EmailVerifiedAt   *time.Time            `json:"email_verified_at"`
	HasPassword       bool                  `json:"has_password"`
	PasswordChangedAt *time.Time            `json:"password_changed_at"`
	DisplayName       *string               `json:"display_name"`
	PreferredLanguage string                `json:"preferred_language"`
	TimeZone          string                `json:"time_zone"`
	CreatedAt         time.Time             `json:"created_at"`
	Status            string                `json:"status"`
	LifecycleRevision int64                 `json:"lifecycle_revision"`
	StateChangedAt    *time.Time            `json:"state_changed_at"`
	Suspension        *adminSuspension      `json:"suspension"`
	PendingDeletion   *adminPendingDeletion `json:"pending_deletion"`
	Role              string                `json:"role"`
	RoleRevision      int64                 `json:"role_revision"`
	RoleChangedAt     *time.Time            `json:"role_changed_at"`
	Sessions          adminSessionsSummary  `json:"sessions"`
	Plan              string                `json:"plan"`
	PlanExpiresAt     *time.Time            `json:"plan_expires_at"`
	EntitlementRev    int64                 `json:"entitlement_revision"`
	AllowedActions    []string              `json:"allowed_actions"`
	AssignableRoles   []string              `json:"assignable_roles"`
}

type adminSession struct {
	ID                uuid.UUID `json:"id"`
	DeviceName        string    `json:"device_name"`
	Platform          string    `json:"platform"`
	CreatedAt         time.Time `json:"created_at"`
	LastSeenAt        time.Time `json:"last_seen_at"`
	RefreshExpiresAt  time.Time `json:"refresh_expires_at"`
	AbsoluteExpiresAt time.Time `json:"absolute_expires_at"`
}

// adminUserBody is an explicit projection: no hashes, tokens, IPs, user agents, pending email
// change addresses, outbox data or learning content (TRD 06 R8).
func adminUserBody(d admin.Detail) adminUser {
	u := d.User
	out := adminUser{
		ID: u.ID, Email: u.Email, EmailVerifiedAt: utc(u.EmailVerifiedAt), HasPassword: u.PasswordHash != nil,
		PasswordChangedAt: utc(u.PasswordChangedAt), DisplayName: u.DisplayName, PreferredLanguage: u.PreferredLanguage,
		TimeZone: u.TimeZone, CreatedAt: u.CreatedAt.UTC(), Status: u.Status, LifecycleRevision: u.LifecycleRevision,
		StateChangedAt: utc(u.StateChangedAt), Role: u.Role, RoleRevision: u.RoleRevision, RoleChangedAt: utc(u.RoleChangedAt),
		Sessions: adminSessionsSummary{LiveCount: d.LiveSessions, LastSeenAt: d.LastSeenAt},
		Plan:     d.Plan.Name, PlanExpiresAt: d.Plan.ExpiresAt, EntitlementRev: u.EntitlementRevision,
		AllowedActions: d.AllowedActions, AssignableRoles: d.AssignableRoles,
	}
	if u.Status == accounts.StatusSuspended && u.SuspensionReason != nil && u.ResumeStatus != nil {
		out.Suspension = &adminSuspension{ReasonCode: *u.SuspensionReason, TicketRef: u.SuspensionTicketRef,
			SuspendedAt: utc(u.StateChangedAt), SuspendedByUserID: u.SuspendedBy, ResumeStatus: *u.ResumeStatus}
	}
	if u.Status == accounts.StatusPendingDeletion {
		out.PendingDeletion = &adminPendingDeletion{AcceptedAt: d.DeletionAcceptedAt}
	}
	return out
}

// --- handlers ----------------------------------------------------------------------------------

func (h *Handlers) adminListUsers(w http.ResponseWriter, r *http.Request, p session.Principal) {
	f, err := parseAdminFilter(r)
	if err != nil {
		h.fail(w, r, err)
		return
	}
	page, err := h.Admin.List(r.Context(), p, f, h.sessionClient(w, r))
	if err != nil {
		h.fail(w, r, err)
		return
	}
	items := make([]adminListItem, 0, len(page.Items))
	for _, row := range page.Items {
		items = append(items, adminListItem{ID: row.ID, Email: row.Email, Status: row.Status, Role: row.Role,
			CreatedAt: row.CreatedAt.UTC(), StateChangedAt: utc(row.StateChangedAt)})
	}
	httpx.WriteJSON(w, http.StatusOK, struct {
		Items         []adminListItem `json:"items"`
		NextPageToken *string         `json:"next_page_token"`
	}{items, page.NextPageToken})
}

func (h *Handlers) adminGetUser(w http.ResponseWriter, r *http.Request, p session.Principal) {
	id, ok := pathUserID(r)
	if !ok {
		h.fail(w, r, httpx.ErrBadRequest)
		return
	}
	d, err := h.Admin.Get(r.Context(), p, id, h.sessionClient(w, r))
	if err != nil {
		h.fail(w, r, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, adminUserBody(d))
}

func (h *Handlers) adminListSessions(w http.ResponseWriter, r *http.Request, p session.Principal) {
	id, ok := pathUserID(r)
	if !ok {
		h.fail(w, r, httpx.ErrBadRequest)
		return
	}
	rows, err := h.Admin.ListSessions(r.Context(), p, id, h.sessionClient(w, r))
	if err != nil {
		h.fail(w, r, err)
		return
	}
	items := make([]adminSession, 0, len(rows))
	for _, s := range rows {
		items = append(items, adminSession{ID: s.ID, DeviceName: s.DeviceName, Platform: s.Platform, CreatedAt: s.CreatedAt.UTC(),
			LastSeenAt: s.LastSeenAt.UTC(), RefreshExpiresAt: s.RefreshExpiresAt.UTC(), AbsoluteExpiresAt: s.AbsoluteExpiresAt.UTC()})
	}
	httpx.WriteJSON(w, http.StatusOK, struct {
		Sessions []adminSession `json:"sessions"`
	}{items})
}

func (h *Handlers) adminRevokeSessions(w http.ResponseWriter, r *http.Request, p session.Principal) {
	id, ok := pathUserID(r)
	if !ok {
		h.fail(w, r, httpx.ErrBadRequest)
		return
	}
	var req struct {
		SessionID  *string `json:"session_id"`
		ReasonCode string  `json:"reason_code"`
		TicketRef  *string `json:"ticket_ref"`
	}
	if err := httpx.DecodeJSON(w, r, &req); err != nil {
		h.fail(w, r, err)
		return
	}
	reason, ok := adminReason("sessions", req.ReasonCode, req.TicketRef)
	var target *uuid.UUID
	if req.SessionID != nil {
		sid, err := uuid.Parse(*req.SessionID)
		if err != nil || len(*req.SessionID) != 36 || sid == uuid.Nil {
			ok = false
		}
		target = &sid
	}
	if !ok {
		h.fail(w, r, httpx.ErrBadRequest)
		return
	}
	n, err := h.Admin.RevokeSessions(r.Context(), p, id, target, reason, h.sessionClient(w, r))
	if err != nil {
		h.fail(w, r, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, struct {
		RevokedSessions int64 `json:"revoked_sessions"`
	}{n})
}

func (h *Handlers) adminTransition(w http.ResponseWriter, r *http.Request, p session.Principal) {
	id, ok := pathUserID(r)
	if !ok {
		h.fail(w, r, httpx.ErrBadRequest)
		return
	}
	var req struct {
		Action                    string  `json:"action"`
		ReasonCode                string  `json:"reason_code"`
		TicketRef                 *string `json:"ticket_ref"`
		ExpectedLifecycleRevision *int64  `json:"expected_lifecycle_revision"`
	}
	if err := httpx.DecodeJSON(w, r, &req); err != nil {
		h.fail(w, r, err)
		return
	}
	reason, ok := adminReason(req.Action, req.ReasonCode, req.TicketRef)
	if !ok || (req.Action != "suspend" && req.Action != "reinstate") || req.ExpectedLifecycleRevision == nil || *req.ExpectedLifecycleRevision < 0 {
		h.fail(w, r, httpx.ErrBadRequest)
		return
	}
	d, err := h.Admin.Transition(r.Context(), p, id, req.Action, *req.ExpectedLifecycleRevision, reason, h.sessionClient(w, r))
	if err != nil {
		h.fail(w, r, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, adminUserBody(d))
}

func (h *Handlers) adminChangeRole(w http.ResponseWriter, r *http.Request, p session.Principal) {
	id, ok := pathUserID(r)
	if !ok {
		h.fail(w, r, httpx.ErrBadRequest)
		return
	}
	var req struct {
		Role                 string  `json:"role"`
		ReasonCode           string  `json:"reason_code"`
		TicketRef            *string `json:"ticket_ref"`
		ExpectedRoleRevision *int64  `json:"expected_role_revision"`
	}
	if err := httpx.DecodeJSON(w, r, &req); err != nil {
		h.fail(w, r, err)
		return
	}
	reason, ok := adminReason("role", req.ReasonCode, req.TicketRef)
	if !ok || accounts.Rank(req.Role) == 0 || req.ExpectedRoleRevision == nil || *req.ExpectedRoleRevision < 0 {
		h.fail(w, r, httpx.ErrBadRequest)
		return
	}
	d, err := h.Admin.ChangeRole(r.Context(), p, id, req.Role, *req.ExpectedRoleRevision, reason, h.sessionClient(w, r))
	if err != nil {
		h.fail(w, r, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, adminUserBody(d))
}

// adminAuditEntry is the explicit field allowlist of the history view (TRD 06 §9a): no IP,
// user agent, request ID, session, email HMAC or other metadata ever leaves the server here.
type adminAuditEntry struct {
	OccurredAt  time.Time  `json:"occurred_at"`
	Action      string     `json:"action"`
	Outcome     string     `json:"outcome"`
	ActorUserID *uuid.UUID `json:"actor_user_id"`
	ReasonCode  *string    `json:"reason_code"`
	TicketRef   *string    `json:"ticket_ref"`
}

func (h *Handlers) adminAuditHistory(w http.ResponseWriter, r *http.Request, p session.Principal) {
	raw := r.PathValue("user_id")
	id, err := uuid.Parse(raw)
	if err != nil || len(raw) != 36 || id == uuid.Nil {
		h.fail(w, r, httpx.ErrBadRequest)
		return
	}
	vals, err := url.ParseQuery(r.URL.RawQuery)
	if err != nil {
		h.fail(w, r, httpx.ErrBadRequest)
		return
	}
	limit, token := 50, ""
	for k, v := range vals {
		if len(v) != 1 {
			h.fail(w, r, httpx.ErrBadRequest)
			return
		}
		switch k {
		case "limit":
			n, err := strconv.Atoi(v[0])
			if !limitPattern.MatchString(v[0]) || err != nil || n > 100 {
				h.fail(w, r, httpx.ErrBadRequest)
				return
			}
			limit = n
		case "page_token":
			if token = v[0]; token == "" {
				h.fail(w, r, httpx.ErrBadRequest)
				return
			}
		default:
			h.fail(w, r, httpx.ErrBadRequest)
			return
		}
	}
	page, err := h.Admin.AuditHistory(r.Context(), p, id, token, limit, h.sessionClient(w, r))
	if err != nil {
		h.fail(w, r, err)
		return
	}
	items := make([]adminAuditEntry, 0, len(page.Items))
	for _, e := range page.Items {
		items = append(items, adminAuditEntry{OccurredAt: e.OccurredAt, Action: e.Action, Outcome: e.Outcome,
			ActorUserID: e.ActorUserID, ReasonCode: e.ReasonCode, TicketRef: e.TicketRef})
	}
	httpx.WriteJSON(w, http.StatusOK, struct {
		Items         []adminAuditEntry `json:"items"`
		NextPageToken *string           `json:"next_page_token"`
	}{items, page.NextPageToken})
}

func (h *Handlers) adminChangePlan(w http.ResponseWriter, r *http.Request, p session.Principal) {
	id, ok := pathUserID(r)
	if !ok {
		h.fail(w, r, httpx.ErrBadRequest)
		return
	}
	var req struct {
		Plan                        string     `json:"plan"`
		EndsAt                      *time.Time `json:"ends_at"`
		ReasonCode                  string     `json:"reason_code"`
		TicketRef                   *string    `json:"ticket_ref"`
		ExpectedEntitlementRevision *int64     `json:"expected_entitlement_revision"`
	}
	if err := httpx.DecodeJSON(w, r, &req); err != nil {
		h.fail(w, r, err)
		return
	}
	kind := map[string]string{entitlements.Premium: "plan_grant", entitlements.Free: "plan_revoke"}[req.Plan]
	reason, ok := adminReason(kind, req.ReasonCode, req.TicketRef)
	// TRD 09 E4: every change carries a ticket; Premium needs an expiry, Free must not have one.
	if !ok || kind == "" || req.TicketRef == nil || req.ExpectedEntitlementRevision == nil || *req.ExpectedEntitlementRevision < 0 ||
		(req.Plan == entitlements.Premium) != (req.EndsAt != nil) {
		h.fail(w, r, httpx.ErrBadRequest)
		return
	}
	d, err := h.Admin.ChangePlan(r.Context(), p, id, req.Plan, req.EndsAt, *req.ExpectedEntitlementRevision, reason, h.sessionClient(w, r))
	if err != nil {
		h.fail(w, r, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, adminUserBody(d))
}

// meEntitlements is GET /v1/me/entitlements (TRD 09 §6.1): the caller's effective plan at
// database time and the plan's limits. Owner only; no capability is gated yet.
func (h *Handlers) meEntitlements(w http.ResponseWriter, r *http.Request, p session.Principal) {
	if r.URL.RawQuery != "" || r.URL.ForceQuery {
		h.fail(w, r, httpx.ErrBadRequest)
		return
	}
	plan, err := entitlements.Effective(r.Context(), sqlc.New(h.Pool), p.UserID)
	if err != nil {
		h.fail(w, r, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, struct {
		Plan          string              `json:"plan"`
		PlanExpiresAt *time.Time          `json:"plan_expires_at"`
		Limits        entitlements.Limits `json:"limits"`
		CheckedAt     time.Time           `json:"checked_at"`
	}{plan.Name, plan.ExpiresAt, entitlements.LimitsFor(plan.Name), plan.CheckedAt})
}
