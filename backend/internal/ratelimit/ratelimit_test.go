package ratelimit

import (
	"bytes"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/identity"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/clientip"
)

// TestDefaultRulesMatchTheTRD pins the approved numbers of TRD 10 (the table "Rule, Key, Limit").
// Changing a default means changing the TRD first.
func TestDefaultRulesMatchTheTRD(t *testing.T) {
	r := DefaultRules()
	want := []struct {
		name   string
		rule   Rule
		limit  int
		window time.Duration
	}{
		{"start per email, hourly", r.StartEmailHourly, 5, time.Hour},
		{"start per email, daily", r.StartEmailDaily, 10, 24 * time.Hour},
		{"start per IP", r.StartIP, 30, time.Hour},
		{"verify failures per email", r.VerifyFailEmail, 10, time.Hour},
		{"verify per IP", r.VerifyIP, 60, time.Hour},
		{"password login failures per email", r.PasswordLoginFailEmail, 10, 15 * time.Minute},
		{"password login per IP", r.PasswordLoginIP, 50, 15 * time.Minute},
		{"password signup start per IP", r.PasswordSignupStartIP, 10, time.Hour},
		{"wrong current password per user", r.WrongCurrentPasswordUser, 5, 15 * time.Minute},
		{"refresh per session", r.RefreshSession, 30, time.Minute},
		{"requests per session", r.RequestSession, 600, time.Minute},
	}
	for _, w := range want {
		if w.rule.Limit != w.limit || w.rule.Window != w.window {
			t.Errorf("%s: got %d per %s, want %d per %s", w.name, w.rule.Limit, w.rule.Window, w.limit, w.window)
		}
	}
	if len(r.All()) != len(want) {
		t.Fatalf("Rules.All lists %d rules, this test covers %d: update both", len(r.All()), len(want))
	}
	if CooldownSeconds != 60 {
		t.Fatalf("cooldown = %d s, TRD 7.2 says 60", CooldownSeconds)
	}
	if err := r.Validate(); err != nil {
		t.Fatal(err)
	}
}

func TestRuleValidation(t *testing.T) {
	good := Rule{Name: "a_rule_1h", Limit: 1, Window: time.Second}
	if err := good.Validate(); err != nil {
		t.Fatal(err)
	}
	bad := map[string]Rule{
		"empty name":        {Name: "", Limit: 1, Window: time.Second},
		"upper case":        {Name: "Rule", Limit: 1, Window: time.Second},
		"colon in name":     {Name: "a:b", Limit: 1, Window: time.Second},
		"space in name":     {Name: "a b", Limit: 1, Window: time.Second},
		"zero limit":        {Name: "r", Limit: 0, Window: time.Second},
		"negative limit":    {Name: "r", Limit: -1, Window: time.Second},
		"zero window":       {Name: "r", Limit: 1, Window: 0},
		"sub second window": {Name: "r", Limit: 1, Window: 500 * time.Millisecond},
		"fractional window": {Name: "r", Limit: 1, Window: 1500 * time.Millisecond},
	}
	for name, r := range bad {
		if err := r.Validate(); err == nil {
			t.Errorf("%s: expected an error", name)
		}
	}
	dup := DefaultRules()
	dup.StartIP.Name = dup.StartEmailHourly.Name
	if err := dup.Validate(); err == nil || !strings.Contains(err.Error(), "duplicate") {
		t.Fatalf("duplicate names must be rejected: %v", err)
	}
}

func TestRetryAfterSeconds(t *testing.T) {
	cases := []struct {
		name string
		d    Decision
		want int
	}{
		{"allowed", Decision{Allowed: true, ResetsIn: 30 * time.Second}, 0},
		{"whole seconds", Decision{ResetsIn: 30 * time.Second}, 30},
		{"rounds up", Decision{ResetsIn: 30*time.Second + time.Millisecond}, 31},
		{"just under a second", Decision{ResetsIn: 999 * time.Millisecond}, 1},
		{"a microsecond left", Decision{ResetsIn: time.Microsecond}, 1},
		{"window already over", Decision{ResetsIn: 0}, 1},
		{"a full hour", Decision{ResetsIn: time.Hour}, 3600},
	}
	for _, c := range cases {
		if got := c.d.RetryAfterSeconds(); got != c.want {
			t.Errorf("%s: got %d, want %d", c.name, got, c.want)
		}
	}
	if (CooldownResult{Granted: true}).RetryAfterSeconds() != 0 {
		t.Error("a granted cooldown has no Retry-After")
	}
	if got := (CooldownResult{RetryAfter: 59*time.Second + time.Millisecond}).RetryAfterSeconds(); got != 60 {
		t.Errorf("cooldown rounds up: %d", got)
	}
	if got := (CooldownResult{}).RetryAfterSeconds(); got != 1 {
		t.Errorf("a denied cooldown is at least 1 s: %d", got)
	}
}

func TestDecideAtTheLimit(t *testing.T) {
	rule := Rule{Name: "r", Limit: 3, Window: time.Hour}
	start := time.Date(2026, 1, 1, 10, 0, 0, 0, time.UTC)
	now := start.Add(10 * time.Minute)
	for count, wantAllowed := range map[int]bool{1: true, 2: true, 3: true, 4: false, 99: false} {
		d := decide(rule, count, start, now)
		if d.Allowed != wantAllowed || d.Count != count || d.ResetsIn != 50*time.Minute {
			t.Errorf("count %d: %+v", count, d)
		}
	}
	// Clock skew inside the statement never yields a negative wait.
	if d := decide(rule, 4, start, start.Add(2*time.Hour)); d.ResetsIn != 0 || d.RetryAfterSeconds() != 1 {
		t.Errorf("past the window end: %+v", d)
	}
}

func TestCheckKeys(t *testing.T) {
	h, _ := identity.NewEmailHMAC(bytes.Repeat([]byte{1}, 32))
	email, err := identity.NormalizeEmail("Secret.Person@Example.test")
	if err != nil {
		t.Fatal(err)
	}
	rules := DefaultRules()

	key := Check{Rule: rules.StartEmailHourly, Subject: EmailSubject(h, email)}.key()
	if !strings.HasPrefix(key, "otp_start_email_1h:email:") || len(key) != len("otp_start_email_1h:email:")+64 {
		t.Fatalf("unexpected key shape: %s", key)
	}
	for _, leak := range []string{"secret", "person", "example", "Secret"} {
		if strings.Contains(key, leak) {
			t.Fatalf("key leaks the email (%q): %s", leak, key)
		}
	}

	// Two spellings of one mailbox share a key, so a user cannot dodge a limit by changing case.
	other, _ := identity.NormalizeEmail("  secret.PERSON@example.TEST ")
	if (Check{Rule: rules.StartEmailHourly, Subject: EmailSubject(h, other)}).key() != key {
		t.Fatal("equivalent emails must share a counter key")
	}
	// Different rules on one subject have different counters.
	if (Check{Rule: rules.StartEmailDaily, Subject: EmailSubject(h, email)}).key() == key {
		t.Fatal("hourly and daily rules must not share a counter")
	}

	ip := clientip.New(nil).Resolve("[2001:db8:1:2::9]:80", nil)
	if got := (Check{Rule: rules.StartIP, Subject: IPSubject(ip)}).key(); got != "otp_start_ip_1h:ip:ip6:2001:db8:1:2::/64" {
		t.Fatalf("ip key = %s", got)
	}
	id := uuid.MustParse("0192f7a0-0000-7000-8000-000000000001")
	if got := (Check{Rule: rules.WrongCurrentPasswordUser, Subject: UserSubject(id)}).key(); got != "wrong_current_password_user_15m:user:"+id.String() {
		t.Fatalf("user key = %s", got)
	}
	if got := (Check{Rule: rules.RefreshSession, Subject: SessionSubject(id)}).key(); got != "refresh_session_1m:session:"+id.String() {
		t.Fatalf("session key = %s", got)
	}
}
