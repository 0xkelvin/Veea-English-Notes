package config

import (
	"bytes"
	"log/slog"
	"strings"
	"testing"
	"time"
)

// testKey is 32 bytes of hex, a throwaway value for tests only.
const testKey = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"
const testKey2 = "ffeeddccbbaa99887766554433221100ffeeddccbbaa99887766554433221100"

func env(m map[string]string) func(string) (string, bool) {
	return func(k string) (string, bool) { v, ok := m[k]; return v, ok }
}

// with returns a valid environment plus overrides.
func with(overrides map[string]string) func(string) (string, bool) {
	m := map[string]string{EnvDatabaseURL: "postgres://u:secret@localhost:5432/db", EnvEmailHMACKey: testKey}
	for k, v := range overrides {
		m[k] = v
	}
	return env(m)
}

func TestLoadDefaults(t *testing.T) {
	cfg, err := Load(with(nil))
	if err != nil {
		t.Fatal(err)
	}
	if cfg.HTTPAddr != ":18386" || cfg.DBMaxConns != 10 || cfg.LogLevel != slog.LevelInfo ||
		cfg.ShutdownTimeout != 15*time.Second || cfg.ReadyTimeout != 2*time.Second {
		t.Fatalf("unexpected defaults: %+v", cfg)
	}
}

func TestLoadOverrides(t *testing.T) {
	cfg, err := Load(with(map[string]string{
		EnvDatabaseURL: "postgresql://localhost/db", EnvHTTPAddr: "127.0.0.1:9000",
		EnvDBMaxConns: "3", EnvLogLevel: "debug", EnvShutdownTimeout: "1s", EnvReadyTimeout: "500ms",
	}))
	if err != nil {
		t.Fatal(err)
	}
	if cfg.HTTPAddr != "127.0.0.1:9000" || cfg.DBMaxConns != 3 || cfg.LogLevel != slog.LevelDebug ||
		cfg.ShutdownTimeout != time.Second || cfg.ReadyTimeout != 500*time.Millisecond {
		t.Fatalf("unexpected config: %+v", cfg)
	}
}

func TestLoadReportsAllProblemsWithoutLeakingSecrets(t *testing.T) {
	_, err := Load(with(map[string]string{
		EnvDatabaseURL: "mysql://u:hunter2@host/db", EnvDBMaxConns: "0",
		EnvLogLevel: "loud", EnvReadyTimeout: "-1s",
	}))
	if err == nil {
		t.Fatal("expected an error")
	}
	msg := err.Error()
	for _, want := range []string{EnvDatabaseURL, EnvDBMaxConns, EnvLogLevel, EnvReadyTimeout} {
		if !strings.Contains(msg, want) {
			t.Errorf("error does not mention %s: %s", want, msg)
		}
	}
	if strings.Contains(msg, "hunter2") {
		t.Fatalf("error leaks the database password: %s", msg)
	}
}

func TestLoadRequiresDatabaseURL(t *testing.T) {
	_, err := Load(env(nil))
	if err == nil {
		t.Fatal("expected an error")
	}
	for _, want := range []string{EnvDatabaseURL, EnvEmailHMACKey} {
		if !strings.Contains(err.Error(), want) {
			t.Fatalf("expected %s to be required, got %v", want, err)
		}
	}
}

func TestLoggingConfigOmitsDatabaseURL(t *testing.T) {
	cfg, err := Load(with(map[string]string{EnvDatabaseURL: "postgres://u:hunter2@localhost/db"}))
	if err != nil {
		t.Fatal(err)
	}
	var buf bytes.Buffer
	slog.New(slog.NewJSONHandler(&buf, nil)).Info("x", "config", cfg)
	for _, want := range []string{`"email_hmac_keys":1`, `"trusted_proxies":0`, `"ready_timeout":"2s"`} {
		if !strings.Contains(buf.String(), want) {
			t.Fatalf("log output should contain %s: %s", want, buf.String())
		}
	}
	for _, secret := range []string{"hunter2", "postgres://", testKey, testKey[:16]} {
		if strings.Contains(buf.String(), secret) {
			t.Fatalf("log output leaks %q: %s", secret, buf.String())
		}
	}
}

func TestEmailHMACKeys(t *testing.T) {
	cfg, err := Load(with(map[string]string{EnvEmailHMACKey: testKey + ", " + testKey2}))
	if err != nil {
		t.Fatal(err)
	}
	if len(cfg.EmailHMACKeys) != 2 || len(cfg.EmailHMACKeys[0]) != 32 || len(cfg.EmailHMACKeys[1]) != 32 {
		t.Fatalf("keys = %d", len(cfg.EmailHMACKeys))
	}
	if cfg.EmailHMACKeys[0][0] != 0x00 || cfg.EmailHMACKeys[1][0] != 0xff {
		t.Fatal("current key must come first")
	}
	// Longer keys are fine.
	if _, err := Load(with(map[string]string{EnvEmailHMACKey: testKey + "aa"})); err != nil {
		t.Fatalf("a 33 byte key must be accepted: %v", err)
	}
}

func TestEmailHMACKeyErrorsNeverContainKeyMaterial(t *testing.T) {
	cases := map[string]string{
		"too short":       testKey[:62],
		"not hex":         strings.Repeat("zz", 32),
		"odd length":      testKey + "a",
		"three keys":      testKey + "," + testKey + "," + testKey,
		"empty previous":  testKey + ",",
		"short previous":  testKey + ",abcd",
		"whitespace only": "   ",
	}
	for name, raw := range cases {
		t.Run(name, func(t *testing.T) {
			_, err := Load(with(map[string]string{EnvEmailHMACKey: raw}))
			if err == nil {
				t.Fatal("expected an error")
			}
			if !strings.Contains(err.Error(), EnvEmailHMACKey) {
				t.Fatalf("error should name the variable: %v", err)
			}
			if strings.Contains(err.Error(), testKey[:12]) || strings.Contains(err.Error(), "abcd") {
				t.Fatalf("error leaks key material: %v", err)
			}
		})
	}
}

func TestTrustedProxies(t *testing.T) {
	cfg, err := Load(with(nil))
	if err != nil || len(cfg.TrustedProxies) != 0 {
		t.Fatalf("default must be no trusted proxies: %v %v", cfg.TrustedProxies, err)
	}
	cfg, err = Load(with(map[string]string{EnvTrustedProxies: "10.0.0.0/8, 192.0.2.7 ,2001:db8::/32,,"}))
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, p := range cfg.TrustedProxies {
		got = append(got, p.String())
	}
	if strings.Join(got, " ") != "10.0.0.0/8 192.0.2.7/32 2001:db8::/32" {
		t.Fatalf("got %v", got)
	}
	for _, bad := range []string{"10.0.0.0/33", "not-an-ip", "10.0.0.1/", "1.2.3.4%eth0", "10.0.0.0/8;10.1.0.0/16"} {
		_, err := Load(with(map[string]string{EnvTrustedProxies: bad}))
		if err == nil || !strings.Contains(err.Error(), EnvTrustedProxies) {
			t.Errorf("%q: expected an error naming %s, got %v", bad, EnvTrustedProxies, err)
		}
		if err != nil && strings.Contains(err.Error(), bad) {
			t.Errorf("%q: error echoes the value", bad)
		}
	}
}
