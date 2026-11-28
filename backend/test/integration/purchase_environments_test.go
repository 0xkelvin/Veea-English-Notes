//go:build integration

package integration

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/app"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/appleiap"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/auth/session"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/entitlements"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/purchases"
)

func sandboxAckEnv(t *testing.T) (*signupEnv, *purchaseVerifier) {
	f := &purchaseVerifier{}
	return newSignupEnv(t, nil, func(o *app.Options) {
		o.AppleVerifier = f
		o.AppleEnvironment = appleiap.EnvProduction
		o.AppleAllowSandbox = true
	}), f
}

func TestPurchases_SandboxAcknowledgementNeverGrantsProductionPremium(t *testing.T) {
	e, f := sandboxAckEnv(t)
	u, a := e.staff(t, "user")
	_, b := e.staff(t, "user")
	f.proof = appleiap.Transaction{ID: "81001", OriginalID: "81001", ProductID: "app.veea.pro", Environment: appleiap.EnvSandbox, AccountToken: u.ID, PurchasedAt: time.Now().Add(-time.Hour)}
	wantProblem(t, e.post(t, applePurchasePath, purchaseBody("81001")), 401, "unauthorized")
	if f.calls != 0 {
		t.Fatal("unauthenticated lookup reached Apple")
	}
	wantProblem(t, e.post(t, applePurchasePath, purchaseBody("81001"), bearer(b.AccessToken)...), 409, "purchase_ownership_conflict")
	for i := 0; i < 2; i++ {
		r := e.post(t, applePurchasePath, purchaseBody("81001"), bearer(a.AccessToken)...)
		wantPlan(t, r, "free", nil)
		if r.body["purchase_environment"] != "Sandbox" || r.body["purchase_recorded"] != false || r.body["purchase_revoked"] != false {
			t.Fatalf("missing sandbox acknowledgement: %s", r.raw)
		}
	}
	if rowCount(t, e.d.Pool, `SELECT count(*) FROM apple_pro_purchases`) != 0 {
		t.Fatal("test proof was persisted")
	}
	wantPlan(t, e.myPlan(t, a.AccessToken), "free", nil)
	plan, err := entitlements.Effective(context.Background(), e.q, u.ID)
	if err != nil || plan.Name != "free" {
		t.Fatalf("Sandbox granted server Premium: %+v %v", plan, err)
	}
	// No client flag can choose the environment or bypass Apple's verified proof.
	wantProblem(t, e.post(t, applePurchasePath, map[string]any{"transaction_id": "81001", "environment": "Sandbox"}, bearer(a.AccessToken)...), 400, "invalid_request")
	// A Sandbox refund is acknowledged, without creating durable payment rows.
	at := time.Now()
	f.proof.RevokedAt = &at
	r := e.post(t, applePurchasePath, purchaseBody("81001"), bearer(a.AccessToken)...)
	wantPlan(t, r, "free", nil)
	if r.body["purchase_revoked"] != true || r.body["purchase_recorded"] != false {
		t.Fatal("Sandbox refund incorrectly acknowledged", r.raw)
	}
	if rowCount(t, e.d.Pool, `SELECT count(*) FROM apple_pro_purchases`) != 0 {
		t.Fatal("refund created a test row")
	}
}

func TestPurchases_SandboxAcknowledgementPreservesRealPurchaseAndManualGrant(t *testing.T) {
	e, f := sandboxAckEnv(t)
	u, a := e.staff(t, "user")
	f.proof = appleiap.Transaction{ID: "82001", OriginalID: "82001", ProductID: "app.veea.pro", Environment: appleiap.EnvProduction, AccountToken: u.ID, PurchasedAt: time.Now().Add(-time.Hour)}
	r := e.post(t, applePurchasePath, purchaseBody("82001"), bearer(a.AccessToken)...)
	wantPlan(t, r, "premium", nil)
	if r.body["purchase_environment"] != "Production" || r.body["purchase_recorded"] != true {
		t.Fatal("real purchase not recorded", r.raw)
	}
	for i := 0; i < 6; i++ {
		f.proof.ID = "82002"
		f.proof.OriginalID = "82002"
		f.proof.Environment = appleiap.EnvSandbox
		wantPlan(t, e.post(t, applePurchasePath, purchaseBody("82002"), bearer(a.AccessToken)...), "premium", nil)
	}
	if rowCount(t, e.d.Pool, `SELECT count(*) FROM apple_pro_purchases WHERE environment='Production' AND original_transaction_id='82001'`) != 1 || rowCount(t, e.d.Pool, `SELECT count(*) FROM apple_pro_purchases`) != 1 {
		t.Fatal("Sandbox claims pruned or changed production proof")
	}
	// Test refunds do not revoke a real purchase.
	at := time.Now()
	f.proof.RevokedAt = &at
	r = e.post(t, applePurchasePath, purchaseBody("82002"), bearer(a.AccessToken)...)
	wantPlan(t, r, "premium", nil)
	if r.body["purchase_revoked"] != true {
		t.Fatal("test refund outcome missing")
	}
	// A stale Production row cannot be renewed via a colliding Sandbox proof.
	mustExec(t, e.d.Pool, `UPDATE apple_pro_purchases SET verified_at=clock_timestamp()-interval '6 minutes' WHERE user_id=$1`, u.ID)
	f.proof.ID = "82001"
	f.proof.OriginalID = "82001"
	f.proof.RevokedAt = nil
	wantProblem(t, e.myPlan(t, a.AccessToken), 400, "purchase_invalid")
	r = e.post(t, applePurchasePath, purchaseBody("82001"), bearer(a.AccessToken)...)
	wantPlan(t, r, "free", nil)
	if r.body["purchase_verification_pending"] != true || r.body["purchase_recorded"] != false || r.body["purchase_revoked"] != false {
		t.Fatal("pending stored proof masked the valid Sandbox acknowledgement", r.raw)
	}
	if rowCount(t, e.d.Pool, `SELECT count(*) FROM apple_pro_purchases WHERE user_id=$1 AND environment='Sandbox'`, u.ID) != 0 {
		t.Fatal("pending account reconciliation persisted a Sandbox acknowledgement in Production")
	}
	rec := httptest.NewRecorder()
	e.metrics.Handler().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/metrics", nil))
	if !strings.Contains(rec.Body.String(), `apple_purchase_verification_total{operation="claim",result="sandbox_acknowledged"} 8`+"\n") {
		t.Fatal("Sandbox acknowledgements were not counted separately")
	}
	// Independent manual grants still work if real-purchase verification is uncertain.
	_, admin := e.staff(t, "admin")
	end := e.dbNow(t).Add(time.Hour)
	wantStatus(t, e.grantPremium(t, admin.AccessToken, u.ID, end, 0), 200)
	r = e.post(t, applePurchasePath, purchaseBody("82001"), bearer(a.AccessToken)...)
	wantPlan(t, r, "premium", &end)
	if r.body["purchase_verification_pending"] != true {
		t.Fatal("manual fallback concealed uncertain real proof")
	}
}

func TestPurchases_SandboxAcknowledgementRevalidatesSessionAndStanding(t *testing.T) {
	for _, change := range []string{"session", "user"} {
		t.Run(change, func(t *testing.T) {
			e, f := sandboxAckEnv(t)
			u, a := e.staff(t, "user")
			f.proof = appleiap.Transaction{ID: "83001", OriginalID: "83001", ProductID: "app.veea.pro", Environment: appleiap.EnvSandbox, AccountToken: u.ID, PurchasedAt: time.Now().Add(-time.Hour)}
			f.before = func() {
				if change == "session" {
					mustExec(t, e.d.Pool, `UPDATE sessions SET revoked_at=clock_timestamp(),revoked_reason='logout' WHERE id=$1`, a.SessionID)
				} else {
					mustExec(t, e.d.Pool, `UPDATE users SET status='deactivated' WHERE id=$1`, u.ID)
				}
			}
			wantProblem(t, e.post(t, applePurchasePath, purchaseBody("83001"), bearer(a.AccessToken)...), 401, "unauthorized")
			if rowCount(t, e.d.Pool, `SELECT count(*) FROM apple_pro_purchases`) != 0 {
				t.Fatal("invalid identity created payment")
			}
		})
	}
}

func TestPurchases_SandboxAcknowledgementsRequireProductionGate(t *testing.T) {
	e, f := billingEnv(t)
	// Explicit flag off retains strict Production-only verification.
	u, a := e.staff(t, "user")
	f.proof = appleiap.Transaction{ID: "84001", OriginalID: "84001", ProductID: "app.veea.pro", Environment: appleiap.EnvSandbox, AccountToken: u.ID, PurchasedAt: time.Now().Add(-time.Hour)}
	wantProblem(t, e.post(t, applePurchasePath, purchaseBody("84001"), bearer(a.AccessToken)...), 400, "purchase_invalid")
	svc := purchases.NewWithSandboxAcknowledgements(e.d.Pool, f, appleiap.EnvSandbox, true, nil)
	if svc.CheckEnvironment(context.Background()) == nil {
		t.Fatal("Sandbox API accepted Production fallback flag")
	}
	mustExec(t, e.d.Pool, `UPDATE apple_iap_control SET environment='Sandbox' WHERE singleton`)
	svc = purchases.NewWithSandboxAcknowledgements(e.d.Pool, f, appleiap.EnvProduction, true, nil)
	if svc.CheckEnvironment(context.Background()) == nil {
		t.Fatal("Production fallback accepted Sandbox database")
	}
	// Dedicated Sandbox staging keeps durable sandbox ownership, as before.
	svc = purchases.New(e.d.Pool, f, appleiap.EnvSandbox, nil)
	if err := svc.CheckEnvironment(context.Background()); err != nil {
		t.Fatal(err)
	}
	outcome, err := svc.VerifyAndClaimOutcome(context.Background(), session.Principal{UserID: u.ID, SessionID: a.SessionID}, "84001")
	if err != nil || !outcome.Recorded || outcome.Environment != appleiap.EnvSandbox {
		t.Fatalf("staging claim failed: %+v %v", outcome, err)
	}
}
