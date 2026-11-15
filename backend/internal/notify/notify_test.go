package notify

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
)

func key(b byte) []byte { return bytes.Repeat([]byte{b}, KeyBytes) }

func mustKeyring(t *testing.T, keys ...Key) *Keyring {
	t.Helper()
	k, err := NewKeyring(keys...)
	if err != nil {
		t.Fatal(err)
	}
	return k
}

// --- keyring ------------------------------------------------------------------------------

func TestKeyringRoundTripAndBinding(t *testing.T) {
	k := mustKeyring(t, Key{ID: 1, Key: key(1)})
	row := uuid.New()
	plain := []byte(`{"code":"123456"}`)

	sealed, id, err := k.Seal(row, plain)
	if err != nil || id != 1 {
		t.Fatalf("seal: %v %d", err, id)
	}
	if bytes.Contains(sealed, []byte("123456")) {
		t.Fatal("ciphertext contains the code")
	}
	got, err := k.Open(row, id, sealed)
	if err != nil || !bytes.Equal(got, plain) {
		t.Fatalf("open: %q %v", got, err)
	}

	// The row id is associated data: the same ciphertext under another row id does not open.
	if _, err := k.Open(uuid.New(), id, sealed); !errors.Is(err, ErrDecrypt) {
		t.Fatalf("moved ciphertext: %v", err)
	}
	// Any bit flip is detected.
	tampered := append([]byte(nil), sealed...)
	tampered[len(tampered)-1] ^= 1
	if _, err := k.Open(row, id, tampered); !errors.Is(err, ErrDecrypt) {
		t.Fatalf("tampered: %v", err)
	}
	if _, err := k.Open(row, id, sealed[:10]); !errors.Is(err, ErrDecrypt) {
		t.Fatalf("truncated: %v", err)
	}
	if _, err := k.Open(row, 9, sealed); !errors.Is(err, ErrUnknownKey) {
		t.Fatalf("unknown key id: %v", err)
	}
	// Fresh nonce each time.
	again, _, _ := k.Seal(row, plain)
	if bytes.Equal(again, sealed) {
		t.Fatal("two seals of the same payload must differ")
	}
}

func TestKeyringRotation(t *testing.T) {
	old := mustKeyring(t, Key{ID: 1, Key: key(1)})
	row := uuid.New()
	sealed, _, _ := old.Seal(row, []byte("payload"))

	rotated := mustKeyring(t, Key{ID: 2, Key: key(2)}, Key{ID: 1, Key: key(1)})
	if rotated.CurrentID() != 2 {
		t.Fatal("the first key is current")
	}
	if got, err := rotated.Open(row, 1, sealed); err != nil || string(got) != "payload" {
		t.Fatalf("old rows must still open after a rotation: %v", err)
	}
	if _, id, _ := rotated.Seal(row, []byte("x")); id != 2 {
		t.Fatalf("new rows use the current key, got %d", id)
	}
}

func TestKeyringValidation(t *testing.T) {
	bad := map[string][]Key{
		"none":         nil,
		"short key":    {{ID: 1, Key: key(1)[:31]}},
		"long key":     {{ID: 1, Key: append(key(1), 1)}},
		"zero id":      {{ID: 0, Key: key(1)}},
		"negative id":  {{ID: -1, Key: key(1)}},
		"duplicate id": {{ID: 1, Key: key(1)}, {ID: 1, Key: key(2)}},
	}
	for name, keys := range bad {
		_, err := NewKeyring(keys...)
		if err == nil {
			t.Errorf("%s: expected an error", name)
			continue
		}
		if strings.Contains(err.Error(), "\x01\x01") || strings.Contains(err.Error(), fmt.Sprintf("%x", key(1)[:8])) {
			t.Errorf("%s: error contains key material", name)
		}
	}
}

// --- messages -----------------------------------------------------------------------------

func codeMessage() Message {
	exp := time.Now().Add(10 * time.Minute)
	ch := uuid.New()
	return Message{Template: TemplateLoginCode, To: "learner@example.test", ChallengeID: &ch, NotAfter: &exp,
		Payload: Payload{Code: "123456"}}
}

func noticeMessage() Message {
	u := uuid.New()
	return Message{Template: TemplatePasswordChanged, To: "learner@example.test", UserID: &u,
		Payload: Payload{DeviceName: "Pixel 9", OccurredAt: time.Date(2026, 11, 14, 8, 30, 0, 0, time.UTC)}}
}

func TestMessageValidation(t *testing.T) {
	if err := codeMessage().validate(); err != nil {
		t.Fatal(err)
	}
	if err := noticeMessage().validate(); err != nil {
		t.Fatal(err)
	}
	bad := map[string]func() Message{
		"unknown template":         func() Message { m := codeMessage(); m.Template = "spam"; return m },
		"display name recipient":   func() Message { m := codeMessage(); m.To = "Eve <eve@example.test>"; return m },
		"header injection":         func() Message { m := codeMessage(); m.To = "a@example.test\r\nBcc: x@y.test"; return m },
		"code without challenge":   func() Message { m := codeMessage(); m.ChallengeID = nil; return m },
		"code without deadline":    func() Message { m := codeMessage(); m.NotAfter = nil; return m },
		"short code":               func() Message { m := codeMessage(); m.Payload.Code = "12345"; return m },
		"non digit code":           func() Message { m := codeMessage(); m.Payload.Code = "12345a"; return m },
		"code with extra fields":   func() Message { m := codeMessage(); m.Payload.DeviceName = "x"; return m },
		"notice with challenge":    func() Message { m := noticeMessage(); c := uuid.New(); m.ChallengeID = &c; return m },
		"notice without user":      func() Message { m := noticeMessage(); m.UserID = nil; return m },
		"notice with a code":       func() Message { m := noticeMessage(); m.Payload.Code = "123456"; return m },
		"notice without time":      func() Message { m := noticeMessage(); m.Payload.OccurredAt = time.Time{}; return m },
		"notice without device":    func() Message { m := noticeMessage(); m.Payload.DeviceName = " "; return m },
		"device name with newline": func() Message { m := noticeMessage(); m.Payload.DeviceName = "a\nb"; return m },
	}
	for name, build := range bad {
		err := build().validate()
		if !errors.Is(err, ErrInvalidMessage) {
			t.Errorf("%s: got %v", name, err)
			continue
		}
		if strings.Contains(err.Error(), "123456") || strings.Contains(err.Error(), "12345a") {
			t.Errorf("%s: error contains the code", name)
		}
	}
}

func TestPayloadNeverPrintsItsContent(t *testing.T) {
	p := Payload{Code: "654321"}
	for _, s := range []string{fmt.Sprint(p), fmt.Sprintf("%v", p), fmt.Sprintf("%+v", p), fmt.Sprintf("%#v", p), fmt.Sprintf("%s", p)} {
		if strings.Contains(s, "654321") {
			t.Fatalf("formatting a payload leaked the code: %s", s)
		}
	}
}

// --- templates ----------------------------------------------------------------------------

func TestRenderCodeEmails(t *testing.T) {
	for _, tpl := range []Template{TemplateSignupCode, TemplateLoginCode, TemplateResetCode, TemplateSetPasswordCode} {
		r, err := Render(tpl, Payload{Code: "042917"})
		if err != nil {
			t.Fatalf("%s: %v", tpl, err)
		}
		for _, body := range []string{r.Text, r.HTML} {
			for _, want := range []string{"042917", "10 minutes", "If this wasn't you, ignore this email"} {
				if !strings.Contains(strings.ReplaceAll(body, "&#39;", "'"), want) {
					t.Errorf("%s: body lacks %q", tpl, want)
				}
			}
			// TRD 8.3: code emails carry no links that could sign someone in.
			for _, forbidden := range []string{"http://", "https://", "href"} {
				if strings.Contains(body, forbidden) {
					t.Errorf("%s: body contains %q", tpl, forbidden)
				}
			}
		}
		if r.Subject == "" || strings.Contains(r.Subject, "042917") {
			t.Errorf("%s: subject %q (must exist and must not carry the code)", tpl, r.Subject)
		}
	}
	if _, err := Render(TemplateLoginCode, Payload{}); err == nil {
		t.Fatal("a code email without a code must not render")
	}
}

func TestRenderNotifications(t *testing.T) {
	when := time.Date(2026, 11, 14, 8, 30, 0, 0, time.UTC)
	for _, tpl := range []Template{TemplatePasswordAdded, TemplatePasswordChanged, TemplatePasswordReset} {
		r, err := Render(tpl, Payload{DeviceName: "Pixel <9>", OccurredAt: when})
		if err != nil {
			t.Fatalf("%s: %v", tpl, err)
		}
		if !strings.Contains(r.Text, "Pixel <9>") || !strings.Contains(r.Text, "14 Nov 2026") ||
			!strings.Contains(r.Text, "reset your password") {
			t.Errorf("%s: text body: %s", tpl, r.Text)
		}
		// The device name is escaped in HTML.
		if strings.Contains(r.HTML, "<9>") || !strings.Contains(r.HTML, "Pixel &lt;9&gt;") {
			t.Errorf("%s: device name not escaped in HTML: %s", tpl, r.HTML)
		}
	}
}

// --- classification -----------------------------------------------------------------------

func TestClassify(t *testing.T) {
	cases := []struct {
		err   error
		class Class
		code  string
	}{
		{Permanent("smtp_rcpt_550"), ClassPermanent, "smtp_rcpt_550"},
		{Retryable("throttled"), ClassRetryable, "throttled"},
		{Ambiguous("data_end_no_reply"), ClassAmbiguous, "data_end_no_reply"},
		{fmt.Errorf("wrapped: %w", Permanent("x")), ClassPermanent, "x"},
		{context.DeadlineExceeded, ClassAmbiguous, "timeout"},
		{fmt.Errorf("post: %w", context.DeadlineExceeded), ClassAmbiguous, "timeout"},
		{context.Canceled, ClassAmbiguous, "canceled"},
		{errors.New("provider said: user secret 123456 rejected"), ClassAmbiguous, "unclassified"},
		// Codes are sanitized, so a provider cannot write free text into last_error.
		{Permanent("Rejected: code 123456 for a@b.test!"), ClassPermanent, "rejectedcode123456forabtest"},
		{Retryable(""), ClassRetryable, "error"},
		{Retryable(strings.Repeat("a", 100)), ClassRetryable, strings.Repeat("a", 40)},
	}
	for _, c := range cases {
		class, code := classify(c.err)
		if class != c.class || code != c.code {
			t.Errorf("%v: got %s/%s, want %s/%s", c.err, class, code, c.class, c.code)
		}
	}
}

// --- worker configuration -----------------------------------------------------------------

func TestWorkerConfigDefaultsMatchTheTRD(t *testing.T) {
	c := WorkerConfig{}.withDefaults()
	if c.Lease != 2*time.Minute || c.MinLeaseForSend != 45*time.Second || c.SendTimeout != 30*time.Second ||
		c.BatchSize != 20 || c.PollInterval != time.Second {
		t.Fatalf("defaults changed: %+v", c)
	}
	want := []time.Duration{30 * time.Second, time.Minute, 2 * time.Minute, 4 * time.Minute}
	if fmt.Sprint(c.Backoff) != fmt.Sprint(want) {
		t.Fatalf("backoff = %v, want %v", c.Backoff, want)
	}
	if MaxSends != 5 {
		t.Fatal("the send budget is 5 (TRD 8.3, R14)")
	}
	if err := c.validate(); err != nil {
		t.Fatal(err)
	}
	bad := c
	bad.SendTimeout = bad.MinLeaseForSend
	if err := bad.validate(); err == nil {
		t.Fatal("a send timeout as long as the reservation margin must be rejected")
	}
}

func TestBackoffSchedule(t *testing.T) {
	w := &Worker{cfg: WorkerConfig{}.withDefaults()}
	for sends, want := range map[int]time.Duration{1: 30 * time.Second, 2: time.Minute, 3: 2 * time.Minute, 4: 4 * time.Minute, 5: 4 * time.Minute, 0: 30 * time.Second} {
		if got := w.backoff(sends); got != want {
			t.Errorf("after send %d: %s, want %s", sends, got, want)
		}
	}
}

func TestTemplateNamesCoverEveryTemplate(t *testing.T) {
	names := TemplateNames()
	if len(names) != len(specs) || !sort.StringsAreSorted(names) {
		t.Fatalf("names %v", names)
	}
	for _, n := range names {
		if !Template(n).valid() {
			t.Errorf("%s is not a valid template", n)
		}
	}
}
