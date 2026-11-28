package config

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"encoding/pem"
	"os"
	"path/filepath"
	"strings"
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

func TestApplePrivateKeyFileConfiguration(t *testing.T) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	der, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	pemKey := pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})
	path := filepath.Join(t.TempDir(), "test-apple-key.p8")
	if err := os.WriteFile(path, pemKey, 0600); err != nil {
		t.Fatal(err)
	}
	oversized := path + ".oversized"
	if err := os.WriteFile(oversized, []byte(strings.Repeat("s", maxApplePrivateKeyFileBytes+1)), 0600); err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		name, enabled, inline, file, wantError string
	}{
		{name: "file only", enabled: "true", file: path},
		{name: "inline escaped PEM", enabled: "true", inline: strings.ReplaceAll(string(pemKey), "\n", `\n`)},
		{name: "both sources", enabled: "true", inline: string(pemKey), file: path, wantError: "set only one"},
		{name: "unreadable file", enabled: "true", file: path + ".missing", wantError: "could not be read"},
		{name: "oversized file", enabled: "true", file: oversized, wantError: "exceeds 16 KiB"},
		{name: "not a regular file", enabled: "true", file: filepath.Dir(path), wantError: "must be a regular file"},
		{name: "no implicit fallback", enabled: "true", inline: string(pemKey), file: path + ".missing", wantError: "set only one"},
		{name: "disabled ignores both sources", enabled: "false", inline: "invalid", file: path + ".missing"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			cfg, err := Load(with(map[string]string{
				"VEEA_APPLE_IAP_ENABLED": tc.enabled, "VEEA_APPLE_IAP_ENVIRONMENT": "Production",
				"VEEA_APPLE_IAP_ISSUER_ID": "12345678-1234-1234-1234-123456789012", "VEEA_APPLE_IAP_KEY_ID": "KEY1234567",
				"VEEA_APPLE_IAP_BUNDLE_ID": "app.veea.english", "VEEA_APPLE_IAP_PRODUCT_IDS": "app.veea.pro",
				"VEEA_APPLE_IAP_PRIVATE_KEY": tc.inline, "VEEA_APPLE_IAP_PRIVATE_KEY_FILE": tc.file,
			}))
			if tc.wantError == "" {
				if err != nil || (cfg.AppleVerifier != nil) != (tc.enabled == "true") {
					t.Fatal("unexpected configuration outcome", err)
				}
				return
			}
			if err == nil || !strings.Contains(err.Error(), tc.wantError) {
				t.Fatal("expected a fixed configuration error")
			}
			if strings.Contains(err.Error(), tc.file) || strings.Contains(err.Error(), "-----BEGIN") {
				t.Fatal("configuration error exposed key source details")
			}
		})
	}
}
