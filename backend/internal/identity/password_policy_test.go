package identity

import (
	"bufio"
	"errors"
	"reflect"
	"strings"
	"testing"
	"unicode/utf8"
)

func testPolicy(t *testing.T, entries ...string) *Policy {
	t.Helper()
	return NewPolicy(NewBlocklist(entries...))
}

// violationsOf runs Validate and returns the violations, failing on any other error.
func violationsOf(t *testing.T, p *Policy, password, email string) []Violation {
	t.Helper()
	_, err := p.Validate(password, email)
	if err == nil {
		return nil
	}
	var pe *PolicyError
	if !errors.As(err, &pe) {
		t.Fatalf("expected *PolicyError, got %T: %v", err, err)
	}
	return pe.Violations
}

func TestPolicyLengthBoundaries(t *testing.T) {
	p := testPolicy(t)
	cases := []struct {
		name string
		pw   string
		want []Violation
	}{
		{"empty", "", []Violation{TooShort}},
		{"14 characters", strings.Repeat("x", 14), []Violation{TooShort}},
		{"15 characters", strings.Repeat("x", 15), nil},
		{"16 characters", strings.Repeat("x", 16), nil},
		{"128 characters", strings.Repeat("x", 128), nil},
		{"129 characters", strings.Repeat("x", 129), []Violation{TooLong}},
		{"way past the raw input cap", strings.Repeat("x", MaxPasswordInputBytes+1), []Violation{TooLong}},
		{"14 multibyte characters", strings.Repeat("é", 14), []Violation{TooShort}},
		{"15 multibyte characters", strings.Repeat("é", 15), nil},
		{"128 emoji", strings.Repeat("😀", 128), nil},
		{"129 emoji", strings.Repeat("😀", 129), []Violation{TooLong}},
		{"spaces count and are not trimmed", strings.Repeat(" ", 15), nil},
		{"passphrase", "correct horse battery staple", nil},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := violationsOf(t, p, c.pw, "")
			if !reflect.DeepEqual(got, c.want) {
				t.Fatalf("violations = %v, want %v", got, c.want)
			}
		})
	}
}

// Length is measured after NFKC, in code points.
func TestPolicyLengthUsesNormalizedCodePoints(t *testing.T) {
	p := testPolicy(t)
	// 15 decomposed letters (e + combining acute) compose to 15 code points. Raw they are 30.
	if got := violationsOf(t, p, strings.Repeat("é", 15), ""); got != nil {
		t.Fatalf("15 composed letters: %v", got)
	}
	if got := violationsOf(t, p, strings.Repeat("é", 14), ""); !reflect.DeepEqual(got, []Violation{TooShort}) {
		t.Fatalf("14 composed letters: %v", got)
	}
	// Fullwidth letters fold to ASCII, so 14 of them are too short even though each is 3 bytes.
	if got := violationsOf(t, p, strings.Repeat("ａ", 14), ""); !reflect.DeepEqual(got, []Violation{TooShort}) {
		t.Fatalf("14 fullwidth letters: %v", got)
	}
	// The "fi" ligature expands: 8 ligatures are 16 code points after NFKC.
	if got := violationsOf(t, p, strings.Repeat("ﬁ", 8), ""); got != nil {
		t.Fatalf("8 ligatures: %v", got)
	}
	// 65 ligatures expand to 130 code points.
	if got := violationsOf(t, p, strings.Repeat("ﬁ", 65), ""); !reflect.DeepEqual(got, []Violation{TooLong}) {
		t.Fatalf("65 ligatures: %v", got)
	}
}

func TestPolicyReturnsNormalizedPassword(t *testing.T) {
	p := testPolicy(t)
	in := strings.Repeat("ａ", 15) // fullwidth "a"
	got, err := p.Validate(in, "")
	if err != nil {
		t.Fatal(err)
	}
	if got != strings.Repeat("a", 15) {
		t.Fatalf("normalized = %q", got)
	}
	// Case is preserved: only the blocklist and email checks ignore case.
	mixed, err := p.Validate("Mixed-Case-Phrase-123", "")
	if err != nil || mixed != "Mixed-Case-Phrase-123" {
		t.Fatalf("case must be preserved: %q %v", mixed, err)
	}
}

func TestPolicyBlocklist(t *testing.T) {
	p := testPolicy(t, "passwordpassword", "Ünïcode-Common-Pass")
	cases := []struct {
		name, pw string
		want     []Violation
	}{
		{"exact entry", "passwordpassword", []Violation{TooCommon}},
		{"upper case", "PASSWORDPASSWORD", []Violation{TooCommon}},
		{"mixed case", "PassWordPassWord", []Violation{TooCommon}},
		{"entry with accents, other case", "ünïCODE-common-PASS", []Violation{TooCommon}},
		{"decomposed form of an entry", "Ünïcode-Common-Pass", []Violation{TooCommon}},
		{"fullwidth form of an entry", "ｐａｓｓｗｏｒｄｐａｓｓｗｏｒｄ", []Violation{TooCommon}},
		{"entry plus a suffix is not blocked", "passwordpassword1", nil},
		{"entry with a prefix is not blocked", "1passwordpassword", nil},
		{"unrelated passphrase", "violet-anchor-stapler-9", nil},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := violationsOf(t, p, c.pw, ""); !reflect.DeepEqual(got, c.want) {
				t.Fatalf("violations = %v, want %v", got, c.want)
			}
		})
	}
}

func TestPolicyContainsEmail(t *testing.T) {
	p := testPolicy(t)
	cases := []struct {
		name, pw, email string
		want            []Violation
	}{
		{"contains the local part", "xx-learner-xxxxxxx", "learner@example.test", []Violation{ContainsEmail}},
		{"is the local part with padding", "learnerlearnerlearner", "learner@example.test", []Violation{ContainsEmail}},
		{"case insensitive", "xx-LeArNeR-xxxxxxx", "learner@example.test", []Violation{ContainsEmail}},
		{"local part with a tag, whole local part", "xx-first.last+tag-xx", "first.last+tag@example.test", []Violation{ContainsEmail}},
		{"3 character local part counts", "xx-abc-xxxxxxxxxx", "abc@example.test", []Violation{ContainsEmail}},
		{"2 character local part is ignored", "xx-ab-xxxxxxxxxxx", "ab@example.test", nil},
		{"domain is not checked", "xx-example-xxxxxxxx", "learner@example.test", nil},
		{"no email known", "xx-learner-xxxxxxx", "", nil},
		{"unrelated", "violet-anchor-stapler-9", "learner@example.test", nil},
		{"fullwidth form of the local part", "xx-ｌｅａｒｎｅｒ-xxxxxxx", "learner@example.test", []Violation{ContainsEmail}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := violationsOf(t, p, c.pw, c.email); !reflect.DeepEqual(got, c.want) {
				t.Fatalf("violations = %v, want %v", got, c.want)
			}
		})
	}
}

func TestPolicyReportsAllViolationsInFixedOrder(t *testing.T) {
	p := testPolicy(t, "abcabcabcabc")
	// Too short, on the blocklist (after padding the entry to be listed) and containing the email.
	p2 := testPolicy(t, "learner")
	if got := violationsOf(t, p2, "learner", "learner@example.test"); !reflect.DeepEqual(got, []Violation{TooShort, TooCommon, ContainsEmail}) {
		t.Fatalf("got %v", got)
	}
	// Too long and containing the email.
	if got := violationsOf(t, p, strings.Repeat("learner", 20), "learner@example.test"); !reflect.DeepEqual(got, []Violation{TooLong, ContainsEmail}) {
		t.Fatalf("got %v", got)
	}
	// Short and common only.
	if got := violationsOf(t, p, "abcabcabcabc", "x@example.test"); !reflect.DeepEqual(got, []Violation{TooShort, TooCommon}) {
		t.Fatalf("got %v", got)
	}
}

func TestPolicyErrorMessageNeverContainsThePassword(t *testing.T) {
	_, err := testPolicy(t).Validate("hunter2", "")
	if err == nil {
		t.Fatal("expected a violation")
	}
	if strings.Contains(err.Error(), "hunter2") {
		t.Fatalf("error leaks the password: %v", err)
	}
	if !strings.Contains(err.Error(), "too_short") {
		t.Fatalf("error should list the violation codes: %v", err)
	}
}

func TestPolicyRejectsInvalidUTF8(t *testing.T) {
	_, err := testPolicy(t).Validate("valid-prefix-\xff\xfe-suffix", "")
	if !errors.Is(err, ErrInvalidPasswordEncoding) {
		t.Fatalf("got %v", err)
	}
}

func TestPolicyWithoutBlocklistSkipsOnlyThatRule(t *testing.T) {
	p := NewPolicy(nil)
	if got := violationsOf(t, p, "passwordpassword", ""); got != nil {
		t.Fatalf("got %v", got)
	}
	if got := violationsOf(t, p, "short", ""); !reflect.DeepEqual(got, []Violation{TooShort}) {
		t.Fatalf("got %v", got)
	}
}

// --- embedded blocklist -------------------------------------------------------------------

func TestDefaultBlocklistCatchesWellKnownLongPasswords(t *testing.T) {
	b, err := DefaultBlocklist()
	if err != nil {
		t.Fatal(err)
	}
	if b.Len() < 4000 {
		t.Fatalf("embedded blocklist looks truncated: %d entries", b.Len())
	}
	p := NewPolicy(b)
	for _, pw := range []string{
		"passwordpassword", "1234567890123456", "qwertyuiopasdfgh", "iloveyouiloveyou",
		"123456789012345", "abcdefghijklmnopqrstuvwxyz", "AAAAAAAAAAAAAAA", "Password1234567",
	} {
		if got := violationsOf(t, p, pw, ""); !reflect.DeepEqual(got, []Violation{TooCommon}) {
			t.Errorf("%q: violations = %v, want [too_common]", pw, got)
		}
	}
	if got := violationsOf(t, p, "violet anchor stapler 9", ""); got != nil {
		t.Errorf("an unrelated passphrase was rejected: %v", got)
	}
}

func TestDefaultBlocklistIsShared(t *testing.T) {
	a, err1 := DefaultBlocklist()
	b, err2 := DefaultBlocklist()
	if err1 != nil || err2 != nil || a != b {
		t.Fatal("DefaultBlocklist must parse once and return the same set")
	}
}

// The data file is derived by scripts/build-blocklist.py. This keeps hand edits honest.
func TestEmbeddedBlocklistFileHygiene(t *testing.T) {
	sc := bufio.NewScanner(strings.NewReader(embeddedBlocklist))
	var prev string
	n := 0
	for sc.Scan() {
		line := sc.Text()
		n++
		if n > 1 && line <= prev {
			t.Fatalf("line %d %q is not strictly after %q: file must be sorted and unique", n, line, prev)
		}
		prev = line
		if cnt := utf8.RuneCountInString(line); cnt < MinPasswordLength || cnt > MaxPasswordLength {
			t.Fatalf("line %d %q has %d code points, outside %d..%d", n, line, cnt, MinPasswordLength, MaxPasswordLength)
		}
		if norm := normalizeForCompare(line); norm != line {
			t.Fatalf("line %d %q is not normalized (want %q)", n, line, norm)
		}
		if strings.Contains(line, "\r") {
			t.Fatalf("line %d contains a carriage return", n)
		}
	}
	if err := sc.Err(); err != nil {
		t.Fatal(err)
	}
	if !strings.HasSuffix(embeddedBlocklist, "\n") {
		t.Fatal("file must end with a newline")
	}
}

func TestLoadBlocklistParsing(t *testing.T) {
	b, err := LoadBlocklist(strings.NewReader("First-Entry\r\n\nsecond entry \n  third\n"))
	if err != nil {
		t.Fatal(err)
	}
	if b.Len() != 3 {
		t.Fatalf("Len = %d", b.Len())
	}
	if !b.Contains("FIRST-ENTRY") || !b.Contains("second entry ") || !b.Contains("  third") {
		t.Fatal("entries should match case-insensitively and keep their spaces")
	}
	if b.Contains("second entry") || b.Contains("third") {
		t.Fatal("trailing and leading spaces are significant")
	}
	var nilList *Blocklist
	if nilList.Contains("x") || nilList.Len() != 0 {
		t.Fatal("a nil blocklist must be empty")
	}
	if _, err := LoadBlocklist(strings.NewReader(strings.Repeat("x", 2000))); err == nil {
		t.Fatal("an over-long line must be an error, not silently truncated")
	}
}
