//go:build integration

package integration

import (
	"context"
	"errors"
	"fmt"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/db/sqlc"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/pgtest"
)

// SQLSTATE codes used by the schema tests.
const (
	pgNotNull    = "23502"
	pgForeignKey = "23503"
	pgUnique     = "23505"
	pgCheck      = "23514"
)

func ptr[T any](v T) *T { return &v }

func newID() uuid.UUID {
	id, err := uuid.NewV7()
	if err != nil {
		panic(err)
	}
	return id
}

// migratedDB returns an isolated database with every production migration applied.
func migratedDB(t *testing.T) (*pgtest.DB, *sqlc.Queries) {
	t.Helper()
	d := pgtest.New(t)
	return d, sqlc.New(d.Pool)
}

// wantPgError fails unless err is a PostgreSQL error with the given SQLSTATE, and, when
// constraint is not empty, that constraint name.
func wantPgError(t *testing.T, err error, code, constraint string) {
	t.Helper()
	var pgErr *pgconn.PgError
	if !errors.As(err, &pgErr) {
		t.Fatalf("expected PostgreSQL error %s %q, got %v", code, constraint, err)
	}
	if pgErr.Code != code || (constraint != "" && pgErr.ConstraintName != constraint) {
		t.Fatalf("expected %s %q, got %s %q (%s)", code, constraint, pgErr.Code, pgErr.ConstraintName, pgErr.Message)
	}
}

func mustExec(t *testing.T, pool *pgxpool.Pool, sql string, args ...any) {
	t.Helper()
	if _, err := pool.Exec(context.Background(), sql, args...); err != nil {
		t.Fatalf("exec %q: %v", sql, err)
	}
}

func rowCount(t *testing.T, pool *pgxpool.Pool, sql string, args ...any) int {
	t.Helper()
	var n int
	if err := pool.QueryRow(context.Background(), sql, args...).Scan(&n); err != nil {
		t.Fatalf("count %q: %v", sql, err)
	}
	return n
}

func newUser(t *testing.T, q *sqlc.Queries) sqlc.User {
	t.Helper()
	id := newID()
	now := time.Now()
	u, err := q.InsertUserIfAbsent(context.Background(), sqlc.InsertUserIfAbsentParams{
		ID: id, Email: fmt.Sprintf("User-%s@Example.test", id), EmailNormalized: fmt.Sprintf("user-%s@example.test", id),
		EmailVerifiedAt: &now,
	})
	if err != nil {
		t.Fatalf("insert user: %v", err)
	}
	return u
}

func sessionParams(userID uuid.UUID) sqlc.InsertSessionParams {
	id := newID()
	now := time.Now()
	return sqlc.InsertSessionParams{
		ID: id, UserID: userID, AuthMethod: "password",
		AccessTokenHash: []byte("access-" + id.String()), AccessExpiresAt: now.Add(15 * time.Minute),
		RefreshTokenHash: []byte("refresh-" + id.String()), RefreshExpiresAt: now.Add(30 * 24 * time.Hour),
		AbsoluteExpiresAt: now.Add(90 * 24 * time.Hour), DeviceName: "Test phone", Platform: "ios",
	}
}

func newSession(t *testing.T, q *sqlc.Queries, userID uuid.UUID) sqlc.Session {
	t.Helper()
	s, err := q.InsertSession(context.Background(), sessionParams(userID))
	if err != nil {
		t.Fatalf("insert session: %v", err)
	}
	return s
}

func challengeParams(purpose, emailNormalized, delivery string) sqlc.InsertOTPChallengeParams {
	id := newID()
	p := sqlc.InsertOTPChallengeParams{
		ID: id, TokenHash: []byte("token-" + id.String()), Purpose: purpose,
		Email: emailNormalized, EmailNormalized: emailNormalized,
		CodeHash: []byte("code-" + id.String()), Delivery: delivery, MaxAttempts: 5,
		ExpiresAt: time.Now().Add(10 * time.Minute),
	}
	if purpose == "signup" {
		p.SignupMethod = ptr("otp")
	}
	return p
}

func newChallenge(t *testing.T, q *sqlc.Queries, p sqlc.InsertOTPChallengeParams) sqlc.OtpChallenge {
	t.Helper()
	c, err := q.InsertOTPChallenge(context.Background(), p)
	if err != nil {
		t.Fatalf("insert challenge: %v", err)
	}
	return c
}

func inTx(t *testing.T, pool *pgxpool.Pool) (pgx.Tx, *sqlc.Queries) {
	t.Helper()
	tx, err := pool.Begin(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = tx.Rollback(context.Background()) })
	return tx, sqlc.New(tx)
}
