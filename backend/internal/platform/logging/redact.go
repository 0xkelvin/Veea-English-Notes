// Package logging holds the slog handler wrapper that enforces log hygiene (TRD 01 §11.2,
// AC-22). It is the last line of defence: code must still never log a secret, but if one slips
// into a message, an attribute or an error string, it is replaced before it is written.
package logging

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"regexp"
	"strings"
)

// Redacted replaces every value the handler removes.
const Redacted = "[redacted]"

// tokenPattern matches challenge, access and refresh tokens anywhere in a string, whatever the
// case of the prefix (TRD 4.1, 8.1).
var tokenPattern = regexp.MustCompile(`(?i)v(?:ct|at|rt)_[A-Za-z0-9_\-]*`)

// sensitiveKeys are attribute names whose values are always dropped (TRD 11.2), the transport
// headers that carry credentials, and email addresses, which are logged only as email_hmac.
var sensitiveKeys = map[string]bool{
	"code": true, "hash": true, "key": true, "authorization": true, "cookie": true, "set-cookie": true,
	"email": true, "to": true,
}

// sensitiveParts make any attribute name containing them sensitive.
var sensitiveParts = []string{"password", "token", "secret", "payload", "ciphertext"}

// sensitiveSuffixes cover names such as code_hash, otp_code, api_key and to_email.
var sensitiveSuffixes = []string{"_hash", "_code", "_key", "_email"}

func sensitive(key string) bool {
	k := strings.ToLower(key)
	if sensitiveKeys[k] {
		return true
	}
	for _, p := range sensitiveParts {
		if strings.Contains(k, p) {
			return true
		}
	}
	for _, s := range sensitiveSuffixes {
		if strings.HasSuffix(k, s) {
			return true
		}
	}
	return false
}

// NewRedactingHandler wraps h so that every record is redacted before h sees it:
//   - an attribute whose name is sensitive (see sensitive) loses its value, a whole group too;
//   - every vct_, vat_ or vrt_ token in the message, a string value, an error, a Stringer or any
//     other structured value (map, slice, struct, http.Header) is replaced, also inside groups
//     and in values produced by slog.LogValuer. Structured values are rendered to a string so
//     nothing reaches the inner handler unscanned.
func NewRedactingHandler(h slog.Handler) slog.Handler { return &redacting{inner: h} }

type redacting struct{ inner slog.Handler }

func (r *redacting) Enabled(ctx context.Context, l slog.Level) bool { return r.inner.Enabled(ctx, l) }

func (r *redacting) Handle(ctx context.Context, rec slog.Record) error {
	out := slog.NewRecord(rec.Time, rec.Level, redactString(rec.Message), rec.PC)
	rec.Attrs(func(a slog.Attr) bool {
		out.AddAttrs(redactAttr(a))
		return true
	})
	return r.inner.Handle(ctx, out)
}

func (r *redacting) WithAttrs(attrs []slog.Attr) slog.Handler {
	clean := make([]slog.Attr, len(attrs))
	for i, a := range attrs {
		clean[i] = redactAttr(a)
	}
	return &redacting{inner: r.inner.WithAttrs(clean)}
}

func (r *redacting) WithGroup(name string) slog.Handler {
	return &redacting{inner: r.inner.WithGroup(name)}
}

func redactAttr(a slog.Attr) slog.Attr {
	v := a.Value.Resolve()
	if sensitive(a.Key) {
		return slog.String(a.Key, Redacted)
	}
	if v.Kind() == slog.KindGroup {
		group := v.Group()
		clean := make([]any, len(group))
		for i, g := range group {
			clean[i] = redactAttr(g)
		}
		return slog.Group(a.Key, clean...)
	}
	switch v.Kind() {
	case slog.KindString:
		return slog.String(a.Key, redactString(v.String()))
	case slog.KindAny:
		return slog.String(a.Key, redactString(render(v.Any())))
	}
	return slog.Attr{Key: a.Key, Value: v}
}

// render turns any value into text: errors and Stringers by their methods, raw bytes into a
// placeholder (they may be key material or ciphertext), everything else as JSON or, failing
// that, %+v. A nil pointer behind an interface renders as "<nil>" instead of panicking.
func render(x any) (out string) {
	defer func() {
		if recover() != nil {
			out = "<nil>"
		}
	}()
	switch v := x.(type) {
	case nil:
		return "<nil>"
	case error:
		return v.Error()
	case fmt.Stringer:
		return v.String()
	case []byte:
		return Redacted
	}
	if b, err := json.Marshal(x); err == nil {
		return string(b)
	}
	return fmt.Sprintf("%+v", x)
}

func redactString(s string) string {
	if !strings.ContainsAny(s, "_") {
		return s
	}
	return tokenPattern.ReplaceAllString(s, Redacted)
}
