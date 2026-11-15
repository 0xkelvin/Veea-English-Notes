package admin

import (
	"slices"
	"testing"
	"time"

	"github.com/google/uuid"
)

// TestPermitsMatchesTheApprovedMatrix pins TRD 06 §3.1 cell by cell.
func TestPermitsMatchesTheApprovedMatrix(t *testing.T) {
	actor, other := uuid.New(), uuid.New()
	all := []Action{ActView, ActSessions, ActSuspend, ActReinstate, ActRole}
	cases := []struct {
		actorRole, targetRole string
		self                  bool
		want                  []Action
	}{
		{"user", "user", false, nil},
		{"user", "user", true, nil},
		{"user", "admin", false, nil},
		{"admin", "user", false, []Action{ActView, ActSessions, ActSuspend, ActReinstate}},
		{"admin", "admin", false, nil},
		{"admin", "super_admin", false, nil},
		{"admin", "admin", true, nil},
		{"super_admin", "user", false, all},
		{"super_admin", "admin", false, all},
		{"super_admin", "super_admin", false, all},
		{"super_admin", "super_admin", true, []Action{ActView, ActRole}},
		{"unknown", "user", false, nil},
	}
	for _, c := range cases {
		target := other
		if c.self {
			target = actor
		}
		for _, a := range all {
			if got := Permits(c.actorRole, actor, c.targetRole, target, a); got != slices.Contains(c.want, a) {
				t.Errorf("%s → %s (self=%v) %s: got %v", c.actorRole, c.targetRole, c.self, a, got)
			}
		}
	}
}

func TestAssignableRoles(t *testing.T) {
	actor, other := uuid.New(), uuid.New()
	cases := []struct {
		actorRole, targetRole string
		self                  bool
		want                  []string
	}{
		{"super_admin", "user", false, []string{"admin", "super_admin"}},
		{"super_admin", "admin", false, []string{"user", "super_admin"}},
		{"super_admin", "super_admin", false, []string{"user", "admin"}},
		{"super_admin", "super_admin", true, []string{"user"}}, // the only self mutation
		{"admin", "user", false, nil},
		{"admin", "admin", true, nil},
		{"user", "user", true, nil},
	}
	for _, c := range cases {
		target := other
		if c.self {
			target = actor
		}
		if got := AssignableRoles(c.actorRole, actor, c.targetRole, target); !slices.Equal(got, c.want) {
			t.Errorf("%s → %s self=%v: got %v, want %v", c.actorRole, c.targetRole, c.self, got, c.want)
		}
	}
}

func TestReasonsAndTicketRefs(t *testing.T) {
	if !ValidReason("suspend", "abuse") || ValidReason("suspend", "appeal_upheld") || ValidReason("role", "") || ValidReason("nope", "other") {
		t.Fatal("reason sets are per action")
	}
	for _, ok := range []string{"SUP-1042", "a", "ticket.7_x"} {
		if !ValidTicketRef(ok) {
			t.Errorf("%q should be valid", ok)
		}
	}
	for _, bad := range []string{"", "-x", "a b", "me@example.test", "vat_abc", "VOP_1", "x" + string(make([]byte, 40))} {
		if ValidTicketRef(bad) {
			t.Errorf("%q should be refused", bad)
		}
	}
}

func TestPageTokenRoundTripAndBinding(t *testing.T) {
	role := "user"
	f := Filter{Role: &role}
	fp := fingerprint(f)
	id := uuid.New()
	at := mustTime(t, "2026-11-15T01:02:03.456789Z")
	tok := encodePageToken(at, id, fp)
	if len(tok) != 46 {
		t.Fatalf("token length %d", len(tok))
	}
	gotAt, gotID, ok := decodePageToken(tok, fp)
	if !ok || !gotAt.Equal(at) || gotID != id {
		t.Fatalf("round trip: %v %v %v", gotAt, gotID, ok)
	}
	other := "admin"
	if _, _, ok := decodePageToken(tok, fingerprint(Filter{Role: &other})); ok {
		t.Fatal("a token must not be accepted with other filters")
	}
	for _, bad := range []string{"", "a1.", "a2." + tok[3:], tok + "A", tok[:45] + "!"} {
		if _, _, ok := decodePageToken(bad, fp); ok {
			t.Errorf("%q accepted", bad)
		}
	}
	if escapeLike(`a_b%c\d`) != `a\_b\%c\\d` {
		t.Fatal("LIKE escaping")
	}
}

func mustTime(t *testing.T, s string) time.Time {
	t.Helper()
	v, err := time.Parse(time.RFC3339Nano, s)
	if err != nil {
		t.Fatal(err)
	}
	return v
}

func TestAuditTokenRoundTripAndBinding(t *testing.T) {
	target, other := uuid.New(), uuid.New()
	at := mustTime(t, "2026-11-15T01:02:03.456789Z")
	tok := encodeAuditToken(at, 42, target)
	if len(tok) != 35 {
		t.Fatalf("token length %d", len(tok))
	}
	gotAt, id, ok := decodeAuditToken(tok, target)
	if !ok || !gotAt.Equal(at) || id != 42 {
		t.Fatalf("round trip: %v %d %v", gotAt, id, ok)
	}
	if _, _, ok := decodeAuditToken(tok, other); ok {
		t.Fatal("a token must be bound to its account")
	}
	for _, bad := range []string{"", "h1.", "a1." + tok[3:], tok + "A", encodeAuditToken(at, 0, target)} {
		if _, _, ok := decodeAuditToken(bad, target); ok {
			t.Errorf("%q accepted", bad)
		}
	}
	if len(AuditActions) != 5 {
		t.Fatal("the history exposes exactly the five TRD 06 mutation actions")
	}
}
