//go:build integration

package integration

import (
	"context"
	"encoding/json"
	"fmt"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/app"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/appleiap"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/entitlements"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/purchases"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

type purchaseVerifier struct {
	mu     sync.Mutex
	proof  appleiap.Transaction
	err    error
	calls  int
	before func()
}

func (f *purchaseVerifier) Verify(_ context.Context, id string) (appleiap.Transaction, error) {
	f.mu.Lock()
	f.calls++
	proof, err, before := f.proof, f.err, f.before
	if proof.SignedAt.IsZero() {
		proof.SignedAt = time.Now().UTC().Truncate(time.Millisecond)
	}
	f.mu.Unlock()
	if before != nil {
		before()
	}
	if proof.ID != id && err == nil {
		return appleiap.Transaction{}, appleiap.ErrInvalid
	}
	return proof, err
}
func billingEnv(t *testing.T) (*signupEnv, *purchaseVerifier) {
	f := &purchaseVerifier{}
	return newSignupEnv(t, nil, func(o *app.Options) { o.AppleVerifier = f; o.AppleEnvironment = "Production" }), f
}
func purchaseBody(id string) map[string]string { return map[string]string{"transaction_id": id} }

const applePurchasePath = "/v1/me/purchases/apple"

func TestPurchases_AccountOwnershipRefundAndManualIndependence(t *testing.T) {
	e, f := billingEnv(t)
	u, a := e.staff(t, "user")
	_, b := e.staff(t, "user")
	f.proof = appleiap.Transaction{ID: "2001", OriginalID: "2001", ProductID: "app.veea.pro", Environment: "Production", AccountToken: u.ID, PurchasedAt: time.Now().Add(-time.Hour)}
	wantProblem(t, e.post(t, applePurchasePath, purchaseBody("2001")), 401, "unauthorized")
	if f.calls != 0 {
		t.Fatal("unauthenticated request reached Apple")
	}
	wantProblem(t, e.post(t, applePurchasePath, purchaseBody("2001"), bearer(b.AccessToken)...), 409, "purchase_ownership_conflict")
	r := e.post(t, applePurchasePath, purchaseBody("2001"), bearer(a.AccessToken)...)
	wantPlan(t, r, "premium", nil)
	if r.body["purchase_revoked"] != false {
		t.Fatal("active receipt outcome missing")
	}
	wantPlan(t, e.post(t, applePurchasePath, purchaseBody("2001"), bearer(a.AccessToken)...), "premium", nil)
	if n := rowCount(t, e.d.Pool, `SELECT count(*) FROM apple_pro_purchases WHERE user_id=$1`, u.ID); n != 1 {
		t.Fatalf("retry duplicated receipt: %d", n)
	}
	wantPlan(t, e.myPlan(t, b.AccessToken), "free", nil)
	at := time.Now()
	reason := int32(1)
	f.proof.RevokedAt = &at
	f.proof.RevocationReason = &reason
	r = e.post(t, applePurchasePath, purchaseBody("2001"), bearer(a.AccessToken)...)
	wantPlan(t, r, "free", nil)
	if r.body["purchase_revoked"] != true {
		t.Fatal("refund not committed/reported")
	}
	// Old active proof must never undo an already observed refund.
	f.proof.RevokedAt = nil
	f.proof.SignedAt = time.Now().Add(-30 * time.Minute)
	f.proof.RevocationReason = nil
	r = e.post(t, applePurchasePath, purchaseBody("2001"), bearer(a.AccessToken)...)
	wantPlan(t, r, "free", nil)
	if r.body["purchase_revoked"] != true {
		t.Fatal("stale active proof undid revocation")
	}
	_, admin := e.staff(t, "admin")
	end := e.dbNow(t).Add(time.Hour)
	wantStatus(t, e.grantPremium(t, admin.AccessToken, u.ID, end, 0), 200)
	wantPlan(t, e.myPlan(t, a.AccessToken), "premium", &end)
	f.proof.RevokedAt = &at
	f.proof.RevocationReason = &reason
	r = e.post(t, applePurchasePath, purchaseBody("2001"), bearer(a.AccessToken)...)
	wantPlan(t, r, "premium", &end)
	if r.body["purchase_revoked"] != true {
		t.Fatal("manual grant concealed receipt revocation")
	}
	wantStatus(t, e.revokePremium(t, admin.AccessToken, u.ID, 1), 200)
	wantPlan(t, e.myPlan(t, a.AccessToken), "free", nil)
}
func TestPurchases_DurableUnknownOutcomeReconcileAndEnvironment(t *testing.T) {
	e, f := billingEnv(t)
	u, a := e.staff(t, "user")
	f.proof = appleiap.Transaction{ID: "3001", OriginalID: "3001", ProductID: "app.veea.pro", Environment: "Production", AccountToken: u.ID, PurchasedAt: time.Now().Add(-time.Hour)}
	wantPlan(t, e.post(t, applePurchasePath, purchaseBody("3001"), bearer(a.AccessToken)...), "premium", nil)
	mustExec(t, e.d.Pool, `UPDATE apple_pro_purchases SET verified_at=clock_timestamp()-interval '6 minutes' WHERE user_id=$1`, u.ID)
	f.err = appleiap.ErrUnavailable
	wantProblem(t, e.myPlan(t, a.AccessToken), 503, "purchase_unavailable")
	plan, err := entitlements.Effective(context.Background(), e.q, u.ID)
	if err != nil || plan.Name != "premium" {
		t.Fatalf("unknown wiped prior proof: %+v %v", plan, err)
	}
	// Other server consumers refuse proofs older than the maximum offline lease.
	mustExec(t, e.d.Pool, `UPDATE apple_pro_purchases SET verified_at=clock_timestamp()-interval '25 hours' WHERE user_id=$1`, u.ID)
	plan, err = entitlements.Effective(context.Background(), e.q, u.ID)
	if err != nil || plan.Name != "free" {
		t.Fatalf("stale proof stayed effective: %+v %v", plan, err)
	}
	f.err = nil
	at := time.Now()
	f.proof.RevokedAt = &at
	wantPlan(t, e.post(t, applePurchasePath, purchaseBody("3001"), bearer(a.AccessToken)...), "free", nil)
	// Sandbox data never grants Production access, even with colliding transaction IDs.
	mustExec(t, e.d.Pool, `INSERT INTO apple_pro_purchases(original_transaction_id,transaction_id,user_id,app_account_token,product_id,environment,purchased_at) VALUES('3001','3001',$1,$1,'app.veea.pro','Sandbox',clock_timestamp()-interval '1 hour')`, u.ID)
	wantPlan(t, e.myPlan(t, a.AccessToken), "free", nil)
	svc := purchases.New(e.d.Pool, f, "Sandbox", nil)
	if svc.CheckEnvironment(context.Background()) == nil {
		t.Fatal("mismatched database environment accepted")
	}
	f.proof.Environment = "Sandbox"
	f.proof.RevokedAt = nil
	wantProblem(t, e.post(t, applePurchasePath, purchaseBody("3001"), bearer(a.AccessToken)...), 400, "purchase_invalid")
}
func TestPurchases_ExportPurgeAndNoAccountTransfer(t *testing.T) {
	e, f := billingEnv(t)
	u, a := e.staff(t, "user")
	f.proof = appleiap.Transaction{ProductID: "app.veea.pro", Environment: "Production", AccountToken: u.ID, PurchasedAt: time.Now().Add(-time.Hour)}
	for i := 0; i < 8; i++ {
		f.proof.ID = fmt.Sprintf("400%d", i)
		f.proof.OriginalID = f.proof.ID
		f.proof.PurchasedAt = f.proof.PurchasedAt.Add(time.Second)
		wantStatus(t, e.post(t, applePurchasePath, purchaseBody(f.proof.ID), bearer(a.AccessToken)...), 200)
	}
	if rowCount(t, e.d.Pool, `SELECT count(*) FROM apple_pro_purchases WHERE user_id=$1`, u.ID) != 5 {
		t.Fatal("retained proof bound failed")
	}
	p, r := e.rightsStart(t, "export", u.Email)
	wantStatus(t, r, 202)
	wantStatus(t, e.rightsComplete(t, p), 202)
	e.finishRightsJobs(t)
	doc := e.download(t, p)
	wantStatus(t, doc, 200)
	proofs, ok := doc.body["apple_purchases"].([]any)
	if !ok || len(proofs) != 5 {
		t.Fatalf("missing bounded export: %s", doc.raw)
	}
	for _, v := range proofs {
		row := v.(map[string]any)
		if len(row) != 4 || row["product_id"] != "app.veea.pro" {
			t.Fatalf("wrong export fields: %v", row)
		}
	}
	// RESTRICT refuses an accidental erase which omitted the purge step.
	if _, err := e.d.Pool.Exec(context.Background(), `DELETE FROM users WHERE id=$1`, u.ID); err == nil {
		t.Fatal("payment rows did not protect purge ordering")
	}
	deletion, r := e.rightsStart(t, "delete", u.Email)
	wantStatus(t, r, 202)
	wantStatus(t, e.rightsComplete(t, deletion), 202)
	e.finishRightsJobs(t)
	if rowCount(t, e.d.Pool, `SELECT count(*) FROM apple_pro_purchases WHERE app_account_token=$1`, u.ID) != 0 {
		t.Fatal("payment ownership survived requested deletion")
	}
	_, next := e.staff(t, "user")
	wantProblem(t, e.post(t, applePurchasePath, purchaseBody(f.proof.ID), bearer(next.AccessToken)...), 409, "purchase_ownership_conflict")
}
func TestPurchases_DisabledInputAndSessionRevalidation(t *testing.T) {
	e := newSignupEnv(t, nil)
	_, a := e.staff(t, "user")
	wantProblem(t, e.post(t, applePurchasePath, purchaseBody("5001"), bearer(a.AccessToken)...), 503, "purchase_unavailable")
	wantProblem(t, e.post(t, applePurchasePath, purchaseBody("vat_invalid"), bearer(a.AccessToken)...), 400, "invalid_request")
	wantProblem(t, e.post(t, applePurchasePath, map[string]any{"transaction_id": "5001", "user_id": "not trusted"}, bearer(a.AccessToken)...), 400, "invalid_request")
	e2, f := billingEnv(t)
	u, b := e2.staff(t, "user")
	f.proof = appleiap.Transaction{ID: "5001", OriginalID: "5001", ProductID: "app.veea.pro", Environment: "Production", AccountToken: u.ID, PurchasedAt: time.Now().Add(-time.Hour)}
	f.before = func() {
		mustExec(t, e2.d.Pool, `UPDATE sessions SET revoked_at=clock_timestamp(),revoked_reason='logout' WHERE id=$1`, b.SessionID)
	}
	// Revocation during external Apple I/O must be rechecked inside the write transaction.
	r := e2.post(t, applePurchasePath, purchaseBody("5001"), bearer(b.AccessToken)...)
	if r.status != http.StatusUnauthorized {
		t.Fatalf("late revoked session wrote payment: %d %s", r.status, r.raw)
	}
	if rowCount(t, e2.d.Pool, `SELECT count(*) FROM apple_pro_purchases`) != 0 {
		t.Fatal("revoked session created entitlement")
	}
}

func TestPurchases_DisablingVerificationPreservesProofAndManualGrant(t *testing.T) {
	e := newSignupEnv(t, nil)
	u, a := e.staff(t, "user")
	mustExec(t, e.d.Pool, `INSERT INTO apple_pro_purchases(original_transaction_id,transaction_id,user_id,app_account_token,product_id,environment,purchased_at) VALUES('5101','5101',$1,$1,'app.veea.pro','Production',clock_timestamp()-interval '1 hour')`, u.ID)
	wantProblem(t, e.myPlan(t, a.AccessToken), 503, "purchase_unavailable")
	wantProblem(t, e.post(t, applePurchasePath, purchaseBody("5101"), bearer(a.AccessToken)...), 503, "purchase_unavailable")
	plan, err := entitlements.Effective(context.Background(), e.q, u.ID)
	if err != nil || plan.Name != "premium" || plan.ExpiresAt != nil {
		t.Fatalf("fresh persisted proof changed: %+v %v", plan, err)
	}
	_, admin := e.staff(t, "admin")
	end := e.dbNow(t).Add(time.Hour)
	wantStatus(t, e.grantPremium(t, admin.AccessToken, u.ID, end, 0), 200)
	r := e.myPlan(t, a.AccessToken)
	wantPlan(t, r, "premium", &end)
	if r.body["purchase_verification_pending"] != true || r.body["apple_purchase_available"] != nil {
		t.Fatal("disabled owner read did not indicate pending verification and unavailable claims", r.raw)
	}
	if rowCount(t, e.d.Pool, `SELECT count(*) FROM apple_pro_purchases WHERE user_id=$1`, u.ID) != 1 {
		t.Fatal("disabling verification changed purchase ownership records")
	}
}

func TestPurchases_ManualGrantSurvivesAppleOutage(t *testing.T) {
	e, f := billingEnv(t)
	u, a := e.staff(t, "user")
	_, admin := e.staff(t, "admin")
	f.proof = appleiap.Transaction{ID: "6001", OriginalID: "6001", ProductID: "app.veea.pro", Environment: "Production", AccountToken: u.ID, PurchasedAt: time.Now().Add(-time.Hour)}
	wantPlan(t, e.post(t, applePurchasePath, purchaseBody("6001"), bearer(a.AccessToken)...), "premium", nil)
	end := e.dbNow(t).Add(time.Hour)
	wantStatus(t, e.grantPremium(t, admin.AccessToken, u.ID, end, 0), 200)
	mustExec(t, e.d.Pool, `UPDATE apple_pro_purchases SET verified_at=clock_timestamp()-interval '6 minutes' WHERE user_id=$1`, u.ID)
	f.err = appleiap.ErrUnavailable
	r := e.myPlan(t, a.AccessToken)
	wantPlan(t, r, "premium", &end)
	if r.body["purchase_verification_pending"] != true {
		t.Fatal("checkout uncertainty not reported")
	}
}

func TestPurchases_ManualFallbackRevalidatesSessionAndClassifiesFailures(t *testing.T) {
	for _, tc := range []struct {
		name    string
		prepare func(*testing.T, *signupEnv, *purchaseVerifier, string)
		status  int
		code    string
	}{
		{"session revoked after valid proof", func(t *testing.T, e *signupEnv, f *purchaseVerifier, sessionID string) {
			f.before = func() {
				mustExec(t, e.d.Pool, `UPDATE sessions SET revoked_at=clock_timestamp(),revoked_reason='logout' WHERE id=$1`, sessionID)
			}
		}, 401, "unauthorized"},
		{"session revoked during Apple outage", func(t *testing.T, e *signupEnv, f *purchaseVerifier, sessionID string) {
			f.err = appleiap.ErrUnavailable
			f.before = func() {
				mustExec(t, e.d.Pool, `UPDATE sessions SET revoked_at=clock_timestamp(),revoked_reason='logout' WHERE id=$1`, sessionID)
			}
		}, 401, "unauthorized"},
		{"reconciliation database failure", func(t *testing.T, e *signupEnv, f *purchaseVerifier, _ string) {
			f.before = func() { mustExec(t, e.d.Pool, `ALTER TABLE apple_pro_purchases RENAME TO unavailable_purchases`) }
		}, 500, "internal_error"},
		{"manual fallback database failure", func(t *testing.T, e *signupEnv, f *purchaseVerifier, _ string) {
			f.err = appleiap.ErrUnavailable
			f.before = func() { mustExec(t, e.d.Pool, `ALTER TABLE entitlement_grants RENAME TO unavailable_grants`) }
		}, 500, "internal_error"},
		{"invalid proof", func(_ *testing.T, _ *signupEnv, f *purchaseVerifier, _ string) {
			f.err = appleiap.ErrInvalid
		}, 200, ""},
		{"ownership conflict", func(t *testing.T, e *signupEnv, f *purchaseVerifier, _ string) {
			other, _ := e.staff(t, "user")
			f.proof.AccountToken = other.ID
		}, 200, ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			e, f := billingEnv(t)
			u, owner := e.staff(t, "user")
			_, admin := e.staff(t, "admin")
			const id = "6101"
			f.proof = appleiap.Transaction{ID: id, OriginalID: id, ProductID: "app.veea.pro",
				Environment: "Production", AccountToken: u.ID, PurchasedAt: time.Now().Add(-time.Hour)}
			wantPlan(t, e.post(t, applePurchasePath, purchaseBody(id), bearer(owner.AccessToken)...), "premium", nil)
			end := e.dbNow(t).Add(time.Hour)
			wantStatus(t, e.grantPremium(t, admin.AccessToken, u.ID, end, 0), 200)
			mustExec(t, e.d.Pool, `UPDATE apple_pro_purchases SET verified_at=clock_timestamp()-interval '6 minutes' WHERE user_id=$1`, u.ID)
			tc.prepare(t, e, f, owner.SessionID.String())
			result := e.myPlan(t, owner.AccessToken)
			if tc.status != http.StatusOK {
				wantProblem(t, result, tc.status, tc.code)
				return
			}
			wantPlan(t, result, "premium", &end)
			if result.body["purchase_verification_pending"] != true {
				t.Fatal("manual fallback did not report pending verification")
			}
		})
	}
}

func TestPurchases_ObsoleteProofCannotBlockAnotherValidPurchase(t *testing.T) {
	e, f := billingEnv(t)
	u, a := e.staff(t, "user")
	f.proof = appleiap.Transaction{ID: "7001", OriginalID: "7001", ProductID: "app.veea.pro", Environment: "Production", AccountToken: u.ID, PurchasedAt: time.Now().Add(-time.Hour)}
	wantPlan(t, e.post(t, applePurchasePath, purchaseBody("7001"), bearer(a.AccessToken)...), "premium", nil)
	mustExec(t, e.d.Pool, `INSERT INTO apple_pro_purchases(original_transaction_id,transaction_id,user_id,app_account_token,product_id,environment,purchased_at) VALUES('1000','1000',$1,$1,'app.veea.pro','Production',clock_timestamp()-interval '1 hour')`, u.ID)
	mustExec(t, e.d.Pool, `UPDATE apple_pro_purchases SET verified_at=clock_timestamp()-interval '6 minutes' WHERE user_id=$1`, u.ID)
	wantPlan(t, e.myPlan(t, a.AccessToken), "premium", nil)
}

func TestPurchases_ContractErrorsAndVerificationRateLimit(t *testing.T) {
	e, f := billingEnv(t)
	u, a := e.staff(t, "user")
	f.proof = appleiap.Transaction{ID: "8001", OriginalID: "8001", ProductID: "app.veea.pro", Environment: "Production", AccountToken: u.ID, PurchasedAt: time.Now().Add(-time.Hour)}
	req := httptest.NewRequest(http.MethodPost, applePurchasePath, strings.NewReader(`{"transaction_id":"8001"}`))
	req.Header.Set("Content-Type", "text/plain")
	req.Header.Set("Authorization", "Bearer "+a.AccessToken)
	rec := httptest.NewRecorder()
	e.contract.wrap(e.handler).ServeHTTP(rec, req)
	var problem map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &problem); err != nil {
		t.Fatal(err)
	}
	if rec.Code != 415 || problem["code"] != "unsupported_media_type" {
		t.Fatalf("invalid media accepted: %d %s", rec.Code, rec.Body.String())
	}
	for i := 0; i < 20; i++ {
		wantStatus(t, e.post(t, applePurchasePath, purchaseBody("8001"), bearer(a.AccessToken)...), 200)
	}
	r := e.post(t, applePurchasePath, purchaseBody("8001"), bearer(a.AccessToken)...)
	wantProblem(t, r, 429, "rate_limited")
	if r.header.Get("Retry-After") == "" {
		t.Fatal("missing retry guidance")
	}
	metricsResponse := httptest.NewRecorder()
	e.metrics.Handler().ServeHTTP(metricsResponse, httptest.NewRequest(http.MethodGet, "/metrics", nil))
	if !strings.Contains(metricsResponse.Body.String(), `apple_purchase_verification_total{operation="claim",result="rate_limited"} 1`+"\n") {
		t.Fatal("missing purchase rate limit metric")
	}
	mustExec(t, e.d.Pool, `UPDATE apple_pro_purchases SET verified_at=clock_timestamp()-interval '6 minutes' WHERE user_id=$1`, u.ID)
	f.err = appleiap.ErrInvalid
	wantProblem(t, e.myPlan(t, a.AccessToken), 400, "purchase_invalid")
	f.err = nil
	f.proof.AccountToken = e.withRole(t, "user").ID
	wantProblem(t, e.myPlan(t, a.AccessToken), 409, "purchase_ownership_conflict")
}

func TestPurchases_ConcurrentClaimsConverge(t *testing.T) {
	e, f := billingEnv(t)
	u, a := e.staff(t, "user")
	f.proof = appleiap.Transaction{ID: "8101", OriginalID: "8101", ProductID: "app.veea.pro", Environment: "Production", AccountToken: u.ID, PurchasedAt: time.Now().Add(-time.Hour)}
	const callers = 6
	arrived := make(chan struct{}, callers)
	release := make(chan struct{})
	f.before = func() {
		arrived <- struct{}{}
		<-release
	}
	var requests sync.WaitGroup
	for range callers {
		requests.Go(func() {
			wantPlan(t, e.post(t, applePurchasePath, purchaseBody("8101"), bearer(a.AccessToken)...), "premium", nil)
		})
	}
	timeout := time.NewTimer(10 * time.Second)
	defer timeout.Stop()
	for range callers {
		select {
		case <-arrived:
		case <-timeout.C:
			close(release)
			requests.Wait()
			t.Fatal("claims did not overlap at verification")
		}
	}
	close(release)
	requests.Wait()
	if n := rowCount(t, e.d.Pool, `SELECT count(*) FROM apple_pro_purchases WHERE user_id=$1`, u.ID); n != 1 {
		t.Fatalf("concurrent claims wrote %d purchase rows", n)
	}
}

func TestPurchases_ReconciliationBackoffAndMetrics(t *testing.T) {
	e, f := billingEnv(t)
	u, a := e.staff(t, "user")
	f.proof = appleiap.Transaction{ID: "8201", OriginalID: "8201", ProductID: "app.veea.pro", Environment: "Production", AccountToken: u.ID, PurchasedAt: time.Now().Add(-time.Hour)}
	wantProblem(t, e.post(t, applePurchasePath, purchaseBody("8201")), 401, "unauthorized")
	wantProblem(t, e.post(t, applePurchasePath, purchaseBody("8202"), bearer(a.AccessToken)...), 400, "purchase_invalid")
	wantPlan(t, e.post(t, applePurchasePath, purchaseBody("8201"), bearer(a.AccessToken)...), "premium", nil)
	mustExec(t, e.d.Pool, `UPDATE apple_pro_purchases SET verified_at=clock_timestamp()-interval '6 minutes' WHERE user_id=$1`, u.ID)
	f.err = appleiap.ErrUnavailable
	wantProblem(t, e.myPlan(t, a.AccessToken), 503, "purchase_unavailable")
	var requests sync.WaitGroup
	for range 6 {
		requests.Go(func() {
			wantProblem(t, e.myPlan(t, a.AccessToken), 503, "purchase_unavailable")
		})
	}
	requests.Wait()
	if f.calls != 3 {
		t.Fatalf("cooldown admitted unexpected Apple calls: %d", f.calls)
	}
	f.err = nil
	refundedAt := time.Now()
	f.proof.RevokedAt = &refundedAt
	wantPlan(t, e.post(t, applePurchasePath, purchaseBody("8201"), bearer(a.AccessToken)...), "free", nil)
	rec := httptest.NewRecorder()
	e.metrics.Handler().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/metrics", nil))
	for _, series := range []string{
		`{operation="claim",result="authentication_failed"} 1`,
		`{operation="claim",result="invalid_proof"} 1`,
		`{operation="claim",result="production_recorded"} 2`,
		`{operation="reconcile",result="upstream_failed"} 1`,
		`{operation="reconcile",result="reconcile_backoff"} 6`,
	} {
		if !strings.Contains(rec.Body.String(), "apple_purchase_verification_total"+series+"\n") {
			t.Errorf("missing purchase metric %s", series)
		}
	}
}

func TestPurchases_OwnerGetPersistsRefundAfterReconciliationCooldown(t *testing.T) {
	e, f := billingEnv(t)
	u, a := e.staff(t, "user")
	ctx := context.Background()
	now := e.dbNow(t).Truncate(time.Microsecond)
	active := appleiap.Transaction{
		ID: "8251", OriginalID: "8251", ProductID: "app.veea.pro", Environment: appleiap.EnvProduction,
		AccountToken: u.ID, PurchasedAt: now.Add(-time.Hour), SignedAt: now.Add(-30 * time.Minute),
	}
	f.proof = active
	wantPlan(t, e.post(t, applePurchasePath, purchaseBody(active.ID), bearer(a.AccessToken)...), "premium", nil)
	wantPlan(t, e.myPlan(t, a.AccessToken), "premium", nil)
	if f.calls != 1 {
		t.Fatal("a fresh proof should serve the owner GET without an Apple lookup")
	}
	const ageProof = `UPDATE apple_pro_purchases SET verified_at=$2 WHERE user_id=$1`
	const readProof = `SELECT verified_at, revoked_at, revocation_reason FROM apple_pro_purchases WHERE user_id=$1`
	checkProof := func(expectedVerification time.Time, expectedRefund *time.Time) time.Time {
		t.Helper()
		var verifiedAt time.Time
		var revokedAt *time.Time
		var reason *int32
		if err := e.d.Pool.QueryRow(ctx, readProof, u.ID).Scan(&verifiedAt, &revokedAt, &reason); err != nil {
			t.Fatal(err)
		}
		if !expectedVerification.IsZero() && !verifiedAt.Equal(expectedVerification) {
			t.Fatalf("verification time changed: got %s, want %s", verifiedAt, expectedVerification)
		}
		if expectedRefund == nil {
			if revokedAt != nil || reason != nil {
				t.Fatal("refund recorded before a verified Apple response")
			}
		} else if revokedAt == nil || !revokedAt.Equal(*expectedRefund) || reason == nil || *reason != 1 {
			t.Fatal("owner GET did not preserve the verified refund")
		}
		return verifiedAt
	}
	stale := now.Add(-6 * time.Minute)
	mustExec(t, e.d.Pool, ageProof, u.ID, stale)
	f.err = appleiap.ErrUnavailable
	wantProblem(t, e.myPlan(t, a.AccessToken), 503, "purchase_unavailable")
	checkProof(stale, nil)

	expired := now.Add(-25 * time.Hour)
	mustExec(t, e.d.Pool, ageProof, u.ID, expired)
	refundAt, reason := now.Add(-time.Minute), int32(1)
	f.err = nil
	f.proof.SignedAt, f.proof.RevokedAt, f.proof.RevocationReason = refundAt, &refundAt, &reason
	wantProblem(t, e.myPlan(t, a.AccessToken), 503, "purchase_unavailable")
	if f.calls != 2 {
		t.Fatalf("owner GET reached Apple during cooldown: %d total calls", f.calls)
	}
	checkProof(expired, nil)
	plan, err := entitlements.Effective(ctx, e.q, u.ID)
	if err != nil || plan.Name != entitlements.Free {
		t.Fatalf("expired proof still granted access: %+v %v", plan, err)
	}

	// Database times are explicit. Only opening the in-process cooldown uses real time.
	deadline := time.Now().Add(10 * time.Second)
	for {
		r := e.myPlan(t, a.AccessToken)
		if r.status == http.StatusOK {
			wantPlan(t, r, "free", nil)
			break
		}
		wantProblem(t, r, 503, "purchase_unavailable")
		if time.Now().After(deadline) {
			t.Fatal("owner GET never admitted the recovery probe")
		}
		time.Sleep(100 * time.Millisecond)
	}
	if f.calls != 3 || !checkProof(time.Time{}, &refundAt).After(now) {
		t.Fatal("expected exactly one recovery lookup and a fresh persisted refund")
	}
	wantPlan(t, e.myPlan(t, a.AccessToken), "free", nil)
	if f.calls != 3 {
		t.Fatal("fresh revoked proof was rechecked immediately")
	}
	// An older active proof received on a later owner GET cannot undo the refund.
	mustExec(t, e.d.Pool, ageProof, u.ID, stale)
	f.proof = active
	wantPlan(t, e.myPlan(t, a.AccessToken), "free", nil)
	checkProof(time.Time{}, &refundAt)
	if f.calls != 4 {
		t.Fatal("expected a lookup of the stale revoked proof")
	}
}

func TestPurchases_DatabaseFailureDoesNotClaimSuccess(t *testing.T) {
	e, f := billingEnv(t)
	u, a := e.staff(t, "user")
	f.proof = appleiap.Transaction{ID: "9001", OriginalID: "9001", ProductID: "app.veea.pro", Environment: "Production", AccountToken: u.ID, PurchasedAt: time.Now().Add(-time.Hour)}
	mustExec(t, e.d.Pool, `DROP TABLE apple_pro_purchases`)
	wantProblem(t, e.post(t, applePurchasePath, purchaseBody("9001"), bearer(a.AccessToken)...), 500, "internal_error")
}

func TestPurchases_NewerAppleProofRestoresRefundReversalButOldProofDoesNot(t *testing.T) {
	e, f := billingEnv(t)
	u, a := e.staff(t, "user")
	purchased := time.Now().Add(-time.Hour)
	f.proof = appleiap.Transaction{ID: "9501", OriginalID: "9501", ProductID: "app.veea.pro", Environment: "Production", AccountToken: u.ID, PurchasedAt: purchased, SignedAt: purchased.Add(time.Minute)}
	wantPlan(t, e.post(t, applePurchasePath, purchaseBody("9501"), bearer(a.AccessToken)...), "premium", nil)
	revoked := time.Now().Add(-time.Minute)
	f.proof.RevokedAt = &revoked
	f.proof.SignedAt = revoked
	wantPlan(t, e.post(t, applePurchasePath, purchaseBody("9501"), bearer(a.AccessToken)...), "free", nil)
	f.proof.RevokedAt = nil
	f.proof.SignedAt = purchased.Add(time.Minute)
	wantPlan(t, e.post(t, applePurchasePath, purchaseBody("9501"), bearer(a.AccessToken)...), "free", nil)
	// Apple REFUND_REVERSED requires reinstatement. A newer signed active proof
	// from the authenticated Apple API can undo the refund; an older proof cannot.
	f.proof.SignedAt = time.Now().UTC().Truncate(time.Millisecond)
	r := e.post(t, applePurchasePath, purchaseBody("9501"), bearer(a.AccessToken)...)
	wantPlan(t, r, "premium", nil)
	if r.body["purchase_revoked"] != false {
		t.Fatal("refund reversal did not restore paid access")
	}
	// A delayed refunded proof cannot override the later reinstatement either.
	f.proof.RevokedAt = &revoked
	f.proof.SignedAt = revoked
	wantPlan(t, e.post(t, applePurchasePath, purchaseBody("9501"), bearer(a.AccessToken)...), "premium", nil)
}
