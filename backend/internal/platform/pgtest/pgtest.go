// Package pgtest is the disposable PostgreSQL harness for integration tests.
//
// It needs VEEA_TEST_DATABASE_URL pointing at a throwaway PostgreSQL on this
// machine. Each test gets its own database, cloned from a template that already
// has the production migrations applied. The harness refuses any non-local host
// so tests can never touch a deployed server.
package pgtest

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io/fs"
	"net"
	"net/url"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/migrate"
	"github.com/0xkelvin/Veea-English-Notes/backend/migrations"
)

// EnvURL names the variable that holds the admin connection URL.
const EnvURL = "VEEA_TEST_DATABASE_URL"

// templateLockKey serializes template creation across parallel test packages.
const templateLockKey int64 = 0x5645_4541_5445_5354 // "VEEATEST"

// DB is one disposable database.
type DB struct {
	Name string
	URL  string
	Pool *pgxpool.Pool
}

// New creates an isolated database for t, cloned from the migrated template. It
// skips the test if EnvURL is unset and fails it if the URL is not local.
func New(t *testing.T) *DB {
	t.Helper()
	admin := adminURL(t)
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	tpl, err := ensureTemplate(ctx, admin, migrations.FS)
	if err != nil {
		t.Fatalf("pgtest: template: %v", err)
	}
	name := "veea_t_" + randomSuffix()
	if err := exec(ctx, admin, fmt.Sprintf(`CREATE DATABASE %s TEMPLATE %s`, quote(name), quote(tpl))); err != nil {
		t.Fatalf("pgtest: create database: %v", err)
	}
	return open(t, admin, name)
}

// NewEmpty creates an isolated database with nothing applied, for tests of the
// migration runner itself.
func NewEmpty(t *testing.T) *DB {
	t.Helper()
	admin := adminURL(t)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	name := "veea_t_" + randomSuffix()
	if err := exec(ctx, admin, fmt.Sprintf(`CREATE DATABASE %s`, quote(name))); err != nil {
		t.Fatalf("pgtest: create database: %v", err)
	}
	return open(t, admin, name)
}

func open(t *testing.T, admin, name string) *DB {
	t.Helper()
	u := withDatabase(admin, name)
	pool, err := pgxpool.New(context.Background(), u)
	if err != nil {
		t.Fatalf("pgtest: open pool: %v", errors.New("connection failed"))
	}
	t.Cleanup(func() {
		pool.Close()
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		if err := exec(ctx, admin, fmt.Sprintf(`DROP DATABASE IF EXISTS %s WITH (FORCE)`, quote(name))); err != nil {
			t.Errorf("pgtest: drop database %s: %v", name, err)
		}
	})
	return &DB{Name: name, URL: u, Pool: pool}
}

func adminURL(t *testing.T) string {
	t.Helper()
	raw := os.Getenv(EnvURL)
	if raw == "" {
		t.Skipf("%s is not set; skipping PostgreSQL integration test", EnvURL)
	}
	if err := RequireLocal(raw); err != nil {
		t.Fatalf("pgtest: %v", err)
	}
	return raw
}

// RequireLocal returns an error unless the URL targets this machine: a
// loopback address, "localhost", or a unix socket directory.
func RequireLocal(raw string) error {
	u, err := url.Parse(raw)
	if err != nil {
		return errors.New(EnvURL + " is not a valid URL")
	}
	host := u.Hostname()
	if host == "" {
		// No host means a unix socket in the default location, or ?host=/dir.
		if h := u.Query().Get("host"); h != "" && !strings.HasPrefix(h, "/") {
			host = h
		} else {
			return nil
		}
	}
	if strings.HasPrefix(host, "/") || host == "localhost" {
		return nil
	}
	if ip := net.ParseIP(host); ip != nil && ip.IsLoopback() {
		return nil
	}
	return errors.New(EnvURL + " must point at a local PostgreSQL (localhost, a loopback IP or a unix socket); refusing to run tests against a remote host")
}

// ensureTemplate returns the name of a migrated template database, creating it
// if needed. The name embeds a hash of the migration set, so changing a
// migration yields a fresh template instead of a stale one.
func ensureTemplate(ctx context.Context, admin string, fsys fs.FS) (string, error) {
	hash, err := hashFS(fsys)
	if err != nil {
		return "", err
	}
	name := "veea_tpl_" + hash[:12]

	conn, err := pgx.Connect(ctx, admin)
	if err != nil {
		return "", errors.New("cannot connect to the test PostgreSQL (is it running?)")
	}
	defer conn.Close(ctx)

	// Other test packages run in parallel; take turns building the template.
	if _, err := conn.Exec(ctx, `SELECT pg_advisory_lock($1)`, templateLockKey); err != nil {
		return "", err
	}
	defer conn.Exec(context.Background(), `SELECT pg_advisory_unlock($1)`, templateLockKey) //nolint:errcheck

	var exists bool
	if err := conn.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM pg_database WHERE datname = $1)`, name).Scan(&exists); err != nil {
		return "", err
	}
	if exists {
		return name, nil
	}

	// Build under a temporary name and rename, so a crash never leaves a
	// half-migrated database under the final template name.
	building := name + "_building"
	if _, err := conn.Exec(ctx, fmt.Sprintf(`DROP DATABASE IF EXISTS %s WITH (FORCE)`, quote(building))); err != nil {
		return "", err
	}
	if _, err := conn.Exec(ctx, fmt.Sprintf(`CREATE DATABASE %s`, quote(building))); err != nil {
		return "", err
	}
	if _, err := migrate.Up(ctx, withDatabase(admin, building), fsys); err != nil {
		return "", err
	}
	if _, err := conn.Exec(ctx, fmt.Sprintf(`ALTER DATABASE %s RENAME TO %s`, quote(building), quote(name))); err != nil {
		return "", err
	}
	return name, nil
}

func hashFS(fsys fs.FS) (string, error) {
	h := sha256.New()
	err := fs.WalkDir(fsys, ".", func(p string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() || !strings.HasSuffix(p, ".sql") {
			return err
		}
		b, err := fs.ReadFile(fsys, p)
		if err != nil {
			return err
		}
		h.Write([]byte(p))
		h.Write([]byte{0})
		h.Write(b)
		h.Write([]byte{0})
		return nil
	})
	return hex.EncodeToString(h.Sum(nil)), err
}

func exec(ctx context.Context, admin, sql string) error {
	conn, err := pgx.Connect(ctx, admin)
	if err != nil {
		return errors.New("cannot connect to the test PostgreSQL (is it running?)")
	}
	defer conn.Close(ctx)
	_, err = conn.Exec(ctx, sql)
	return err
}

func withDatabase(raw, name string) string {
	u, _ := url.Parse(raw)
	u.Path = "/" + name
	return u.String()
}

func quote(ident string) string { return pgx.Identifier{ident}.Sanitize() }

func randomSuffix() string {
	var b [6]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic(err) // crypto/rand does not fail on supported platforms
	}
	return hex.EncodeToString(b[:])
}
