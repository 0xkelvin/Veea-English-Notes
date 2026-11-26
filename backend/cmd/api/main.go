// Command api runs the Veea HTTP service, its email outbox worker, the TRD 6.10 cleanup jobs and
// the internal metrics listener.
package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/app"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/identity"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/learning"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/lifecycle"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/maintenance"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/notify"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/config"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/db"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/httpx"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/logging"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/metrics"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/purchases"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}

func run() error {
	cfg, err := config.Load(os.LookupEnv)
	if err != nil {
		return fmt.Errorf("configuration:\n%w", err)
	}
	// Every log line passes the redacting handler (TRD 11.2).
	log := slog.New(logging.NewRedactingHandler(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: cfg.LogLevel})))

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	pool, err := db.NewPool(ctx, cfg.DatabaseURL, cfg.DBMaxConns)
	if err != nil {
		return err
	}
	defer pool.Close() // last: every background task below stops first

	m := metrics.New()
	m.InitEmailSend(notify.TemplateNames()) // TRD 08: failure series exist at 0 from startup

	// Background tasks. Each stops on every exit path before the pool closes: the worker lets
	// reserved sends finish and record; the cleanup runner interrupts a running job and releases
	// its advisory lock.
	worker, err := newOutboxWorker(cfg, pool, log, m)
	if err != nil {
		return err
	}
	maintenancePool := pool
	if cfg.MaintenanceDatabaseURL != "" {
		maintenancePool, err = db.NewPool(ctx, cfg.MaintenanceDatabaseURL, cfg.DBMaxConns)
		if err != nil {
			return err
		}
		defer maintenancePool.Close()
	}
	keys, err := notify.NewKeyring(cfg.OutboxKeys...)
	if err != nil {
		return err
	}
	digests, err := identity.NewEmailHMAC(cfg.EmailHMACKeys...)
	if err != nil {
		return err
	}
	rightsJobs := lifecycle.New(maintenancePool, nil, keys, digests, m, nil)
	cleanup, err := maintenance.New(maintenance.Config{Pool: maintenancePool, Logger: log.With("component", "cleanup"), AccountJob: rightsJobs.RunBatch, LearningJob: learning.Cleanup})
	if err != nil {
		return err
	}
	bgCtx, stopBackground := context.WithCancel(ctx)
	defer stopBackground()
	waitWorker := background(func() { _ = worker.Run(bgCtx) })
	waitCleanup := background(func() { _ = cleanup.Run(bgCtx) })
	defer func() {
		stopBackground()
		waitCleanup()
		waitWorker()
	}()

	var appleVerifier purchases.Verifier
	if cfg.AppleVerifier != nil {
		appleVerifier = cfg.AppleVerifier
	}
	handler, err := app.New(app.Options{
		AppleVerifier: appleVerifier, AppleEnvironment: cfg.AppleEnvironment, AppleAllowSandbox: cfg.AppleAllowSandbox,
		Pool: pool, ReadyTimeout: cfg.ReadyTimeout, Logger: log,
		EmailHMACKeys: cfg.EmailHMACKeys, OTPKeys: cfg.OTPKeys, OutboxKeys: cfg.OutboxKeys,
		TrustedProxies: cfg.TrustedProxies, Metrics: m, Argon2: cfg.Argon2,
	})
	if err != nil {
		return err
	}
	srv := httpx.NewServer(cfg.HTTPAddr, handler)
	metricsSrv := httpx.NewServer(cfg.MetricsAddr, m.Handler())
	errCh := make(chan error, 2)
	go func() { errCh <- srv.ListenAndServe() }()
	go func() { errCh <- fmt.Errorf("metrics listener: %w", metricsSrv.ListenAndServe()) }()
	log.Info("api started", "config", cfg)

	var runErr error
	select {
	case err := <-errCh:
		if !errors.Is(err, http.ErrServerClosed) {
			runErr = err
		}
	case <-ctx.Done():
	}

	log.Info("shutting down")
	shutdownCtx, cancel := context.WithTimeout(context.Background(), cfg.ShutdownTimeout)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil && runErr == nil {
		runErr = err
	}
	_ = metricsSrv.Shutdown(shutdownCtx)
	return runErr
}

// background runs fn in a goroutine and returns a function that waits for it to finish.
func background(fn func()) (wait func()) {
	done := make(chan struct{})
	go func() {
		defer close(done)
		fn()
	}()
	return func() { <-done }
}

// newOutboxWorker builds the email outbox worker (TRD 8.3) for the configured sender.
func newOutboxWorker(cfg config.Config, pool *pgxpool.Pool, log *slog.Logger, m *metrics.Metrics) (*notify.Worker, error) {
	keys, err := notify.NewKeyring(cfg.OutboxKeys...)
	if err != nil {
		return nil, err
	}
	var sender notify.Sender
	switch cfg.EmailSender {
	case "smtp":
		if sender, err = notify.NewSMTPSender(cfg.SMTPAddr, cfg.EmailFrom); err != nil {
			return nil, err
		}
	case "resend":
		if sender, err = notify.NewResendSender(cfg.ResendAPIKey, cfg.EmailFrom); err != nil {
			return nil, err
		}
	case "fake":
		log.Warn("email sender is fake: emails are kept in memory and never delivered")
		sender = &notify.FakeSender{}
	default:
		return nil, fmt.Errorf("unsupported email sender %q", cfg.EmailSender)
	}
	return notify.NewWorker(pool, keys, sender, notify.WorkerConfig{
		Logger: log.With("component", "outbox"), OnSend: m.EmailSend, OnStale: m.StaleResult,
	})
}
