//go:build integration

package integration

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"slices"
	"sort"
	"strconv"
	"strings"
	"sync"
	"testing"

	"github.com/getkin/kin-openapi/openapi3"
	"github.com/getkin/kin-openapi/openapi3filter"
	"github.com/getkin/kin-openapi/routers"
	"github.com/getkin/kin-openapi/routers/gorillamux"

	"github.com/0xkelvin/Veea-English-Notes/backend/api"
)

// contract validates every request and response that crosses a test server against
// api/openapi.yaml (TRD 01 §5.1, §12.1 "Every integration test validates responses").
type contract struct {
	doc    *openapi3.T
	router routers.Router

	mu         sync.Mutex
	violations []string
	seen       map[string]int // "METHOD /path STATUS code" -> responses checked
}

var (
	contractOnce sync.Once
	sharedDoc    *openapi3.T
	sharedRouter routers.Router
	contractErr  error

	// suiteCoverage aggregates every checked response across the package, for TestMain.
	suiteCoverage   = map[string]int{}
	suiteCoverageMu sync.Mutex
)

func loadContract() (*openapi3.T, routers.Router, error) {
	contractOnce.Do(func() {
		sharedDoc, contractErr = api.Load(context.Background())
		if contractErr == nil {
			sharedRouter, contractErr = gorillamux.NewRouter(sharedDoc)
		}
	})
	return sharedDoc, sharedRouter, contractErr
}

func newContract(t *testing.T) *contract {
	t.Helper()
	doc, router, err := loadContract()
	if err != nil {
		t.Fatalf("load api/openapi.yaml: %v", err)
	}
	c := &contract{doc: doc, router: router, seen: map[string]int{}}
	t.Cleanup(func() {
		c.mu.Lock()
		defer c.mu.Unlock()
		for i, v := range c.violations {
			if i == 10 {
				t.Errorf("... and %d more contract violations", len(c.violations)-10)
				break
			}
			t.Errorf("contract violation: %s", v)
		}
	})
	return c
}

func (c *contract) fail(format string, args ...any) {
	c.mu.Lock()
	c.violations = append(c.violations, fmt.Sprintf(format, args...))
	c.mu.Unlock()
}

// wrap serves next and checks the exchange.
func (c *contract) wrap(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		r.Body = io.NopCloser(bytes.NewReader(body))
		rec := httptest.NewRecorder()
		next.ServeHTTP(rec, r)
		for k, v := range rec.Header() {
			w.Header()[k] = v
		}
		w.WriteHeader(rec.Code)
		_, _ = w.Write(rec.Body.Bytes())

		check := r.Clone(context.Background())
		check.Body = io.NopCloser(bytes.NewReader(body))
		c.check(check, rec.Code, rec.Header(), rec.Body.Bytes())
	})
}

func (c *contract) check(r *http.Request, status int, header http.Header, body []byte) {
	route, params, err := c.router.FindRoute(r)
	if err != nil {
		// Outside every operation: only the documented 404/405 problems are acceptable.
		var p struct {
			Code   string `json:"code"`
			Status int    `json:"status"`
		}
		_ = json.Unmarshal(body, &p)
		switch {
		case r.Method == http.MethodHead && (status == http.StatusMethodNotAllowed || status == http.StatusNotFound):
		case status == http.StatusNotFound && p.Code == "not_found" && p.Status == status:
		case status == http.StatusMethodNotAllowed && p.Code == "method_not_allowed" && p.Status == status && header.Get("Allow") != "":
		default:
			c.fail("%s %s: not in the spec and not a 404/405 problem (%d %s)", r.Method, r.URL.Path, status, body)
		}
		if header.Get("Content-Type") != "application/problem+json" || header.Get("X-Request-Id") == "" {
			c.fail("%s %s %d: unmatched requests get a problem document with X-Request-Id", r.Method, r.URL.Path, status)
		}
		return
	}
	op := route.Method + " " + route.Path
	auth := func(_ context.Context, in *openapi3filter.AuthenticationInput) error {
		h := in.RequestValidationInput.Request.Header.Get("Authorization")
		if scheme, tok, ok := strings.Cut(h, " "); !ok || !strings.EqualFold(scheme, "Bearer") || tok == "" {
			return errors.New("no bearer token")
		}
		return nil
	}
	reqIn := &openapi3filter.RequestValidationInput{Request: r, PathParams: params, Route: route,
		Options: &openapi3filter.Options{AuthenticationFunc: auth, MultiError: true}}
	if reqErr := openapi3filter.ValidateRequest(context.Background(), reqIn); reqErr != nil && status < 400 {
		c.fail("%s: answered %d to a request the spec forbids: %v", op, status, reqErr)
	}
	respIn := &openapi3filter.ResponseValidationInput{RequestValidationInput: reqIn, Status: status, Header: header,
		Body: io.NopCloser(bytes.NewReader(body)), Options: &openapi3filter.Options{IncludeResponseStatus: true, MultiError: true}}
	if err := openapi3filter.ValidateResponse(context.Background(), respIn); err != nil {
		c.fail("%s %d: %v", op, status, err)
	}

	// Rules the schema language cannot state, or states per response but not per operation.
	code := ""
	if status >= 400 {
		var p struct {
			Code   string `json:"code"`
			Status int    `json:"status"`
		}
		_ = json.Unmarshal(body, &p)
		code = p.Code
		if !slices.Contains(api.ErrorCodes(route.Operation), code) {
			c.fail("%s %d: code %q is not in its x-error-codes", op, status, code)
		}
		if p.Status != status {
			c.fail("%s %d: problem body says status %d", op, status, p.Status)
		}
		if ref := route.Operation.Responses.Status(status); ref != nil && ref.Value != nil {
			allowed, _ := ref.Value.Extensions["x-codes"].([]any)
			if !slices.Contains(allowed, any(code)) {
				c.fail("%s %d: code %q does not belong to this status (x-codes %v)", op, status, code, allowed)
			}
		}
		if header.Get("Cache-Control") != "no-store" {
			c.fail("%s %d: a problem response must not be cacheable", op, status)
		}
	}
	if status == http.StatusTooManyRequests {
		if n, err := strconv.Atoi(header.Get("Retry-After")); err != nil || n < 1 {
			c.fail("%s 429: Retry-After %q", op, header.Get("Retry-After"))
		}
	}
	if code == "unauthorized" && header.Get("WWW-Authenticate") != "Bearer" {
		c.fail("%s 401: WWW-Authenticate %q", op, header.Get("WWW-Authenticate"))
	}
	if status < 300 && route.Path != "/healthz" && route.Path != "/readyz" && header.Get("Cache-Control") != "no-store" {
		c.fail("%s %d: a success response must carry Cache-Control: no-store", op, status)
	}

	key := fmt.Sprintf("%s %d %s", op, status, code)
	c.mu.Lock()
	c.seen[key]++
	c.mu.Unlock()
	suiteCoverageMu.Lock()
	suiteCoverage[key]++
	suiteCoverageMu.Unlock()
}

// notExercised are documented responses the router suite cannot reach without breaking the
// database under a live request. Each has other evidence, named here.
var notExercised = map[string]string{
	"GET /readyz 503":           "httpx unit tests (TestReadyzUnavailableHidesCause, TestReadyzTimesOut)",
	"GET /readyz not_ready":     "httpx unit tests",
	"GET /v1/me 500":            "the shared error mapper; every other operation's 500 is exercised",
	"GET /v1/me internal_error": "as above",
}

// TestMain prints which documented operations, statuses and codes the suite exercised. A full
// run (no -run filter) fails when a documented operation was never called, or when a documented
// status or error code was never produced and is not in notExercised.
func TestMain(m *testing.M) {
	flag.Parse()
	code := m.Run()
	if f := flag.Lookup("test.run"); code != 0 || (f != nil && f.Value.String() != "") || os.Getenv("VEEA_TEST_DATABASE_URL") == "" {
		os.Exit(code)
	}
	doc, _, err := loadContract()
	if err != nil {
		fmt.Println("contract coverage: spec did not load:", err)
		os.Exit(1)
	}
	var missingOps, unexercised []string
	for path, item := range doc.Paths.Map() {
		for method, op := range item.Operations() {
			name := method + " " + path
			called := false
			for status := range op.Responses.Map() {
				prefix := name + " " + status + " "
				hit := false
				for k := range suiteCoverage {
					if strings.HasPrefix(k, prefix) {
						hit, called = true, true
					}
				}
				if !hit {
					unexercised = append(unexercised, name+" "+status)
				}
			}
			for _, code := range api.ErrorCodes(op) {
				hit := false
				for k := range suiteCoverage {
					if strings.HasPrefix(k, name+" ") && strings.HasSuffix(k, " "+code) {
						hit = true
					}
				}
				if !hit {
					unexercised = append(unexercised, name+" "+code)
				}
			}
			if !called {
				missingOps = append(missingOps, name)
			}
		}
	}
	var unexplained []string
	for _, u := range unexercised {
		if _, ok := notExercised[u]; !ok {
			unexplained = append(unexplained, u)
		}
	}
	sort.Strings(unexercised)
	keys := make([]string, 0, len(suiteCoverage))
	for k := range suiteCoverage {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	fmt.Printf("contract coverage: %d distinct operation/status/code combinations checked\n", len(keys))
	fmt.Printf("contract coverage: documented responses never exercised (%d):\n  %s\n", len(unexercised), strings.Join(unexercised, "\n  "))
	if len(missingOps) > 0 {
		sort.Strings(missingOps)
		fmt.Printf("contract coverage: FAIL, operations never called: %s\n", strings.Join(missingOps, ", "))
		os.Exit(1)
	}
	if len(unexplained) > 0 {
		sort.Strings(unexplained)
		fmt.Printf("contract coverage: FAIL, documented but never produced and not explained in notExercised:\n  %s\n", strings.Join(unexplained, "\n  "))
		os.Exit(1)
	}
	os.Exit(code)
}

// =============================================================================================
// Spec-driven route tests
// =============================================================================================

// TRD 5.1: every operation the spec marks as bearer-protected answers 401 unauthorized with
// WWW-Authenticate: Bearer when no token is sent; every other operation does not ask for one.
func TestContract_BearerRequirementMatchesTheSpec(t *testing.T) {
	env := newSignupEnv(t, nil)
	doc, _, err := loadContract()
	if err != nil {
		t.Fatal(err)
	}
	bodies := map[string]any{
		"/v1/me/password/set": map[string]string{"challenge_token": "x", "code": "1", "new_password": "y"},
		"/v1/me/password":     map[string]string{"current_password": "x", "new_password": "y"},
	}
	for path, item := range doc.Paths.Map() {
		for method, op := range item.Operations() {
			protected := op.Security != nil && len(*op.Security) > 0
			t.Run(method+" "+path, func(t *testing.T) {
				var r response
				if method == http.MethodGet {
					r = env.get(t, path)
				} else {
					body := bodies[path]
					if body == nil {
						body = ""
					}
					r = env.send(t, method, path, body)
				}
				switch {
				case protected:
					wantUnauthorized(t, r)
				case r.status == http.StatusUnauthorized && r.str("code") == "unauthorized" && path != "/v1/auth/token/refresh":
					t.Fatalf("%s %s is public in the spec but asked for a token", method, path)
				}
			})
		}
	}
}
