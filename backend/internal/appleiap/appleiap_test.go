package appleiap

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"io"
	"math/big"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
)

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

type testPKI struct {
	rootCert         *x509.Certificate
	rootKey          *ecdsa.PrivateKey
	intermediateCert *x509.Certificate
	intermediateKey  *ecdsa.PrivateKey
	leafCert         *x509.Certificate
	leafKey          *ecdsa.PrivateKey
	x5c              []string
}

func newTestPKI(t *testing.T, now time.Time, includeLeafOID, includeInterOID bool) *testPKI {
	t.Helper()
	rootKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	rootTmpl := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: "Synthetic Apple Root CA - G3", Organization: []string{"Apple Inc."}},
		NotBefore:             now.Add(-24 * time.Hour),
		NotAfter:              now.Add(24 * time.Hour),
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageCRLSign,
		BasicConstraintsValid: true,
		IsCA:                  true,
		MaxPathLen:            2,
	}
	rootDER, err := x509.CreateCertificate(rand.Reader, rootTmpl, rootTmpl, &rootKey.PublicKey, rootKey)
	if err != nil {
		t.Fatal(err)
	}
	rootCert, err := x509.ParseCertificate(rootDER)
	if err != nil {
		t.Fatal(err)
	}

	interKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	interTmpl := &x509.Certificate{
		SerialNumber:          big.NewInt(2),
		Subject:               pkix.Name{CommonName: "Synthetic Apple WWDR Intermediate"},
		NotBefore:             now.Add(-12 * time.Hour),
		NotAfter:              now.Add(12 * time.Hour),
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageDigitalSignature,
		BasicConstraintsValid: true,
		IsCA:                  true,
		MaxPathLen:            0,
		MaxPathLenZero:        true,
	}
	if includeInterOID {
		interTmpl.ExtraExtensions = []pkix.Extension{{Id: oidAppleWWDRIntermediate, Value: []byte{0x05, 0x00}}}
	}
	interDER, err := x509.CreateCertificate(rand.Reader, interTmpl, rootCert, &interKey.PublicKey, rootKey)
	if err != nil {
		t.Fatal(err)
	}
	interCert, err := x509.ParseCertificate(interDER)
	if err != nil {
		t.Fatal(err)
	}

	leafKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	leafTmpl := &x509.Certificate{
		SerialNumber:          big.NewInt(3),
		Subject:               pkix.Name{CommonName: "Synthetic App Store Receipt Signing"},
		NotBefore:             now.Add(-time.Hour),
		NotAfter:              now.Add(time.Hour),
		KeyUsage:              x509.KeyUsageDigitalSignature,
		BasicConstraintsValid: true,
	}
	if includeLeafOID {
		leafTmpl.ExtraExtensions = []pkix.Extension{{Id: oidAppleLeafReceiptSigning, Value: []byte{0x05, 0x00}}}
	}
	leafDER, err := x509.CreateCertificate(rand.Reader, leafTmpl, interCert, &leafKey.PublicKey, interKey)
	if err != nil {
		t.Fatal(err)
	}
	leafCert, err := x509.ParseCertificate(leafDER)
	if err != nil {
		t.Fatal(err)
	}

	return &testPKI{
		rootCert:         rootCert,
		rootKey:          rootKey,
		intermediateCert: interCert,
		intermediateKey:  interKey,
		leafCert:         leafCert,
		leafKey:          leafKey,
		x5c: []string{
			base64.StdEncoding.EncodeToString(leafDER),
			base64.StdEncoding.EncodeToString(interDER),
			base64.StdEncoding.EncodeToString(rootDER),
		},
	}
}

func (p *testPKI) signJWS(t *testing.T, alg string, x5c []string, claims map[string]any, signer *ecdsa.PrivateKey) string {
	t.Helper()
	hdrBytes, err := json.Marshal(map[string]any{"alg": alg, "x5c": x5c})
	if err != nil {
		t.Fatal(err)
	}
	payloadBytes, err := json.Marshal(claims)
	if err != nil {
		t.Fatal(err)
	}
	input := base64.RawURLEncoding.EncodeToString(hdrBytes) + "." + base64.RawURLEncoding.EncodeToString(payloadBytes)
	sig, err := signES256(signer, []byte(input))
	if err != nil {
		t.Fatal(err)
	}
	return input + "." + base64.RawURLEncoding.EncodeToString(sig)
}

func generateTestPrivateKeyPEM(t *testing.T) (*ecdsa.PrivateKey, string) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	der, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	block := pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})
	return key, string(block)
}

func injectTestRoot(v *Verifier, root *x509.Certificate) {
	pool := x509.NewCertPool()
	pool.AddCert(root)
	v.roots = pool
	v.rootDERs = map[string]struct{}{string(root.Raw): {}}
}

func TestPinnedAppleRootCAG3IsEmbeddedAndValid(t *testing.T) {
	cert, err := parsePinnedAppleRoot()
	if err != nil {
		t.Fatalf("parsePinnedAppleRoot: %v", err)
	}
	if cert.Subject.CommonName != "Apple Root CA - G3" || !cert.IsCA {
		t.Fatalf("unexpected root certificate: %+v", cert.Subject)
	}
}

func TestConfigValidationAndRedaction(t *testing.T) {
	_, pkcs8PEM := generateTestPrivateKeyPEM(t)
	valid := Config{
		IssuerID:    uuid.NewString(),
		KeyID:       "ABC1234567",
		PrivateKey:  strings.ReplaceAll(pkcs8PEM, "\n", `\n`), // escaped newlines supported
		BundleID:    "com.veea.english",
		Environment: EnvSandbox,
		ProductIDs:  []string{"com.veea.pro.lifetime", "com.veea.pro.lifetime.early"},
	}
	v, err := New(valid)
	if err != nil {
		t.Fatalf("expected valid config to succeed, got: %v", err)
	}
	if v.baseURL != sandboxBaseURL {
		t.Fatalf("sandbox baseURL = %q, want %q", v.baseURL, sandboxBaseURL)
	}

	prod := valid
	prod.Environment = EnvProduction
	vp, err := New(prod)
	if err != nil || vp.baseURL != productionBaseURL {
		t.Fatalf("production verifier: %v %v", vp, err)
	}

	// Also accept SEC1 EC PRIVATE KEY PEM.
	ecKey, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	sec1DER, _ := x509.MarshalECPrivateKey(ecKey)
	sec1Cfg := valid
	sec1Cfg.PrivateKey = string(pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: sec1DER}))
	if _, err := New(sec1Cfg); err != nil {
		t.Fatalf("SEC1 EC PRIVATE KEY should succeed: %v", err)
	}

	// Reject P-384 and RSA keys without leaking key material.
	p384Key, _ := ecdsa.GenerateKey(elliptic.P384(), rand.Reader)
	p384DER, _ := x509.MarshalPKCS8PrivateKey(p384Key)
	p384PEM := string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: p384DER}))

	rsaKey, _ := rsa.GenerateKey(rand.Reader, 2048)
	rsaDER, _ := x509.MarshalPKCS8PrivateKey(rsaKey)
	rsaPEM := string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: rsaDER}))

	cases := map[string]Config{
		"bad issuer":        {IssuerID: "not-a-uuid", KeyID: valid.KeyID, PrivateKey: pkcs8PEM, BundleID: valid.BundleID, Environment: EnvSandbox, ProductIDs: valid.ProductIDs},
		"nil issuer":        {IssuerID: uuid.Nil.String(), KeyID: valid.KeyID, PrivateKey: pkcs8PEM, BundleID: valid.BundleID, Environment: EnvSandbox, ProductIDs: valid.ProductIDs},
		"bad key id":        {IssuerID: valid.IssuerID, KeyID: "SHORT", PrivateKey: pkcs8PEM, BundleID: valid.BundleID, Environment: EnvSandbox, ProductIDs: valid.ProductIDs},
		"empty private key": {IssuerID: valid.IssuerID, KeyID: valid.KeyID, PrivateKey: "", BundleID: valid.BundleID, Environment: EnvSandbox, ProductIDs: valid.ProductIDs},
		"bad pem":           {IssuerID: valid.IssuerID, KeyID: valid.KeyID, PrivateKey: "SECRET_KEY_MATERIAL_NOT_PEM", BundleID: valid.BundleID, Environment: EnvSandbox, ProductIDs: valid.ProductIDs},
		"p384 key":          {IssuerID: valid.IssuerID, KeyID: valid.KeyID, PrivateKey: p384PEM, BundleID: valid.BundleID, Environment: EnvSandbox, ProductIDs: valid.ProductIDs},
		"rsa key":           {IssuerID: valid.IssuerID, KeyID: valid.KeyID, PrivateKey: rsaPEM, BundleID: valid.BundleID, Environment: EnvSandbox, ProductIDs: valid.ProductIDs},
		"bad bundle id":     {IssuerID: valid.IssuerID, KeyID: valid.KeyID, PrivateKey: pkcs8PEM, BundleID: "nodot", Environment: EnvSandbox, ProductIDs: valid.ProductIDs},
		"bad environment":   {IssuerID: valid.IssuerID, KeyID: valid.KeyID, PrivateKey: pkcs8PEM, BundleID: valid.BundleID, Environment: "Xcode", ProductIDs: valid.ProductIDs},
		"empty products":    {IssuerID: valid.IssuerID, KeyID: valid.KeyID, PrivateKey: pkcs8PEM, BundleID: valid.BundleID, Environment: EnvSandbox, ProductIDs: nil},
		"bad product id":    {IssuerID: valid.IssuerID, KeyID: valid.KeyID, PrivateKey: pkcs8PEM, BundleID: valid.BundleID, Environment: EnvSandbox, ProductIDs: []string{"bad product!"}},
	}
	for name, cfg := range cases {
		t.Run(name, func(t *testing.T) {
			_, err := New(cfg)
			if err == nil {
				t.Fatal("expected error")
			}
			if strings.Contains(err.Error(), "SECRET_KEY_MATERIAL") || strings.Contains(err.Error(), "BEGIN") {
				t.Fatalf("error leaked key material: %v", err)
			}
		})
	}
}

func TestVerifySuccessAndRevokedAndServerJWT(t *testing.T) {
	now := time.Date(2026, 11, 17, 15, 0, 0, 0, time.UTC)
	apiKey, apiPEM := generateTestPrivateKeyPEM(t)
	issuerID := uuid.NewString()
	accountToken := uuid.New()
	pki := newTestPKI(t, now, true, true)

	v, err := New(Config{
		IssuerID:    issuerID,
		KeyID:       "KEY1234567",
		PrivateKey:  apiPEM,
		BundleID:    "com.veea.english",
		Environment: EnvSandbox,
		ProductIDs:  []string{"com.veea.pro.lifetime.early", "com.veea.pro.lifetime"},
	})
	if err != nil {
		t.Fatal(err)
	}
	v.now = func() time.Time { return now }
	injectTestRoot(v, pki.rootCert)

	purchasedAt := now.Add(-10 * time.Minute)
	revokedAt := now.Add(-2 * time.Minute)
	var currentSignedJWS string

	v.client.Transport = roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if r.Method != http.MethodGet || r.URL.String() != "https://api.storekit-sandbox.apple.com/inApps/v1/transactions/2000000123456789" {
			t.Fatalf("unexpected request: %s %s", r.Method, r.URL.String())
		}
		auth := r.Header.Get("Authorization")
		tok, ok := strings.CutPrefix(auth, "Bearer ")
		if !ok {
			t.Fatalf("missing Bearer header: %q", auth)
		}
		// Verify the server-auth ES256 JWT generated by Verifier.
		parts := strings.Split(tok, ".")
		if len(parts) != 3 {
			t.Fatalf("jwt parts: %d", len(parts))
		}
		sig, err := base64.RawURLEncoding.DecodeString(parts[2])
		if err != nil || len(sig) != 64 {
			t.Fatalf("jwt sig: %v", err)
		}
		digest := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
		if !ecdsa.Verify(&apiKey.PublicKey, digest[:], new(big.Int).SetBytes(sig[:32]), new(big.Int).SetBytes(sig[32:])) {
			t.Fatal("server-auth JWT signature did not verify")
		}
		claimsRaw, _ := base64.RawURLEncoding.DecodeString(parts[1])
		var claims map[string]any
		_ = json.Unmarshal(claimsRaw, &claims)
		if claims["iss"] != issuerID || claims["aud"] != "appstoreconnect-v1" || claims["bid"] != "com.veea.english" {
			t.Fatalf("unexpected jwt claims: %v", claims)
		}

		body, _ := json.Marshal(map[string]any{
			"signedTransactionInfo": currentSignedJWS,
			"futureMetadata":        map[string]any{"schemaVersion": 2},
		})
		return &http.Response{
			StatusCode: http.StatusOK,
			Header:     http.Header{"Content-Type": []string{"application/json"}},
			Body:       io.NopCloser(bytes.NewReader(body)),
		}, nil
	})

	baseClaims := func() map[string]any {
		return map[string]any{
			"transactionId":         "2000000123456789",
			"originalTransactionId": "2000000123456700",
			"bundleId":              "com.veea.english",
			"productId":             "com.veea.pro.lifetime.early",
			"environment":           EnvSandbox,
			"type":                  "Non-Consumable",
			"inAppOwnershipType":    "PURCHASED",
			"appAccountToken":       accountToken.String(),
			"purchaseDate":          purchasedAt.UnixMilli(),
			"signedDate":            now.UnixMilli(),
		}
	}

	// 1. Active non-consumable purchase.
	currentSignedJWS = pki.signJWS(t, "ES256", pki.x5c, baseClaims(), pki.leafKey)
	tx, err := v.Verify(context.Background(), "2000000123456789")
	if err != nil {
		t.Fatalf("Verify active: %v", err)
	}
	if tx.ID != "2000000123456789" || tx.OriginalID != "2000000123456700" || tx.ProductID != "com.veea.pro.lifetime.early" ||
		tx.BundleID != "com.veea.english" || tx.Environment != EnvSandbox || tx.AccountToken != accountToken ||
		!tx.PurchasedAt.Equal(purchasedAt) || tx.RevokedAt != nil || tx.RevocationReason != nil {
		t.Fatalf("unexpected transaction: %+v", tx)
	}

	// 2. Revoked purchase returns Transaction with RevokedAt and RevocationReason populated.
	revokedClaims := baseClaims()
	revokedClaims["revocationDate"] = revokedAt.UnixMilli()
	revokedClaims["revocationReason"] = 1
	currentSignedJWS = pki.signJWS(t, "ES256", pki.x5c, revokedClaims, pki.leafKey)
	tx, err = v.Verify(context.Background(), "2000000123456789")
	if err != nil {
		t.Fatalf("Verify revoked: %v", err)
	}
	if tx.RevokedAt == nil || !tx.RevokedAt.Equal(revokedAt) || tx.RevocationReason == nil || *tx.RevocationReason != 1 {
		t.Fatalf("expected revoked fields on transaction, got: %+v", tx)
	}
}

func TestVerifyRejectsUntrustedRootAndInvalidSignaturesAndClaims(t *testing.T) {
	now := time.Date(2026, 11, 17, 15, 0, 0, 0, time.UTC)
	_, apiPEM := generateTestPrivateKeyPEM(t)
	accountToken := uuid.New()
	pki := newTestPKI(t, now, true, true)
	attackerPKI := newTestPKI(t, now, true, true)

	v, err := New(Config{
		IssuerID:    uuid.NewString(),
		KeyID:       "KEY1234567",
		PrivateKey:  apiPEM,
		BundleID:    "com.veea.english",
		Environment: EnvProduction,
		ProductIDs:  []string{"com.veea.pro.lifetime"},
	})
	if err != nil {
		t.Fatal(err)
	}
	v.now = func() time.Time { return now }

	// Note: before injecting test root, v is pinned to real Apple Root CA - G3, so synthetic pki must fail!
	var responseJWS string
	v.client.Transport = roundTripFunc(func(r *http.Request) (*http.Response, error) {
		body, _ := json.Marshal(map[string]string{"signedTransactionInfo": responseJWS})
		return &http.Response{
			StatusCode: http.StatusOK,
			Header:     http.Header{"Content-Type": []string{"application/json"}},
			Body:       io.NopCloser(bytes.NewReader(body)),
		}, nil
	})

	validClaims := func() map[string]any {
		return map[string]any{
			"transactionId":         "1000000999",
			"originalTransactionId": "1000000999",
			"bundleId":              "com.veea.english",
			"productId":             "com.veea.pro.lifetime",
			"environment":           EnvProduction,
			"type":                  "Non-Consumable",
			"inAppOwnershipType":    "PURCHASED",
			"appAccountToken":       accountToken.String(),
			"purchaseDate":          now.Add(-time.Minute).UnixMilli(),
			"signedDate":            now.UnixMilli(),
		}
	}

	responseJWS = pki.signJWS(t, "ES256", pki.x5c, validClaims(), pki.leafKey)
	if _, err := v.Verify(context.Background(), "1000000999"); !errors.Is(err, ErrInvalid) {
		t.Fatalf("synthetic chain against pinned Apple Root CA - G3 must fail with ErrInvalid, got: %v", err)
	}

	// Now inject pki.rootCert as the trusted root for synthetic claim and signature tests.
	injectTestRoot(v, pki.rootCert)

	// Attacker x5c chain signed by attacker's own root must be rejected even though x5c is self-consistent.
	responseJWS = attackerPKI.signJWS(t, "ES256", attackerPKI.x5c, validClaims(), attackerPKI.leafKey)
	if _, err := v.Verify(context.Background(), "1000000999"); !errors.Is(err, ErrInvalid) {
		t.Fatalf("attacker x5c root must be rejected with ErrInvalid, got: %v", err)
	}

	// Wrong signing key (signed by attacker leaf key but presenting valid x5c).
	responseJWS = pki.signJWS(t, "ES256", pki.x5c, validClaims(), attackerPKI.leafKey)
	if _, err := v.Verify(context.Background(), "1000000999"); !errors.Is(err, ErrInvalid) {
		t.Fatalf("forged signature must fail with ErrInvalid, got: %v", err)
	}

	// Missing leaf OID or intermediate OID.
	noLeafOID := newTestPKI(t, now, false, true)
	injectTestRoot(v, noLeafOID.rootCert)
	responseJWS = noLeafOID.signJWS(t, "ES256", noLeafOID.x5c, validClaims(), noLeafOID.leafKey)
	if _, err := v.Verify(context.Background(), "1000000999"); !errors.Is(err, ErrInvalid) {
		t.Fatalf("missing leaf OID must fail with ErrInvalid, got: %v", err)
	}

	noInterOID := newTestPKI(t, now, true, false)
	injectTestRoot(v, noInterOID.rootCert)
	responseJWS = noInterOID.signJWS(t, "ES256", noInterOID.x5c, validClaims(), noInterOID.leafKey)
	if _, err := v.Verify(context.Background(), "1000000999"); !errors.Is(err, ErrInvalid) {
		t.Fatalf("missing intermediate OID must fail with ErrInvalid, got: %v", err)
	}

	// Restore valid test PKI root.
	injectTestRoot(v, pki.rootCert)

	// Expired certificate chain.
	v.now = func() time.Time { return now.Add(48 * time.Hour) }
	expiredClaims := validClaims()
	expiredClaims["purchaseDate"] = now.Add(47 * time.Hour).UnixMilli()
	expiredClaims["signedDate"] = now.Add(48 * time.Hour).UnixMilli()
	responseJWS = pki.signJWS(t, "ES256", pki.x5c, expiredClaims, pki.leafKey)
	if _, err := v.Verify(context.Background(), "1000000999"); !errors.Is(err, ErrInvalid) {
		t.Fatalf("expired cert chain must fail with ErrInvalid, got: %v", err)
	}
	v.now = func() time.Time { return now }

	// Claim tampering and invalid claim cases.
	claimCases := map[string]func(map[string]any){
		"wrong transactionId":        func(c map[string]any) { c["transactionId"] = "9999999999" },
		"bad originalTransactionId":  func(c map[string]any) { c["originalTransactionId"] = "vat_secret" },
		"wrong bundleId":             func(c map[string]any) { c["bundleId"] = "com.other.app" },
		"unallowed productId":        func(c map[string]any) { c["productId"] = "com.veea.pro.subscription" },
		"wrong environment":          func(c map[string]any) { c["environment"] = EnvSandbox },
		"auto-renewable type":        func(c map[string]any) { c["type"] = "Auto-Renewable Subscription" },
		"consumable type":            func(c map[string]any) { c["type"] = "Consumable" },
		"family shared":              func(c map[string]any) { c["inAppOwnershipType"] = "FAMILY_SHARED" },
		"upgraded":                   func(c map[string]any) { c["isUpgraded"] = true },
		"missing appAccountToken":    func(c map[string]any) { delete(c, "appAccountToken") },
		"nil appAccountToken":        func(c map[string]any) { c["appAccountToken"] = uuid.Nil.String() },
		"malformed appAccountToken":  func(c map[string]any) { c["appAccountToken"] = "not-a-uuid" },
		"future purchaseDate":        func(c map[string]any) { c["purchaseDate"] = now.Add(10 * time.Minute).UnixMilli() },
		"ancient purchaseDate":       func(c map[string]any) { c["purchaseDate"] = time.Date(2015, 1, 1, 0, 0, 0, 0, time.UTC).UnixMilli() },
		"signedDate before purchase": func(c map[string]any) { c["signedDate"] = now.Add(-24 * time.Hour).UnixMilli() },
		"revocation before buy":      func(c map[string]any) { c["revocationDate"] = now.Add(-time.Hour).UnixMilli() },
		"reason without date":        func(c map[string]any) { c["revocationReason"] = 0 },
	}
	for name, mutate := range claimCases {
		t.Run(name, func(t *testing.T) {
			c := validClaims()
			mutate(c)
			responseJWS = pki.signJWS(t, "ES256", pki.x5c, c, pki.leafKey)
			if _, err := v.Verify(context.Background(), "1000000999"); !errors.Is(err, ErrInvalid) {
				t.Fatalf("%s: expected ErrInvalid, got: %v", name, err)
			}
		})
	}

	// Malformed transactionID rejected before HTTP call.
	for _, badID := range []string{"", "has space", "../123", "vat_token_prefix", strings.Repeat("1", 65)} {
		if _, err := v.Verify(context.Background(), badID); !errors.Is(err, ErrInvalid) {
			t.Fatalf("bad transactionID %q: expected ErrInvalid, got: %v", badID, err)
		}
	}
}

func TestVerifyUpstreamAndUnconfiguredClassification(t *testing.T) {
	var nilVerifier *Verifier
	if _, err := nilVerifier.Verify(context.Background(), "10000001"); !errors.Is(err, ErrUnavailable) {
		t.Fatalf("nil verifier must return ErrUnavailable, got: %v", err)
	}

	_, apiPEM := generateTestPrivateKeyPEM(t)
	v, err := New(Config{
		IssuerID:    uuid.NewString(),
		KeyID:       "KEY1234567",
		PrivateKey:  apiPEM,
		BundleID:    "com.veea.english",
		Environment: EnvSandbox,
		ProductIDs:  []string{"com.veea.pro.lifetime"},
	})
	if err != nil {
		t.Fatal(err)
	}

	// 404 Not Found and 400 with 4040010 map to ErrInvalid.
	for _, tc := range []struct {
		name   string
		status int
		body   string
		want   error
	}{
		{"404 not found", http.StatusNotFound, `{"errorCode":4040010}`, ErrInvalid},
		{"400 tx not found code", http.StatusBadRequest, `{"errorCode":4040010}`, ErrInvalid},
		{"400 invalid tx id code", http.StatusBadRequest, `{"errorCode":4000006}`, ErrInvalid},
		{"400 generic upstream", http.StatusBadRequest, `{"errorCode":4000000}`, ErrUnavailable},
		{"401 unauthorized upstream", http.StatusUnauthorized, `{}`, ErrUnavailable},
		{"429 rate limited upstream", http.StatusTooManyRequests, `{}`, ErrUnavailable},
		{"500 internal upstream", http.StatusInternalServerError, `{}`, ErrUnavailable},
		{"503 unavailable upstream", http.StatusServiceUnavailable, `{}`, ErrUnavailable},
		{"200 empty json", http.StatusOK, `{}`, ErrUnavailable},
		{"200 unknown field without proof", http.StatusOK, `{"extra":1}`, ErrUnavailable},
		{"200 empty proof", http.StatusOK, `{"signedTransactionInfo":"","extra":1}`, ErrUnavailable},
		{"200 trailing JSON", http.StatusOK, `{"signedTransactionInfo":"a.b.c"}{}`, ErrUnavailable},
		{"200 invalid proof with unknown field", http.StatusOK, `{"signedTransactionInfo":"a.b.c","extra":1}`, ErrInvalid},
	} {
		t.Run(tc.name, func(t *testing.T) {
			v.client.Transport = roundTripFunc(func(r *http.Request) (*http.Response, error) {
				return &http.Response{
					StatusCode: tc.status,
					Header:     http.Header{"Content-Type": []string{"application/json"}},
					Body:       io.NopCloser(strings.NewReader(tc.body)),
				}, nil
			})
			_, err := v.Verify(context.Background(), "20000001")
			if !errors.Is(err, tc.want) {
				t.Fatalf("%s: got %v, want %v", tc.name, err, tc.want)
			}
		})
	}

	// Transport errors are upstream unavailability.
	v.client.Transport = roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return nil, errors.New("synthetic network failure")
	})
	if _, err := v.Verify(context.Background(), "20000001"); !errors.Is(err, ErrUnavailable) {
		t.Fatalf("network error: got %v, want unavailability", err)
	}
}
