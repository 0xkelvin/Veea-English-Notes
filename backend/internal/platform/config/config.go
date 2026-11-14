// Package config loads and validates service configuration from the environment.
package config

import (
	"encoding/hex"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/netip"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/auth/otp"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/identity"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/notify"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/clientip"
)

// Config is the validated runtime configuration.
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
	// OTPKeys hold the keys behind the stored code hashes, HMAC(key, challenge_id || code),
	// current first and optionally one previous (TRD 4.2, 13). Secrets, never logged.
	OTPKeys [][]byte
	// TrustedProxies are the networks whose X-Forwarded-For header is believed (TRD 10).
	// Empty means the header is ignored.
	TrustedProxies []netip.Prefix

	// OutboxKeys encrypt email payloads, current first (TRD 8.2, 13). Secrets, never logged.
	OutboxKeys []notify.Key
	// EmailSender selects the delivery backend: "smtp" (local Mailpit) or "fake" (tests). The
	// production provider is still open (TRD R12).
	EmailSender string
	SMTPAddr    string
	EmailFrom   string

	// MetricsAddr is the internal Prometheus listener (TRD 11.3, 13).
	MetricsAddr string
	// Argon2 are the password hash parameters (TRD 9.2, 13).
	Argon2 identity.Params
}

// Defaults for optional settings.
const (
	DefaultHTTPAddr        = ":18386"
	DefaultDBMaxConns      = 10
	DefaultShutdownTimeout = 15 * time.Second
	DefaultReadyTimeout    = 2 * time.Second
	DefaultEmailSender     = "smtp"
	DefaultSMTPAddr        = "localhost:1025"
	DefaultEmailFrom       = "no-reply@veea.local"
	DefaultMetricsAddr     = "127.0.0.1:9090"
	// MinArgon2MemoryKiB is the least memory accepted for Argon2id (7 MiB).
	MinArgon2MemoryKiB = 7 * 1024
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
	EnvOTPKey          = "VEEA_OTP_KEY"
	EnvTrustedProxies  = "VEEA_TRUSTED_PROXIES"
	EnvOutboxKey       = "VEEA_OUTBOX_KEY"
	EnvEmailSender     = "VEEA_EMAIL_SENDER"
	EnvSMTPAddr        = "VEEA_SMTP_ADDR"
	EnvEmailFrom       = "VEEA_EMAIL_FROM"
	EnvMetricsAddr     = "VEEA_METRICS_ADDR"
	EnvArgon2Memory    = "VEEA_ARGON2_MEMORY_KIB"
	EnvArgon2Time      = "VEEA_ARGON2_TIME"
	EnvArgon2Threads   = "VEEA_ARGON2_THREADS"
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
	if cfg.EmailHMACKeys, kerr = parseHexKeys(get(EnvEmailHMACKey, ""), identity.MinEmailHMACKeyBytes); kerr != nil {
		errs = append(errs, fmt.Errorf("%s: %w", EnvEmailHMACKey, kerr))
	}
	if cfg.OTPKeys, kerr = parseHexKeys(get(EnvOTPKey, ""), otp.MinKeyBytes); kerr != nil {
		errs = append(errs, fmt.Errorf("%s: %w", EnvOTPKey, kerr))
	}
	if cfg.TrustedProxies, kerr = clientip.ParseTrustedProxies(get(EnvTrustedProxies, "")); kerr != nil {
		errs = append(errs, fmt.Errorf("%s: %w", EnvTrustedProxies, kerr))
	}
	if cfg.OutboxKeys, kerr = parseOutboxKeys(get(EnvOutboxKey, "")); kerr != nil {
		errs = append(errs, fmt.Errorf("%s: %w", EnvOutboxKey, kerr))
	}
	cfg.EmailSender = get(EnvEmailSender, DefaultEmailSender)
	cfg.SMTPAddr = get(EnvSMTPAddr, DefaultSMTPAddr)
	cfg.EmailFrom = get(EnvEmailFrom, DefaultEmailFrom)
	switch cfg.EmailSender {
	case "fake":
	case "smtp":
		if _, err := notify.NewSMTPSender(cfg.SMTPAddr, cfg.EmailFrom); err != nil {
			errs = append(errs, fmt.Errorf("%s / %s: %w", EnvSMTPAddr, EnvEmailFrom, err))
		}
	default:
		errs = append(errs, fmt.Errorf("%s must be smtp or fake (the production provider is not chosen yet)", EnvEmailSender))
	}

	cfg.MetricsAddr = get(EnvMetricsAddr, DefaultMetricsAddr)
	if err := validateMetricsAddr(cfg.MetricsAddr, cfg.HTTPAddr); err != nil {
		errs = append(errs, fmt.Errorf("%s: %w", EnvMetricsAddr, err))
	}

	var aerr error
	if cfg.Argon2, aerr = parseArgon2(get); aerr != nil {
		errs = append(errs, aerr)
	}

	if len(errs) > 0 {
		return Config{}, errors.Join(errs...)
	}
	return cfg, nil
}

// validateMetricsAddr requires host:port with an IP address, localhost or an empty host (all
// interfaces), a port from 1 to 65535, and no overlap with the API listener.
func validateMetricsAddr(addr, httpAddr string) error {
	host, port, err := net.SplitHostPort(addr)
	if err != nil || (host != "" && host != "localhost" && net.ParseIP(host) == nil) {
		return errors.New("must be host:port with an IP address or localhost, such as 127.0.0.1:9090")
	}
	p, err := strconv.ParseUint(port, 10, 16)
	if err != nil || p == 0 {
		return errors.New("port must be 1 to 65535")
	}
	if hh, hp, err := net.SplitHostPort(httpAddr); err == nil && hp == port && hostsOverlap(host, hh) {
		return fmt.Errorf("must not share a port with %s", EnvHTTPAddr)
	}
	return nil
}

// hostsOverlap reports whether two listen hosts could bind the same interface.
func hostsOverlap(a, b string) bool {
	wildcard := func(h string) bool { return h == "" || h == "0.0.0.0" || h == "::" }
	return a == b || wildcard(a) || wildcard(b)
}

// parseArgon2 reads VEEA_ARGON2_MEMORY_KIB, _TIME and _THREADS (defaults 19456, 2, 1). The
// parameters must pass identity.Params.Validate; memory × time must be at least the approved
// default's (19456 KiB × 2); and memory must be at least MinArgon2MemoryKiB, the smallest
// memory in the OWASP equivalent-cost table (7 MiB with t = 5). So the cost can be tuned up or
// traded between memory and passes, but never below the approved floor or into a setting that
// is barely memory-hard (TRD 9.2).
func parseArgon2(get func(key, def string) string) (identity.Params, error) {
	p := identity.DefaultParams
	var errs []error
	read := func(env string, def uint64, bits int) uint64 {
		v, err := strconv.ParseUint(get(env, strconv.FormatUint(def, 10)), 10, bits)
		if err != nil {
			errs = append(errs, fmt.Errorf("%s must be a positive integer", env))
			return def
		}
		return v
	}
	p.MemoryKiB = uint32(read(EnvArgon2Memory, uint64(p.MemoryKiB), 32))
	p.Time = uint32(read(EnvArgon2Time, uint64(p.Time), 32))
	p.Threads = uint8(read(EnvArgon2Threads, uint64(p.Threads), 8))
	if len(errs) > 0 {
		return identity.Params{}, errors.Join(errs...)
	}
	if err := p.Validate(); err != nil {
		return identity.Params{}, fmt.Errorf("VEEA_ARGON2_*: %w", err)
	}
	if p.MemoryKiB < MinArgon2MemoryKiB {
		return identity.Params{}, fmt.Errorf("VEEA_ARGON2_MEMORY_KIB must be at least %d", MinArgon2MemoryKiB)
	}
	floor := uint64(identity.DefaultParams.MemoryKiB) * uint64(identity.DefaultParams.Time)
	if uint64(p.MemoryKiB)*uint64(p.Time) < floor {
		return identity.Params{}, fmt.Errorf("VEEA_ARGON2_*: memory × time must be at least %d KiB × %d (the approved cost)",
			identity.DefaultParams.MemoryKiB, identity.DefaultParams.Time)
	}
	return p, nil
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

// parseOutboxKeys parses "id:hex[,id:hex]" (TRD 13), current first. Ids are 1 to 32767 and
// unique; each key is exactly 32 bytes (64 hex characters). Errors never include key material.
func parseOutboxKeys(raw string) ([]notify.Key, error) {
	if strings.TrimSpace(raw) == "" {
		return nil, errors.New("is required: id:hexkey, optionally followed by more id:hexkey entries after commas, current first")
	}
	var keys []notify.Key
	seen := map[int16]bool{}
	for i, item := range strings.Split(raw, ",") {
		idText, keyText, ok := strings.Cut(strings.TrimSpace(item), ":")
		if !ok {
			return nil, fmt.Errorf("entry %d must be id:hexkey", i+1)
		}
		id, err := strconv.ParseInt(idText, 10, 16)
		if err != nil || id < 1 {
			return nil, fmt.Errorf("entry %d: id must be a number from 1 to 32767", i+1)
		}
		if seen[int16(id)] {
			return nil, fmt.Errorf("entry %d: id %d is used twice", i+1, id)
		}
		seen[int16(id)] = true
		key, err := hex.DecodeString(keyText)
		if err != nil {
			return nil, fmt.Errorf("entry %d: key is not valid hex", i+1)
		}
		if len(key) != notify.KeyBytes {
			return nil, fmt.Errorf("entry %d: key must be exactly %d bytes (%d hex characters)", i+1, notify.KeyBytes, 2*notify.KeyBytes)
		}
		keys = append(keys, notify.Key{ID: int16(id), Key: key})
	}
	return keys, nil
}

// parseHexKeys parses "current[,previous]", each key hex encoded and at least minBytes long
// once decoded (VEEA_EMAIL_HMAC_KEY, VEEA_OTP_KEY). Errors never include key material.
func parseHexKeys(raw string, minBytes int) ([][]byte, error) {
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
		if len(key) < minBytes {
			return nil, fmt.Errorf("key %d is shorter than %d bytes (%d hex characters)", i+1, minBytes, 2*minBytes)
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
		slog.Int("otp_keys", len(c.OTPKeys)),              // a count, never the keys
		slog.Int("trusted_proxies", len(c.TrustedProxies)),
		slog.Int("outbox_keys", len(c.OutboxKeys)), // a count, never the keys
		slog.String("email_sender", c.EmailSender),
		slog.String("smtp_addr", c.SMTPAddr),
		slog.String("email_from", c.EmailFrom),
		slog.String("metrics_addr", c.MetricsAddr),
		slog.Group("argon2", slog.Uint64("memory_kib", uint64(c.Argon2.MemoryKiB)),
			slog.Uint64("time", uint64(c.Argon2.Time)), slog.Uint64("threads", uint64(c.Argon2.Threads))),
	)
}
