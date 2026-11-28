package httpapi

import (
	"context"
	"errors"
	"testing"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/appleiap"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/purchases"
)

func TestPurchaseFailureMetricClassification(t *testing.T) {
	for _, test := range []struct {
		err    error
		result string
	}{
		{context.Canceled, "request_canceled"},
		{context.DeadlineExceeded, "request_canceled"},
		{appleiap.ErrUnavailable, "upstream_failed"},
		{purchases.ErrReconcileBackoff, "reconcile_backoff"},
		{purchases.ErrReconcileSaturated, "reconcile_saturated"},
		{appleiap.ErrInvalid, "invalid_proof"},
		{errors.New("synthetic internal error"), "internal_error"},
	} {
		if got := purchaseResult(test.err); got != test.result {
			t.Errorf("got %q, want %q", got, test.result)
		}
	}
}
