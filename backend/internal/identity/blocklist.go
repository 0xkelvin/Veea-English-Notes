package identity

import (
	"bufio"
	_ "embed"
	"fmt"
	"io"
	"strings"
	"sync"

	"golang.org/x/text/unicode/norm"
)

//go:embed blocklist/common-passwords.txt
var embeddedBlocklist string

// Blocklist is an immutable set of known-bad passwords. Entries are stored normalized (NFKC,
// lowercase), so a lookup is case-insensitive and insensitive to compatibility forms.
type Blocklist struct {
	set map[string]struct{}
}

// maxBlocklistLine bounds a single entry while loading.
const maxBlocklistLine = 1 << 10

// LoadBlocklist reads one entry per line. Empty lines are skipped. Entries are not trimmed,
// because spaces can be part of a password.
func LoadBlocklist(r io.Reader) (*Blocklist, error) {
	b := &Blocklist{set: make(map[string]struct{})}
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 0, 512), maxBlocklistLine)
	for sc.Scan() {
		line := strings.TrimRight(sc.Text(), "\r")
		if line == "" {
			continue
		}
		b.set[normalizeForCompare(line)] = struct{}{}
	}
	if err := sc.Err(); err != nil {
		return nil, fmt.Errorf("identity: read blocklist: %w", err)
	}
	return b, nil
}

// NewBlocklist builds a set from entries, normalizing each one.
func NewBlocklist(entries ...string) *Blocklist {
	b := &Blocklist{set: make(map[string]struct{}, len(entries))}
	for _, e := range entries {
		b.set[normalizeForCompare(e)] = struct{}{}
	}
	return b
}

// Contains reports whether password is on the list. The password may be in any case and
// any Unicode normalization form.
func (b *Blocklist) Contains(password string) bool {
	if b == nil {
		return false
	}
	_, ok := b.set[normalizeForCompare(password)]
	return ok
}

// Len returns the number of distinct entries.
func (b *Blocklist) Len() int {
	if b == nil {
		return 0
	}
	return len(b.set)
}

var (
	defaultBlocklistOnce sync.Once
	defaultBlocklist     *Blocklist
	defaultBlocklistErr  error
)

// DefaultBlocklist returns the embedded list, parsed once and shared.
func DefaultBlocklist() (*Blocklist, error) {
	defaultBlocklistOnce.Do(func() {
		defaultBlocklist, defaultBlocklistErr = LoadBlocklist(strings.NewReader(embeddedBlocklist))
		if defaultBlocklistErr == nil && defaultBlocklist.Len() == 0 {
			defaultBlocklistErr = fmt.Errorf("identity: embedded blocklist is empty")
		}
	})
	return defaultBlocklist, defaultBlocklistErr
}

// normalizeForCompare is the single normalization used for blocklist entries and lookups.
func normalizeForCompare(s string) string {
	return strings.ToLower(norm.NFKC.String(s))
}
