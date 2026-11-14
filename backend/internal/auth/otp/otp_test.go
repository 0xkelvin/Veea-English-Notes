package otp

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"strings"
	"testing"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/identity"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/notify"
)

var (
	key1 = bytes.Repeat([]byte{0x01}, 32)
	key2 = bytes.Repeat([]byte{0x02}, 32)
)

func TestTokenFormatAndStoredHash(t *testing.T) {
	tok, hash, err := newToken(bytes.NewReader(bytes.Repeat([]byte{0xab}, 32)))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(tok, "vct_") || len(tok) != 4+43 {
		t.Fatalf("token %q is not vct_ + 43 base64url characters", tok)
	}
	raw, err := base64.RawURLEncoding.DecodeString(tok[4:])
	if err != nil || !bytes.Equal(raw, bytes.Repeat([]byte{0xab}, 32)) {
		t.Fatal("token body must be the 32 random bytes, base64url without padding")
	}
	want := sha256.Sum256([]byte(tok))
	if !bytes.Equal(hash, want[:]) || !bytes.Equal(HashToken(tok), want[:]) {
		t.Fatal("the stored form must be SHA-256 of the whole token string")
	}
	if _, _, err := newToken(bytes.NewReader(make([]byte, 5))); err == nil {
		t.Fatal("a short randomness source must be an error, not a weak token")
	}
}

func TestTokensAreUnique(t *testing.T) {
	seen := map[string]bool{}
	for range 1000 {
		tok, _, err := newToken(cryptoReader{})
		if err != nil {
			t.Fatal(err)
		}
		if seen[tok] {
			t.Fatal("duplicate token")
		}
		seen[tok] = true
	}
}

// fixed returns 4-byte big-endian words, one per code candidate.
func fixed(words ...uint32) io.Reader {
	var b bytes.Buffer
	for _, w := range words {
		_ = binary.Write(&b, binary.BigEndian, w)
	}
	return &b
}

func TestCodeRejectionSampling(t *testing.T) {
	cases := []struct {
		name  string
		words []uint32
		want  string
	}{
		{"zero", []uint32{0}, "000000"},
		{"leading zeros kept", []uint32{42}, "000042"},
		{"modulo", []uint32{1_234_567}, "234567"},
		{"largest accepted", []uint32{codeLimit - 1}, "999999"},
		{"rejects the biased tail", []uint32{codeLimit, 0xffffffff, 7}, "000007"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, err := newCode(fixed(c.words...))
			if err != nil || got != c.want {
				t.Fatalf("got %q, %v; want %q", got, err, c.want)
			}
		})
	}
	if codeLimit%codeSpace != 0 || codeLimit > 1<<32 || (1<<32)-codeLimit >= codeSpace {
		t.Fatal("codeLimit must be the largest multiple of 10^6 that fits in 32 bits")
	}
}

func TestCodeFailsClosedOnBadRandomness(t *testing.T) {
	if _, err := newCode(bytes.NewReader([]byte{1, 2})); err == nil {
		t.Fatal("a short read must be an error")
	}
	always := make([]uint32, 64)
	for i := range always {
		always[i] = 0xffffffff
	}
	if _, err := newCode(fixed(always...)); err == nil {
		t.Fatal("a source that only returns rejected values must be an error")
	}
}

func TestCodesAreSixDigitsAndSpread(t *testing.T) {
	var firstDigit [10]int
	for range 20000 {
		c, err := newCode(cryptoReader{})
		if err != nil {
			t.Fatal(err)
		}
		if len(c) != 6 || strings.Trim(c, "0123456789") != "" {
			t.Fatalf("code %q is not 6 digits", c)
		}
		firstDigit[c[0]-'0']++
	}
	for d, n := range firstDigit {
		if n < 1500 || n > 2500 { // expected 2000 each; this bound fails with negligible probability
			t.Fatalf("first digit %d appeared %d times out of 20000", d, n)
		}
	}
}

func TestCodeHashIsHMACOfIDAndCode(t *testing.T) {
	keys, err := NewCodeKeys(key1)
	if err != nil {
		t.Fatal(err)
	}
	id := uuid.New()
	m := hmac.New(sha256.New, key1)
	m.Write(id[:])
	m.Write([]byte("123456"))
	if !bytes.Equal(keys.Hash(id, "123456"), m.Sum(nil)) {
		t.Fatal("stored hash must be HMAC-SHA256(key, id || code)")
	}
	if !keys.Match(id, "123456", keys.Hash(id, "123456")) {
		t.Fatal("the right code must match")
	}
	if keys.Match(id, "123457", keys.Hash(id, "123456")) {
		t.Fatal("a different code must not match")
	}
	// Bound to the challenge: the same code under another id is a different hash (TRD 4.1).
	if keys.Match(uuid.New(), "123456", keys.Hash(id, "123456")) {
		t.Fatal("a code must only match the challenge it was issued for")
	}
	if bytes.Contains(keys.Hash(id, "123456"), []byte("123456")) {
		t.Fatal("the hash must not contain the code")
	}
}

func TestCodeKeyRotation(t *testing.T) {
	old, _ := NewCodeKeys(key1)
	rotated, _ := NewCodeKeys(key2, key1)
	id := uuid.New()
	stored := old.Hash(id, "654321")
	if !rotated.Match(id, "654321", stored) {
		t.Fatal("a hash made with the previous key must still verify")
	}
	if bytes.Equal(rotated.Hash(id, "654321"), stored) {
		t.Fatal("new hashes must use the current key")
	}
	if !rotated.Match(id, "654321", rotated.Hash(id, "654321")) {
		t.Fatal("a hash made with the current key must verify")
	}
	only2, _ := NewCodeKeys(key2)
	if only2.Match(id, "654321", stored) {
		t.Fatal("once the previous key is dropped, its hashes no longer verify")
	}
}

func TestCodeKeyValidationNeverLeaksKeys(t *testing.T) {
	short := bytes.Repeat([]byte{0x5a}, 31)
	for name, keys := range map[string][][]byte{
		"none": nil, "short": {short}, "short previous": {key1, short}, "three": {key1, key1, key1},
	} {
		t.Run(name, func(t *testing.T) {
			_, err := NewCodeKeys(keys...)
			if err == nil {
				t.Fatal("expected an error")
			}
			if strings.Contains(err.Error(), string(short)) || strings.Contains(err.Error(), fmt.Sprintf("%x", short[:4])) {
				t.Fatal("error leaks key material")
			}
		})
	}
	k := bytes.Clone(key1)
	keys, _ := NewCodeKeys(k)
	id := uuid.New()
	h := keys.Hash(id, "111111")
	k[0] ^= 0xff
	if !bytes.Equal(keys.Hash(id, "111111"), h) {
		t.Fatal("CodeKeys must copy its keys")
	}
}

func TestPurposesMapToTemplatesAndActions(t *testing.T) {
	want := map[Purpose]notify.Template{
		PurposeSignup: notify.TemplateSignupCode, PurposeLogin: notify.TemplateLoginCode,
		PurposePasswordReset: notify.TemplateResetCode, PurposeSetPassword: notify.TemplateSetPasswordCode,
		PurposeEmailCurrent: notify.TemplateEmailCurrentCode, PurposeEmailNew: notify.TemplateEmailNewCode,
	}
	if len(purposes) != len(want) {
		t.Fatalf("expected all TRD 01/03 purposes, got %d", len(purposes))
	}
	for p, tmpl := range want {
		info, err := p.info()
		if err != nil || info.template != tmpl || !tmpl.IsCode() {
			t.Fatalf("%s: template %s, %v", p, info.template, err)
		}
		if (!strings.HasPrefix(info.startAction, "auth.") && !strings.HasPrefix(info.startAction, "account.")) || (!strings.HasPrefix(info.verifyAction, "auth.") && !strings.HasPrefix(info.verifyAction, "account.")) {
			t.Fatalf("%s: audit actions %q %q", p, info.startAction, info.verifyAction)
		}
	}
	if _, err := Purpose("email_change").info(); err == nil {
		t.Fatal("an unknown purpose must be refused")
	}
	if !purposes[PurposeSetPassword].callerBound || purposes[PurposeLogin].callerBound {
		t.Fatal("only set_password is bound to the caller's session")
	}
}

func TestBindTarget(t *testing.T) {
	user, session := uuid.New(), uuid.New()
	e := identity.Email{Display: "Learner@Example.test", Normalized: "learner@example.test"}
	cases := []struct {
		name    string
		purpose Purpose
		method  SignupMethod
		target  Target
		wantErr bool
		want    Target
	}{
		{"signup otp", PurposeSignup, SignupOTP, Target{Eligible: true}, false, Target{Eligible: true, To: e.Display}},
		{"signup password keeps hash", PurposeSignup, SignupPassword, Target{Eligible: true, PendingPasswordHash: "$argon2id$x"}, false,
			Target{Eligible: true, PendingPasswordHash: "$argon2id$x", To: e.Display}},
		{"signup password needs hash", PurposeSignup, SignupPassword, Target{Eligible: true}, true, Target{}},
		{"signup otp refuses hash", PurposeSignup, SignupOTP, Target{Eligible: true, PendingPasswordHash: "h"}, true, Target{}},
		{"signup refuses account", PurposeSignup, SignupOTP, Target{Eligible: true, UserID: &user}, true, Target{}},
		{"login needs account", PurposeLogin, "", Target{Eligible: true}, true, Target{}},
		{"login refuses session", PurposeLogin, "", Target{Eligible: true, UserID: &user, SessionID: &session}, true, Target{}},
		{"login custom recipient", PurposeLogin, "", Target{Eligible: true, UserID: &user, To: "stored@example.test"}, false,
			Target{Eligible: true, UserID: &user, To: "stored@example.test"}},
		{"set_password needs session", PurposeSetPassword, "", Target{Eligible: true, UserID: &user}, true, Target{}},
		{"set_password bound", PurposeSetPassword, "", Target{Eligible: true, UserID: &user, SessionID: &session}, false,
			Target{Eligible: true, UserID: &user, SessionID: &session, To: e.Display}},
		// An ineligible request is stripped of every binding and credential (TRD 4.4).
		{"ineligible drops everything", PurposeSignup, SignupPassword,
			Target{UserID: &user, SessionID: &session, PendingPasswordHash: "h", To: "x@example.test"}, false, Target{}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, err := bindTarget(purposes[c.purpose], StartRequest{Purpose: c.purpose, SignupMethod: c.method, Email: e}, c.target)
			if (err != nil) != c.wantErr {
				t.Fatalf("err = %v, want error %v", err, c.wantErr)
			}
			if !c.wantErr && fmt.Sprint(got) != fmt.Sprint(c.want) {
				t.Fatalf("got %+v, want %+v", got, c.want)
			}
		})
	}
}

func TestStartRequestValidation(t *testing.T) {
	e := identity.Email{Display: "a@example.test", Normalized: "a@example.test"}
	var check Eligibility = func(context.Context, pgx.Tx) (Target, error) { return Target{}, nil }
	cases := []struct {
		name string
		req  StartRequest
		ok   bool
	}{
		{"login", StartRequest{Purpose: PurposeLogin, Email: e, Check: check}, true},
		{"signup otp", StartRequest{Purpose: PurposeSignup, SignupMethod: SignupOTP, Email: e, Check: check}, true},
		{"signup without method", StartRequest{Purpose: PurposeSignup, Email: e, Check: check}, false},
		{"signup with unknown method", StartRequest{Purpose: PurposeSignup, SignupMethod: "magic", Email: e, Check: check}, false},
		{"method on login", StartRequest{Purpose: PurposeLogin, SignupMethod: SignupOTP, Email: e, Check: check}, false},
		{"no eligibility check", StartRequest{Purpose: PurposeLogin, Email: e}, false},
		{"no email", StartRequest{Purpose: PurposeLogin, Check: check}, false},
	}
	for _, c := range cases {
		if err := c.req.validate(); (err == nil) != c.ok {
			t.Errorf("%s: err = %v", c.name, err)
		}
	}
}

func TestFlowOutcomesUnwrap(t *testing.T) {
	inner := errors.New("signup_unavailable")
	for _, err := range []error{CommitFailure("account_exists", inner), Rollback("account_unavailable", inner)} {
		if !errors.Is(err, inner) || err.Error() != inner.Error() {
			t.Fatalf("%v must unwrap to the flow's error", err)
		}
	}
	var ff *flowFailure
	if !errors.As(fmt.Errorf("wrapped: %w", CommitFailure("r", inner)), &ff) || !ff.commit {
		t.Fatal("a wrapped CommitFailure must still be recognized")
	}
}

type cryptoReader struct{}

func (cryptoReader) Read(p []byte) (int, error) { return io.ReadFull(rand.Reader, p) }

// Review finding 1 and 2 (release hardening): a failed commit is an error, never the result the
// rolled-back closure prepared, and a database failure while checking limits is not rate limiting.
func TestVerifyMetricResults(t *testing.T) {
	commitFailed := errors.New("commit: connection reset")
	cases := []struct {
		name          string
		out           outcome
		txErr, result error
		want          string
	}{
		{"success", outcome{}, nil, nil, "success"},
		{"invalid code", outcome{reject: ErrInvalidCode}, nil, ErrInvalidCode, "invalid_code"},
		{"attempts", outcome{reject: ErrAttemptsExceeded}, nil, ErrAttemptsExceeded, "attempts_exceeded"},
		{"commit failed after a rejection", outcome{reject: ErrInvalidCode}, commitFailed, commitFailed, "error"},
		{"commit failed after CommitFailure", outcome{flowFail: &flowFailure{commit: true, err: errors.New("x")}}, commitFailed, commitFailed, "error"},
		{"CommitFailure committed", outcome{flowFail: &flowFailure{commit: true, err: errors.New("x")}}, nil, errors.New("x"), "rejected"},
		{"Rollback", outcome{}, Rollback("account_unavailable", ErrInvalidCode), ErrInvalidCode, "rejected"},
	}
	for _, c := range cases {
		out := c.out
		if got := verifyResult(&out, c.txErr, c.result); got != c.want {
			t.Errorf("%s: %q, want %q", c.name, got, c.want)
		}
	}
	if limitResult(&RateLimitedError{Rule: "x", RetryAfter: 1}) != "rate_limited" || limitResult(errors.New("db down")) != "error" {
		t.Fatal("limit refusals and database errors must be told apart")
	}
}
