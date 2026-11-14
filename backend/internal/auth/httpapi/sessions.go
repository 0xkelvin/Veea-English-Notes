package httpapi

import (
	"net/http"
	"time"

	"github.com/google/uuid"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/auth/session"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/httpx"
)

type sessionSummary struct {
	ID                uuid.UUID `json:"id"`
	DeviceName        string    `json:"device_name"`
	Platform          string    `json:"platform"`
	CreatedAt         time.Time `json:"created_at"`
	LastSeenAt        time.Time `json:"last_seen_at"`
	RefreshExpiresAt  time.Time `json:"refresh_expires_at"`
	AbsoluteExpiresAt time.Time `json:"absolute_expires_at"`
	IsCurrent         bool      `json:"is_current"`
}

func (h *Handlers) listSessions(w http.ResponseWriter, r *http.Request, p session.Principal) {
	if r.URL.RawQuery != "" || r.URL.ForceQuery {
		h.fail(w, r, httpx.ErrBadRequest)
		return
	}
	rows, err := h.Sessions.ListLive(r.Context(), p)
	if err != nil {
		h.fail(w, r, err)
		return
	}
	items := make([]sessionSummary, 0, len(rows))
	for _, row := range rows {
		items = append(items, sessionSummary{ID: row.ID, DeviceName: row.DeviceName, Platform: row.Platform,
			CreatedAt: row.CreatedAt.UTC(), LastSeenAt: row.LastSeenAt.UTC(), RefreshExpiresAt: row.RefreshExpiresAt.UTC(),
			AbsoluteExpiresAt: row.AbsoluteExpiresAt.UTC(), IsCurrent: row.IsCurrent})
	}
	httpx.WriteJSON(w, http.StatusOK, struct {
		CurrentSessionID uuid.UUID        `json:"current_session_id"`
		Sessions         []sessionSummary `json:"sessions"`
	}{p.SessionID, items})
}

func (h *Handlers) revokeSession(w http.ResponseWriter, r *http.Request, p session.Principal) {
	raw := r.PathValue("session_id")
	id, err := uuid.Parse(raw)
	if err != nil || len(raw) != 36 || id == uuid.Nil || r.URL.RawQuery != "" || r.URL.ForceQuery {
		h.fail(w, r, httpx.ErrBadRequest)
		return
	}
	h.noContent(w, r, h.Sessions.RevokeOwned(r.Context(), p, id, h.sessionClient(w, r)))
}

func (h *Handlers) logoutAll(w http.ResponseWriter, r *http.Request, p session.Principal) {
	if r.URL.RawQuery != "" || r.URL.ForceQuery {
		h.fail(w, r, httpx.ErrBadRequest)
		return
	}
	h.noContent(w, r, h.Sessions.LogoutAll(r.Context(), p, h.sessionClient(w, r)))
}
