// Package app wires the modules into the HTTP handler. cmd/api and the integration tests both
// build the router through New, so tests exercise the same routes and dependencies as the
// binary; they only swap the email sender, the randomness source and the limits.
package app

import (
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/netip"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/account"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/auth/httpapi"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/auth/otp"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/auth/password"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/auth/session"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/auth/signin"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/auth/signup"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/identity"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/notify"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/clientip"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/db/sqlc"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/httpx"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/metrics"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/ratelimit"
)

// Options are the handler's dependencies. Keys come from config.Config.
type Options struct {
	Pool           *pgxpool.Pool
	ReadyTimeout   time.Duration
	Logger         *slog.Logger
	EmailHMACKeys  [][]byte
	OTPKeys        [][]byte
	OutboxKeys     []notify.Key
	TrustedProxies []netip.Prefix

	// Hasher hashes and verifies passwords. Nil means an identity.Hasher with the approved
	// parameters. Tests wrap the real hasher to count Argon2id runs.
	Hasher signin.Verifier
	// Policy is the password policy. Nil means the embedded blocklist.
	Policy *identity.Policy
	// Rules overrides the TRD 10 limits. Nil means the defaults.
	Rules *ratelimit.Rules
	// Random overrides crypto/rand for codes and tokens (tests only).
	Random io.Reader
	// OnTxRetry is called when a transaction is retried after a deadlock (tests assert none).
	OnTxRetry func(sqlstate string)
	// Metrics receives the TRD 11.3 metrics. Nil disables them.
	Metrics *metrics.Metrics
	// Argon2 are the hash parameters for the default Hasher (VEEA_ARGON2_*). The zero value
	// means identity.DefaultParams. Ignored when Hasher is set.
	Argon2 identity.Params
}

// New builds the router with every Phase 1 route implemented so far.
func New(o Options) (http.Handler, error) {
	if o.Pool == nil {
		return nil, errors.New("app: a database pool is required")
	}
	if o.Logger == nil {
		o.Logger = slog.New(slog.DiscardHandler)
	}
	m := o.Metrics
	userRetry := o.OnTxRetry
	o.OnTxRetry = func(code string) {
		m.TxRetry(code)
		if userRetry != nil {
			userRetry(code)
		}
	}
	if o.Argon2 == (identity.Params{}) {
		o.Argon2 = identity.DefaultParams
	}
	emailHMAC, err := identity.NewEmailHMAC(o.EmailHMACKeys...)
	if err != nil {
		return nil, err
	}
	codes, err := otp.NewCodeKeys(o.OTPKeys...)
	if err != nil {
		return nil, err
	}
	keyring, err := notify.NewKeyring(o.OutboxKeys...)
	if err != nil {
		return nil, err
	}
	if o.Hasher == nil {
		if o.Hasher, err = identity.NewHasher(identity.HasherConfig{Params: o.Argon2, ObserveWait: m.Argon2Wait}); err != nil {
			return nil, err
		}
	}
	if o.Policy == nil {
		blocklist, err := identity.DefaultBlocklist()
		if err != nil {
			return nil, err
		}
		o.Policy = identity.NewPolicy(blocklist)
	}

	otpSvc, err := otp.NewService(otp.Config{
		Pool: o.Pool, Codes: codes, EmailHMAC: emailHMAC, Outbox: notify.NewOutbox(keyring), Rules: o.Rules,
		Random: o.Random, Logger: o.Logger.With("component", "otp"), OnTxRetry: o.OnTxRetry, Metrics: m,
	})
	if err != nil {
		return nil, err
	}
	signupSvc, err := signup.New(signup.Config{
		Pool: o.Pool, OTP: otpSvc, Hasher: o.Hasher, Policy: o.Policy, Rules: o.Rules, Random: o.Random, Metrics: m,
	})
	if err != nil {
		return nil, err
	}
	signinSvc, err := signin.New(signin.Config{
		Pool: o.Pool, OTP: otpSvc, Hasher: o.Hasher, EmailHMAC: emailHMAC, Rules: o.Rules, Random: o.Random,
		Logger: o.Logger.With("component", "signin"), OnTxRetry: o.OnTxRetry, Metrics: m,
	})
	if err != nil {
		return nil, err
	}
	outbox := notify.NewOutbox(keyring)
	passwordSvc, err := password.New(password.Config{
		Pool: o.Pool, OTP: otpSvc, Outbox: outbox, Hasher: o.Hasher, Policy: o.Policy, Rules: o.Rules,
		Logger: o.Logger.With("component", "password"), OnTxRetry: o.OnTxRetry, Metrics: m,
	})
	if err != nil {
		return nil, err
	}
	sessions, err := session.NewService(session.Config{
		Pool: o.Pool, Rules: o.Rules, Random: o.Random, Logger: o.Logger.With("component", "session"), OnTxRetry: o.OnTxRetry,
		Metrics: m,
	})
	if err != nil {
		return nil, err
	}
	auth := &httpapi.Handlers{Signup: signupSvc, Signin: signinSvc, Password: passwordSvc, Sessions: sessions,
		Account: account.New(o.Pool, otpSvc, outbox, m, o.OnTxRetry),
		Limiter: ratelimit.NewLimiter(o.Pool), Metrics: m, IPs: clientip.New(o.TrustedProxies),
		Log: o.Logger.With("component", "http")}
	m.RegisterOutboxPending(sqlc.New(o.Pool).CountPendingOutbox)
	return httpx.NewHandler(o.Pool, o.ReadyTimeout, auth.Mount), nil
}
