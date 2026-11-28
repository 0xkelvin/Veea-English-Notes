// Package appleiap verifies one-time App Store non-consumable Pro purchases with Apple's
// App Store Server API (Get Transaction Info) and pinned Apple PKI trust roots (TRD 11).
//
// It never trusts client booleans or unverified JWS strings: every Verify call authenticates to
// Apple with a short-lived ES256 server JWT, fetches a fresh signedTransactionInfo response for
// the requested transaction ID, verifies the x5c certificate chain against the pinned Apple Root
// CA - G3 certificate (plus Apple's leaf and WWDR intermediate OID extensions), verifies the
// ES256 JWS signature, and validates bundle, product allowlist, environment, non-consumable
// product type, PURCHASED ownership, non-nil appAccountToken UUID, and timestamps.
//
// Keys, JWTs, and raw JWS payloads are never logged or included in returned errors.
package appleiap

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/asn1"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"time"

	"github.com/google/uuid"
)

// Sentinel errors classified by callers (TRD 11).
var (
	// ErrUnavailable reports that Apple IAP verification is unconfigured or that Apple's
	// App Store Server API failed, timed out, or returned an upstream/auth/rate error.
	ErrUnavailable = errors.New("appleiap: service unavailable")
	// ErrInvalid reports that the transaction ID is malformed or nonexistent, or that the
	// JWS signature, certificate chain, or required transaction claims failed verification.
	ErrInvalid = errors.New("appleiap: invalid transaction")
	// ErrNotFound is only Apple's explicit 4040010 response, not a failed signature
	// or an outage. It also classifies as ErrInvalid for existing callers.
	ErrNotFound = fmt.Errorf("%w: transaction not found", ErrInvalid)
)

// Supported App Store environments and their fixed App Store Server API base URLs.
const (
	EnvProduction = "Production"
	EnvSandbox    = "Sandbox"

	productionBaseURL = "https://api.storekit.apple.com"
	sandboxBaseURL    = "https://api.storekit-sandbox.apple.com"

	jwtAudience      = "appstoreconnect-v1"
	jwtTTL           = 5 * time.Minute
	requestTimeout   = 10 * time.Second
	maxResponseBytes = 64 << 10
	maxClockSkew     = 5 * time.Minute
)

// minPurchaseTime rejects impossible pre-StoreKit 2 epoch or corrupt purchase timestamps.
var minPurchaseTime = time.Date(2020, 1, 1, 0, 0, 0, 0, time.UTC)

// Apple PKI X.509 extension OIDs required on App Store JWS signing certificates.
var (
	oidAppleLeafReceiptSigning = asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 6, 11, 1}
	oidAppleWWDRIntermediate   = asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 6, 2, 1}
)

// Pinned Apple Root CA - G3 (SHA-256: 63343abfb89a6a03ebb57e9b3f5fa7be7c4f5c756f3017b3a8c488c3653e9179).
const (
	appleRootCAG3SHA256 = "63343abfb89a6a03ebb57e9b3f5fa7be7c4f5c756f3017b3a8c488c3653e9179"
	appleRootCAG3PEM    = `-----BEGIN CERTIFICATE-----
MIICQzCCAcmgAwIBAgIILcX8iNLFS5UwCgYIKoZIzj0EAwMwZzEbMBkGA1UEAwwS
QXBwbGUgUm9vdCBDQSAtIEczMSYwJAYDVQQLDB1BcHBsZSBDZXJ0aWZpY2F0aW9u
IEF1dGhvcml0eTETMBEGA1UECgwKQXBwbGUgSW5jLjELMAkGA1UEBhMCVVMwHhcN
MTQwNDMwMTgxOTA2WhcNMzkwNDMwMTgxOTA2WjBnMRswGQYDVQQDDBJBcHBsZSBS
b290IENBIC0gRzMxJjAkBgNVBAsMHUFwcGxlIENlcnRpZmljYXRpb24gQXV0aG9y
aXR5MRMwEQYDVQQKDApBcHBsZSBJbmMuMQswCQYDVQQGEwJVUzB2MBAGByqGSM49
AgEGBSuBBAAiA2IABJjpLz1AcqTtkyJygRMc3RCV8cWjTnHcFBbZDuWmBSp3ZHtf
TjjTuxxEtX/1H7YyYl3J6YRbTzBPEVoA/VhYDKX1DyxNB0cTddqXl5dvMVztK517
IDvYuVTZXpmkOlEKMaNCMEAwHQYDVR0OBBYEFLuw3qFYM4iapIqZ3r6966/ayySr
MA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgEGMAoGCCqGSM49BAMDA2gA
MGUCMQCD6cHEFl4aXTQY2e3v9GwOAEZLuN+yRhHFD/3meoyhpmvOwgPUnPWTxnS4
at+qIxUCMG1mihDK1A3UT82NQz60imOlM27jbdoXt2QfyFMm+YhidDkLF1vLUagM
6BgD56KyKA==
-----END CERTIFICATE-----`
)

var (
	keyIDPattern         = regexp.MustCompile(`^[A-Za-z0-9]{10}$`)
	bundleIDPattern      = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,159}$`)
	productIDPattern     = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$`)
	transactionIDPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`)
	tokenPrefixes        = []string{"vct_", "vat_", "vrt_", "vop_"}
)

// Config holds the App Store Server API credentials and product allowlist.
type Config struct {
	IssuerID    string
	KeyID       string
	PrivateKey  string
	BundleID    string
	Environment string
	ProductIDs  []string
	// AllowSandbox acknowledges review/TestFlight proofs on a Production API.
	// The purchase service must never persist these as Production entitlements.
	AllowSandbox bool
}

// Transaction is a verified App Store non-consumable purchase record.
type Transaction struct {
	ID               string
	OriginalID       string
	ProductID        string
	BundleID         string
	Environment      string
	AccountToken     uuid.UUID
	PurchasedAt      time.Time
	SignedAt         time.Time
	RevokedAt        *time.Time
	RevocationReason *int32
}

// Verifier fetches and verifies App Store transactions. It is safe for concurrent use.
type Verifier struct {
	issuerID    string
	keyID       string
	key         *ecdsa.PrivateKey
	bundleID    string
	environment string
	baseURL     string
	products    map[string]struct{}
	roots       *x509.CertPool
	rootDERs    map[string]struct{}
	client      *http.Client
	now         func() time.Time
	sandbox     *Verifier
}

// New validates cfg and pins Apple Root CA - G3 and the fixed endpoint for
// cfg.Environment. Production may explicitly enable a separate Sandbox fallback.
func New(cfg Config) (*Verifier, error) {
	var errs []error
	if cfg.AllowSandbox && cfg.Environment != EnvProduction {
		errs = append(errs, errors.New("appleiap: Sandbox fallback requires Production environment"))
	}

	issuer, err := uuid.Parse(strings.TrimSpace(cfg.IssuerID))
	if err != nil || issuer == uuid.Nil {
		errs = append(errs, errors.New("appleiap: IssuerID must be a non-nil UUID"))
	}

	keyID := strings.TrimSpace(cfg.KeyID)
	if !keyIDPattern.MatchString(keyID) {
		errs = append(errs, errors.New("appleiap: KeyID must be 10 alphanumeric characters"))
	}

	key, err := parseP256PrivateKey(cfg.PrivateKey)
	if err != nil {
		errs = append(errs, err)
	}

	bundleID := strings.TrimSpace(cfg.BundleID)
	if !bundleIDPattern.MatchString(bundleID) || !strings.Contains(bundleID, ".") {
		errs = append(errs, errors.New("appleiap: BundleID must be a valid reverse-DNS identifier"))
	}

	var baseURL string
	switch cfg.Environment {
	case EnvProduction:
		baseURL = productionBaseURL
	case EnvSandbox:
		baseURL = sandboxBaseURL
	default:
		errs = append(errs, errors.New("appleiap: Environment must be Production or Sandbox"))
	}

	products := make(map[string]struct{}, len(cfg.ProductIDs))
	for _, raw := range cfg.ProductIDs {
		p := strings.TrimSpace(raw)
		if !productIDPattern.MatchString(p) {
			errs = append(errs, errors.New("appleiap: ProductIDs contains an invalid product identifier"))
			break
		}
		products[p] = struct{}{}
	}
	if len(products) == 0 {
		errs = append(errs, errors.New("appleiap: at least one ProductID is required"))
	}

	if len(errs) > 0 {
		return nil, errors.Join(errs...)
	}

	rootCert, err := parsePinnedAppleRoot()
	if err != nil {
		return nil, err
	}
	roots := x509.NewCertPool()
	roots.AddCert(rootCert)
	rootDERs := map[string]struct{}{string(rootCert.Raw): {}}

	transport := &http.Transport{
		Proxy:                 http.ProxyFromEnvironment,
		ForceAttemptHTTP2:     true,
		MaxIdleConns:          10,
		IdleConnTimeout:       30 * time.Second,
		TLSHandshakeTimeout:   5 * time.Second,
		ExpectContinueTimeout: 1 * time.Second,
		TLSClientConfig:       &tls.Config{MinVersion: tls.VersionTLS12},
	}

	v := &Verifier{
		issuerID:    issuer.String(),
		keyID:       keyID,
		key:         key,
		bundleID:    bundleID,
		environment: cfg.Environment,
		baseURL:     baseURL,
		products:    products,
		roots:       roots,
		rootDERs:    rootDERs,
		client:      &http.Client{Transport: transport, Timeout: requestTimeout},
		now:         time.Now,
	}
	if cfg.AllowSandbox {
		cfg.AllowSandbox = false
		cfg.Environment = EnvSandbox
		v.sandbox, err = New(cfg)
		if err != nil {
			return nil, err
		}
	}
	return v, nil
}

// Verify fetches fresh signed transaction information from Apple for transactionID and
// validates its certificate chain, ES256 signature, and non-consumable purchase claims.
func (v *Verifier) Verify(ctx context.Context, transactionID string) (Transaction, error) {
	proof, err := v.verify(ctx, transactionID)
	// Apple documents Production first, then Sandbox only for 4040010. A bad
	// signature, wrong bundle/owner/environment, generic 404 or outage never retries.
	if v != nil && v.sandbox != nil && errors.Is(err, ErrNotFound) {
		return v.sandbox.verify(ctx, transactionID)
	}
	return proof, err
}

func (v *Verifier) verify(ctx context.Context, transactionID string) (Transaction, error) {
	if v == nil || v.key == nil || v.client == nil || v.roots == nil {
		return Transaction{}, ErrUnavailable
	}
	if !ValidTransactionID(transactionID) {
		return Transaction{}, ErrInvalid
	}

	now := v.now().UTC()
	bearer, err := v.mintBearerJWT(now)
	if err != nil {
		return Transaction{}, fmt.Errorf("%w: sign server token", ErrUnavailable)
	}

	reqCtx, cancel := context.WithTimeout(ctx, requestTimeout)
	defer cancel()

	endpoint := v.baseURL + "/inApps/v1/transactions/" + url.PathEscape(transactionID)
	req, err := http.NewRequestWithContext(reqCtx, http.MethodGet, endpoint, nil)
	if err != nil {
		return Transaction{}, fmt.Errorf("%w: build request", ErrUnavailable)
	}
	req.Header.Set("Authorization", "Bearer "+bearer)
	req.Header.Set("Accept", "application/json")

	res, err := v.client.Do(req)
	if err != nil {
		return Transaction{}, fmt.Errorf("%w: request failed", ErrUnavailable)
	}
	defer res.Body.Close()

	body, err := io.ReadAll(io.LimitReader(res.Body, maxResponseBytes+1))
	if err != nil || len(body) > maxResponseBytes {
		return Transaction{}, fmt.Errorf("%w: read response", ErrUnavailable)
	}

	switch res.StatusCode {
	case http.StatusOK:
	case http.StatusNotFound:
		var apiErr struct {
			ErrorCode int `json:"errorCode"`
		}
		if json.Unmarshal(body, &apiErr) == nil && apiErr.ErrorCode == 4040010 {
			return Transaction{}, ErrNotFound
		}
		return Transaction{}, fmt.Errorf("%w: transaction not found", ErrInvalid)
	case http.StatusBadRequest:
		var apiErr struct {
			ErrorCode int `json:"errorCode"`
		}
		if json.Unmarshal(body, &apiErr) == nil && (apiErr.ErrorCode == 4040010 || apiErr.ErrorCode == 4000006) {
			return Transaction{}, fmt.Errorf("%w: invalid transaction id", ErrInvalid)
		}
		return Transaction{}, fmt.Errorf("%w: upstream status 400", ErrUnavailable)
	default:
		return Transaction{}, fmt.Errorf("%w: upstream status %d", ErrUnavailable, res.StatusCode)
	}

	var envelope struct {
		SignedTransactionInfo string `json:"signedTransactionInfo"`
	}
	if err := json.Unmarshal(body, &envelope); err != nil || envelope.SignedTransactionInfo == "" {
		return Transaction{}, fmt.Errorf("%w: malformed response envelope", ErrUnavailable)
	}

	return v.verifyJWS(envelope.SignedTransactionInfo, transactionID, now)
}

// ValidTransactionID reports whether s is a well-formed, non-secret-looking transaction identifier.
func ValidTransactionID(s string) bool {
	if !transactionIDPattern.MatchString(s) {
		return false
	}
	lower := strings.ToLower(s)
	for _, p := range tokenPrefixes {
		if strings.Contains(lower, p) {
			return false
		}
	}
	return true
}

func (v *Verifier) mintBearerJWT(now time.Time) (string, error) {
	headerJSON, err := json.Marshal(struct {
		Alg string `json:"alg"`
		Kid string `json:"kid"`
		Typ string `json:"typ"`
	}{Alg: "ES256", Kid: v.keyID, Typ: "JWT"})
	if err != nil {
		return "", err
	}
	claimsJSON, err := json.Marshal(struct {
		Iss string `json:"iss"`
		Iat int64  `json:"iat"`
		Exp int64  `json:"exp"`
		Aud string `json:"aud"`
		Bid string `json:"bid"`
	}{
		Iss: v.issuerID,
		Iat: now.Unix(),
		Exp: now.Add(jwtTTL).Unix(),
		Aud: jwtAudience,
		Bid: v.bundleID,
	})
	if err != nil {
		return "", err
	}
	signingInput := base64.RawURLEncoding.EncodeToString(headerJSON) + "." +
		base64.RawURLEncoding.EncodeToString(claimsJSON)
	sig, err := signES256(v.key, []byte(signingInput))
	if err != nil {
		return "", err
	}
	return signingInput + "." + base64.RawURLEncoding.EncodeToString(sig), nil
}

func signES256(key *ecdsa.PrivateKey, signingInput []byte) ([]byte, error) {
	digest := sha256.Sum256(signingInput)
	r, s, err := ecdsa.Sign(rand.Reader, key, digest[:])
	if err != nil {
		return nil, err
	}
	var out [64]byte
	r.FillBytes(out[:32])
	s.FillBytes(out[32:])
	return out[:], nil
}

type jwsHeader struct {
	Alg string   `json:"alg"`
	X5c []string `json:"x5c"`
}

type jwsPayload struct {
	TransactionID         string `json:"transactionId"`
	OriginalTransactionID string `json:"originalTransactionId"`
	BundleID              string `json:"bundleId"`
	ProductID             string `json:"productId"`
	Environment           string `json:"environment"`
	Type                  string `json:"type"`
	InAppOwnershipType    string `json:"inAppOwnershipType"`
	AppAccountToken       string `json:"appAccountToken"`
	PurchaseDate          *int64 `json:"purchaseDate"`
	SignedDate            *int64 `json:"signedDate"`
	RevocationDate        *int64 `json:"revocationDate"`
	RevocationReason      *int32 `json:"revocationReason"`
	IsUpgraded            bool   `json:"isUpgraded"`
}

func (v *Verifier) verifyJWS(compact, requestedID string, now time.Time) (Transaction, error) {
	parts := strings.Split(compact, ".")
	if len(parts) != 3 || parts[0] == "" || parts[1] == "" || parts[2] == "" {
		return Transaction{}, fmt.Errorf("%w: malformed jws", ErrInvalid)
	}
	headerBytes, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return Transaction{}, fmt.Errorf("%w: jws header encoding", ErrInvalid)
	}
	var hdr jwsHeader
	if err := json.Unmarshal(headerBytes, &hdr); err != nil || hdr.Alg != "ES256" || len(hdr.X5c) < 2 || len(hdr.X5c) > 5 {
		return Transaction{}, fmt.Errorf("%w: jws header", ErrInvalid)
	}

	// Only a fresh authenticated Apple API response reaches this private method.
	// Historical purchases can carry older signedDate and signing certificates.
	// Validate the chain at signing time (Apple SignedDataVerifier's offline-chain mode),
	// then verify the signature and all claims below. Client JWS is never accepted.
	preliminaryBytes, err := base64.RawURLEncoding.DecodeString(parts[1])
	var preliminary jwsPayload
	if err != nil || json.Unmarshal(preliminaryBytes, &preliminary) != nil || preliminary.SignedDate == nil || *preliminary.SignedDate <= 0 {
		return Transaction{}, ErrInvalid
	}
	effectiveTime := time.UnixMilli(*preliminary.SignedDate).UTC()
	if effectiveTime.After(now.Add(maxClockSkew)) {
		return Transaction{}, ErrInvalid
	}
	leafKey, err := v.verifyCertChain(hdr.X5c, effectiveTime)
	if err != nil {
		return Transaction{}, err
	}

	sigBytes, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil || len(sigBytes) != 64 {
		return Transaction{}, fmt.Errorf("%w: jws signature encoding", ErrInvalid)
	}
	r := new(big.Int).SetBytes(sigBytes[:32])
	s := new(big.Int).SetBytes(sigBytes[32:])
	digest := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	if !ecdsa.Verify(leafKey, digest[:], r, s) {
		return Transaction{}, fmt.Errorf("%w: jws signature verification failed", ErrInvalid)
	}

	payloadBytes, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return Transaction{}, fmt.Errorf("%w: jws payload encoding", ErrInvalid)
	}
	var p jwsPayload
	if err := json.Unmarshal(payloadBytes, &p); err != nil {
		return Transaction{}, fmt.Errorf("%w: jws payload json", ErrInvalid)
	}

	if !ValidTransactionID(p.TransactionID) || !ValidTransactionID(p.OriginalTransactionID) {
		return Transaction{}, fmt.Errorf("%w: invalid transaction identifiers", ErrInvalid)
	}
	if p.TransactionID != requestedID {
		return Transaction{}, fmt.Errorf("%w: transaction id mismatch", ErrInvalid)
	}
	if p.BundleID != v.bundleID {
		return Transaction{}, fmt.Errorf("%w: bundle id mismatch", ErrInvalid)
	}
	if _, ok := v.products[p.ProductID]; !ok {
		return Transaction{}, fmt.Errorf("%w: product id not allowed", ErrInvalid)
	}
	if p.Environment != v.environment {
		return Transaction{}, fmt.Errorf("%w: environment mismatch", ErrInvalid)
	}
	if p.Type != "Non-Consumable" {
		return Transaction{}, fmt.Errorf("%w: product type is not Non-Consumable", ErrInvalid)
	}
	if p.InAppOwnershipType != "PURCHASED" || p.IsUpgraded {
		return Transaction{}, fmt.Errorf("%w: ownership type not eligible", ErrInvalid)
	}

	accountToken, err := uuid.Parse(p.AppAccountToken)
	if err != nil || accountToken == uuid.Nil || !strings.EqualFold(accountToken.String(), p.AppAccountToken) {
		return Transaction{}, fmt.Errorf("%w: missing or invalid appAccountToken", ErrInvalid)
	}

	if p.PurchaseDate == nil || *p.PurchaseDate <= 0 || p.SignedDate == nil || *p.SignedDate <= 0 {
		return Transaction{}, fmt.Errorf("%w: missing purchaseDate or signedDate", ErrInvalid)
	}
	purchasedAt := time.UnixMilli(*p.PurchaseDate).UTC()
	if purchasedAt.Before(minPurchaseTime) || purchasedAt.After(now.Add(maxClockSkew)) {
		return Transaction{}, fmt.Errorf("%w: purchaseDate out of range", ErrInvalid)
	}
	signedAt := time.UnixMilli(*p.SignedDate).UTC()
	if signedAt.Before(purchasedAt.Add(-maxClockSkew)) || signedAt.After(now.Add(maxClockSkew)) {
		return Transaction{}, fmt.Errorf("%w: signedDate out of range", ErrInvalid)
	}

	var revokedAt *time.Time
	var revocationReason *int32
	if p.RevocationDate != nil {
		if *p.RevocationDate <= 0 {
			return Transaction{}, fmt.Errorf("%w: invalid revocationDate", ErrInvalid)
		}
		rev := time.UnixMilli(*p.RevocationDate).UTC()
		if rev.Before(purchasedAt) || rev.After(now.Add(maxClockSkew)) {
			return Transaction{}, fmt.Errorf("%w: revocationDate out of range", ErrInvalid)
		}
		revokedAt = &rev
		if p.RevocationReason != nil {
			reason := *p.RevocationReason
			revocationReason = &reason
		}
	} else if p.RevocationReason != nil {
		return Transaction{}, fmt.Errorf("%w: revocationReason without revocationDate", ErrInvalid)
	}

	return Transaction{
		ID:               p.TransactionID,
		OriginalID:       p.OriginalTransactionID,
		ProductID:        p.ProductID,
		BundleID:         p.BundleID,
		Environment:      p.Environment,
		AccountToken:     accountToken,
		PurchasedAt:      purchasedAt,
		SignedAt:         signedAt,
		RevokedAt:        revokedAt,
		RevocationReason: revocationReason,
	}, nil
}

func (v *Verifier) verifyCertChain(x5c []string, now time.Time) (*ecdsa.PublicKey, error) {
	certs := make([]*x509.Certificate, len(x5c))
	for i, rawB64 := range x5c {
		der, err := base64.StdEncoding.DecodeString(rawB64)
		if err != nil {
			return nil, fmt.Errorf("%w: x5c[%d] base64", ErrInvalid, i)
		}
		cert, err := x509.ParseCertificate(der)
		if err != nil {
			return nil, fmt.Errorf("%w: x5c[%d] parse", ErrInvalid, i)
		}
		certs[i] = cert
	}

	leaf := certs[0]
	intermediate := certs[1]
	top := certs[len(certs)-1]

	if !hasExtensionOID(leaf, oidAppleLeafReceiptSigning) {
		return nil, fmt.Errorf("%w: leaf certificate missing Apple receipt signing OID", ErrInvalid)
	}
	if !hasExtensionOID(intermediate, oidAppleWWDRIntermediate) {
		return nil, fmt.Errorf("%w: intermediate certificate missing Apple WWDR OID", ErrInvalid)
	}
	if _, pinned := v.rootDERs[string(top.Raw)]; !pinned {
		return nil, fmt.Errorf("%w: x5c root is not pinned Apple Root CA - G3", ErrInvalid)
	}

	intermediates := x509.NewCertPool()
	for _, c := range certs[1 : len(certs)-1] {
		intermediates.AddCert(c)
	}
	chains, err := leaf.Verify(x509.VerifyOptions{
		Roots:         v.roots,
		Intermediates: intermediates,
		CurrentTime:   now,
		KeyUsages:     []x509.ExtKeyUsage{x509.ExtKeyUsageAny},
	})
	if err != nil || len(chains) == 0 {
		return nil, fmt.Errorf("%w: x5c chain verification failed", ErrInvalid)
	}

	pub, ok := leaf.PublicKey.(*ecdsa.PublicKey)
	if !ok || pub.Curve != elliptic.P256() {
		return nil, fmt.Errorf("%w: leaf public key is not P-256 ECDSA", ErrInvalid)
	}
	return pub, nil
}

func hasExtensionOID(cert *x509.Certificate, want asn1.ObjectIdentifier) bool {
	for _, ext := range cert.Extensions {
		if ext.Id.Equal(want) {
			return true
		}
	}
	return false
}

func parsePinnedAppleRoot() (*x509.Certificate, error) {
	block, rest := pem.Decode([]byte(appleRootCAG3PEM))
	if block == nil || block.Type != "CERTIFICATE" || len(strings.TrimSpace(string(rest))) != 0 {
		return nil, errors.New("appleiap: embedded Apple Root CA - G3 PEM is invalid")
	}
	sum := sha256.Sum256(block.Bytes)
	if hex.EncodeToString(sum[:]) != appleRootCAG3SHA256 {
		return nil, errors.New("appleiap: embedded Apple Root CA - G3 fingerprint mismatch")
	}
	cert, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		return nil, errors.New("appleiap: parse embedded Apple Root CA - G3")
	}
	return cert, nil
}

func parseP256PrivateKey(raw string) (*ecdsa.PrivateKey, error) {
	normalized := strings.ReplaceAll(strings.TrimSpace(raw), `\n`, "\n")
	if normalized == "" {
		return nil, errors.New("appleiap: PrivateKey is required")
	}
	block, rest := pem.Decode([]byte(normalized))
	if block == nil || len(strings.TrimSpace(string(rest))) != 0 {
		return nil, errors.New("appleiap: PrivateKey must be a single PEM block")
	}
	var key *ecdsa.PrivateKey
	switch block.Type {
	case "PRIVATE KEY":
		parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
		if err != nil {
			return nil, errors.New("appleiap: PrivateKey is not valid PKCS#8")
		}
		var ok bool
		key, ok = parsed.(*ecdsa.PrivateKey)
		if !ok {
			return nil, errors.New("appleiap: PrivateKey is not an ECDSA key")
		}
	case "EC PRIVATE KEY":
		var err error
		key, err = x509.ParseECPrivateKey(block.Bytes)
		if err != nil {
			return nil, errors.New("appleiap: PrivateKey is not a valid EC private key")
		}
	default:
		return nil, errors.New("appleiap: PrivateKey PEM type must be PRIVATE KEY or EC PRIVATE KEY")
	}
	if key.Curve != elliptic.P256() {
		return nil, errors.New("appleiap: PrivateKey must use the P-256 curve")
	}
	return key, nil
}
