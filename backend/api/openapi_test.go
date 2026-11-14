package api

import (
	"context"
	"net/http"
	"slices"
	"sort"
	"strings"
	"testing"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/auth/httpapi"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/httpx"
)

func load(t *testing.T) *Doc {
	t.Helper()
	doc, err := Load(context.Background())
	if err != nil {
		t.Fatalf("api/openapi.yaml is not a valid OpenAPI document: %v", err)
	}
	return &Doc{doc}
}

// The spec lists exactly the operations the real router registers, no more and no fewer.
func TestSpecMatchesTheRegisteredRoutes(t *testing.T) {
	d := load(t)
	registered := httpx.Patterns((&httpapi.Handlers{}).Mount)
	var documented []string
	for path, item := range d.Paths.Map() {
		for method := range item.Operations() {
			documented = append(documented, method+" "+path)
		}
	}
	sort.Strings(registered)
	sort.Strings(documented)
	if strings.Join(registered, "\n") != strings.Join(documented, "\n") {
		t.Fatalf("routes and spec differ\nregistered:\n  %s\ndocumented:\n  %s",
			strings.Join(registered, "\n  "), strings.Join(documented, "\n  "))
	}
}

// Every operation declares its error codes, all of them known, and every documented problem
// status has at least one code to go with it.
func TestEveryOperationDeclaresKnownErrorCodes(t *testing.T) {
	d := load(t)
	known := map[string]bool{}
	for _, v := range d.Components.Schemas["ErrorCode"].Value.Enum {
		known[v.(string)] = true
	}
	for path, item := range d.Paths.Map() {
		for method, op := range item.Operations() {
			if _, ok := op.Extensions["x-error-codes"]; !ok {
				t.Errorf("%s %s has no x-error-codes", method, path)
			}
			codes := ErrorCodes(op)
			for _, c := range codes {
				if !known[c] {
					t.Errorf("%s %s lists unknown code %q", method, path, c)
				}
			}
			if path != "/healthz" && path != "/readyz" && !slices.Contains(codes, "internal_error") {
				t.Errorf("%s %s must document internal_error", method, path)
			}
			if op.Security != nil && len(*op.Security) > 0 && func() bool { _, ok := (*op.Security)[0]["bearerAuth"]; return ok }() && !slices.Contains(codes, "unauthorized") {
				t.Errorf("%s %s requires a bearer token but does not list unauthorized", method, path)
			}
			if slices.Contains(codes, "rate_limited") && op.Responses.Status(http.StatusTooManyRequests) == nil {
				t.Errorf("%s %s lists rate_limited without a 429 response", method, path)
			}
		}
	}
}

// Each problem response lists the codes it can carry (x-codes), and every code an operation
// declares has a response that can carry it. Shared responses may list more codes than one
// operation uses; at run time the contract checker requires a code to be in both lists.
func TestErrorCodesAgreeWithTheirResponses(t *testing.T) {
	d := load(t)
	for path, item := range d.Paths.Map() {
		for method, op := range item.Operations() {
			union := map[string]bool{}
			for status, ref := range op.Responses.Map() {
				if status < "400" {
					continue
				}
				codes, _ := ref.Value.Extensions["x-codes"].([]any)
				if len(codes) == 0 {
					t.Errorf("%s %s %s: problem response without x-codes", method, path, status)
				}
				for _, c := range codes {
					union[c.(string)] = true
				}
			}
			for _, c := range ErrorCodes(op) {
				if !union[c] {
					t.Errorf("%s %s: x-error-codes lists %s but no response carries it", method, path, c)
				}
			}
		}
	}
}
