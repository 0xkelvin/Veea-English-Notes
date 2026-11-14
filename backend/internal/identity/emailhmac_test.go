package identity

import (
	"bytes"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"strings"
	"testing"
)

func testKey(b byte) []byte { return bytes.Repeat([]byte{b}, 32) }

func mustEmail(t *testing.T, s string) Email {
	t.Helper()
	e, err := NormalizeEmail(s)
	if err != nil {
		t.Fatal(err)
	}
	return e
}

func TestEmailHMACIsHMACSHA256OfTheNormalizedEmail(t *testing.T) {
	h, err := NewEmailHMAC(testKey(1))
	if err != nil {
		t.Fatal(err)
	}
	e := mustEmail(t, "A.User@Example.TEST")

	m := hmac.New(sha256.New, testKey(1))
	m.Write([]byte("a.user@example.test"))
	want := m.Sum(nil)

	if got := h.Current(e); !bytes.Equal(got, want) || len(got) != 32 {
		t.Fatalf("digest = %x, want %x", got, want)
	}
	if got := h.CurrentHex(e); got != hex.EncodeToString(want) {
		t.Fatalf("hex = %s", got)
	}
}

// AC-8: spellings of one mailbox share a digest, different mailboxes do not.
func TestEmailHMACFollowsNormalization(t *testing.T) {
	h, _ := NewEmailHMAC(testKey(1))
	a := h.CurrentHex(mustEmail(t, "A.User@Example.TEST"))
	b := h.CurrentHex(mustEmail(t, "  a.user@example.test "))
	c := h.CurrentHex(mustEmail(t, "café@example.test"))
	d := h.CurrentHex(mustEmail(t, "café@example.test"))
	other := h.CurrentHex(mustEmail(t, "auser@example.test"))
	if a != b || c != d {
		t.Fatal("equivalent spellings must share a digest")
	}
	if a == other {
		t.Fatal("different mailboxes must not share a digest")
	}
}

func TestEmailHMACDigestNeverContainsTheEmail(t *testing.T) {
	h, _ := NewEmailHMAC(testKey(1))
	e := mustEmail(t, "secret.person@example.test")
	for _, s := range []string{h.CurrentHex(e), string(h.Current(e))} {
		if strings.Contains(s, "secret") || strings.Contains(s, "example") {
			t.Fatalf("digest leaks the address: %q", s)
		}
	}
}

func TestEmailHMACKeyRotation(t *testing.T) {
	old, _ := NewEmailHMAC(testKey(1))
	rotated, err := NewEmailHMAC(testKey(2), testKey(1))
	if err != nil {
		t.Fatal(err)
	}
	e := mustEmail(t, "learner@example.test")

	if bytes.Equal(rotated.Current(e), old.Current(e)) {
		t.Fatal("after rotation new digests must use the new key")
	}
	all := rotated.All(e)
	if len(all) != 2 || !bytes.Equal(all[0], rotated.Current(e)) || !bytes.Equal(all[1], old.Current(e)) {
		t.Fatal("All must list the current digest first, then the previous one")
	}
}

func TestEmailHMACKeyValidation(t *testing.T) {
	if _, err := NewEmailHMAC(); err == nil {
		t.Fatal("no keys must be rejected")
	}
	if _, err := NewEmailHMAC(bytes.Repeat([]byte{1}, 31)); err == nil {
		t.Fatal("a 31 byte key must be rejected")
	}
	if _, err := NewEmailHMAC(testKey(1), bytes.Repeat([]byte{2}, 8)); err == nil {
		t.Fatal("a short previous key must be rejected")
	}
	if _, err := NewEmailHMAC(bytes.Repeat([]byte{1}, 64)); err != nil {
		t.Fatalf("a 64 byte key is fine: %v", err)
	}
}

func TestEmailHMACCopiesItsKeys(t *testing.T) {
	key := testKey(1)
	h, _ := NewEmailHMAC(key)
	e := mustEmail(t, "learner@example.test")
	before := h.CurrentHex(e)
	key[0] = 0xff // the caller reuses its buffer
	if h.CurrentHex(e) != before {
		t.Fatal("mutating the caller's key slice changed the digest")
	}
}
