package httpx

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

type fakePinger struct{ err error }

func (f fakePinger) Ping(context.Context) error { return f.err }

type blockingPinger struct{}

func (blockingPinger) Ping(ctx context.Context) error { <-ctx.Done(); return ctx.Err() }

func get(h http.Handler, path string, hdr ...string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(http.MethodGet, path, nil)
	for i := 0; i+1 < len(hdr); i += 2 {
		req.Header.Set(hdr[i], hdr[i+1])
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

func TestHealthzIgnoresDatabase(t *testing.T) {
	h := NewHandler(fakePinger{err: errors.New("down")}, time.Second)
	if rec := get(h, "/healthz"); rec.Code != http.StatusOK {
		t.Fatalf("status = %d", rec.Code)
	}
}

func TestReadyzOK(t *testing.T) {
	rec := get(NewHandler(fakePinger{}, time.Second), "/readyz")
	if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), `"ok"`) {
		t.Fatalf("status = %d body = %s", rec.Code, rec.Body)
	}
}

func TestReadyzUnavailableHidesCause(t *testing.T) {
	rec := get(NewHandler(fakePinger{err: errors.New("password=hunter2 refused")}, time.Second), "/readyz")
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("status = %d", rec.Code)
	}
	if ct := rec.Header().Get("Content-Type"); ct != "application/problem+json" {
		t.Fatalf("content type = %q", ct)
	}
	body := rec.Body.String()
	if strings.Contains(body, "hunter2") || !strings.Contains(body, `"code":"not_ready"`) {
		t.Fatalf("unexpected body: %s", body)
	}
}

func TestReadyzTimesOut(t *testing.T) {
	start := time.Now()
	rec := get(NewHandler(blockingPinger{}, 50*time.Millisecond), "/readyz")
	if rec.Code != http.StatusServiceUnavailable || time.Since(start) > 2*time.Second {
		t.Fatalf("status = %d after %s", rec.Code, time.Since(start))
	}
}

func TestRequestID(t *testing.T) {
	h := NewHandler(fakePinger{}, time.Second)
	if id := get(h, "/healthz").Header().Get("X-Request-Id"); len(id) != 24 {
		t.Fatalf("generated id = %q", id)
	}
	if id := get(h, "/healthz", "X-Request-Id", "client-req-1234").Header().Get("X-Request-Id"); id != "client-req-1234" {
		t.Fatalf("well-formed id not reused: %q", id)
	}
	if id := get(h, "/healthz", "X-Request-Id", "bad id\nx").Header().Get("X-Request-Id"); id == "bad id\nx" || len(id) != 24 {
		t.Fatalf("malformed id accepted: %q", id)
	}
}

func TestUnknownRouteAndMethod(t *testing.T) {
	h := NewHandler(fakePinger{}, time.Second)
	if rec := get(h, "/nope"); rec.Code != http.StatusNotFound {
		t.Fatalf("status = %d", rec.Code)
	}
	req := httptest.NewRequest(http.MethodPost, "/healthz", nil)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusMethodNotAllowed {
		t.Fatalf("status = %d", rec.Code)
	}
}
