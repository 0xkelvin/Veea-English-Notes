package httpapi

import (
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/auth/session"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/db/sqlc"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/httpx"
	"github.com/google/uuid"
	"net/http"
	"strconv"
	"strings"
	"time"
)

func (h *Handlers) deactivate(w http.ResponseWriter, r *http.Request, p session.Principal) {
	if r.URL.RawQuery != "" || r.URL.ForceQuery {
		h.fail(w, r, httpx.ErrBadRequest)
		return
	}
	var req struct {
		Confirm          bool   `json:"confirm"`
		ExpectedRevision *int64 `json:"expected_revision"`
	}
	if err := httpx.DecodeJSON(w, r, &req); err != nil {
		h.fail(w, r, err)
		return
	}
	if !req.Confirm || req.ExpectedRevision == nil || *req.ExpectedRevision < 0 {
		h.fail(w, r, httpx.ErrBadRequest)
		return
	}
	h.noContent(w, r, h.Lifecycle.Deactivate(r.Context(), p, *req.ExpectedRevision, h.sessionClient(w, r)))
}
func (h *Handlers) rightsStart(action string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.URL.RawQuery != "" || r.URL.ForceQuery {
			h.fail(w, r, httpx.ErrBadRequest)
			return
		}
		var req emailRequest
		if err := httpx.DecodeJSON(w, r, &req); err != nil {
			h.fail(w, r, err)
			return
		}
		out, err := h.Lifecycle.Start(r.Context(), action, req.Email, h.sessionClient(w, r))
		if err != nil {
			h.fail(w, r, err)
			return
		}
		httpx.WriteJSON(w, 202, struct {
			OperationID    uuid.UUID `json:"operation_id"`
			OperationToken string    `json:"operation_token"`
			ChallengeToken string    `json:"challenge_token"`
			ExpiresAt      time.Time `json:"expires_at"`
			ResendAfter    time.Time `json:"resend_after"`
		}{out.OperationID, out.OperationToken, out.Proof.ChallengeToken, out.Proof.ExpiresAt, out.Proof.ResendAfter})
	}
}

// rightsAuthenticated is deliberately separate from live-session authenticated: it grants
// only one operation, including to a mailbox-proven inactive owner. It never makes a Principal.
func (h *Handlers) rightsAuthenticated(action string, next func(http.ResponseWriter, *http.Request, sqlc.AccountOperation)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		raw := r.PathValue("operation_id")
		id, err := uuid.Parse(raw)
		if err != nil || len(raw) != 36 || id == uuid.Nil || r.URL.RawQuery != "" || r.URL.ForceQuery {
			h.fail(w, r, httpx.ErrBadRequest)
			return
		}
		headers := r.Header.Values("Authorization")
		token := ""
		if len(headers) == 1 {
			scheme, value, ok := strings.Cut(headers[0], " ")
			if ok && strings.EqualFold(scheme, "Rights") && !strings.ContainsAny(value, " \t\n") {
				token = value
			}
		}
		op, err := h.Lifecycle.Lookup(r.Context(), action, id, token, h.sessionClient(w, r))
		if err != nil {
			h.fail(w, r, err)
			return
		}
		next(w, r, op)
	}
}
func (h *Handlers) rightsComplete(w http.ResponseWriter, r *http.Request, op sqlc.AccountOperation) {
	if op.Action == "delete" {
		var req struct {
			ChallengeToken string `json:"challenge_token"`
			Code           string `json:"code"`
			Confirm        string `json:"confirm"`
		}
		if err := httpx.DecodeJSON(w, r, &req); err != nil {
			h.fail(w, r, err)
			return
		}
		if req.Confirm != "delete_account" {
			h.fail(w, r, httpx.ErrBadRequest)
			return
		}
		if err := h.Lifecycle.Complete(r.Context(), op, req.ChallengeToken, req.Code, h.sessionClient(w, r)); err != nil {
			h.fail(w, r, err)
			return
		}
	} else {
		var req struct {
			ChallengeToken string `json:"challenge_token"`
			Code           string `json:"code"`
		}
		if err := httpx.DecodeJSON(w, r, &req); err != nil {
			h.fail(w, r, err)
			return
		}
		if err := h.Lifecycle.Complete(r.Context(), op, req.ChallengeToken, req.Code, h.sessionClient(w, r)); err != nil {
			h.fail(w, r, err)
			return
		}
	}
	if op.Action == "reactivate" {
		h.noContent(w, r, nil)
		return
	}
	// Reuse capability authorization after commit; no response field contains an address/token.
	_, token, _ := strings.Cut(r.Header.Get("Authorization"), " ")
	current, err := h.Lifecycle.Lookup(r.Context(), op.Action, op.ID, token, h.sessionClient(w, r))
	if err != nil {
		h.fail(w, r, err)
		return
	}
	httpx.WriteJSON(w, 202, operationBody(current))
}

type operationView struct {
	ID                uuid.UUID  `json:"operation_id"`
	Action            string     `json:"action"`
	State             string     `json:"state"`
	RequestedAt       time.Time  `json:"requested_at"`
	AcceptedAt        *time.Time `json:"accepted_at"`
	CompletedAt       *time.Time `json:"completed_at"`
	ExpiresAt         time.Time  `json:"expires_at"`
	DownloadExpiresAt *time.Time `json:"download_expires_at"`
	BackupExpiryDueAt *time.Time `json:"backup_expiry_due_at"`
}

func operationBody(op sqlc.AccountOperation) operationView {
	var backup *time.Time
	if op.Action == "delete" && op.State == "completed" && op.CompletedAt != nil {
		t := op.CompletedAt.Add(30 * 24 * time.Hour)
		backup = &t
	}
	return operationView{op.ID, op.Action, op.State, op.CreatedAt, op.AcceptedAt, op.CompletedAt, op.ExpiresAt, op.DownloadExpiresAt, backup}
}
func (h *Handlers) rightsStatus(w http.ResponseWriter, r *http.Request, op sqlc.AccountOperation) {
	httpx.WriteJSON(w, 200, operationBody(op))
}
func (h *Handlers) rightsDownload(w http.ResponseWriter, r *http.Request, op sqlc.AccountOperation) {
	a, err := h.Lifecycle.Download(r.Context(), op, h.sessionClient(w, r))
	if err != nil {
		h.fail(w, r, err)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Content-Disposition", `attachment; filename="veea-account.json"`)
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Length", strconv.FormatInt(a.Size, 10))
	w.WriteHeader(200)
	if err := h.Lifecycle.StreamArtifact(r.Context(), a, w); err != nil {
		// Headers are sent: abort the connection short of Content-Length rather than end cleanly.
		h.Log.Error("export download aborted", "request_id", httpx.RequestID(w), "error", err)
		panic(http.ErrAbortHandler)
	}
}
