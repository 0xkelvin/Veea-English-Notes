//go:build integration

package integration

import (
	"context"
	"io/fs"
	"net/http"
	"net/http/httptest"
	"testing"
	"testing/fstest"
	"time"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/db"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/httpx"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/migrate"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/pgtest"
)

func TestPoolConnects(t *testing.T) {
	d := pgtest.New(t)
	pool, err := db.NewPool(context.Background(), d.URL, 3)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	var one int
	if err := pool.QueryRow(context.Background(), "SELECT 1").Scan(&one); err != nil || one != 1 {
		t.Fatalf("select 1: %v %d", err, one)
	}
	if got := pool.Config().MaxConns; got != 3 {
		t.Fatalf("MaxConns = %d", got)
	}
}

func TestReadinessReflectsDatabase(t *testing.T) {
	d := pgtest.New(t)
	pool, err := db.NewPool(context.Background(), d.URL, 2)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	h := httpx.NewHandler(pool, 2*time.Second)

	status := func() int {
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/readyz", nil))
		return rec.Code
	}
	if got := status(); got != http.StatusOK {
		t.Fatalf("ready with database up: %d", got)
	}
	// A closed pool stands in for an unreachable database.
	pool.Close()
	if got := status(); got != http.StatusServiceUnavailable {
		t.Fatalf("ready with pool closed: %d", got)
	}
}

func TestReadinessWithUnreachableDatabase(t *testing.T) {
	// Port 1 on loopback: nothing listens, so connecting fails quickly.
	pool, err := db.NewPool(context.Background(), "postgres://u:p@127.0.0.1:1/db?connect_timeout=1", 1)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	rec := httptest.NewRecorder()
	httpx.NewHandler(pool, time.Second).ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/readyz", nil))
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("status = %d", rec.Code)
	}
}

func TestHarnessGivesIsolatedDatabases(t *testing.T) {
	a, b := pgtest.New(t), pgtest.New(t)
	if a.Name == b.Name {
		t.Fatal("databases share a name")
	}
	ctx := context.Background()
	if _, err := a.Pool.Exec(ctx, "CREATE TABLE marker (id int)"); err != nil {
		t.Fatal(err)
	}
	var n int
	if err := b.Pool.QueryRow(ctx, "SELECT count(*) FROM pg_tables WHERE tablename = 'marker'").Scan(&n); err != nil || n != 0 {
		t.Fatalf("table leaked into the other database: %v %d", err, n)
	}
}

func TestHarnessDropsDatabaseOnCleanup(t *testing.T) {
	var name string
	t.Run("inner", func(t *testing.T) { name = pgtest.New(t).Name })

	probe := pgtest.New(t)
	var n int
	err := probe.Pool.QueryRow(context.Background(),
		"SELECT count(*) FROM pg_database WHERE datname = $1", name).Scan(&n)
	if err != nil || n != 0 {
		t.Fatalf("database %s still exists: %v %d", name, err, n)
	}
}

func testMigrations() fs.FS {
	return fstest.MapFS{
		"00001_a.sql": {Data: []byte("-- +goose Up\nCREATE TABLE IF NOT EXISTS a (id int);\n")},
		"00002_b.sql": {Data: []byte("-- +goose Up\nCREATE TABLE IF NOT EXISTS b (id int);\n")},
	}
}

func TestMigrateUpIsIdempotentAndStatusReports(t *testing.T) {
	d := pgtest.NewEmpty(t)
	ctx := context.Background()

	st, err := migrate.Status(ctx, d.URL, testMigrations())
	if err != nil || st.Pending != 2 || st.Current != 0 {
		t.Fatalf("status before: %+v %v", st, err)
	}
	res, err := migrate.Up(ctx, d.URL, testMigrations())
	if err != nil || len(res.Applied) != 2 || res.Current != 2 {
		t.Fatalf("first up: %+v %v", res, err)
	}
	res, err = migrate.Up(ctx, d.URL, testMigrations())
	if err != nil || len(res.Applied) != 0 || res.Current != 2 {
		t.Fatalf("second up: %+v %v", res, err)
	}
	st, err = migrate.Status(ctx, d.URL, testMigrations())
	if err != nil || st.Pending != 0 || st.Current != 2 {
		t.Fatalf("status after: %+v %v", st, err)
	}
	var n int
	err = d.Pool.QueryRow(ctx, "SELECT count(*) FROM pg_tables WHERE tablename IN ('a','b')").Scan(&n)
	if err != nil || n != 2 {
		t.Fatalf("tables: %v %d", err, n)
	}
}

func TestMigrateConcurrentRunsTakeTurns(t *testing.T) {
	d := pgtest.NewEmpty(t)
	ctx := context.Background()
	type out struct {
		res migrate.Result
		err error
	}
	ch := make(chan out, 4)
	for i := 0; i < 4; i++ {
		go func() {
			r, err := migrate.Up(ctx, d.URL, testMigrations())
			ch <- out{r, err}
		}()
	}
	applied := 0
	for i := 0; i < 4; i++ {
		o := <-ch
		if o.err != nil {
			t.Fatal(o.err)
		}
		applied += len(o.res.Applied)
	}
	if applied != 2 {
		t.Fatalf("each migration must be applied exactly once, applied=%d", applied)
	}
}

func TestMigrateFailureLeavesNoPartialMigration(t *testing.T) {
	d := pgtest.NewEmpty(t)
	bad := fstest.MapFS{
		"00001_bad.sql": {Data: []byte("-- +goose Up\nCREATE TABLE IF NOT EXISTS ok_t (id int);\nSELECT * FROM does_not_exist;\n")},
	}
	if _, err := migrate.Up(context.Background(), d.URL, bad); err == nil {
		t.Fatal("expected failure")
	}
	var n int
	err := d.Pool.QueryRow(context.Background(), "SELECT count(*) FROM pg_tables WHERE tablename = 'ok_t'").Scan(&n)
	if err != nil || n != 0 {
		t.Fatalf("partial migration persisted: %v %d", err, n)
	}
}

func TestMigrateErrorHidesDatabaseURL(t *testing.T) {
	_, err := migrate.Up(context.Background(), "postgres://u:hunter2@127.0.0.1:1/db?connect_timeout=1", testMigrations())
	if err == nil {
		t.Fatal("expected connection error")
	}
	if s := err.Error(); len(s) == 0 || contains(s, "hunter2") {
		t.Fatalf("error leaks credentials: %s", s)
	}
}

func contains(s, sub string) bool {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}
