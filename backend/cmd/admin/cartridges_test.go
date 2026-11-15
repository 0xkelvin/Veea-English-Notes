package main

import (
	"bytes"
	"context"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/learning"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestPublishCartridgeCLIRefusesUnsafeInput(t *testing.T) {
	file := filepath.Join(t.TempDir(), "pack.json")
	if err := os.WriteFile(file, bytes.Repeat([]byte{'x'}, learning.MaxCartridgeBytes+1), 0600); err != nil {
		t.Fatal(err)
	}
	for _, args := range [][]string{{"publish-cartridge"}, {"publish-cartridge", "--file", file, "--ticket-ref", "vat_secret"}, {"publish-cartridge", "--file", file, "--ticket-ref", "FIX-10"}} {
		var out, stderr bytes.Buffer
		code := run(context.Background(), args, func(string) string { return "" }, &out, &stderr)
		if code != 2 || out.Len() != 0 || strings.Contains(stderr.String(), "vat_secret") {
			t.Fatalf("unsafe CLI refusal: %d", code)
		}
	}
}
