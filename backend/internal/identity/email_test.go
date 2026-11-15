package identity

import (
	"errors"
	"strings"
	"testing"
	"unicode/utf8"
)

func TestNormalizeEmailValid(t *testing.T) {
	cases := []struct {
		name, in, display, normalized string
	}{
		{"plain", "learner@example.test", "learner@example.test", "learner@example.test"},
		{"mixed case keeps display", "A.User@Example.TEST", "A.User@Example.TEST", "a.user@example.test"},
		{"surrounding whitespace", "  \tlearner@example.test \n", "learner@example.test", "learner@example.test"},
		{"dots are kept", "first.last@example.test", "first.last@example.test", "first.last@example.test"},
		{"plus tags are kept", "Name+Tag@Example.test", "Name+Tag@Example.test", "name+tag@example.test"},
		{"unicode local part", "Jürgen@Example.test", "Jürgen@Example.test", "jürgen@example.test"},
		{"decomposed becomes composed", "Café@example.test", "Café@example.test", "café@example.test"},
		// Go lowercases with simple case mapping, so U+0130 becomes a plain "i" in every locale.
		{"dotted capital I", "\u0130@example.test", "\u0130@example.test", "i@example.test"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, err := NormalizeEmail(c.in)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if got.Display != c.display || got.Normalized != c.normalized {
				t.Fatalf("got display=%q normalized=%q, want display=%q normalized=%q",
					got.Display, got.Normalized, c.display, c.normalized)
			}
		})
	}
}

// AC-8: spellings of one mailbox collapse to one normalized value.
func TestNormalizeEmailEquivalentSpellings(t *testing.T) {
	spellings := []string{
		"a.user@example.test", "A.User@Example.TEST", "  a.USER@example.test  ",
		"a.user@EXAMPLE.test",
	}
	first, err := NormalizeEmail(spellings[0])
	if err != nil {
		t.Fatal(err)
	}
	for _, s := range spellings {
		got, err := NormalizeEmail(s)
		if err != nil || got.Normalized != first.Normalized {
			t.Errorf("%q -> %q (%v), want %q", s, got.Normalized, err, first.Normalized)
		}
	}
	composed, _ := NormalizeEmail("café@example.test")
	decomposed, _ := NormalizeEmail("café@example.test")
	if composed.Normalized != decomposed.Normalized {
		t.Error("NFC and NFD spellings must normalize to the same value")
	}
	// Dots and tags are different mailboxes and must stay different.
	dotted, _ := NormalizeEmail("a.user@example.test")
	plain, _ := NormalizeEmail("auser@example.test")
	tagged, _ := NormalizeEmail("a.user+x@example.test")
	if dotted.Normalized == plain.Normalized || dotted.Normalized == tagged.Normalized {
		t.Error("dots and +tags must not be stripped")
	}
}

func TestNormalizeEmailInvalid(t *testing.T) {
	cases := map[string]string{
		"empty":             "",
		"only spaces":       "   ",
		"no at sign":        "learner.example.test",
		"no local part":     "@example.test",
		"no domain":         "learner@",
		"display name":      "Learner <learner@example.test>",
		"angle brackets":    "<learner@example.test>",
		"quoted local part": `"a b"@example.test`,
		"comment":           "learner@example.test (home)",
		"address list":      "a@example.test, b@example.test",
		"two at signs":      "a@b@example.test",
		"inner space":       "lear ner@example.test",
		// U+037E is valid for the parser, but NFC turns it into ";", which is not.
		"normalization breaks validity": "\u037e@0",
		"NUL byte":                      "learner\x00@example.test",
		"newline inside":                "learner@exam\nple.test",
		"tab inside":                    "learner@exam\tple.test",
		"DEL control":                   "learner\x7f@example.test",
		"invalid UTF-8":                 "learner\xff@example.test",
		"input far too long":            strings.Repeat("a", 5000) + "@example.test",
		"normalized over 254":           strings.Repeat("a", 255-len("@example.test")) + "@example.test",
		"multibyte pushes it over":      strings.Repeat("é", 125) + "@example.test", // 250 + 13 octets
	}
	for name, in := range cases {
		t.Run(name, func(t *testing.T) {
			got, err := NormalizeEmail(in)
			if !errors.Is(err, ErrInvalidEmail) {
				t.Fatalf("expected ErrInvalidEmail, got %q, %v", got.Normalized, err)
			}
			if got != (Email{}) {
				t.Fatalf("a rejected email must return the zero value, got %+v", got)
			}
		})
	}
}

func TestNormalizeEmailLengthBoundary(t *testing.T) {
	const domain = "@example.test"
	atLimit := strings.Repeat("a", MaxEmailOctets-len(domain)) + domain
	if len(atLimit) != MaxEmailOctets {
		t.Fatalf("test setup: %d octets", len(atLimit))
	}
	got, err := NormalizeEmail(atLimit)
	if err != nil {
		t.Fatalf("254 octets must be accepted: %v", err)
	}
	if len(got.Normalized) != MaxEmailOctets {
		t.Fatalf("normalized length = %d", len(got.Normalized))
	}
	if _, err := NormalizeEmail("a" + atLimit); !errors.Is(err, ErrInvalidEmail) {
		t.Fatalf("255 octets must be rejected, got %v", err)
	}
	// The limit is on octets of the normalized form, not on characters.
	multi := strings.Repeat("é", (MaxEmailOctets-len(domain))/2) + domain
	if len(multi) > MaxEmailOctets {
		t.Fatalf("test setup: %d octets", len(multi))
	}
	if _, err := NormalizeEmail(multi); err != nil {
		t.Fatalf("multibyte address within the octet limit: %v", err)
	}
	if _, err := NormalizeEmail("é" + multi); !errors.Is(err, ErrInvalidEmail) {
		t.Fatalf("multibyte address over the octet limit must be rejected, got %v", err)
	}
}

func TestEmailLocalPart(t *testing.T) {
	e, err := NormalizeEmail("First.Last+Tag@Example.test")
	if err != nil {
		t.Fatal(err)
	}
	if got := e.LocalPart(); got != "first.last+tag" {
		t.Fatalf("LocalPart = %q", got)
	}
}

func FuzzNormalizeEmail(f *testing.F) {
	for _, s := range []string{"a@example.test", "A.B+c@Example.TEST", "İ@x.test", "café@x.test",
		"Name <a@b.test>", "", "@", "a@b@c", "\x00@x.test", "\u037e@0"} {
		f.Add(s)
	}
	f.Fuzz(func(t *testing.T, in string) {
		got, err := NormalizeEmail(in)
		if err != nil {
			if !errors.Is(err, ErrInvalidEmail) || got != (Email{}) {
				t.Fatalf("bad failure shape: %v %+v", err, got)
			}
			return
		}
		if !utf8.ValidString(got.Normalized) || len(got.Normalized) > MaxEmailOctets {
			t.Fatalf("invalid result %q", got.Normalized)
		}
		// Idempotent: normalizing the normalized form changes nothing.
		again, err := NormalizeEmail(got.Normalized)
		if err != nil || again.Normalized != got.Normalized {
			t.Fatalf("not idempotent: %q -> %q (%v)", got.Normalized, again.Normalized, err)
		}
	})
}
