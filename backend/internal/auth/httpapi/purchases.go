package httpapi

import (
	"errors"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/appleiap"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/auth/session"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/httpx"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/purchases"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/ratelimit"
	"net/http"
	"time"
)

func (h *Handlers) applePurchase(w http.ResponseWriter, r *http.Request, p session.Principal) {
	var req struct {
		TransactionID string `json:"transaction_id"`
	}
	if r.URL.RawQuery != "" || r.URL.ForceQuery {
		h.fail(w, r, httpx.ErrBadRequest)
		return
	}
	if err := httpx.DecodeJSON(w, r, &req); err != nil {
		h.fail(w, r, err)
		return
	}
	if !purchases.ValidTransactionID(req.TransactionID) {
		h.fail(w, r, httpx.ErrBadRequest)
		return
	}
	decision, err := h.Limiter.Allow(r.Context(), ratelimit.Check{Rule: ratelimit.Rule{Name: "purchase_verify_user_1m", Limit: 20, Window: time.Minute}, Subject: ratelimit.UserSubject(p.UserID)})
	if err != nil {
		h.purchaseFailure(w, r, appleiap.ErrUnavailable)
		return
	}
	if !decision.Allowed {
		w.Header().Set("Retry-After", "60")
		httpx.WriteProblem(w, 429, httpx.CodeRateLimited)
		return
	}
	if h.Purchases == nil {
		h.purchaseFailure(w, r, appleiap.ErrUnavailable)
		return
	}
	outcome, err := h.Purchases.VerifyAndClaimOutcome(r.Context(), p, req.TransactionID)
	if err != nil {
		h.purchaseFailure(w, r, err)
		return
	}
	h.writeMyEntitlements(w, r, p, &outcome)
}
func (h *Handlers) purchaseFailure(w http.ResponseWriter, r *http.Request, err error) {
	switch {
	case errors.Is(err, appleiap.ErrUnavailable):
		w.Header().Set("Retry-After", "60")
		httpx.WriteProblem(w, 503, httpx.CodePurchaseUnavailable)
	case errors.Is(err, appleiap.ErrInvalid):
		httpx.WriteProblem(w, 400, httpx.CodePurchaseInvalid)
	case errors.Is(err, purchases.ErrOwnership):
		httpx.WriteProblem(w, 409, httpx.CodePurchaseOwnership)
	default:
		h.fail(w, r, err)
	}
}
