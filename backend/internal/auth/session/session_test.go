package session

import (
	"bytes"
	"crypto/sha256"
	"strings"
	"testing"
)

func TestDeviceValidation(t *testing.T) {
	ok := []Device{
		{Name: "Pixel 9", Platform: "android"}, {Name: "x", Platform: "ios"},
		{Name: strings.Repeat("é", 64), Platform: "web"}, {Name: "Laptop", Platform: "other"},
	}
	for _, d := range ok {
		if err := d.Validate(); err != nil {
			t.Errorf("%+v: %v", d, err)
		}
	}
	bad := []Device{
		{Name: "", Platform: "ios"}, {Name: "   ", Platform: "ios"}, {Name: strings.Repeat("a", 65), Platform: "ios"},
		{Name: "tab\tname", Platform: "ios"}, {Name: "nul\x00", Platform: "ios"}, {Name: "\xff", Platform: "ios"},
		{Name: "Pixel", Platform: "Android"}, {Name: "Pixel", Platform: ""}, {Name: "Pixel", Platform: "windows"},
	}
	for _, d := range bad {
		if err := d.Validate(); err != ErrInvalidDevice {
			t.Errorf("%q/%q: want ErrInvalidDevice, got %v", d.Name, d.Platform, err)
		}
	}
}

func TestPendingTokens(t *testing.T) {
	p, err := NewPending(nil)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(p.access, AccessPrefix) || !strings.HasPrefix(p.refresh, RefreshPrefix) ||
		len(p.access) != 4+43 || len(p.refresh) != 4+43 || p.access[4:] == p.refresh[4:] {
		t.Fatal("tokens must be distinct vat_/vrt_ + 43 base64url characters")
	}
	want := sha256.Sum256([]byte(p.access))
	if !bytes.Equal(p.accessHash, want[:]) || !bytes.Equal(HashToken(p.refresh), p.refreshHash) {
		t.Fatal("stored forms must be SHA-256 of the whole token")
	}
	if _, err := NewPending(bytes.NewReader(make([]byte, 40))); err == nil {
		t.Fatal("short randomness must be an error, not a weak token")
	}
	q, _ := NewPending(nil)
	if q.id == p.id || q.access == p.access {
		t.Fatal("ids and tokens must be unique")
	}
}

func TestLifetimesMatchTheTRD(t *testing.T) {
	if AccessTTL.Minutes() != 15 || RefreshIdleTTL.Hours() != 30*24 || AbsoluteTTL.Hours() != 90*24 || MaxActive != 20 {
		t.Fatal("TRD 8.1 lifetimes and R11 cap changed")
	}
}
