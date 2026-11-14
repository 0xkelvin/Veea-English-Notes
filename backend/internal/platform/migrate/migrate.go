// Package migrate applies embedded goose migrations. It is up-only by design
// (TRD 01 §6.1): there is no down command.
package migrate

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"io/fs"

	"github.com/jackc/pgx/v5/stdlib"
	"github.com/pressly/goose/v3"
	"github.com/pressly/goose/v3/lock"
)

// Result summarizes a run.
type Result struct {
	Applied []int64 // versions applied by this run, in order
	Current int64   // highest applied version after the run (0 if none)
	Pending int     // migrations known but not applied (Status only)
}

func open(databaseURL string, fsys fs.FS) (*goose.Provider, *sql.DB, error) {
	cfg, err := pgxParse(databaseURL)
	if err != nil {
		return nil, nil, err
	}
	db := stdlib.OpenDB(*cfg)
	// A Postgres advisory lock makes concurrent runs (for example two deploy
	// jobs) take turns instead of racing. Retry every second for up to two minutes.
	locker, err := lock.NewPostgresSessionLocker(lock.WithLockTimeout(1, 120))
	if err != nil {
		_ = db.Close()
		return nil, nil, fmt.Errorf("migrate: create locker: %w", err)
	}
	p, err := goose.NewProvider(goose.DialectPostgres, db, fsys, goose.WithSessionLocker(locker))
	if err != nil {
		_ = db.Close()
		if errors.Is(err, goose.ErrNoMigrations) {
			return nil, nil, ErrNoMigrations
		}
		return nil, nil, fmt.Errorf("migrate: create provider: %w", err)
	}
	return p, db, nil
}

// ErrNoMigrations means the migration set contains no SQL files yet.
var ErrNoMigrations = errors.New("migrate: no migration files")

// Up applies all pending migrations. An empty migration set is not an error:
// it returns a zero Result so the foundation can ship before any schema.
func Up(ctx context.Context, databaseURL string, fsys fs.FS) (Result, error) {
	p, db, err := open(databaseURL, fsys)
	if errors.Is(err, ErrNoMigrations) {
		return Result{}, nil
	}
	if err != nil {
		return Result{}, err
	}
	defer db.Close()
	defer p.Close()

	results, err := p.Up(ctx)
	if err != nil {
		return Result{}, fmt.Errorf("migrate: up: %w", err)
	}
	var res Result
	for _, r := range results {
		res.Applied = append(res.Applied, r.Source.Version)
	}
	res.Current, err = p.GetDBVersion(ctx)
	if err != nil {
		return Result{}, fmt.Errorf("migrate: read version: %w", err)
	}
	return res, nil
}

// Status reports the current version and the number of pending migrations
// without changing the database schema.
func Status(ctx context.Context, databaseURL string, fsys fs.FS) (Result, error) {
	p, db, err := open(databaseURL, fsys)
	if errors.Is(err, ErrNoMigrations) {
		return Result{}, nil
	}
	if err != nil {
		return Result{}, err
	}
	defer db.Close()
	defer p.Close()

	statuses, err := p.Status(ctx)
	if err != nil {
		return Result{}, fmt.Errorf("migrate: status: %w", err)
	}
	var res Result
	for _, s := range statuses {
		if s.State == goose.StateApplied {
			if s.Source.Version > res.Current {
				res.Current = s.Source.Version
			}
		} else {
			res.Pending++
		}
	}
	return res, nil
}
