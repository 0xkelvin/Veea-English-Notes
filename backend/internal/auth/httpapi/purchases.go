package httpapi

import (
	"context"
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
		h.Metrics.ApplePurchaseVerification("claim", "invalid_request")
		h.fail(w, r, httpx.ErrBadRequest)
		return
	}
	if err := httpx.DecodeJSON(w, r, &req); err != nil {
		h.Metrics.ApplePurchaseVerification("claim", "invalid_request")
		h.fail(w, r, err)
		return
	}
	if !purchases.ValidTransactionID(req.TransactionID) {
		h.Metrics.ApplePurchaseVerification("claim", "invalid_request")
		h.fail(w, r, httpx.ErrBadRequest)
		return
	}
	decision, err := h.Limiter.Allow(r.Context(), ratelimit.Check{Rule: ratelimit.Rule{Name: "purchase_verify_user_1m", Limit: 20, Window: time.Minute}, Subject: ratelimit.UserSubject(p.UserID)})
	if err != nil {
		h.Metrics.ApplePurchaseVerification("claim", purchaseResult(err))
		if r.Context().Err() != nil {
			return
		}
		h.purchaseFailure(w, r, appleiap.ErrUnavailable)
		return
	}
	if !decision.Allowed {
		h.Metrics.ApplePurchaseVerification("claim", "rate_limited")
		w.Header().Set("Retry-After", "60")
		httpx.WriteProblem(w, 429, httpx.CodeRateLimited)
		return
	}
	if !h.Purchases.Available() {
		h.Metrics.ApplePurchaseVerification("claim", "disabled")
		h.purchaseFailure(w, r, appleiap.ErrUnavailable)
		return
	}
	outcome, err := h.Purchases.VerifyAndClaimOutcome(r.Context(), p, req.TransactionID)
	if err != nil {
		h.Metrics.ApplePurchaseVerification("claim", purchaseResult(err))
		h.purchaseFailure(w, r, err)
		return
	}
	result := "sandbox_recorded"
	if outcome.Environment == appleiap.EnvProduction {
		result = "production_recorded"
	} else if !outcome.Recorded {
		result = "sandbox_acknowledged"
	}
	h.Metrics.ApplePurchaseVerification("claim", result)
	h.writeMyEntitlements(w, r, p, &outcome)
}

func purchaseResult(err error) string {
	switch {
	case errors.Is(err, context.Canceled), errors.Is(err, context.DeadlineExceeded):
		return "request_canceled"
	case errors.Is(err, session.ErrUnauthorized):
		return "authentication_failed"
	case errors.Is(err, purchases.ErrReconcileBackoff):
		return "reconcile_backoff"
	case errors.Is(err, appleiap.ErrUnavailable):
		return "upstream_failed"
	case errors.Is(err, appleiap.ErrInvalid):
		return "invalid_proof"
	case errors.Is(err, purchases.ErrOwnership):
		return "ownership_conflict"
	default:
		return "internal_error"
	}
}

func (h *Handlers) purchaseFailure(w http.ResponseWriter, r *http.Request, err error) {
	if r.Context().Err() != nil {
		return
	}
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
