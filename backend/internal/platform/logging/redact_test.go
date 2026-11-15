package logging

import (
	"bytes"
	"errors"
	"log/slog"
	"net/http"
	"strings"
	"testing"
)

type secretConfig struct{}

func (secretConfig) LogValue() slog.Value {
	return slog.GroupValue(slog.String("note", "refresh vrt_fromlogvaluer"), slog.Int("keys", 2))
}

type stringer struct{}

func (stringer) String() string { return "bearer VAT_fromstringer" }

func TestRedactingHandlerRemovesSecrets(t *testing.T) {
	var buf bytes.Buffer
	log := slog.New(NewRedactingHandler(slog.NewJSONHandler(&buf, &slog.HandlerOptions{Level: slog.LevelDebug})))
	log = log.With("access_token", "vat_withattrs", "component", "test")
	log.WithGroup("req").Info("got vct_inmessage from client",
		"password", "correct horse battery staple",
		"new_password", "another long secret phrase",
		"code", "123456",
		"refresh_token", "vrt_named",
		"note", "header Authorization: Bearer vat_inline here",
		"error", errors.New("lookup failed for vct_inerror"),
		"detail", "operation vop_inerror",
		"value", stringer{},
		"config", secretConfig{},
		"raw", []byte("0123456789abcdef"),
		slog.Group("nested", slog.String("token", "plain"), slog.String("detail", "vrt_ingroup")),
		"count", 3,
	)
	out := buf.String()
	for _, leak := range []string{
		"vat_", "vct_", "vrt_", "vop_", "VAT_", "correct horse", "another long secret", "123456", "0123456789abcdef", "plain",
	} {
		if strings.Contains(out, leak) {
			t.Errorf("log output leaks %q: %s", leak, out)
		}
	}
	for _, kept := range []string{`"component":"test"`, `"count":3`, `"keys":2`, `got [redacted] from client`, `"msg"`} {
		if !strings.Contains(out, kept) {
			t.Errorf("log output should keep %s: %s", kept, out)
		}
	}
}

type nilErr struct{ msg string }

func (e *nilErr) Error() string { return e.msg }

func TestRedactingHandlerCoversStructuredValuesAndSensitiveGroups(t *testing.T) {
	var buf bytes.Buffer
	log := slog.New(NewRedactingHandler(slog.NewJSONHandler(&buf, nil)))
	var typedNil *nilErr
	log.Info("x",
		"hdr", http.Header{"Authorization": {"Bearer vat_inheader"}, "Accept": {"json"}},
		"m", map[string]any{"refresh": "vrt_inmap"},
		"s", []string{"vct_inslice"},
		slog.Group("password", slog.String("anything", "plain secret text")),
		"code_hash", "deadbeef", "otp_code", "424242", "outbox_key", "k", "email", "learner@example.test",
		"to_email", "learner@example.test", "pending_password_hash", "$argon2id$x",
		"err", error(typedNil),
		"status", 200, "email_hmac", "abcdef",
	)
	out := buf.String()
	for _, leak := range []string{"vat_", "vrt_", "vct_", "plain secret", "deadbeef", "424242", "learner@", "$argon2id", `"k"`} {
		if strings.Contains(out, leak) {
			t.Errorf("leaks %q: %s", leak, out)
		}
	}
	for _, kept := range []string{`\"Accept\":[\"json\"]`, `"status":200`, `"email_hmac":"abcdef"`, `"err":"<nil>"`} {
		if !strings.Contains(out, kept) {
			t.Errorf("should keep %s: %s", kept, out)
		}
	}
}

func TestRedactingHandlerLeavesOrdinaryValuesAlone(t *testing.T) {
	var buf bytes.Buffer
	slog.New(NewRedactingHandler(slog.NewJSONHandler(&buf, nil))).Info("request failed",
		"request_id", "0a1b2c3d4e5f", "error", errors.New("otp: lock challenge: timeout"), "outbox_id", "0192-abc")
	if !strings.Contains(buf.String(), `"error":"otp: lock challenge: timeout"`) || !strings.Contains(buf.String(), "0a1b2c3d4e5f") {
		t.Fatalf("ordinary values must pass through: %s", buf.String())
	}
}
