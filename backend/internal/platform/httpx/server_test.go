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

func TestTokenShapedRequestIDIsReplaced(t *testing.T) {
	h := NewHandler(fakePinger{}, time.Second)
	for _, id := range []string{"vct_abcdefgh", "xx-VAT_abcdef", "vrt_0123456789"} {
		if got := get(h, "/healthz", "X-Request-Id", id).Header().Get("X-Request-Id"); got == id || len(got) != 24 {
			t.Fatalf("token-shaped id %q was reused: %q", id, got)
		}
	}
}

func TestMountedRoutesShareTheMiddleware(t *testing.T) {
	h := NewHandler(fakePinger{}, time.Second, func(mux *http.ServeMux) {
		mux.HandleFunc("GET /v1/x", func(w http.ResponseWriter, _ *http.Request) {
			WriteProblem(w, http.StatusConflict, CodeSignupUnavailable, map[string]any{"violations": []string{"a"}, "code": "overridden"})
		})
	})
	rec := get(h, "/v1/x")
	body := rec.Body.String()
	if rec.Code != http.StatusConflict || rec.Header().Get("X-Request-Id") == "" ||
		!strings.Contains(body, `"code":"signup_unavailable"`) || !strings.Contains(body, `"violations":["a"]`) ||
		!strings.Contains(body, `"request_id":"`+rec.Header().Get("X-Request-Id")+`"`) {
		t.Fatalf("unexpected problem: %d %s", rec.Code, body)
	}
}

func TestWriteProblemNeverEmitsAnUnknownCode(t *testing.T) {
	rec := httptest.NewRecorder()
	WriteProblem(rec, http.StatusBadRequest, "leaked detail: pq error")
	if strings.Contains(rec.Body.String(), "leaked") || !strings.Contains(rec.Body.String(), `"code":"internal_error"`) {
		t.Fatalf("unknown codes must fall back to internal_error: %s", rec.Body)
	}
}

func TestWriteRateLimitedSetsRetryAfter(t *testing.T) {
	rec := httptest.NewRecorder()
	WriteRateLimited(rec, 0)
	if rec.Code != http.StatusTooManyRequests || rec.Header().Get("Retry-After") != "1" {
		t.Fatalf("status %d, Retry-After %q", rec.Code, rec.Header().Get("Retry-After"))
	}
}

func TestDecodeJSONIsStrict(t *testing.T) {
	type body struct {
		Email string `json:"email"`
	}
	cases := map[string]bool{
		`{"email":"a@example.test"}`:              true,
		`  {"email":"a@example.test"}  ` + "\n":   true,
		`{"email":"a@example.test","extra":1}`:    false,
		`{"email":"a@example.test"}{"email":"b"}`: false,
		`{"email":"a@example.test"} x`:            false,
		`[]`:                                      false,
		``:                                        false,
		`{"email":` + strings.Repeat(" ", MaxBodyBytes) + `"a"}`: false,
	}
	for raw, ok := range cases {
		req := httptest.NewRequest(http.MethodPost, "/", strings.NewReader(raw))
		var b body
		err := DecodeJSON(httptest.NewRecorder(), req, &b)
		if (err == nil) != ok {
			t.Errorf("%.40q: err = %v, want ok=%v", raw, err, ok)
		}
		if err != nil && !errors.Is(err, ErrBadRequest) {
			t.Errorf("errors must be ErrBadRequest without detail, got %v", err)
		}
	}
}
