package config

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"encoding/pem"
	"testing"
)

func TestAppleSandboxAcknowledgementConfiguration(t *testing.T) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	der, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	m := map[string]string{
		"VEEA_APPLE_IAP_ENABLED": "true", "VEEA_APPLE_IAP_ENVIRONMENT": "Production",
		"VEEA_APPLE_IAP_ISSUER_ID": "12345678-1234-1234-1234-123456789012", "VEEA_APPLE_IAP_KEY_ID": "KEY1234567",
		"VEEA_APPLE_IAP_PRIVATE_KEY": string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})),
		"VEEA_APPLE_IAP_BUNDLE_ID":   "app.veea.english", "VEEA_APPLE_IAP_PRODUCT_IDS": "app.veea.pro",
	}
	cfg, err := Load(with(m))
	if err != nil || cfg.AppleAllowSandbox || cfg.AppleVerifier == nil {
		t.Fatal("default production config", err)
	}
	m["VEEA_APPLE_IAP_ALLOW_SANDBOX"] = "true"
	cfg, err = Load(with(m))
	if err != nil || !cfg.AppleAllowSandbox || cfg.AppleVerifier == nil {
		t.Fatal("explicit sandbox config", err)
	}
	m["VEEA_APPLE_IAP_ENVIRONMENT"] = "Sandbox"
	if _, err = Load(with(m)); err == nil {
		t.Fatal("Sandbox fallback allowed in Sandbox-only service")
	}
	m["VEEA_APPLE_IAP_ALLOW_SANDBOX"] = "false"
	cfg, err = Load(with(m))
	if err != nil || cfg.AppleAllowSandbox || cfg.AppleVerifier == nil {
		t.Fatal("dedicated sandbox config", err)
	}
	m["VEEA_APPLE_IAP_ALLOW_SANDBOX"] = "yes"
	if _, err = Load(with(m)); err == nil {
		t.Fatal("invalid Sandbox switch allowed")
	}
	m["VEEA_APPLE_IAP_ALLOW_SANDBOX"] = "true"
	m["VEEA_APPLE_IAP_ENABLED"] = "false"
	if _, err = Load(with(m)); err == nil {
		t.Fatal("Sandbox flag allowed with payments off")
	}
}
