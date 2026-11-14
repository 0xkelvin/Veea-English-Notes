package identity

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
)

// MinEmailHMACKeyBytes is the shortest accepted key (TRD 13: keys shorter than 32 bytes are
// refused at startup).
const MinEmailHMACKeyBytes = 32

// EmailHMAC derives the keyed digest of a normalized email that stands in for the address in
// cooldown rows, rate-limit keys and audit events, so none of them stores a raw email
// (TRD 6.4, 6.9, 6.8). It is HMAC-SHA256(key, Email.Normalized).
//
// It accepts only an Email, which NormalizeEmail produces, so every caller uses the same
// normalization and two spellings of one mailbox always share a digest (AC-8).
//
// Keys rotate as "current, previous". New digests always use the current key. The previous key
// exists so later code can look up digests made before a rotation (audit correlation). Rate
// limit counters and cooldown rows are keyed by the current digest only: right after a rotation
// they start from zero, which is an accepted, bounded loss of history.
type EmailHMAC struct {
	keys [][]byte
}

// NewEmailHMAC returns a digester for keys, current first. At least one key is required, each
// of at least MinEmailHMACKeyBytes bytes.
func NewEmailHMAC(keys ...[]byte) (*EmailHMAC, error) {
	if len(keys) == 0 {
		return nil, errors.New("identity: at least one email HMAC key is required")
	}
	cp := make([][]byte, len(keys))
	for i, k := range keys {
		if len(k) < MinEmailHMACKeyBytes {
			return nil, fmt.Errorf("identity: email HMAC key %d is shorter than %d bytes", i, MinEmailHMACKeyBytes)
		}
		cp[i] = append([]byte(nil), k...)
	}
	return &EmailHMAC{keys: cp}, nil
}

// Current returns the digest under the current key. It is 32 bytes long.
func (h *EmailHMAC) Current(e Email) []byte { return digest(h.keys[0], e.Normalized) }

// CurrentHex is Current in lowercase hex, for text keys.
func (h *EmailHMAC) CurrentHex(e Email) string { return hex.EncodeToString(h.Current(e)) }

// All returns the digests under every configured key, current first.
func (h *EmailHMAC) All(e Email) [][]byte {
	out := make([][]byte, len(h.keys))
	for i, k := range h.keys {
		out[i] = digest(k, e.Normalized)
	}
	return out
}

func digest(key []byte, normalized string) []byte {
	m := hmac.New(sha256.New, key)
	m.Write([]byte(normalized))
	return m.Sum(nil)
}
