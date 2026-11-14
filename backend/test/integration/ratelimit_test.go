//go:build integration

package integration

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/identity"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/clientip"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/db/sqlc"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/pgtest"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/ratelimit"
)

func testEmailHMAC(t *testing.T) *identity.EmailHMAC {
	t.Helper()
	h, err := identity.NewEmailHMAC(bytes.Repeat([]byte{0x42}, 32))
	if err != nil {
		t.Fatal(err)
	}
	return h
}

func email(t *testing.T, raw string) identity.Email {
	t.Helper()
	e, err := identity.NormalizeEmail(raw)
	if err != nil {
		t.Fatal(err)
	}
	return e
}

func counterRows(t *testing.T, d *pgtest.DB, keyPrefix string) int {
	t.Helper()
	return rowCount(t, d.Pool, `SELECT count(*) FROM rate_limit_counters WHERE key LIKE $1`, keyPrefix+"%")
}

// stable runs scenario, and runs it again with a fresh subject if the database clock crossed a
// window boundary while it ran (detected by the scenario returning false). Windows are fixed on
// the database clock, so a scenario that must stay inside one window needs this at the top of
// the hour or at midnight UTC. It fails after a few attempts instead of passing silently.
func stable(t *testing.T, scenario func(subject ratelimit.Subject) (sameWindow bool)) {
	t.Helper()
	for attempt := 0; attempt < 5; attempt++ {
		if scenario(ratelimit.SessionSubject(uuid.New())) {
			return
		}
	}
	t.Fatal("the scenario kept crossing a window boundary")
}

// --- Limiter ------------------------------------------------------------------------------

func TestLimiter_AllowsUpToTheLimitThenDenies(t *testing.T) {
	d, _ := migratedDB(t)
	l := ratelimit.NewLimiter(d.Pool)
	ctx := context.Background()
	rule := ratelimit.Rule{Name: "t_basic", Limit: 3, Window: time.Hour}

	stable(t, func(subj ratelimit.Subject) bool {
		var decisions []ratelimit.Decision
		for i := 0; i < 5; i++ {
			dec, err := l.Allow(ctx, ratelimit.Check{Rule: rule, Subject: subj})
			if err != nil {
				t.Fatal(err)
			}
			decisions = append(decisions, dec)
		}
		for i, dec := range decisions {
			if dec.Count != i+1 {
				return false // crossed into a new window; run again
			}
			wantAllowed := i+1 <= 3
			if dec.Allowed != wantAllowed {
				t.Fatalf("event %d: allowed = %v", i+1, dec.Allowed)
			}
			if dec.Rule != rule || dec.ResetsIn <= 0 || dec.ResetsIn > time.Hour {
				t.Fatalf("event %d: %+v", i+1, dec)
			}
		}
		denied := decisions[4]
		if s := denied.RetryAfterSeconds(); s < 1 || s > 3600 {
			t.Fatalf("Retry-After = %d", s)
		}
		if decisions[0].RetryAfterSeconds() != 0 {
			t.Fatal("an allowed request has no Retry-After")
		}
		return true
	})
}

// The window comes from the database clock, aligned to the Unix epoch. Retry-After is the time
// left in that window as the database sees it.
func TestLimiter_WindowsAreEpochAlignedOnDatabaseTime(t *testing.T) {
	d, _ := migratedDB(t)
	l := ratelimit.NewLimiter(d.Pool)
	ctx := context.Background()

	for _, window := range []time.Duration{time.Minute, 15 * time.Minute, time.Hour, 24 * time.Hour} {
		rule := ratelimit.Rule{Name: "t_aligned", Limit: 1, Window: window}
		subj := ratelimit.UserSubject(uuid.New())
		dec, err := l.Allow(ctx, ratelimit.Check{Rule: rule, Subject: subj})
		if err != nil {
			t.Fatal(err)
		}

		var mod, untilEnd float64
		err = d.Pool.QueryRow(ctx, `
			SELECT mod(extract(epoch FROM window_start)::bigint, $2::bigint)::float8,
			       extract(epoch FROM (window_start + $2::bigint * interval '1 second' - now()))::float8
			FROM rate_limit_counters WHERE key LIKE $1`, "t_aligned:%"+subj.String(), int64(window/time.Second)).Scan(&mod, &untilEnd)
		if err != nil {
			t.Fatalf("%s: %v", window, err)
		}
		if mod != 0 {
			t.Fatalf("%s: window start is not epoch aligned (offset %v s)", window, mod)
		}
		// Both numbers are measured a few milliseconds apart, so allow a little slack.
		if diff := dec.ResetsIn.Seconds() - untilEnd; diff < -2 || diff > 2 {
			t.Fatalf("%s: ResetsIn %.3fs but the database says %.3fs", window, dec.ResetsIn.Seconds(), untilEnd)
		}
		mustExec(t, d.Pool, `DELETE FROM rate_limit_counters`)
	}
}

func TestLimiter_WindowBoundaryResetsTheCount(t *testing.T) {
	d, _ := migratedDB(t)
	l := ratelimit.NewLimiter(d.Pool)
	ctx := context.Background()
	rule := ratelimit.Rule{Name: "t_boundary", Limit: 2, Window: 2 * time.Second}

	for attempt := 0; attempt < 8; attempt++ {
		subj := ratelimit.SessionSubject(uuid.New())
		var decisions []ratelimit.Decision
		for i := 0; i < 3; i++ {
			dec, err := l.Allow(ctx, ratelimit.Check{Rule: rule, Subject: subj})
			if err != nil {
				t.Fatal(err)
			}
			decisions = append(decisions, dec)
		}
		if decisions[0].Count != 1 || decisions[1].Count != 2 || decisions[2].Count != 3 {
			continue // a boundary fell inside the burst, try again
		}
		if !decisions[1].Allowed || decisions[2].Allowed {
			t.Fatalf("limit 2: %v %v %v", decisions[0].Allowed, decisions[1].Allowed, decisions[2].Allowed)
		}

		// Wait out the window, as Retry-After tells a client to.
		time.Sleep(time.Duration(decisions[2].RetryAfterSeconds())*time.Second + 50*time.Millisecond)
		after, err := l.Allow(ctx, ratelimit.Check{Rule: rule, Subject: subj})
		if err != nil {
			t.Fatal(err)
		}
		if !after.Allowed || after.Count != 1 {
			t.Fatalf("after Retry-After the counter must start over: %+v", after)
		}
		if n := counterRows(t, d, "t_boundary:"); n != 2 {
			t.Fatalf("expected one row per window, got %d", n)
		}
		return
	}
	t.Fatal("never found a burst inside one window")
}

func TestLimiter_ConcurrentCallersSeeExactlyLimitAllowed(t *testing.T) {
	d, _ := migratedDB(t)
	l := ratelimit.NewLimiter(d.Pool)
	rule := ratelimit.Rule{Name: "t_concurrent", Limit: 25, Window: time.Hour}
	const callers = 60

	stable(t, func(subj ratelimit.Subject) bool {
		var allowed, denied atomic.Int32
		counts := make(chan int, callers)
		start := make(chan struct{})
		var wg sync.WaitGroup
		for i := 0; i < callers; i++ {
			wg.Add(1)
			go func() {
				defer wg.Done()
				<-start
				dec, err := l.Allow(context.Background(), ratelimit.Check{Rule: rule, Subject: subj})
				if err != nil {
					t.Error(err)
					return
				}
				if dec.Allowed {
					allowed.Add(1)
				} else {
					denied.Add(1)
				}
				counts <- dec.Count
			}()
		}
		close(start)
		wg.Wait()
		close(counts)

		var got []int
		for c := range counts {
			got = append(got, c)
		}
		sort.Ints(got)
		for i, c := range got {
			if c != i+1 {
				return false // window changed mid-test
			}
		}
		if allowed.Load() != 25 || denied.Load() != callers-25 {
			t.Fatalf("allowed=%d denied=%d, want 25 and %d", allowed.Load(), denied.Load(), callers-25)
		}
		return true
	})
}

// TRD 7.1 rules 3 and 6: the record of an attempt must outlive a business transaction that fails.
func TestLimiter_CountersSurviveCallerRollback(t *testing.T) {
	d, _ := migratedDB(t)
	l := ratelimit.NewLimiter(d.Pool)
	ctx := context.Background()
	rule := ratelimit.Rule{Name: "t_rollback", Limit: 2, Window: time.Hour}

	stable(t, func(subj ratelimit.Subject) bool {
		var last ratelimit.Decision
		for round := 1; round <= 3; round++ {
			tx, err := d.Pool.Begin(ctx)
			if err != nil {
				t.Fatal(err)
			}
			// A business transaction holding real work and a row lock.
			u := newUser(t, sqlc.New(tx))
			if _, err := sqlc.New(tx).LockUserForNoKeyUpdate(ctx, u.ID); err != nil {
				t.Fatal(err)
			}

			// The limiter uses its own connection, so it neither waits for nor joins the transaction.
			done := make(chan struct{})
			go func() {
				defer close(done)
				dec, err := l.Allow(ctx, ratelimit.Check{Rule: rule, Subject: subj})
				if err != nil {
					t.Error(err)
				}
				last = dec
			}()
			select {
			case <-done:
			case <-time.After(5 * time.Second):
				t.Fatal("the limiter blocked behind the caller's transaction")
			}

			if err := tx.Rollback(ctx); err != nil {
				t.Fatal(err)
			}
			if n := rowCount(t, d.Pool, `SELECT count(*) FROM users WHERE id = $1`, u.ID); n != 0 {
				t.Fatalf("the business transaction should be gone, user rows = %d", n)
			}
			if last.Count != round {
				return false
			}
		}
		if last.Allowed {
			t.Fatalf("after three rolled-back attempts the limit of 2 must still bite: %+v", last)
		}
		var stored int
		if err := d.Pool.QueryRow(ctx, `SELECT count FROM rate_limit_counters WHERE key LIKE $1`, "t_rollback:%"+subj.String()).Scan(&stored); err != nil {
			t.Fatal(err)
		}
		if stored != 3 {
			t.Fatalf("stored count = %d, want 3", stored)
		}
		return true
	})
}

func TestLimiter_AllowCountsEveryCheckAndReportsTheLongestWait(t *testing.T) {
	d, _ := migratedDB(t)
	l := ratelimit.NewLimiter(d.Pool)
	ctx := context.Background()
	hourly := ratelimit.Rule{Name: "t_multi_1h", Limit: 1, Window: time.Hour}
	daily := ratelimit.Rule{Name: "t_multi_24h", Limit: 1, Window: 24 * time.Hour}
	other := ratelimit.Rule{Name: "t_multi_other", Limit: 100, Window: time.Hour}

	stable(t, func(subj ratelimit.Subject) bool {
		checks := []ratelimit.Check{{Rule: hourly, Subject: subj}, {Rule: other, Subject: subj}, {Rule: daily, Subject: subj}}
		first, err := l.Allow(ctx, checks...)
		if err != nil || !first.Allowed {
			t.Fatalf("first: %+v %v", first, err)
		}
		second, err := l.Allow(ctx, checks...)
		if err != nil {
			t.Fatal(err)
		}
		if second.Allowed {
			t.Fatal("both limits are exceeded")
		}
		// The decision must carry the longest wait among the denying rules, so a client that
		// honors Retry-After is not refused again by the other rule.
		hourlyWait, _ := l.Peek(ctx, ratelimit.Check{Rule: hourly, Subject: subj})
		dailyWait, _ := l.Peek(ctx, ratelimit.Check{Rule: daily, Subject: subj})
		longest := max(hourlyWait.ResetsIn, dailyWait.ResetsIn)
		if diff := longest - second.ResetsIn; diff < -time.Second || diff > time.Second {
			t.Fatalf("reported wait %s, but the longest denying window has %s left (hourly %s, daily %s)",
				second.ResetsIn, longest, hourlyWait.ResetsIn, dailyWait.ResetsIn)
		}
		if dailyWait.ResetsIn > hourlyWait.ResetsIn+time.Second && second.Rule != daily {
			t.Fatalf("expected the daily rule to be reported, got %s", second.Rule.Name)
		}

		// Every check was counted, including the one placed after a denial.
		for _, r := range []ratelimit.Rule{hourly, other, daily} {
			p, err := l.Peek(ctx, ratelimit.Check{Rule: r, Subject: subj})
			if err != nil {
				t.Fatal(err)
			}
			if p.Count != 2 {
				if r == hourly {
					return false
				}
				t.Fatalf("%s counted %d, want 2", r.Name, p.Count)
			}
		}
		return true
	})
}

func TestLimiter_PeekDoesNotCount(t *testing.T) {
	d, _ := migratedDB(t)
	l := ratelimit.NewLimiter(d.Pool)
	ctx := context.Background()
	rule := ratelimit.Rule{Name: "t_peek", Limit: 2, Window: time.Hour}

	stable(t, func(subj ratelimit.Subject) bool {
		c := ratelimit.Check{Rule: rule, Subject: subj}
		p, err := l.Peek(ctx, c)
		if err != nil || p.Count != 0 || !p.Allowed || p.ResetsIn <= 0 {
			t.Fatalf("unused key: %+v %v", p, err)
		}
		if counterRows(t, d, "t_peek:") != 0 {
			t.Fatal("Peek must not create a counter row")
		}
		for i := 0; i < 2; i++ {
			if _, err := l.Allow(ctx, c); err != nil {
				t.Fatal(err)
			}
		}
		for i := 0; i < 3; i++ { // repeated peeks never move the counter
			p, _ = l.Peek(ctx, c)
			if p.Count != 2 {
				return false
			}
			if p.Allowed {
				t.Fatalf("at the limit a further event no longer fits: %+v", p)
			}
		}
		mustExec(t, d.Pool, `DELETE FROM rate_limit_counters`)
		return true
	})
}

// AC-27: the limiter never sees whether an account exists, so eligible and ineligible emails
// get identical treatment. This runs the same sequence for both and compares.
func TestLimiter_SameBehaviorForEligibleAndIneligibleEmails(t *testing.T) {
	d, q := migratedDB(t)
	h := testEmailHMAC(t)
	l := ratelimit.NewLimiter(d.Pool)
	ctx := context.Background()
	rules := ratelimit.DefaultRules()

	registered := newUser(t, q)
	eligible := email(t, registered.Email)
	ineligible := email(t, "nobody-here@example.test")

	run := func(e identity.Email) []string {
		var out []string
		for i := 0; i < 7; i++ {
			dec, err := l.Allow(ctx,
				ratelimit.Check{Rule: rules.StartEmailHourly, Subject: ratelimit.EmailSubject(h, e)},
				ratelimit.Check{Rule: rules.StartEmailDaily, Subject: ratelimit.EmailSubject(h, e)})
			if err != nil {
				t.Fatal(err)
			}
			out = append(out, fmt.Sprintf("%v/%s/%d", dec.Allowed, dec.Rule.Name, dec.Count))
		}
		return out
	}
	a, b := run(eligible), run(ineligible)
	if strings.Join(a, " ") != strings.Join(b, " ") {
		t.Fatalf("decisions differ by eligibility:\n eligible   %v\n ineligible %v", a, b)
	}
	if !strings.HasPrefix(a[0], "true/") || !strings.HasPrefix(a[5], "false/otp_start_email_1h/6") {
		t.Fatalf("unexpected sequence: %v", a)
	}
}

func TestLimiter_EmailKeysAreHMACsAndSpellingsShareACounter(t *testing.T) {
	d, _ := migratedDB(t)
	h := testEmailHMAC(t)
	l := ratelimit.NewLimiter(d.Pool)
	ctx := context.Background()
	rule := ratelimit.Rule{Name: "t_email", Limit: 100, Window: time.Hour}

	var last ratelimit.Decision
	for _, spelling := range []string{"Secret.Person@Example.test", "  secret.person@EXAMPLE.TEST", "SECRET.PERSON@example.test"} {
		dec, err := l.Allow(ctx, ratelimit.Check{Rule: rule, Subject: ratelimit.EmailSubject(h, email(t, spelling))})
		if err != nil {
			t.Fatal(err)
		}
		last = dec
	}
	if last.Count != 3 {
		t.Fatalf("three spellings of one mailbox must share a counter, got %d", last.Count)
	}

	rows, err := d.Pool.Query(ctx, `SELECT key FROM rate_limit_counters`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	n := 0
	for rows.Next() {
		var key string
		_ = rows.Scan(&key)
		n++
		if strings.Contains(strings.ToLower(key), "secret") || strings.Contains(key, "example") {
			t.Fatalf("counter key contains the email: %s", key)
		}
		if !strings.HasPrefix(key, "t_email:email:") {
			t.Fatalf("unexpected key %s", key)
		}
	}
	if n != 1 {
		t.Fatalf("expected one counter row, got %d", n)
	}
}

func TestLimiter_IPBucketsShareCountersWithinASlash64(t *testing.T) {
	d, _ := migratedDB(t)
	l := ratelimit.NewLimiter(d.Pool)
	res := clientip.New(nil)
	ctx := context.Background()
	rule := ratelimit.Rule{Name: "t_ip", Limit: 100, Window: time.Hour}

	allow := func(remote string) int {
		dec, err := l.Allow(ctx, ratelimit.Check{Rule: rule, Subject: ratelimit.IPSubject(res.Resolve(remote, nil))})
		if err != nil {
			t.Fatal(err)
		}
		return dec.Count
	}
	// Use a subnet unique to this test database run.
	allow("[2001:db8:aaaa:1::1]:1")
	allow("[2001:db8:aaaa:1:ffff::9]:1")
	if got := allow("[2001:db8:aaaa:1:1:2:3:4]:1"); got != 3 {
		t.Fatalf("one /64 must be one counter, got %d", got)
	}
	if got := allow("[2001:db8:aaaa:2::1]:1"); got != 1 {
		t.Fatalf("another /64 has its own counter, got %d", got)
	}
	if got := allow("198.51.100.1:1"); got != 1 {
		t.Fatalf("IPv4 has its own counter, got %d", got)
	}
}

func TestLimiter_FailsClosedOnDatabaseErrors(t *testing.T) {
	d := pgtest.New(t)
	pool, err := pgxpool.New(context.Background(), d.URL)
	if err != nil {
		t.Fatal(err)
	}
	l := ratelimit.NewLimiter(pool)
	rule := ratelimit.Rule{Name: "t_err", Limit: 5, Window: time.Hour}
	check := ratelimit.Check{Rule: rule, Subject: ratelimit.UserSubject(uuid.New())}

	pool.Close()
	dec, err := l.Allow(context.Background(), check)
	if err == nil || dec.Allowed {
		t.Fatalf("a failing database must give an error and no allowance: %+v %v", dec, err)
	}
	if _, err := l.Peek(context.Background(), check); err == nil {
		t.Fatal("Peek must fail too")
	}

	d2, _ := migratedDB(t)
	l2 := ratelimit.NewLimiter(d2.Pool)
	cancelled, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := l2.Allow(cancelled, check); !errors.Is(err, context.Canceled) {
		t.Fatalf("got %v", err)
	}
}

func TestLimiter_RejectsInvalidInput(t *testing.T) {
	d, _ := migratedDB(t)
	l := ratelimit.NewLimiter(d.Pool)
	ctx := context.Background()
	if _, err := l.Allow(ctx); err == nil {
		t.Fatal("no checks must be an error")
	}
	bad := ratelimit.Check{Rule: ratelimit.Rule{Name: "Bad Name", Limit: 1, Window: time.Hour}, Subject: ratelimit.UserSubject(uuid.New())}
	if _, err := l.Allow(ctx, bad); err == nil {
		t.Fatal("an invalid rule must be an error")
	}
	if counterRows(t, d, "") != 0 {
		t.Fatal("an invalid check must not write anything")
	}
}

// --- Cooldown -----------------------------------------------------------------------------

func newCooldown(t *testing.T) ratelimit.Cooldown {
	return ratelimit.Cooldown{Email: testEmailHMAC(t)}
}

func begin(t *testing.T, pool *pgxpool.Pool) pgx.Tx {
	t.Helper()
	tx, err := pool.Begin(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = tx.Rollback(context.Background()) })
	return tx
}

func TestCooldown_FirstClaimIsGrantedThenDenied(t *testing.T) {
	d, _ := migratedDB(t)
	cd := newCooldown(t)
	ctx := context.Background()
	e := email(t, "learner@example.test")

	tx1 := begin(t, d.Pool)
	res, err := cd.Claim(ctx, tx1, "signup", e)
	if err != nil || !res.Granted || res.RetryAfterSeconds() != 0 {
		t.Fatalf("first claim: %+v %v", res, err)
	}
	if err := tx1.Commit(ctx); err != nil {
		t.Fatal(err)
	}

	tx2 := begin(t, d.Pool)
	res, err = cd.Claim(ctx, tx2, "signup", e)
	if err != nil || res.Granted {
		t.Fatalf("second claim must be denied: %+v %v", res, err)
	}
	if s := res.RetryAfterSeconds(); s < 55 || s > 60 {
		t.Fatalf("Retry-After = %d, want about 60", s)
	}
	_ = tx2.Rollback(ctx)

	// Another purpose or another mailbox has its own cooldown.
	tx3 := begin(t, d.Pool)
	for _, c := range []struct {
		purpose string
		e       identity.Email
	}{{"login", e}, {"signup", email(t, "someone.else@example.test")}} {
		if res, err := cd.Claim(ctx, tx3, c.purpose, c.e); err != nil || !res.Granted {
			t.Fatalf("%s %s: %+v %v", c.purpose, c.e.Normalized, res, err)
		}
	}
}

// TRD 7.2 step 1: the claim is allowed once last_issued_at <= now() - cooldown. Inside one
// transaction now() is fixed, so the boundary can be tested exactly.
func TestCooldown_BoundaryIsInclusive(t *testing.T) {
	d, _ := migratedDB(t)
	cd := newCooldown(t)
	ctx := context.Background()
	e := email(t, "boundary@example.test")
	tx := begin(t, d.Pool)

	if res, err := cd.Claim(ctx, tx, "login", e); err != nil || !res.Granted {
		t.Fatalf("setup claim: %+v %v", res, err)
	}
	setAge := func(age string) {
		t.Helper()
		if _, err := tx.Exec(ctx, `UPDATE otp_cooldowns SET last_issued_at = now() - $1::interval`, age); err != nil {
			t.Fatal(err)
		}
	}

	cases := []struct {
		age         string
		wantGranted bool
		wantSeconds int // Retry-After when denied
	}{
		{"1 second", false, 59},
		{"30 seconds", false, 30},
		{"59 seconds", false, 1},
		{"59.999 seconds", false, 1}, // a millisecond left rounds up to a whole second
		{"59.999999 seconds", false, 1},
		{"60 seconds", true, 0}, // exactly on the boundary: granted
		{"60.000001 seconds", true, 0},
		{"5 minutes", true, 0},
	}
	for _, c := range cases {
		setAge(c.age)
		res, err := cd.Claim(ctx, tx, "login", e)
		if err != nil {
			t.Fatalf("age %s: %v", c.age, err)
		}
		if res.Granted != c.wantGranted {
			t.Fatalf("age %s: granted = %v, want %v", c.age, res.Granted, c.wantGranted)
		}
		if !res.Granted && res.RetryAfterSeconds() != c.wantSeconds {
			t.Fatalf("age %s: Retry-After = %d, want %d (%s)", c.age, res.RetryAfterSeconds(), c.wantSeconds, res.RetryAfter)
		}
	}
}

func TestCooldown_CustomLength(t *testing.T) {
	d, _ := migratedDB(t)
	cd := ratelimit.Cooldown{Email: testEmailHMAC(t), Seconds: 5}
	ctx := context.Background()
	e := email(t, "short@example.test")
	tx := begin(t, d.Pool)
	if res, _ := cd.Claim(ctx, tx, "login", e); !res.Granted {
		t.Fatal("first claim")
	}
	mustTxExec(t, tx, `UPDATE otp_cooldowns SET last_issued_at = now() - interval '4 seconds'`)
	if res, _ := cd.Claim(ctx, tx, "login", e); res.Granted || res.RetryAfterSeconds() != 1 {
		t.Fatalf("4 s into a 5 s cooldown: %+v", res)
	}
	mustTxExec(t, tx, `UPDATE otp_cooldowns SET last_issued_at = now() - interval '5 seconds'`)
	if res, _ := cd.Claim(ctx, tx, "login", e); !res.Granted {
		t.Fatal("5 s into a 5 s cooldown must be granted")
	}
}

func mustTxExec(t *testing.T, tx pgx.Tx, sql string, args ...any) {
	t.Helper()
	if _, err := tx.Exec(context.Background(), sql, args...); err != nil {
		t.Fatal(err)
	}
}

// A granted claim lives and dies with the transaction that issues the challenge.
func TestCooldown_RollbackReleasesTheClaim(t *testing.T) {
	d, _ := migratedDB(t)
	cd := newCooldown(t)
	ctx := context.Background()
	e := email(t, "rollback@example.test")

	tx1 := begin(t, d.Pool)
	if res, err := cd.Claim(ctx, tx1, "signup", e); err != nil || !res.Granted {
		t.Fatalf("claim: %+v %v", res, err)
	}
	if err := tx1.Rollback(ctx); err != nil {
		t.Fatal(err)
	}
	if n := rowCount(t, d.Pool, `SELECT count(*) FROM otp_cooldowns`); n != 0 {
		t.Fatalf("a rolled-back claim left %d rows", n)
	}

	tx2 := begin(t, d.Pool)
	if res, err := cd.Claim(ctx, tx2, "signup", e); err != nil || !res.Granted {
		t.Fatalf("after a rollback the next claim must be granted at once: %+v %v", res, err)
	}
	if err := tx2.Commit(ctx); err != nil {
		t.Fatal(err)
	}
	tx3 := begin(t, d.Pool)
	if res, _ := cd.Claim(ctx, tx3, "signup", e); res.Granted {
		t.Fatal("a committed claim must hold")
	}
}

func TestCooldown_ClaimDoesNotAbortTheTransaction(t *testing.T) {
	d, _ := migratedDB(t)
	cd := newCooldown(t)
	ctx := context.Background()
	e := email(t, "usable@example.test")

	tx1 := begin(t, d.Pool)
	_, _ = cd.Claim(ctx, tx1, "login", e)
	_ = tx1.Commit(ctx)

	tx2 := begin(t, d.Pool)
	if res, err := cd.Claim(ctx, tx2, "login", e); err != nil || res.Granted {
		t.Fatalf("expected a plain denial: %+v %v", res, err)
	}
	// The caller can still use the transaction, for example to write an audit event.
	if _, err := tx2.Exec(ctx, `SELECT 1`); err != nil {
		t.Fatalf("the transaction was poisoned by a denied claim: %v", err)
	}
}

func TestCooldown_ConcurrentFirstClaimsGrantExactlyOne(t *testing.T) {
	d, _ := migratedDB(t)
	cd := newCooldown(t)
	e := email(t, "race@example.test")
	var granted, denied atomic.Int32
	start := make(chan struct{})
	var wg sync.WaitGroup
	for i := 0; i < 20; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			ctx := context.Background()
			tx, err := d.Pool.Begin(ctx)
			if err != nil {
				t.Error(err)
				return
			}
			<-start
			res, err := cd.Claim(ctx, tx, "signup", e)
			if err != nil {
				t.Error(err)
				_ = tx.Rollback(ctx)
				return
			}
			if res.Granted {
				granted.Add(1)
			} else {
				denied.Add(1)
			}
			_ = tx.Commit(ctx)
		}()
	}
	close(start)
	wg.Wait()
	if granted.Load() != 1 || denied.Load() != 19 {
		t.Fatalf("granted=%d denied=%d, want 1 and 19", granted.Load(), denied.Load())
	}
}

// TRD 7.2: a second claimant waits for the first. If the first rolls back it gets the claim,
// if the first commits it is denied.
func TestCooldown_WaiterFollowsTheFirstTransactionsOutcome(t *testing.T) {
	for _, tc := range []struct {
		name        string
		commit      bool
		wantGranted bool
	}{{"first rolls back", false, true}, {"first commits", true, false}} {
		t.Run(tc.name, func(t *testing.T) {
			d, _ := migratedDB(t)
			cd := newCooldown(t)
			ctx := context.Background()
			e := email(t, "waiter@example.test")

			tx1 := begin(t, d.Pool)
			if res, err := cd.Claim(ctx, tx1, "signup", e); err != nil || !res.Granted {
				t.Fatalf("first claim: %+v %v", res, err)
			}

			type outcome struct {
				res ratelimit.CooldownResult
				err error
			}
			done := make(chan outcome, 1)
			go func() {
				tx2, err := d.Pool.Begin(ctx)
				if err != nil {
					done <- outcome{err: err}
					return
				}
				defer tx2.Rollback(ctx)
				res, err := cd.Claim(ctx, tx2, "signup", e)
				done <- outcome{res, err}
			}()

			select {
			case <-done:
				t.Fatal("the second claim must wait for the first transaction")
			case <-time.After(300 * time.Millisecond):
			}
			if tc.commit {
				_ = tx1.Commit(ctx)
			} else {
				_ = tx1.Rollback(ctx)
			}
			select {
			case o := <-done:
				if o.err != nil || o.res.Granted != tc.wantGranted {
					t.Fatalf("waiter: %+v %v, want granted=%v", o.res, o.err, tc.wantGranted)
				}
			case <-time.After(5 * time.Second):
				t.Fatal("the waiter never finished")
			}
		})
	}
}

func TestCooldown_StoresOnlyTheEmailHMAC(t *testing.T) {
	d, _ := migratedDB(t)
	h := testEmailHMAC(t)
	cd := ratelimit.Cooldown{Email: h}
	ctx := context.Background()
	e := email(t, "Hidden.Name@Example.test")

	tx := begin(t, d.Pool)
	if _, err := cd.Claim(ctx, tx, "login", e); err != nil {
		t.Fatal(err)
	}
	_ = tx.Commit(ctx)

	var stored []byte
	if err := d.Pool.QueryRow(ctx, `SELECT email_hmac FROM otp_cooldowns`).Scan(&stored); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(stored, h.Current(e)) {
		t.Fatal("the stored value must be the HMAC of the normalized email")
	}
	if bytes.Contains(stored, []byte("hidden")) {
		t.Fatal("the row contains the address")
	}
	// A different spelling of the same mailbox hits the same cooldown.
	tx2 := begin(t, d.Pool)
	res, err := cd.Claim(ctx, tx2, "login", email(t, " hidden.name@EXAMPLE.test "))
	if err != nil || res.Granted {
		t.Fatalf("equivalent spelling must share the cooldown: %+v %v", res, err)
	}
}

func TestCooldown_RejectsBadInput(t *testing.T) {
	d, _ := migratedDB(t)
	ctx := context.Background()
	tx := begin(t, d.Pool)
	if _, err := newCooldown(t).Claim(ctx, tx, "", email(t, "a@example.test")); err == nil {
		t.Fatal("an empty purpose must be an error")
	}
	if _, err := (ratelimit.Cooldown{}).Claim(ctx, tx, "login", email(t, "a@example.test")); err == nil {
		t.Fatal("a missing EmailHMAC must be an error")
	}
}
