package appleiap

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
)

func TestProductionSandboxRoutingOnlyAfterAppleTransactionNotFound(t *testing.T) {
	now := time.Date(2026, 11, 26, 10, 0, 0, 0, time.UTC)
	_, key := generateTestPrivateKeyPEM(t)
	pki := newTestPKI(t, now, true, true)
	claims := func(env string) map[string]any {
		return map[string]any{
			"transactionId": "12345", "originalTransactionId": "12345", "bundleId": "app.veea.english",
			"productId": "app.veea.pro", "environment": env, "type": "Non-Consumable", "inAppOwnershipType": "PURCHASED",
			"appAccountToken": uuid.NewString(), "purchaseDate": now.Add(-time.Hour).UnixMilli(), "signedDate": now.UnixMilli(),
		}
	}
	envelope := func(c map[string]any) string {
		b, _ := json.Marshal(map[string]string{"signedTransactionInfo": pki.signJWS(t, "ES256", pki.x5c, c, pki.leafKey)})
		return string(b)
	}
	prod, sandbox := envelope(claims(EnvProduction)), envelope(claims(EnvSandbox))
	wrongBundle := claims(EnvProduction)
	wrongBundle["bundleId"] = "other.app"
	wrongProduct := claims(EnvProduction)
	wrongProduct["productId"] = "other.product"
	for _, tc := range []struct {
		name        string
		status      int
		body        string
		sandboxBody string
		calls       int
		env         string
		wantErr     error
	}{
		{"production wins", 200, prod, sandbox, 1, EnvProduction, nil},
		{"review sandbox", 404, `{"errorCode":4040010}`, sandbox, 2, EnvSandbox, nil},
		{"bare 404", 404, `{}`, sandbox, 1, "", ErrInvalid},
		{"other 404", 404, `{"errorCode":4040005}`, sandbox, 1, "", ErrInvalid},
		{"malformed 404", 404, `invalid`, sandbox, 1, "", ErrInvalid},
		{"invalid id", 400, `{"errorCode":4000006}`, sandbox, 1, "", ErrInvalid},
		{"wrong status for notfound", 400, `{"errorCode":4040010}`, sandbox, 1, "", ErrInvalid},
		{"auth", 401, `{}`, sandbox, 1, "", ErrUnavailable},
		{"forbidden", 403, `{}`, sandbox, 1, "", ErrUnavailable},
		{"rate limited", 429, `{}`, sandbox, 1, "", ErrUnavailable},
		{"outage", 503, `{}`, sandbox, 1, "", ErrUnavailable},
		{"wrong environment", 200, sandbox, sandbox, 1, "", ErrInvalid},
		{"wrong bundle", 200, envelope(wrongBundle), sandbox, 1, "", ErrInvalid},
		{"wrong product", 200, envelope(wrongProduct), sandbox, 1, "", ErrInvalid},
		{"bad signature", 200, `{"signedTransactionInfo":"invalid"}`, sandbox, 1, "", ErrInvalid},
		{"bad sandbox signature", 404, `{"errorCode":4040010}`, `{"signedTransactionInfo":"invalid"}`, 2, "", ErrInvalid},
		{"sandbox cannot return production", 404, `{"errorCode":4040010}`, prod, 2, "", ErrInvalid},
	} {
		t.Run(tc.name, func(t *testing.T) {
			v, err := New(Config{IssuerID: uuid.NewString(), KeyID: "KEY1234567", PrivateKey: key, BundleID: "app.veea.english", Environment: EnvProduction, ProductIDs: []string{"app.veea.pro"}, AllowSandbox: true})
			if err != nil {
				t.Fatal(err)
			}
			for _, verifier := range []*Verifier{v, v.sandbox} {
				verifier.now = func() time.Time { return now }
				injectTestRoot(verifier, pki.rootCert)
			}
			calls := 0
			transport := roundTripFunc(func(r *http.Request) (*http.Response, error) {
				calls++
				status, body := tc.status, tc.body
				if calls == 1 && r.URL.Host != "api.storekit.apple.com" {
					t.Fatal("did not try production first")
				}
				if calls == 2 {
					if r.URL.Host != "api.storekit-sandbox.apple.com" {
						t.Fatal("wrong fallback host")
					}
					status, body = 200, tc.sandboxBody
				}
				return &http.Response{StatusCode: status, Body: io.NopCloser(strings.NewReader(body))}, nil
			})
			v.client.Transport = transport
			v.sandbox.client.Transport = transport
			proof, err := v.Verify(context.Background(), "12345")
			if calls != tc.calls || (tc.wantErr == nil && err != nil) || (tc.wantErr != nil && !errors.Is(err, tc.wantErr)) || proof.Environment != tc.env {
				t.Fatalf("calls=%d proof=%+v err=%v", calls, proof, err)
			}
		})
	}
}

func TestSandboxFallbackIsExplicitAndProductionOnly(t *testing.T) {
	_, key := generateTestPrivateKeyPEM(t)
	cfg := Config{IssuerID: uuid.NewString(), KeyID: "KEY1234567", PrivateKey: key, BundleID: "app.veea.english", Environment: EnvProduction, ProductIDs: []string{"app.veea.pro"}}
	v, err := New(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if v.sandbox != nil {
		t.Fatal("fallback enabled by default")
	}
	cfg.AllowSandbox = true
	cfg.Environment = EnvSandbox
	if _, err = New(cfg); err == nil {
		t.Fatal("fallback allowed on Sandbox verifier")
	}
	cfg.Environment = EnvProduction
	v, err = New(cfg)
	if err != nil {
		t.Fatal(err)
	}
	calls := 0
	transport := roundTripFunc(func(r *http.Request) (*http.Response, error) { calls++; return nil, context.Canceled })
	v.client.Transport = transport
	v.sandbox.client.Transport = transport
	if _, err = v.Verify(context.Background(), "12345"); !errors.Is(err, ErrUnavailable) || calls != 1 {
		t.Fatal("network failure retried Sandbox", err, calls)
	}
}
