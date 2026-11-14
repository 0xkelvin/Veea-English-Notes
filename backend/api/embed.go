// Package api holds the OpenAPI contract of the HTTP service (TRD 01 §5.1: normative for §5).
// Tests load it to check that the router registers exactly these operations and that every
// response matches it.
package api

import (
	"context"
	_ "embed"

	"github.com/getkin/kin-openapi/openapi3"
)

// Spec is api/openapi.yaml.
//
//go:embed openapi.yaml
var Spec []byte

// Load parses and validates the contract.
func Load(ctx context.Context) (*openapi3.T, error) {
	doc, err := openapi3.NewLoader().LoadFromData(Spec)
	if err != nil {
		return nil, err
	}
	if err := doc.Validate(ctx); err != nil {
		return nil, err
	}
	return doc, nil
}

// Doc wraps the parsed document for tests.
type Doc struct{ *openapi3.T }

// ErrorCodes returns the operation's x-error-codes: every problem code it may answer with.
func ErrorCodes(op *openapi3.Operation) []string {
	raw, _ := op.Extensions["x-error-codes"].([]any)
	codes := make([]string, 0, len(raw))
	for _, c := range raw {
		if s, ok := c.(string); ok {
			codes = append(codes, s)
		}
	}
	return codes
}
