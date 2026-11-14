package httpapi

import (
	"net/http"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/account"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/auth/session"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/httpx"
	"github.com/google/uuid"
)

type profileBody struct {
	DisplayName       *string `json:"display_name"`
	PreferredLanguage string  `json:"preferred_language"`
	TimeZone          string  `json:"time_zone"`
	DailyGoal         int32   `json:"daily_goal"`
	Revision          int64   `json:"revision"`
}

func (h *Handlers) updateProfile(w http.ResponseWriter, r *http.Request, p session.Principal) {
	if r.URL.RawQuery != "" || r.URL.ForceQuery {
		h.fail(w, r, httpx.ErrBadRequest)
		return
	}
	var req struct {
		ExpectedRevision  *int64  `json:"expected_revision"`
		DisplayName       *string `json:"display_name"`
		PreferredLanguage string  `json:"preferred_language"`
		TimeZone          string  `json:"time_zone"`
		DailyGoal         *int32  `json:"daily_goal"`
	}
	if err := httpx.DecodeJSON(w, r, &req); err != nil {
		h.fail(w, r, err)
		return
	}
	if req.ExpectedRevision == nil || req.DailyGoal == nil {
		h.fail(w, r, httpx.ErrBadRequest)
		return
	}
	u, err := h.Account.UpdateProfile(r.Context(), p, account.Profile{DisplayName: req.DisplayName, PreferredLanguage: req.PreferredLanguage, TimeZone: req.TimeZone, DailyGoal: *req.DailyGoal, ExpectedRevision: *req.ExpectedRevision}, h.sessionClient(w, r))
	if err != nil {
		h.fail(w, r, err)
		return
	}
	httpx.WriteJSON(w, 200, userBody(u))
}

func (h *Handlers) startEmailChange(w http.ResponseWriter, r *http.Request, p session.Principal) {
	if r.URL.RawQuery != "" || r.URL.ForceQuery {
		h.fail(w, r, httpx.ErrBadRequest)
		return
	}
	var req struct {
		NewEmail string `json:"new_email"`
	}
	if err := httpx.DecodeJSON(w, r, &req); err != nil {
		h.fail(w, r, err)
		return
	}
	out, err := h.Account.StartEmailChange(r.Context(), p, req.NewEmail, h.sessionClient(w, r))
	if err != nil {
		h.fail(w, r, err)
		return
	}
	httpx.WriteJSON(w, 202, struct {
		ChangeID     uuid.UUID       `json:"change_id"`
		CurrentEmail acknowledgement `json:"current_email"`
		NewEmail     acknowledgement `json:"new_email"`
	}{out.ChangeID, ackBody(out.Current), ackBody(out.New)})
}

func (h *Handlers) completeEmailChange(w http.ResponseWriter, r *http.Request, p session.Principal) {
	raw := r.PathValue("change_id")
	id, err := uuid.Parse(raw)
	if err != nil || len(raw) != 36 || id == uuid.Nil || r.URL.RawQuery != "" || r.URL.ForceQuery {
		h.fail(w, r, httpx.ErrBadRequest)
		return
	}
	var req struct {
		CurrentToken string `json:"current_challenge_token"`
		CurrentCode  string `json:"current_code"`
		NewToken     string `json:"new_challenge_token"`
		NewCode      string `json:"new_code"`
	}
	if err := httpx.DecodeJSON(w, r, &req); err != nil {
		h.fail(w, r, err)
		return
	}
	h.noContent(w, r, h.Account.CompleteEmailChange(r.Context(), p, id, account.ProofPair{CurrentToken: req.CurrentToken, CurrentCode: req.CurrentCode, NewToken: req.NewToken, NewCode: req.NewCode}, h.sessionClient(w, r)))
}
