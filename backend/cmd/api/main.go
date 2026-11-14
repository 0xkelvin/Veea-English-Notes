// Command api runs the Veea HTTP service.
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

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/notify"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/config"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/db"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/httpx"
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
	log := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: cfg.LogLevel}))

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	pool, err := db.NewPool(ctx, cfg.DatabaseURL, cfg.DBMaxConns)
	if err != nil {
		return err
	}
	defer pool.Close()

	worker, err := newOutboxWorker(cfg, pool, log)
	if err != nil {
		return err
	}
	workerCtx, stopWorker := context.WithCancel(ctx)
	workerDone := make(chan struct{})
	go func() {
		defer close(workerDone)
		_ = worker.Run(workerCtx)
	}()
	// On every exit path: stop claiming, let reserved sends finish and record, then return.
	defer func() {
		stopWorker()
		<-workerDone
	}()

	srv := httpx.NewServer(cfg.HTTPAddr, httpx.NewHandler(pool, cfg.ReadyTimeout))
	errCh := make(chan error, 1)
	go func() { errCh <- srv.ListenAndServe() }()
	log.Info("api started", "config", cfg)

	select {
	case err := <-errCh:
		if !errors.Is(err, http.ErrServerClosed) {
			return err
		}
		return nil
	case <-ctx.Done():
	}

	log.Info("shutting down")
	shutdownCtx, cancel := context.WithTimeout(context.Background(), cfg.ShutdownTimeout)
	defer cancel()
	return srv.Shutdown(shutdownCtx)
}

// newOutboxWorker builds the email outbox worker (TRD 8.3) for the configured sender.
func newOutboxWorker(cfg config.Config, pool *pgxpool.Pool, log *slog.Logger) (*notify.Worker, error) {
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
	case "fake":
		log.Warn("email sender is fake: emails are kept in memory and never delivered")
		sender = &notify.FakeSender{}
	default:
		return nil, fmt.Errorf("unsupported email sender %q", cfg.EmailSender)
	}
	return notify.NewWorker(pool, keys, sender, notify.WorkerConfig{Logger: log.With("component", "outbox")})
}
