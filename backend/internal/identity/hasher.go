package identity

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"runtime"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"golang.org/x/crypto/argon2"
)

// Hashing errors. None of them ever carries the password or the stored hash.
var (
	// ErrBusy means no hashing slot became free within the wait limit. The API maps it
	// to 503 so memory stays bounded under attack (TRD 9.2).
	ErrBusy = errors.New("identity: hasher busy")
	// ErrMalformedHash means a stored hash is not a well-formed Argon2id PHC string, or its
	// parameters are outside the accepted bounds.
	ErrMalformedHash = errors.New("identity: malformed password hash")
	// ErrUnsupportedHash means the stored hash is well-formed but not Argon2id version 19.
	ErrUnsupportedHash = errors.New("identity: unsupported password hash")
	// ErrPasswordTooLong is returned by Hash for input beyond MaxPasswordInputBytes. Invalid
	// UTF-8 returns ErrInvalidPasswordEncoding.
	ErrPasswordTooLong = errors.New("identity: password too long")
)

// Bounds applied to every PHC string read from storage. They stop a corrupted or poisoned
// row from making Verify allocate gigabytes or run for minutes.
const (
	maxStoredMemoryKiB = 256 * 1024 // 256 MiB
	maxStoredTime      = 16
	maxStoredThreads   = 16
	minStoredSalt      = 8
	maxStoredSalt      = 64
	minStoredKey       = 16
	maxStoredKey       = 64
)

// Params are the Argon2id cost parameters (TRD 9.2).
type Params struct {
	MemoryKiB uint32 // m
	Time      uint32 // t
	Threads   uint8  // p
	SaltLen   uint32
	KeyLen    uint32
}

// DefaultParams are the approved defaults: m = 19 MiB, t = 2, p = 1, 16-byte salt, 32-byte key.
var DefaultParams = Params{MemoryKiB: 19 * 1024, Time: 2, Threads: 1, SaltLen: 16, KeyLen: 32}

// Validate checks that the parameters can be used and that Verify would accept the hashes
// they produce.
func (p Params) Validate() error {
	switch {
	case p.Threads < 1 || p.Threads > maxStoredThreads:
		return fmt.Errorf("identity: argon2 threads must be 1 to %d", maxStoredThreads)
	case p.Time < 1 || p.Time > maxStoredTime:
		return fmt.Errorf("identity: argon2 time must be 1 to %d", maxStoredTime)
	case p.MemoryKiB < 8*uint32(p.Threads) || p.MemoryKiB > maxStoredMemoryKiB:
		return fmt.Errorf("identity: argon2 memory must be %d to %d KiB", 8*uint32(p.Threads), maxStoredMemoryKiB)
	case p.SaltLen < minStoredSalt || p.SaltLen > maxStoredSalt:
		return fmt.Errorf("identity: argon2 salt length must be %d to %d bytes", minStoredSalt, maxStoredSalt)
	case p.KeyLen < minStoredKey || p.KeyLen > maxStoredKey:
		return fmt.Errorf("identity: argon2 key length must be %d to %d bytes", minStoredKey, maxStoredKey)
	}
	return nil
}

// HasherConfig configures a Hasher.
type HasherConfig struct {
	Params Params
	// MaxConcurrent is the number of hashes that may run at once. Zero means GOMAXPROCS.
	MaxConcurrent int
	// MaxWait is how long a caller waits for a free slot before ErrBusy. Zero means 2 s.
	MaxWait time.Duration
	// Rand supplies salts. Zero means crypto/rand. Tests inject a deterministic reader.
	Rand io.Reader
	// ObserveWait, if set, receives how long each call waited for a slot. It is the hook for
	// the argon2_wait_seconds metric.
	ObserveWait func(time.Duration)
}

// DefaultMaxWait is the longest a request waits for a hashing slot (TRD 9.2).
const DefaultMaxWait = 2 * time.Second

// Hasher hashes and verifies passwords with Argon2id under a bounded number of concurrent
// computations. It is safe for concurrent use.
//
// It never touches the database. Call it before opening a transaction.
type Hasher struct {
	params      Params
	slots       chan struct{}
	maxWait     time.Duration
	rand        io.Reader
	observeWait func(time.Duration)
	dummy       phc // a real hash, so unknown-account checks cost the same as real ones

	// onCompute is a test hook called around each Argon2 run. Nil in production.
	onCompute func() (done func())
}

// NewHasher validates cfg and computes the dummy hash used by VerifyDummy. It performs one
// Argon2 run, so call it at startup.
func NewHasher(cfg HasherConfig) (*Hasher, error) {
	if err := cfg.Params.Validate(); err != nil {
		return nil, err
	}
	if cfg.MaxConcurrent < 0 {
		return nil, errors.New("identity: MaxConcurrent must not be negative")
	}
	if cfg.MaxConcurrent == 0 {
		cfg.MaxConcurrent = runtime.GOMAXPROCS(0)
	}
	if cfg.MaxWait == 0 {
		cfg.MaxWait = DefaultMaxWait
	}
	if cfg.Rand == nil {
		cfg.Rand = rand.Reader
	}
	h := &Hasher{
		params:      cfg.Params,
		slots:       make(chan struct{}, cfg.MaxConcurrent),
		maxWait:     cfg.MaxWait,
		rand:        cfg.Rand,
		observeWait: cfg.ObserveWait,
	}

	secret := make([]byte, 32)
	if _, err := io.ReadFull(h.rand, secret); err != nil {
		return nil, fmt.Errorf("identity: read randomness: %w", err)
	}
	dummy, err := h.compute(h.params, []byte(base64.RawStdEncoding.EncodeToString(secret)))
	if err != nil {
		return nil, err
	}
	h.dummy = dummy
	return h, nil
}

// Params returns the parameters new hashes are created with.
func (h *Hasher) Params() Params { return h.params }

// Hash returns a PHC string for password: normalized to NFKC, a fresh random salt, the
// configured parameters. Callers normally pass the output of Policy.Validate; normalizing
// again changes nothing.
func (h *Hasher) Hash(ctx context.Context, password string) (string, error) {
	if len(password) > MaxPasswordInputBytes {
		return "", ErrPasswordTooLong
	}
	if !utf8.ValidString(password) {
		return "", ErrInvalidPasswordEncoding
	}
	if err := h.acquire(ctx); err != nil {
		return "", err
	}
	defer h.release()

	p, err := h.compute(h.params, []byte(NormalizePassword(password)))
	if err != nil {
		return "", err
	}
	return p.encode(), nil
}

// VerifyResult is the outcome of a successful verification attempt.
type VerifyResult struct {
	// Match reports whether the password is correct.
	Match bool
	// NeedsRehash is true only when Match is true and the stored hash was made with
	// parameters other than the current ones. The caller then stores a new hash.
	NeedsRehash bool
}

// Verify checks password against a stored PHC string using the parameters stored in it. A
// wrong password is not an error: it returns Match == false. A stored hash that cannot be
// parsed returns ErrMalformedHash or ErrUnsupportedHash, so corrupt data is never mistaken
// for a wrong password. Input that is too long to be a valid password cannot match and is
// answered without running Argon2.
func (h *Hasher) Verify(ctx context.Context, encoded, password string) (VerifyResult, error) {
	stored, err := parsePHC(encoded)
	if err != nil {
		return VerifyResult{}, err
	}
	if len(password) > MaxPasswordInputBytes || !utf8.ValidString(password) {
		return VerifyResult{}, nil
	}
	if err := h.acquire(ctx); err != nil {
		return VerifyResult{}, err
	}
	defer h.release()

	candidate, err := h.recompute(stored, []byte(NormalizePassword(password)))
	if err != nil {
		return VerifyResult{}, err
	}
	if subtle.ConstantTimeCompare(candidate, stored.key) != 1 {
		return VerifyResult{}, nil
	}
	return VerifyResult{Match: true, NeedsRehash: h.needsRehash(stored)}, nil
}

// VerifyDummy burns the same cost as a real Verify against a hash made with the current
// parameters. Use it when the account does not exist, has no password, or is only a pending
// registration, so response time does not reveal which case it was (AC-7). It never matches.
func (h *Hasher) VerifyDummy(ctx context.Context, password string) error {
	if len(password) > MaxPasswordInputBytes || !utf8.ValidString(password) {
		return nil
	}
	if err := h.acquire(ctx); err != nil {
		return err
	}
	defer h.release()

	candidate, err := h.recompute(h.dummy, []byte(NormalizePassword(password)))
	if err != nil {
		return err
	}
	_ = subtle.ConstantTimeCompare(candidate, h.dummy.key)
	return nil
}

// NeedsRehash reports whether a stored hash differs from the current parameters in memory,
// time, threads, salt length or key length. It parses only and runs no Argon2.
func (h *Hasher) NeedsRehash(encoded string) (bool, error) {
	stored, err := parsePHC(encoded)
	if err != nil {
		return false, err
	}
	return h.needsRehash(stored), nil
}

func (h *Hasher) needsRehash(p phc) bool {
	return p.memoryKiB != h.params.MemoryKiB ||
		p.time != h.params.Time ||
		p.threads != h.params.Threads ||
		uint32(len(p.salt)) != h.params.SaltLen ||
		uint32(len(p.key)) != h.params.KeyLen
}

// acquire takes a hashing slot, waiting up to maxWait. It honors ctx cancellation.
func (h *Hasher) acquire(ctx context.Context) error {
	start := time.Now()
	observe := func() {
		if h.observeWait != nil {
			h.observeWait(time.Since(start))
		}
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	select {
	case h.slots <- struct{}{}:
		observe()
		return nil
	default:
	}

	timer := time.NewTimer(h.maxWait)
	defer timer.Stop()
	select {
	case h.slots <- struct{}{}:
		observe()
		return nil
	case <-timer.C:
		observe()
		return ErrBusy
	case <-ctx.Done():
		observe()
		return ctx.Err()
	}
}

func (h *Hasher) release() { <-h.slots }

// compute creates a new hash with a fresh salt. The caller holds a slot, except in NewHasher.
func (h *Hasher) compute(p Params, password []byte) (phc, error) {
	salt := make([]byte, p.SaltLen)
	if _, err := io.ReadFull(h.rand, salt); err != nil {
		return phc{}, fmt.Errorf("identity: read salt: %w", err)
	}
	out := phc{memoryKiB: p.MemoryKiB, time: p.Time, threads: p.Threads, salt: salt}
	out.key = h.run(out, password, p.KeyLen)
	return out, nil
}

// recompute derives the key for stored parameters and salt.
func (h *Hasher) recompute(stored phc, password []byte) ([]byte, error) {
	return h.run(stored, password, uint32(len(stored.key))), nil
}

func (h *Hasher) run(p phc, password []byte, keyLen uint32) []byte {
	if h.onCompute != nil {
		defer h.onCompute()()
	}
	return argon2.IDKey(password, p.salt, p.time, p.memoryKiB, p.threads, keyLen)
}

// phc is a parsed Argon2id PHC string.
type phc struct {
	memoryKiB uint32
	time      uint32
	threads   uint8
	salt      []byte
	key       []byte
}

// encode renders the canonical form:
//
//	$argon2id$v=19$m=19456,t=2,p=1$<salt>$<key>
//
// with unpadded standard base64 for salt and key.
func (p phc) encode() string {
	b64 := base64.RawStdEncoding
	return fmt.Sprintf("$argon2id$v=%d$m=%d,t=%d,p=%d$%s$%s",
		argon2.Version, p.memoryKiB, p.time, p.threads, b64.EncodeToString(p.salt), b64.EncodeToString(p.key))
}

// parsePHC strictly parses an Argon2id PHC string. It accepts only the canonical encoding
// produced by encode and rejects anything else, so equal hashes have one spelling.
func parsePHC(s string) (phc, error) {
	parts := strings.Split(s, "$")
	// "$argon2id$v=19$m=..,t=..,p=..$salt$key" splits into 6 parts with an empty first one.
	if len(parts) != 6 || parts[0] != "" {
		return phc{}, ErrMalformedHash
	}
	if parts[1] != "argon2id" {
		if strings.HasPrefix(parts[1], "argon2") {
			return phc{}, ErrUnsupportedHash
		}
		return phc{}, ErrMalformedHash
	}
	version, ok := strings.CutPrefix(parts[2], "v=")
	if !ok {
		return phc{}, ErrMalformedHash
	}
	if version != strconv.Itoa(argon2.Version) {
		if _, err := strconv.ParseUint(version, 10, 32); err != nil {
			return phc{}, ErrMalformedHash
		}
		return phc{}, ErrUnsupportedHash
	}

	var out phc
	params := strings.Split(parts[3], ",")
	if len(params) != 3 {
		return phc{}, ErrMalformedHash
	}
	m, okM := cutUint(params[0], "m=", 32)
	t, okT := cutUint(params[1], "t=", 32)
	p, okP := cutUint(params[2], "p=", 8)
	if !okM || !okT || !okP {
		return phc{}, ErrMalformedHash
	}
	out.memoryKiB, out.time, out.threads = uint32(m), uint32(t), uint8(p)

	b64 := base64.RawStdEncoding.Strict()
	var err error
	if out.salt, err = b64.DecodeString(parts[4]); err != nil {
		return phc{}, ErrMalformedHash
	}
	if out.key, err = b64.DecodeString(parts[5]); err != nil {
		return phc{}, ErrMalformedHash
	}

	if (Params{MemoryKiB: out.memoryKiB, Time: out.time, Threads: out.threads,
		SaltLen: uint32(len(out.salt)), KeyLen: uint32(len(out.key))}).Validate() != nil {
		return phc{}, ErrMalformedHash
	}
	// Reject non-canonical spellings such as leading zeros in numbers.
	if out.encode() != s {
		return phc{}, ErrMalformedHash
	}
	return out, nil
}

// cutUint parses "<prefix><digits>" where digits are ASCII 0-9 only.
func cutUint(s, prefix string, bits int) (uint64, bool) {
	digits, ok := strings.CutPrefix(s, prefix)
	if !ok || digits == "" {
		return 0, false
	}
	for i := 0; i < len(digits); i++ {
		if digits[i] < '0' || digits[i] > '9' {
			return 0, false
		}
	}
	n, err := strconv.ParseUint(digits, 10, bits)
	return n, err == nil
}
