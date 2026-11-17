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
const testKey3 = "a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebfc0"

func env(m map[string]string) func(string) (string, bool) {
	return func(k string) (string, bool) { v, ok := m[k]; return v, ok }
}

// with returns a valid environment plus overrides.
func with(overrides map[string]string) func(string) (string, bool) {
	m := map[string]string{EnvDatabaseURL: "postgres://u:secret@localhost:5432/db", EnvEmailHMACKey: testKey,
		EnvOutboxKey: "1:" + testKey2, EnvOTPKey: testKey3}
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
	for _, want := range []string{EnvDatabaseURL, EnvEmailHMACKey, EnvOutboxKey, EnvOTPKey} {
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
	for _, want := range []string{`"email_hmac_keys":1`, `"otp_keys":1`, `"trusted_proxies":0`, `"ready_timeout":"2s"`} {
		if !strings.Contains(buf.String(), want) {
			t.Fatalf("log output should contain %s: %s", want, buf.String())
		}
	}
	for _, secret := range []string{"hunter2", "postgres://", testKey, testKey[:16], testKey2, testKey2[:16], testKey3, testKey3[:16]} {
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

func TestOTPKeys(t *testing.T) {
	cfg, err := Load(with(map[string]string{EnvOTPKey: testKey3 + "," + testKey}))
	if err != nil {
		t.Fatal(err)
	}
	if len(cfg.OTPKeys) != 2 || len(cfg.OTPKeys[0]) != 32 || cfg.OTPKeys[0][0] != 0xa1 || cfg.OTPKeys[1][0] != 0x00 {
		t.Fatalf("expected two 32 byte keys, current first; got %d", len(cfg.OTPKeys))
	}
}

func TestOTPKeyErrorsNeverContainKeyMaterial(t *testing.T) {
	cases := map[string]string{
		"missing":        "",
		"too short":      testKey3[:62],
		"not hex":        strings.Repeat("zz", 32),
		"three keys":     testKey3 + "," + testKey3 + "," + testKey3,
		"short previous": testKey3 + ",a1a2",
	}
	for name, raw := range cases {
		t.Run(name, func(t *testing.T) {
			_, err := Load(with(map[string]string{EnvOTPKey: raw}))
			if err == nil || !strings.Contains(err.Error(), EnvOTPKey) {
				t.Fatalf("expected an error naming %s, got %v", EnvOTPKey, err)
			}
			if strings.Contains(err.Error(), testKey3[:12]) || strings.Contains(err.Error(), "a1a2") {
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

func TestOutboxKeys(t *testing.T) {
	cfg, err := Load(with(map[string]string{EnvOutboxKey: "2:" + testKey + ", 1:" + testKey2}))
	if err != nil {
		t.Fatal(err)
	}
	if len(cfg.OutboxKeys) != 2 || cfg.OutboxKeys[0].ID != 2 || cfg.OutboxKeys[1].ID != 1 {
		t.Fatalf("keys = %+v", len(cfg.OutboxKeys))
	}
	if cfg.OutboxKeys[0].Key[0] != 0x00 || cfg.OutboxKeys[1].Key[0] != 0xff || len(cfg.OutboxKeys[0].Key) != 32 {
		t.Fatal("keys parsed in the wrong order or length")
	}
}

func TestOutboxKeyErrorsNeverContainKeyMaterial(t *testing.T) {
	cases := map[string]string{
		"no id":         testKey,
		"id zero":       "0:" + testKey,
		"id too big":    "40000:" + testKey,
		"id not number": "x:" + testKey,
		"duplicate id":  "1:" + testKey + ",1:" + testKey2,
		"short key":     "1:" + testKey[:62],
		"long key":      "1:" + testKey + "aa",
		"not hex":       "1:" + strings.Repeat("zz", 32),
		"empty entry":   "1:" + testKey + ",",
		"whitespace":    "   ",
	}
	for name, raw := range cases {
		t.Run(name, func(t *testing.T) {
			_, err := Load(with(map[string]string{EnvOutboxKey: raw}))
			if err == nil || !strings.Contains(err.Error(), EnvOutboxKey) {
				t.Fatalf("expected an error naming %s, got %v", EnvOutboxKey, err)
			}
			if strings.Contains(err.Error(), testKey[:12]) || strings.Contains(err.Error(), testKey2[:12]) {
				t.Fatalf("error leaks key material: %v", err)
			}
		})
	}
}

func TestEmailSenderSettings(t *testing.T) {
	cfg, err := Load(with(nil))
	if err != nil {
		t.Fatal(err)
	}
	if cfg.EmailSender != "smtp" || cfg.SMTPAddr != "localhost:1025" || cfg.EmailFrom != "no-reply@veea.local" {
		t.Fatalf("defaults: %q %q %q", cfg.EmailSender, cfg.SMTPAddr, cfg.EmailFrom)
	}
	if _, err := Load(with(map[string]string{EnvEmailSender: "fake"})); err != nil {
		t.Fatalf("fake sender: %v", err)
	}
	for name, env := range map[string]map[string]string{
		"unknown sender": {EnvEmailSender: "ses"},
		"remote smtp":    {EnvSMTPAddr: "smtp.example.com:25"},
		"smtp no port":   {EnvSMTPAddr: "localhost"},
		"from with name": {EnvEmailFrom: "Veea <no-reply@veea.local>"},
		"from not email": {EnvEmailFrom: "nobody"},
	} {
		if _, err := Load(with(env)); err == nil {
			t.Errorf("%s: expected an error", name)
		}
	}
}

func TestResendSettingsAndSecretHygiene(t *testing.T) {
	const key = "re_synthetic_config_key"
	for _, sender := range []string{"smtp", "fake"} {
		t.Run(sender+" ignores Resend key", func(t *testing.T) {
			cfg, err := Load(with(map[string]string{EnvEmailSender: sender, EnvResendAPIKey: "invalid private\nkey"}))
			if err != nil || cfg.ResendAPIKey != "" {
				t.Fatal("unused Resend credentials must not be loaded or validated")
			}
		})
	}
	for name, overrides := range map[string]map[string]string{
		"missing key":      {EnvEmailSender: "resend"},
		"invalid key":      {EnvEmailSender: "resend", EnvResendAPIKey: "private-key"},
		"header injection": {EnvEmailSender: "resend", EnvResendAPIKey: "re_private\r\nheader"},
		"invalid From":     {EnvEmailSender: "resend", EnvResendAPIKey: key, EnvEmailFrom: "private-not-an-email"},
	} {
		t.Run(name, func(t *testing.T) {
			_, err := Load(with(overrides))
			if err == nil || !strings.Contains(err.Error(), EnvResendAPIKey) || strings.Contains(err.Error(), "private") || strings.Contains(err.Error(), key) {
				t.Fatal("Resend setting validation failed or exposed a secret")
			}
		})
	}
	cfg, err := Load(with(map[string]string{EnvEmailSender: "resend", EnvResendAPIKey: key,
		EnvEmailFrom: "sender@example.test", EnvSMTPAddr: "unused-invalid-smtp"}))
	if err != nil || cfg.ResendAPIKey != key || cfg.EmailFrom != "sender@example.test" {
		t.Fatal("Resend settings were not loaded independently of SMTP")
	}
	var logs bytes.Buffer
	slog.New(slog.NewJSONHandler(&logs, nil)).Info("config", "config", cfg)
	if strings.Contains(logs.String(), key) || strings.Contains(logs.String(), "resend_api_key") || !strings.Contains(logs.String(), `"email_sender":"resend"`) {
		t.Fatal("configuration logging leaked the API key or lost the sender selection")
	}
}

func TestMetricsAddr(t *testing.T) {
	cfg, err := Load(with(nil))
	if err != nil || cfg.MetricsAddr != "127.0.0.1:9090" {
		t.Fatalf("default metrics address %q, %v", cfg.MetricsAddr, err)
	}
	if cfg, err := Load(with(map[string]string{EnvMetricsAddr: ":9100"})); err != nil || cfg.MetricsAddr != ":9100" {
		t.Fatalf("all-interfaces form must be accepted: %v", err)
	}
	for _, bad := range []string{"9090", "metrics.internal:9090", "127.0.0.1:", ":18386", "127.0.0.1:18386",
		"127.0.0.1:0", "127.0.0.1:99999", "127.0.0.1:http"} {
		if _, err := Load(with(map[string]string{EnvMetricsAddr: bad})); err == nil || !strings.Contains(err.Error(), EnvMetricsAddr) {
			t.Errorf("%q: expected an error naming %s, got %v", bad, EnvMetricsAddr, err)
		}
	}
}

func TestArgon2Settings(t *testing.T) {
	cfg, err := Load(with(nil))
	if err != nil || cfg.Argon2.MemoryKiB != 19456 || cfg.Argon2.Time != 2 || cfg.Argon2.Threads != 1 ||
		cfg.Argon2.SaltLen != 16 || cfg.Argon2.KeyLen != 32 {
		t.Fatalf("defaults %+v, %v", cfg.Argon2, err)
	}
	cfg, err = Load(with(map[string]string{EnvArgon2Memory: "65536", EnvArgon2Time: "3", EnvArgon2Threads: "2"}))
	if err != nil || cfg.Argon2.MemoryKiB != 65536 || cfg.Argon2.Time != 3 || cfg.Argon2.Threads != 2 {
		t.Fatalf("tuned up %+v, %v", cfg.Argon2, err)
	}
	// Equal cost with less memory and more passes is allowed (19456 × 2 = 9728 × 4).
	if _, err := Load(with(map[string]string{EnvArgon2Memory: "9728", EnvArgon2Time: "4"})); err != nil {
		t.Fatalf("an equal-cost trade must be accepted: %v", err)
	}
	for name, env := range map[string]map[string]string{
		"below the floor":   {EnvArgon2Memory: "8192"},
		"one pass":          {EnvArgon2Time: "1"},
		"not a number":      {EnvArgon2Memory: "lots"},
		"negative":          {EnvArgon2Time: "-1"},
		"zero threads":      {EnvArgon2Threads: "0"},
		"too many threads":  {EnvArgon2Threads: "300"},
		"memory over bound": {EnvArgon2Memory: "1048576"},
		// Equal cost on paper (2432 × 16 = 19456 × 2) but barely memory-hard.
		"too little memory": {EnvArgon2Memory: "2432", EnvArgon2Time: "16"},
	} {
		if _, err := Load(with(env)); err == nil || !strings.Contains(err.Error(), "VEEA_ARGON2") {
			t.Errorf("%s: expected a VEEA_ARGON2 error, got %v", name, err)
		}
	}
}

func TestMaintenanceDatabaseURLValidationAndRedaction(t *testing.T) {
	raw := "postgres://maintenance:throwaway-maintenance-password@localhost/local_test"
	cfg, err := Load(with(map[string]string{"VEEA_MAINTENANCE_DATABASE_URL": raw}))
	if err != nil {
		t.Fatal(err)
	}
	if cfg.MaintenanceDatabaseURL != raw {
		t.Fatal("maintenance URL not loaded")
	}
	var buf bytes.Buffer
	slog.New(slog.NewJSONHandler(&buf, nil)).Info("config", "config", cfg)
	if strings.Contains(buf.String(), "throwaway-maintenance-password") || strings.Contains(buf.String(), raw) {
		t.Fatal("maintenance credentials logged")
	}
	_, err = Load(with(map[string]string{"VEEA_MAINTENANCE_DATABASE_URL": "mysql://maintenance:throwaway-maintenance-password@localhost/db"}))
	if err == nil || strings.Contains(err.Error(), "throwaway-maintenance-password") {
		t.Fatal("invalid maintenance URL not safely rejected")
	}
}

func TestApplePurchaseConfigurationFailsClosedAndRedactsKeys(t *testing.T) {
	cfg, err := Load(with(nil))
	if err != nil || cfg.AppleVerifier != nil {
		t.Fatalf("default billing must be disabled: %v", err)
	}
	cfg, err = Load(with(map[string]string{"VEEA_APPLE_IAP_ENABLED": "false", "VEEA_APPLE_IAP_PRIVATE_KEY": "private-synthetic-value"}))
	if err != nil || cfg.AppleVerifier != nil {
		t.Fatal("explicit disabled ignored")
	}
	_, err = Load(with(map[string]string{"VEEA_APPLE_IAP_ENABLED": "true", "VEEA_APPLE_IAP_PRIVATE_KEY": "private-synthetic-value"}))
	if err == nil || strings.Contains(err.Error(), "private-synthetic-value") {
		t.Fatal("invalid purchase config accepted or exposed secret")
	}
	_, err = Load(with(map[string]string{"VEEA_APPLE_IAP_ENABLED": "yes"}))
	if err == nil {
		t.Fatal("invalid billing switch accepted")
	}
}
