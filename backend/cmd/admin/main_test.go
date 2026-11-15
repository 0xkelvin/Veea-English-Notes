package main

import (
	"bytes"
	"context"
	"strings"
	"testing"

	"github.com/google/uuid"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/admin"
)

func TestRunParsesAndNeverPrintsTheAddress(t *testing.T) {
	var got admin.BootstrapRequest
	bootstrapper = func(_ context.Context, url string, req admin.BootstrapRequest) (admin.BootstrapResult, error) {
		got = req
		return admin.BootstrapResult{UserID: uuid.MustParse("019a7d93-4c00-7000-8000-000000000001"), RoleRevision: 1}, nil
	}
	env := func(k string) string {
		if k == "VEEA_DATABASE_URL" {
			return "postgres://127.0.0.1/x"
		}
		return ""
	}
	var out, errOut bytes.Buffer
	code := run(context.Background(), []string{"bootstrap-super-admin", "--email", "Owner@Example.Test"}, env, &out, &errOut)
	if code != 0 || got.Email == nil || got.Email.Normalized != "owner@example.test" || got.Mode != admin.ModeFirst {
		t.Fatalf("code %d, req %+v, stderr %s", code, got, errOut.String())
	}
	if strings.Contains(strings.ToLower(out.String()+errOut.String()), "example.test") {
		t.Fatal("the address was printed")
	}
	code = run(context.Background(), []string{"bootstrap-super-admin", "--user-id", "019a7d93-4c00-7000-8000-000000000001",
		"--mode", "break_glass", "--reason-code", "lost_access", "--ticket-ref", "OPS-1"}, env, &out, &errOut)
	if code != 0 || got.UserID == nil || got.Mode != admin.ModeBreakGlass || got.ReasonCode != "lost_access" || *got.TicketRef != "OPS-1" {
		t.Fatalf("break glass: %d %+v", code, got)
	}
}

func TestRunRefusesBadUsage(t *testing.T) {
	bootstrapper = func(context.Context, string, admin.BootstrapRequest) (admin.BootstrapResult, error) {
		t.Fatal("must not reach the database")
		return admin.BootstrapResult{}, nil
	}
	env := func(string) string { return "postgres://127.0.0.1/x" }
	for _, args := range [][]string{
		nil, {"other"}, {"bootstrap-super-admin"},
		{"bootstrap-super-admin", "--email", "a@b.test", "--user-id", uuid.NewString()},
		{"bootstrap-super-admin", "--user-id", "nope"}, {"bootstrap-super-admin", "--email", "not an email"},
		{"bootstrap-super-admin", "--user-id", uuid.NewString(), "extra"},
	} {
		var out, errOut bytes.Buffer
		if code := run(context.Background(), args, env, &out, &errOut); code != 2 {
			t.Errorf("%v: code %d", args, code)
		}
	}
	var out, errOut bytes.Buffer
	if code := run(context.Background(), []string{"bootstrap-super-admin", "--user-id", uuid.NewString()}, func(string) string { return "" }, &out, &errOut); code != 2 {
		t.Errorf("missing database URL: %d", code)
	}
}

func TestRunMapsRefusals(t *testing.T) {
	env := func(string) string { return "postgres://127.0.0.1/x" }
	for err, want := range map[error]int{admin.ErrAlreadyProvisioned: 1, admin.ErrIneligibleTarget: 1, admin.ErrInvalidBootstrap: 2} {
		bootstrapper = func(context.Context, string, admin.BootstrapRequest) (admin.BootstrapResult, error) {
			return admin.BootstrapResult{}, err
		}
		var out, errOut bytes.Buffer
		if code := run(context.Background(), []string{"bootstrap-super-admin", "--user-id", uuid.NewString()}, env, &out, &errOut); code != want {
			t.Errorf("%v: code %d", err, code)
		}
	}
}
