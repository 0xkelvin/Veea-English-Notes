package identity

import (
	"bytes"
	"context"
	"errors"
	"go/parser"
	"go/token"
	"io"
	"os"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// fastParams keep unit tests quick. The production defaults are covered separately.
var fastParams = Params{MemoryKiB: 64, Time: 1, Threads: 1, SaltLen: 16, KeyLen: 32}

func newTestHasher(t *testing.T, mutate ...func(*HasherConfig)) *Hasher {
	t.Helper()
	cfg := HasherConfig{Params: fastParams, MaxConcurrent: 4, MaxWait: time.Second}
	for _, m := range mutate {
		m(&cfg)
	}
	h, err := NewHasher(cfg)
	if err != nil {
		t.Fatal(err)
	}
	return h
}

func mustHash(t *testing.T, h *Hasher, password string) string {
	t.Helper()
	encoded, err := h.Hash(context.Background(), password)
	if err != nil {
		t.Fatal(err)
	}
	return encoded
}

func isInvalidHash(err error) bool {
	return errors.Is(err, ErrMalformedHash) || errors.Is(err, ErrUnsupportedHash)
}

// --- format and known answers -------------------------------------------------------------

func TestDefaultParamsMatchTheApprovedValues(t *testing.T) {
	if DefaultParams != (Params{MemoryKiB: 19456, Time: 2, Threads: 1, SaltLen: 16, KeyLen: 32}) {
		t.Fatalf("DefaultParams changed: %+v", DefaultParams)
	}
	if err := DefaultParams.Validate(); err != nil {
		t.Fatal(err)
	}
}

func TestHashWithProductionParametersUsesCanonicalPHC(t *testing.T) {
	h, err := NewHasher(HasherConfig{Params: DefaultParams})
	if err != nil {
		t.Fatal(err)
	}
	encoded := mustHash(t, h, "correct horse battery staple")
	// 16-byte salt is 22 base64 characters, 32-byte key is 43.
	if !regexp.MustCompile(`^\$argon2id\$v=19\$m=19456,t=2,p=1\$[A-Za-z0-9+/]{22}\$[A-Za-z0-9+/]{43}$`).MatchString(encoded) {
		t.Fatalf("unexpected format: %s", encoded)
	}
	res, err := h.Verify(context.Background(), encoded, "correct horse battery staple")
	if err != nil || !res.Match || res.NeedsRehash {
		t.Fatalf("round trip: %+v %v", res, err)
	}
}

// Reference vectors from the Argon2 reference implementation ("password", salt "somesalt",
// 24-byte output), as used by golang.org/x/crypto/argon2. They pin our PHC parsing and the
// parameter order to an independent source.
func TestVerifyKnownAnswers(t *testing.T) {
	h := newTestHasher(t)
	cases := []struct{ name, encoded string }{
		{"t=2 m=64 p=1", "$argon2id$v=19$m=64,t=2,p=1$c29tZXNhbHQ$Bo1ismRVk2qm6+YAYLCmWHDb+j3fjUH3"},
		{"t=2 m=64 p=2", "$argon2id$v=19$m=64,t=2,p=2$c29tZXNhbHQ$NQrDciL0Nsy1wJcvHr079rlYvyBxhBNi"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			res, err := h.Verify(context.Background(), c.encoded, "password")
			if err != nil || !res.Match {
				t.Fatalf("reference vector did not verify: %+v %v", res, err)
			}
			// Stored with other parameters than the hasher's, so a rehash is due.
			if !res.NeedsRehash {
				t.Fatal("expected NeedsRehash for a hash with different parameters")
			}
			if res, _ := h.Verify(context.Background(), c.encoded, "Password"); res.Match {
				t.Fatal("verification must be case sensitive")
			}
		})
	}
}

// --- hash and verify ----------------------------------------------------------------------

func TestHashVerifyRoundTrip(t *testing.T) {
	h := newTestHasher(t)
	ctx := context.Background()
	encoded := mustHash(t, h, "a long enough passphrase")

	res, err := h.Verify(ctx, encoded, "a long enough passphrase")
	if err != nil || !res.Match || res.NeedsRehash {
		t.Fatalf("correct password: %+v %v", res, err)
	}
}

func TestVerifyWrongPasswordIsNotAnError(t *testing.T) {
	h := newTestHasher(t)
	encoded := mustHash(t, h, "a long enough passphrase")
	for _, wrong := range []string{
		"", " ", "a long enough passphras", "a long enough passphrasee", "A long enough passphrase",
		"a long enough passphrase ", " a long enough passphrase", strings.Repeat("x", 200),
	} {
		res, err := h.Verify(context.Background(), encoded, wrong)
		if err != nil {
			t.Fatalf("%q: a wrong password must not be an error: %v", wrong, err)
		}
		if res.Match || res.NeedsRehash {
			t.Fatalf("%q: matched or asked for a rehash: %+v", wrong, res)
		}
	}
}

func TestWrongPasswordNeverReportsRehash(t *testing.T) {
	old := newTestHasher(t)
	encoded := mustHash(t, old, "a long enough passphrase")
	newer := newTestHasher(t, func(c *HasherConfig) { c.Params.Time = 2 })
	res, err := newer.Verify(context.Background(), encoded, "wrong wrong wrong")
	if err != nil || res.Match || res.NeedsRehash {
		t.Fatalf("got %+v %v", res, err)
	}
}

func TestSaltsAreUnique(t *testing.T) {
	h := newTestHasher(t)
	a, b := mustHash(t, h, "same password, twice"), mustHash(t, h, "same password, twice")
	if a == b {
		t.Fatal("two hashes of one password must differ")
	}
	for _, e := range []string{a, b} {
		if res, _ := h.Verify(context.Background(), e, "same password, twice"); !res.Match {
			t.Fatal("both must verify")
		}
	}
}

func TestPasswordsAreNormalizedToNFKC(t *testing.T) {
	h := newTestHasher(t)
	encoded := mustHash(t, h, "ｆｕｌｌｗｉｄｔｈ-password") // fullwidth letters
	for _, same := range []string{"fullwidth-password", "ｆｕｌｌｗｉｄｔｈ-password"} {
		if res, _ := h.Verify(context.Background(), encoded, same); !res.Match {
			t.Errorf("%q should match after NFKC", same)
		}
	}
	composed := mustHash(t, h, "café au lait 1234")
	if res, _ := h.Verify(context.Background(), composed, "café au lait 1234"); !res.Match {
		t.Error("composed and decomposed forms must match")
	}
}

func TestHashUsesTheInjectedRandomness(t *testing.T) {
	salt := bytes.Repeat([]byte{7}, 16)
	// First read is the dummy hash secret (32 bytes), then the salt for our hash.
	r := io.MultiReader(bytes.NewReader(bytes.Repeat([]byte{1}, 32+16)), bytes.NewReader(salt))
	h := newTestHasher(t, func(c *HasherConfig) { c.Rand = r })
	encoded := mustHash(t, h, "deterministic salt test")
	if !strings.Contains(encoded, "$BwcHBwcHBwcHBwcHBwcHBw$") { // base64 of sixteen 0x07 bytes
		t.Fatalf("salt did not come from the injected reader: %s", encoded)
	}
}

type failingReader struct{}

func (failingReader) Read([]byte) (int, error) { return 0, errors.New("entropy exhausted") }

func TestRandomnessFailureIsAnErrorNotAWeakHash(t *testing.T) {
	if _, err := NewHasher(HasherConfig{Params: fastParams, Rand: failingReader{}}); err == nil {
		t.Fatal("NewHasher must fail when randomness fails")
	}
	r := io.MultiReader(bytes.NewReader(bytes.Repeat([]byte{1}, 32+16)), failingReader{})
	h := newTestHasher(t, func(c *HasherConfig) { c.Rand = r })
	if _, err := h.Hash(context.Background(), "some password here"); err == nil {
		t.Fatal("Hash must fail when randomness fails")
	}
}

func TestOversizedAndInvalidInput(t *testing.T) {
	h := newTestHasher(t)
	ctx := context.Background()
	if _, err := h.Hash(ctx, strings.Repeat("x", MaxPasswordInputBytes+1)); !errors.Is(err, ErrPasswordTooLong) {
		t.Fatalf("Hash oversized: %v", err)
	}
	if _, err := h.Hash(ctx, "bad-\xff-utf8-password"); !errors.Is(err, ErrInvalidPasswordEncoding) {
		t.Fatalf("Hash invalid UTF-8: %v", err)
	}

	// Verify answers "no match" without running Argon2 for input that cannot be a password.
	var runs atomic.Int32
	h.onCompute = func() func() { runs.Add(1); return func() {} }
	encoded := mustHash(t, h, "a long enough passphrase")
	runs.Store(0)
	for _, in := range []string{strings.Repeat("x", MaxPasswordInputBytes+1), "bad-\xff-utf8"} {
		res, err := h.Verify(ctx, encoded, in)
		if err != nil || res.Match {
			t.Fatalf("got %+v %v", res, err)
		}
	}
	if runs.Load() != 0 {
		t.Fatalf("Argon2 ran %d times for input that cannot match", runs.Load())
	}
}

// --- malformed and unsupported stored hashes ----------------------------------------------

func TestVerifyRejectsMalformedHashes(t *testing.T) {
	h := newTestHasher(t)
	good := mustHash(t, h, "a long enough passphrase")
	parts := strings.Split(good, "$") // "", argon2id, v=19, params, salt, key
	join := func(p ...string) string { return strings.Join(p, "$") }
	salt, key := parts[4], parts[5]

	malformed := map[string]string{
		"empty":                   "",
		"plain text":              "hunter2",
		"bcrypt":                  "$2a$10$N9qo8uLOickgx2ZMRZoMyeIjZAgcfl7p92ldGxad68LJZdL17lhWy",
		"missing key":             join("", "argon2id", "v=19", "m=64,t=1,p=1", salt),
		"extra field":             good + "$extra",
		"no leading dollar":       strings.TrimPrefix(good, "$"),
		"params out of order":     join("", "argon2id", "v=19", "t=1,m=64,p=1", salt, key),
		"missing parameter":       join("", "argon2id", "v=19", "m=64,t=1", salt, key),
		"extra parameter":         join("", "argon2id", "v=19", "m=64,t=1,p=1,q=2", salt, key),
		"empty parameter value":   join("", "argon2id", "v=19", "m=,t=1,p=1", salt, key),
		"non numeric memory":      join("", "argon2id", "v=19", "m=lots,t=1,p=1", salt, key),
		"signed number":           join("", "argon2id", "v=19", "m=+64,t=1,p=1", salt, key),
		"hex number":              join("", "argon2id", "v=19", "m=0x40,t=1,p=1", salt, key),
		"leading zero":            join("", "argon2id", "v=19", "m=064,t=1,p=1", salt, key),
		"memory overflows":        join("", "argon2id", "v=19", "m=99999999999,t=1,p=1", salt, key),
		"memory too large":        join("", "argon2id", "v=19", "m=4194304,t=1,p=1", salt, key),
		"memory below 8 per lane": join("", "argon2id", "v=19", "m=8,t=1,p=2", salt, key),
		"time zero":               join("", "argon2id", "v=19", "m=64,t=0,p=1", salt, key),
		"time too large":          join("", "argon2id", "v=19", "m=64,t=17,p=1", salt, key),
		"threads zero":            join("", "argon2id", "v=19", "m=64,t=1,p=0", salt, key),
		"threads over 8 bits":     join("", "argon2id", "v=19", "m=64,t=1,p=256", salt, key),
		"threads too many":        join("", "argon2id", "v=19", "m=64,t=1,p=17", salt, key),
		"version not a number":    join("", "argon2id", "v=x", "m=64,t=1,p=1", salt, key),
		"version missing prefix":  join("", "argon2id", "19", "m=64,t=1,p=1", salt, key),
		"salt not base64":         join("", "argon2id", "v=19", "m=64,t=1,p=1", "!!!!!!!!!!!!!!!!", key),
		"padded salt":             join("", "argon2id", "v=19", "m=64,t=1,p=1", salt+"==", key),
		"salt too short":          join("", "argon2id", "v=19", "m=64,t=1,p=1", "AAAAAAA", key),
		"salt too long":           join("", "argon2id", "v=19", "m=64,t=1,p=1", strings.Repeat("A", 100), key),
		"key not base64":          join("", "argon2id", "v=19", "m=64,t=1,p=1", salt, "***"),
		"key too short":           join("", "argon2id", "v=19", "m=64,t=1,p=1", salt, "AAAAAAAAAAA"),
		"key too long":            join("", "argon2id", "v=19", "m=64,t=1,p=1", salt, strings.Repeat("A", 100)),
		"non-canonical base64":    join("", "argon2id", "v=19", "m=64,t=1,p=1", salt, key[:len(key)-1]+"B"),
		"trailing newline":        good + "\n",
		"leading space":           " " + good,
		"trailing space":          good + " ",
		"nul byte":                good + "\x00",
	}
	for name, in := range malformed {
		t.Run(name, func(t *testing.T) {
			res, err := h.Verify(context.Background(), in, "a long enough passphrase")
			if !isInvalidHash(err) {
				t.Fatalf("expected a hash error, got %+v, %v", res, err)
			}
			if res.Match || res.NeedsRehash {
				t.Fatalf("a malformed hash must never match: %+v", res)
			}
			if err != nil && in != "" && strings.Contains(err.Error(), strings.TrimSpace(in)) {
				t.Fatalf("error leaks the stored hash: %v", err)
			}
			if _, err := h.NeedsRehash(in); !isInvalidHash(err) {
				t.Fatalf("NeedsRehash should reject it too, got %v", err)
			}
		})
	}
}

func TestVerifySeparatesUnsupportedFromMalformed(t *testing.T) {
	h := newTestHasher(t)
	good := mustHash(t, h, "a long enough passphrase")
	salt, key := strings.Split(good, "$")[4], strings.Split(good, "$")[5]
	unsupported := map[string]string{
		"argon2i":   "$argon2i$v=19$m=64,t=1,p=1$" + salt + "$" + key,
		"argon2d":   "$argon2d$v=19$m=64,t=1,p=1$" + salt + "$" + key,
		"version16": "$argon2id$v=16$m=64,t=1,p=1$" + salt + "$" + key,
		"version20": "$argon2id$v=20$m=64,t=1,p=1$" + salt + "$" + key,
	}
	for name, in := range unsupported {
		t.Run(name, func(t *testing.T) {
			if _, err := h.Verify(context.Background(), in, "x"); !errors.Is(err, ErrUnsupportedHash) {
				t.Fatalf("got %v", err)
			}
		})
	}
}

// A poisoned row must not make Verify allocate gigabytes.
func TestVerifyRejectsHugeMemoryWithoutRunningArgon2(t *testing.T) {
	h := newTestHasher(t)
	var runs atomic.Int32
	h.onCompute = func() func() { runs.Add(1); return func() {} }
	in := "$argon2id$v=19$m=4194304,t=16,p=16$c29tZXNhbHQ$AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
	start := time.Now()
	if _, err := h.Verify(context.Background(), in, "x"); !isInvalidHash(err) {
		t.Fatalf("got %v", err)
	}
	if runs.Load() != 0 || time.Since(start) > 500*time.Millisecond {
		t.Fatalf("a rejected hash must cost nothing: runs=%d elapsed=%s", runs.Load(), time.Since(start))
	}
}

func TestParamsValidate(t *testing.T) {
	ok := fastParams
	if err := ok.Validate(); err != nil {
		t.Fatal(err)
	}
	bad := map[string]func(*Params){
		"threads 0":      func(p *Params) { p.Threads = 0 },
		"threads 17":     func(p *Params) { p.Threads = 17 },
		"time 0":         func(p *Params) { p.Time = 0 },
		"time 17":        func(p *Params) { p.Time = 17 },
		"memory < 8*p":   func(p *Params) { p.Threads = 4; p.MemoryKiB = 31 },
		"memory too big": func(p *Params) { p.MemoryKiB = 256*1024 + 1 },
		"salt too short": func(p *Params) { p.SaltLen = 7 },
		"salt too long":  func(p *Params) { p.SaltLen = 65 },
		"key too short":  func(p *Params) { p.KeyLen = 15 },
		"key too long":   func(p *Params) { p.KeyLen = 65 },
	}
	for name, mutate := range bad {
		p := fastParams
		mutate(&p)
		if err := p.Validate(); err == nil {
			t.Errorf("%s: expected an error", name)
		}
		if _, err := NewHasher(HasherConfig{Params: p}); err == nil {
			t.Errorf("%s: NewHasher accepted it", name)
		}
	}
	if _, err := NewHasher(HasherConfig{Params: fastParams, MaxConcurrent: -1}); err == nil {
		t.Error("negative MaxConcurrent must be rejected")
	}
}

// --- rehash detection ---------------------------------------------------------------------

func TestRehashDetection(t *testing.T) {
	base := fastParams
	old := newTestHasher(t)
	encoded := mustHash(t, old, "a long enough passphrase")

	t.Run("same parameters", func(t *testing.T) {
		if need, err := old.NeedsRehash(encoded); err != nil || need {
			t.Fatalf("got %v %v", need, err)
		}
	})

	changes := map[string]func(*Params){
		"memory":  func(p *Params) { p.MemoryKiB = base.MemoryKiB * 2 },
		"time":    func(p *Params) { p.Time = base.Time + 1 },
		"threads": func(p *Params) { p.Threads = 2 },
		"salt":    func(p *Params) { p.SaltLen = base.SaltLen + 8 },
		"key":     func(p *Params) { p.KeyLen = base.KeyLen + 16 },
		// Lowering a cost is a change too: the stored hash no longer matches the policy.
		"lower memory": func(p *Params) { p.MemoryKiB = 32 },
	}
	for name, change := range changes {
		t.Run(name, func(t *testing.T) {
			p := base
			change(&p)
			newer := newTestHasher(t, func(c *HasherConfig) { c.Params = p })

			need, err := newer.NeedsRehash(encoded)
			if err != nil || !need {
				t.Fatalf("NeedsRehash = %v, %v", need, err)
			}
			// Verify still uses the stored parameters, matches, and reports the rehash.
			res, err := newer.Verify(context.Background(), encoded, "a long enough passphrase")
			if err != nil || !res.Match || !res.NeedsRehash {
				t.Fatalf("Verify = %+v, %v", res, err)
			}
			// A rehash with the new hasher settles it.
			upgraded := mustHash(t, newer, "a long enough passphrase")
			if need, _ := newer.NeedsRehash(upgraded); need {
				t.Fatal("a fresh hash must not need another rehash")
			}
			res, err = newer.Verify(context.Background(), upgraded, "a long enough passphrase")
			if err != nil || !res.Match || res.NeedsRehash {
				t.Fatalf("upgraded Verify = %+v, %v", res, err)
			}
		})
	}
}

// --- bounded concurrency ------------------------------------------------------------------

func TestConcurrencyIsBounded(t *testing.T) {
	const limit = 2
	h := newTestHasher(t, func(c *HasherConfig) { c.MaxConcurrent = limit; c.MaxWait = 10 * time.Second })
	var active, peak atomic.Int32
	h.onCompute = func() func() {
		n := active.Add(1)
		for {
			p := peak.Load()
			if n <= p || peak.CompareAndSwap(p, n) {
				break
			}
		}
		time.Sleep(20 * time.Millisecond) // widen the window so overlap would show
		return func() { active.Add(-1) }
	}

	var wg sync.WaitGroup
	for i := 0; i < 12; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if _, err := h.Hash(context.Background(), "a long enough passphrase"); err != nil {
				t.Error(err)
			}
		}()
	}
	wg.Wait()
	if peak.Load() > limit || peak.Load() < 1 {
		t.Fatalf("peak concurrent hashes = %d, limit %d", peak.Load(), limit)
	}
	if active.Load() != 0 {
		t.Fatalf("slots leaked: %d still active", active.Load())
	}
}

func TestBusyAfterMaxWait(t *testing.T) {
	var waits []time.Duration
	var mu sync.Mutex
	h := newTestHasher(t, func(c *HasherConfig) {
		c.MaxConcurrent = 1
		c.MaxWait = 80 * time.Millisecond
		c.ObserveWait = func(d time.Duration) { mu.Lock(); waits = append(waits, d); mu.Unlock() }
	})
	encoded := mustHash(t, h, "a long enough passphrase")
	ctx := context.Background()

	if err := h.acquire(ctx); err != nil { // occupy the only slot
		t.Fatal(err)
	}
	start := time.Now()
	if _, err := h.Hash(ctx, "another long passphrase"); !errors.Is(err, ErrBusy) {
		t.Fatalf("Hash: %v", err)
	}
	if _, err := h.Verify(ctx, encoded, "a long enough passphrase"); !errors.Is(err, ErrBusy) {
		t.Fatalf("Verify: %v", err)
	}
	if err := h.VerifyDummy(ctx, "x"); !errors.Is(err, ErrBusy) {
		t.Fatalf("VerifyDummy: %v", err)
	}
	if elapsed := time.Since(start); elapsed < 3*80*time.Millisecond || elapsed > 3*time.Second {
		t.Fatalf("three busy calls took %s, expected about 240ms", elapsed)
	}

	h.release()
	if _, err := h.Hash(ctx, "another long passphrase"); err != nil {
		t.Fatalf("after the slot is free: %v", err)
	}

	mu.Lock()
	defer mu.Unlock()
	if len(waits) < 4 {
		t.Fatalf("ObserveWait should see every call, saw %d", len(waits))
	}
}

func TestContextCancellationWhileWaiting(t *testing.T) {
	h := newTestHasher(t, func(c *HasherConfig) { c.MaxConcurrent = 1; c.MaxWait = 10 * time.Second })
	if err := h.acquire(context.Background()); err != nil {
		t.Fatal(err)
	}
	defer h.release()

	ctx, cancel := context.WithCancel(context.Background())
	go func() { time.Sleep(50 * time.Millisecond); cancel() }()
	start := time.Now()
	if _, err := h.Hash(ctx, "a long enough passphrase"); !errors.Is(err, context.Canceled) {
		t.Fatalf("got %v", err)
	}
	if time.Since(start) > 2*time.Second {
		t.Fatal("cancellation was not honored promptly")
	}

	// An already-cancelled context never takes a slot.
	cancelled, cancel2 := context.WithCancel(context.Background())
	cancel2()
	h2 := newTestHasher(t)
	if _, err := h2.Hash(cancelled, "a long enough passphrase"); !errors.Is(err, context.Canceled) {
		t.Fatalf("got %v", err)
	}
}

func TestConcurrentVerifyIsRaceFree(t *testing.T) {
	h := newTestHasher(t, func(c *HasherConfig) { c.MaxConcurrent = 3 })
	encoded := mustHash(t, h, "a long enough passphrase")
	var wg sync.WaitGroup
	for i := 0; i < 16; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			pw := "a long enough passphrase"
			want := true
			if i%2 == 1 {
				pw, want = "wrong password here "+strconv.Itoa(i), false
			}
			res, err := h.Verify(context.Background(), encoded, pw)
			if err != nil || res.Match != want {
				t.Errorf("i=%d: %+v %v", i, res, err)
			}
		}(i)
	}
	wg.Wait()
}

// --- dummy verification -------------------------------------------------------------------

func TestVerifyDummyCostsLikeARealVerify(t *testing.T) {
	h := newTestHasher(t, func(c *HasherConfig) { c.Params.Time = 3; c.Params.MemoryKiB = 128 })
	if need := h.needsRehash(h.dummy); need {
		t.Fatal("the dummy hash must use the current parameters, or timing would differ")
	}
	if got := Params(h.Params()); got.Time != 3 || got.MemoryKiB != 128 {
		t.Fatalf("Params() = %+v", got)
	}

	var runs atomic.Int32
	h.onCompute = func() func() { runs.Add(1); return func() {} }
	if err := h.VerifyDummy(context.Background(), "whatever the attacker typed"); err != nil {
		t.Fatal(err)
	}
	if runs.Load() != 1 {
		t.Fatalf("VerifyDummy must run Argon2 exactly once, ran %d", runs.Load())
	}
	// Input that real Verify answers without hashing is also answered without hashing.
	runs.Store(0)
	if err := h.VerifyDummy(context.Background(), strings.Repeat("x", MaxPasswordInputBytes+1)); err != nil || runs.Load() != 0 {
		t.Fatalf("oversized input: err=%v runs=%d", err, runs.Load())
	}
}

// --- structure ----------------------------------------------------------------------------

// Hashing must stay outside database transactions (TRD 7.1 rule 4). The surest guard is that
// the package cannot even name a database type.
func TestPackageDoesNotImportDatabaseCode(t *testing.T) {
	entries, err := os.ReadDir(".")
	if err != nil {
		t.Fatal(err)
	}
	forbidden := []string{"database/sql", "github.com/jackc/", "internal/platform/db", "internal/platform/pgtest"}
	checked := 0
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".go") || strings.HasSuffix(e.Name(), "_test.go") {
			continue
		}
		file, err := parser.ParseFile(token.NewFileSet(), e.Name(), nil, parser.ImportsOnly)
		if err != nil {
			t.Fatal(err)
		}
		checked++
		for _, imp := range file.Imports {
			path, _ := strconv.Unquote(imp.Path.Value)
			for _, bad := range forbidden {
				if strings.Contains(path, bad) {
					t.Errorf("%s imports %s: identity primitives must not depend on the database", e.Name(), path)
				}
			}
		}
	}
	if checked < 4 {
		t.Fatalf("only %d source files checked", checked)
	}
}
