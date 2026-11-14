// Package config loads and validates service configuration from the environment.
package config

import (
	"encoding/hex"
	"errors"
	"fmt"
	"log/slog"
	"net/netip"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/identity"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/clientip"
)

// Config is the validated runtime configuration.
//
// The OTP and outbox keys and the email sender belong to later tickets and are absent for now.
type Config struct {
	HTTPAddr        string
	DatabaseURL     string
	DBMaxConns      int32
	LogLevel        slog.Level
	ShutdownTimeout time.Duration
	ReadyTimeout    time.Duration

	// EmailHMACKeys holds the keys behind EmailHMAC, current first and optionally one previous
	// (TRD 13). The values are secrets and are never logged.
	EmailHMACKeys [][]byte
	// TrustedProxies are the networks whose X-Forwarded-For header is believed (TRD 10).
	// Empty means the header is ignored.
	TrustedProxies []netip.Prefix
}

// Defaults for optional settings.
const (
	DefaultHTTPAddr        = ":18386"
	DefaultDBMaxConns      = 10
	DefaultShutdownTimeout = 15 * time.Second
	DefaultReadyTimeout    = 2 * time.Second
)

// Environment variable names.
const (
	EnvHTTPAddr        = "VEEA_HTTP_ADDR"
	EnvDatabaseURL     = "VEEA_DATABASE_URL"
	EnvDBMaxConns      = "VEEA_DB_MAX_CONNS"
	EnvLogLevel        = "VEEA_LOG_LEVEL"
	EnvShutdownTimeout = "VEEA_SHUTDOWN_TIMEOUT"
	EnvReadyTimeout    = "VEEA_READY_TIMEOUT"
	EnvEmailHMACKey    = "VEEA_EMAIL_HMAC_KEY"
	EnvTrustedProxies  = "VEEA_TRUSTED_PROXIES"
)

// Load reads configuration through lookup (os.LookupEnv in production) and
// returns every validation problem at once.
func Load(lookup func(string) (string, bool)) (Config, error) {
	get := func(key, def string) string {
		if v, ok := lookup(key); ok && v != "" {
			return v
		}
		return def
	}

	var errs []error
	cfg := Config{
		HTTPAddr:    get(EnvHTTPAddr, DefaultHTTPAddr),
		DatabaseURL: get(EnvDatabaseURL, ""),
	}

	if cfg.DatabaseURL == "" {
		errs = append(errs, fmt.Errorf("%s is required", EnvDatabaseURL))
	} else if err := validateDatabaseURL(cfg.DatabaseURL); err != nil {
		// Never echo the URL: it may contain a password.
		errs = append(errs, fmt.Errorf("%s: %w", EnvDatabaseURL, err))
	}

	n, err := strconv.Atoi(get(EnvDBMaxConns, strconv.Itoa(DefaultDBMaxConns)))
	if err != nil || n < 1 || n > 200 {
		errs = append(errs, fmt.Errorf("%s must be an integer between 1 and 200", EnvDBMaxConns))
	}
	cfg.DBMaxConns = int32(n)

	if err := cfg.LogLevel.UnmarshalText([]byte(get(EnvLogLevel, "info"))); err != nil {
		errs = append(errs, fmt.Errorf("%s must be one of debug, info, warn, error", EnvLogLevel))
	}

	var derr error
	if cfg.ShutdownTimeout, derr = parseDuration(get(EnvShutdownTimeout, ""), DefaultShutdownTimeout); derr != nil {
		errs = append(errs, fmt.Errorf("%s: %w", EnvShutdownTimeout, derr))
	}
	if cfg.ReadyTimeout, derr = parseDuration(get(EnvReadyTimeout, ""), DefaultReadyTimeout); derr != nil {
		errs = append(errs, fmt.Errorf("%s: %w", EnvReadyTimeout, derr))
	}

	var kerr error
	if cfg.EmailHMACKeys, kerr = parseEmailHMACKeys(get(EnvEmailHMACKey, "")); kerr != nil {
		errs = append(errs, fmt.Errorf("%s: %w", EnvEmailHMACKey, kerr))
	}
	if cfg.TrustedProxies, kerr = clientip.ParseTrustedProxies(get(EnvTrustedProxies, "")); kerr != nil {
		errs = append(errs, fmt.Errorf("%s: %w", EnvTrustedProxies, kerr))
	}

	if len(errs) > 0 {
		return Config{}, errors.Join(errs...)
	}
	return cfg, nil
}

func parseDuration(s string, def time.Duration) (time.Duration, error) {
	if s == "" {
		return def, nil
	}
	d, err := time.ParseDuration(s)
	if err != nil || d <= 0 {
		return 0, errors.New("must be a positive duration such as 5s")
	}
	return d, nil
}

func validateDatabaseURL(raw string) error {
	u, err := url.Parse(raw)
	if err != nil {
		return errors.New("is not a valid URL")
	}
	if u.Scheme != "postgres" && u.Scheme != "postgresql" {
		return errors.New(`must use the "postgres" or "postgresql" scheme`)
	}
	return nil
}

// parseEmailHMACKeys parses "current[,previous]", each key hex encoded and at least
// identity.MinEmailHMACKeyBytes bytes long once decoded. Errors never include key material.
func parseEmailHMACKeys(raw string) ([][]byte, error) {
	if strings.TrimSpace(raw) == "" {
		return nil, errors.New("is required: current key as hex, optionally followed by the previous key after a comma")
	}
	items := strings.Split(raw, ",")
	if len(items) > 2 {
		return nil, errors.New("accepts at most two keys, current and previous")
	}
	keys := make([][]byte, 0, len(items))
	for i, item := range items {
		key, err := hex.DecodeString(strings.TrimSpace(item))
		if err != nil {
			return nil, fmt.Errorf("key %d is not valid hex", i+1)
		}
		if len(key) < identity.MinEmailHMACKeyBytes {
			return nil, fmt.Errorf("key %d is shorter than %d bytes (%d hex characters)",
				i+1, identity.MinEmailHMACKeyBytes, 2*identity.MinEmailHMACKeyBytes)
		}
		keys = append(keys, key)
	}
	return keys, nil
}

// LogValue implements slog.LogValuer. It omits the database URL and the keys so that
// logging a Config can never leak credentials.
func (c Config) LogValue() slog.Value {
	return slog.GroupValue(
		slog.String("http_addr", c.HTTPAddr),
		slog.Int("db_max_conns", int(c.DBMaxConns)),
		slog.String("log_level", c.LogLevel.String()),
		slog.String("shutdown_timeout", c.ShutdownTimeout.String()),
		slog.String("ready_timeout", c.ReadyTimeout.String()),
		slog.Int("email_hmac_keys", len(c.EmailHMACKeys)), // a count, never the keys
		slog.Int("trusted_proxies", len(c.TrustedProxies)),
	)
}
