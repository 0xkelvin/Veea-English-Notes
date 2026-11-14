package otp

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"fmt"
	"io"

	"github.com/google/uuid"
)

// TokenPrefix marks a challenge token, so log redaction and secret scanners can spot one
// (TRD 4.1, 11.2).
const TokenPrefix = "vct_"

// tokenBytes is the random part of a challenge token.
const tokenBytes = 32

// MinKeyBytes is the shortest accepted OTP key (TRD 13).
const MinKeyBytes = 32

// newToken returns a challenge token, "vct_" + base64url(32 random bytes), and its SHA-256,
// which is all the database stores (TRD 4.1).
func newToken(r io.Reader) (token string, hash []byte, err error) {
	var b [tokenBytes]byte
	if _, err := io.ReadFull(r, b[:]); err != nil {
		return "", nil, errors.New("otp: read randomness for the challenge token")
	}
	token = TokenPrefix + base64.RawURLEncoding.EncodeToString(b[:])
	return token, HashToken(token), nil
}

// HashToken is the stored form of a challenge token: SHA-256 of the whole token string. Any
// input is accepted, so a malformed token simply matches no row.
func HashToken(token string) []byte {
	h := sha256.Sum256([]byte(token))
	return h[:]
}

// codeSpace is the number of 6-digit codes. codeLimit is the largest multiple of codeSpace
// that fits in 32 bits: values at or above it are rejected so every code is equally likely.
const (
	codeSpace = 1_000_000
	codeLimit = (1 << 32) / codeSpace * codeSpace
)

// newCode returns 6 decimal digits from r by rejection sampling (TRD 4.2). It reads 4 bytes at
// a time.
func newCode(r io.Reader) (string, error) {
	var b [4]byte
	for range 64 {
		if _, err := io.ReadFull(r, b[:]); err != nil {
			return "", errors.New("otp: read randomness for the code")
		}
		v := binary.BigEndian.Uint32(b[:])
		if v < codeLimit {
			return fmt.Sprintf("%06d", v%codeSpace), nil
		}
	}
	// 64 rejections in a row has probability below 2^-500 from a real source.
	return "", errors.New("otp: randomness source keeps returning out-of-range values")
}

// CodeKeys computes and checks stored code hashes: HMAC-SHA256(key, challenge_id || code)
// (TRD 4.2). A plain hash of a 6-digit code could be reversed from a database dump in a
// moment; the key keeps a dump useless on its own.
//
// Keys rotate as "current, previous" (TRD 13): new hashes use the current key, and Match tries
// every key, so challenges issued just before a rotation still verify.
type CodeKeys struct {
	keys [][]byte
}

// NewCodeKeys returns CodeKeys for keys, current first. One or two keys, each at least
// MinKeyBytes long. Errors never include key material.
func NewCodeKeys(keys ...[]byte) (*CodeKeys, error) {
	if len(keys) == 0 || len(keys) > 2 {
		return nil, errors.New("otp: one or two OTP keys are required, current first")
	}
	cp := make([][]byte, len(keys))
	for i, k := range keys {
		if len(k) < MinKeyBytes {
			return nil, fmt.Errorf("otp: OTP key %d is shorter than %d bytes", i+1, MinKeyBytes)
		}
		cp[i] = append([]byte(nil), k...)
	}
	return &CodeKeys{keys: cp}, nil
}

// Hash returns the stored hash of code for challenge id under the current key.
func (c *CodeKeys) Hash(id uuid.UUID, code string) []byte { return codeMAC(c.keys[0], id, code) }

// Match reports whether code is the code of challenge id. It computes the MAC under every key
// and compares each with hmac.Equal before combining, so the work done does not depend on which
// key matched or on how much of the value matched.
func (c *CodeKeys) Match(id uuid.UUID, code string, stored []byte) bool {
	ok := false
	for _, k := range c.keys {
		if hmac.Equal(codeMAC(k, id, code), stored) {
			ok = true
		}
	}
	return ok
}

func codeMAC(key []byte, id uuid.UUID, code string) []byte {
	m := hmac.New(sha256.New, key)
	m.Write(id[:])
	m.Write([]byte(code))
	return m.Sum(nil)
}
