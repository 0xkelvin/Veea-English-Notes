// Package db creates the PostgreSQL connection pool.
package db

import (
	"context"
	"errors"

	"github.com/jackc/pgx/v5/pgxpool"
)

// NewPool builds a pgx pool. Connections are opened lazily, so a database that
// is down at startup shows up as "not ready" instead of a crash loop.
func NewPool(ctx context.Context, databaseURL string, maxConns int32) (*pgxpool.Pool, error) {
	cfg, err := pgxpool.ParseConfig(databaseURL)
	if err != nil {
		// pgx errors can embed the URL; return a fixed message instead.
		return nil, errors.New("db: invalid database URL")
	}
	if maxConns > 0 {
		cfg.MaxConns = maxConns
	}
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return nil, errors.New("db: create pool failed")
	}
	return pool, nil
}
