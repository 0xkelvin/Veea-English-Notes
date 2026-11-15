package entitlements

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/learning"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/db/sqlc"
)

func TestLimitsAreIdenticalForBothPlans(t *testing.T) {
	want := Limits{LiveWords: learning.MaxLiveWords, ContentBytes: learning.MaxContentBytes, Writers: learning.MaxActiveWriters}
	if LimitsFor(Free) != want || LimitsFor(Premium) != want || want.LiveWords != 50_000 || want.ContentBytes != 64<<20 || want.Writers != 20 {
		t.Fatalf("limits: %+v %+v", LimitsFor(Free), LimitsFor(Premium))
	}
}

func TestExportSectionStatusesAndAllowlist(t *testing.T) {
	at := time.Date(2026, 11, 15, 12, 0, 0, 0, time.UTC)
	h := func(d int) time.Time { return at.Add(time.Duration(d) * time.Hour) }
	p := func(t time.Time) *time.Time { return &t }
	s := func(v string) *string { return &v }
	grants := []sqlc.ListRetainedEntitlementGrantsRow{
		{StartsAt: h(-1), EndsAt: h(24), PeriodEnd: p(h(24))},                                                      // active
		{StartsAt: h(-48), EndsAt: h(-24), PeriodEnd: p(h(-24))},                                                   // expired, open
		{StartsAt: h(-96), EndsAt: h(-72), ClosedAt: p(h(-70)), ClosedReason: s("replaced"), PeriodEnd: p(h(-72))}, // closed after expiry
		{StartsAt: h(-200), EndsAt: h(-100), ClosedAt: p(h(-150)), ClosedReason: s("replaced"), PeriodEnd: p(h(-150))},
		{StartsAt: h(-300), EndsAt: h(-210), ClosedAt: p(h(-250)), ClosedReason: s("revoked"), PeriodEnd: p(h(-250))},
	}
	plan := Plan{Name: Premium, ExpiresAt: p(h(24)), CheckedAt: at}
	b := AppendExport(nil, plan, grants, at)
	var doc struct {
		E struct {
			Plan    string           `json:"plan"`
			Expires *string          `json:"plan_expires_at"`
			Days    int              `json:"retention_days"`
			Grants  []map[string]any `json:"grants"`
		} `json:"entitlements"`
	}
	if err := json.Unmarshal(append([]byte(`{"x":0`), append(b, '}')...), &doc); err != nil {
		t.Fatalf("not JSON: %v: %s", err, b)
	}
	want := []string{StatusActive, StatusExpired, StatusExpired, StatusReplaced, StatusRevoked}
	for i, g := range doc.E.Grants {
		if g["status"] != want[i] || len(g) != 5 || g["source"] != "manual" {
			t.Fatalf("grant %d: %v", i, g)
		}
		if (g["ended_at"] == nil) != (i == 0) {
			t.Fatalf("grant %d ended_at: %v", i, g)
		}
	}
	if doc.E.Plan != Premium || doc.E.Expires == nil || doc.E.Days != RetentionDays {
		t.Fatalf("section: %s", b)
	}
	free := AppendExport(nil, Plan{Name: Free, CheckedAt: at}, nil, at)
	if string(free) != `,"entitlements":{"plan":"free","plan_expires_at":null,"retention_days":180,"grants":[]}` {
		t.Fatalf("free section: %s", free)
	}
}
