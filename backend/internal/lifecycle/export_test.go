package lifecycle

import (
	"bytes"
	"compress/flate"
	"crypto/rand"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/entitlements"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/db/sqlc"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/learning"
)

func TestChunkEncodingNeverGrowsAndRoundTrips(t *testing.T) {
	random := make([]byte, learning.ExportChunkBytes)
	_, _ = rand.Read(random)
	text := bytes.Repeat([]byte(`{"word":"a","meaning":"b"},`), learning.ExportChunkBytes/27)
	for name, chunk := range map[string][]byte{"incompressible": random, "text": text, "empty": {}} {
		body, err := encodeChunk(chunk)
		if err != nil {
			t.Fatal(err)
		}
		if len(body) > 1+len(chunk) {
			t.Fatalf("%s: encoded %d bytes for a %d-byte chunk", name, len(body), len(chunk))
		}
		if name == "incompressible" && (body[0] != encodingRaw || len(body)+12+16 != learning.MaxSealedChunkBytes) {
			t.Fatalf("an incompressible full chunk must be stored raw at the sealed bound: %d", len(body)+28)
		}
		if name == "text" && body[0] != encodingDeflate {
			t.Fatal("compressible chunks should deflate")
		}
		back, err := decodeChunk(body)
		if err != nil || !bytes.Equal(back, chunk) {
			t.Fatalf("%s: round trip: %v", name, err)
		}
	}
	// A body that inflates past 1 MiB is refused.
	var z bytes.Buffer
	z.WriteByte(encodingDeflate)
	fw, _ := flate.NewWriter(&z, flate.BestSpeed)
	_, _ = fw.Write(make([]byte, learning.ExportChunkBytes+1))
	_ = fw.Close()
	if _, err := decodeChunk(z.Bytes()); err == nil {
		t.Fatal("inflation over 1 MiB must fail")
	}
	if _, err := decodeChunk([]byte{7, 1}); err == nil {
		t.Fatal("unknown encoding must fail")
	}
}

// TRD 09 §7: the schema 3 header with the widest account and the widest entitlement section
// stays inside learning.MaxHeaderBytes, so the verified TRD 05 export bound is unchanged.
func TestExportHeaderWorstCaseWithEntitlements(t *testing.T) {
	far := time.Date(9999, 12, 31, 23, 59, 59, 999_000_000, time.UTC)
	name := strings.Repeat("&", 64)  // 64 code points, each escaped by encoding/json as &
	zone := strings.Repeat("&", 255) // no IANA name is this long; pessimistic on purpose
	verified := far
	// The display email: at most 1,024 input bytes. Only escaped ASCII (6 bytes each) can grow,
	// and it is bounded by the 254-octet normalized form; U+2028 (3 bytes) escapes to 6.
	email := strings.Repeat("&", 254) + strings.Repeat(" ", (1024-254)/3)
	u := sqlc.User{ID: uuid.New(), Email: email, EmailVerifiedAt: &verified, CreatedAt: far,
		DisplayName: &name, PreferredLanguage: "vi", TimeZone: zone, DailyGoal: 1000}
	replaced := "replaced"
	grants := make([]sqlc.ListRetainedEntitlementGrantsRow, entitlements.MaxRetainedGrants+5)
	for i := range grants {
		grants[i] = sqlc.ListRetainedEntitlementGrantsRow{StartsAt: far, EndsAt: far, ClosedAt: &far, ClosedReason: &replaced, PeriodEnd: &far}
	}
	plan := entitlements.Plan{Name: entitlements.Premium, ExpiresAt: &far, CheckedAt: far}
	section := entitlements.AppendExport(nil, plan, grants, far)
	if len(section) > entitlements.MaxExportSectionBytes {
		t.Fatalf("section %d bytes exceeds its bound %d", len(section), entitlements.MaxExportSectionBytes)
	}
	installations := make([]sqlc.ListCartridgeInstallationsRow, learning.MaxCartridges)
	for i := range installations {
		installations[i] = sqlc.ListCartridgeInstallationsRow{CartridgeID: strings.Repeat("z", 48), InstalledVersion: 2147483647}
	}
	beforeCartridges := len(section)
	section = learning.AppendCartridgeInstallations(section, installations)
	if len(section)-beforeCartridges != 1612 {
		t.Fatalf("cartridge section bound changed: %d", len(section)-beforeCartridges)
	}
	h, err := exportHeader(far, 9_223_372_036_854_775_807, u, section)
	if err != nil {
		t.Fatal(err)
	}
	if got := len(h) + len(exportTrailer); got > learning.MaxHeaderBytes {
		t.Fatalf("worst-case header %d bytes exceeds MaxHeaderBytes %d", got, learning.MaxHeaderBytes)
	} else {
		t.Logf("worst-case header %d of %d bytes (entitlements + cartridges %d)", got, learning.MaxHeaderBytes, len(section))
	}
	if learning.MaxExportPlainBytes != 79_225_248 {
		t.Fatal("the TRD 05 export bound must not change")
	}
	var doc map[string]any
	if err := json.Unmarshal(append(h, exportTrailer...), &doc); err != nil {
		t.Fatalf("header is not JSON: %v", err)
	}
	ent := doc["entitlements"].(map[string]any)
	if doc["schema_version"].(float64) != 3 || len(ent["grants"].([]any)) != entitlements.MaxRetainedGrants {
		t.Fatalf("header shape: %v", ent)
	}
	for _, g := range ent["grants"].([]any) {
		if len(g.(map[string]any)) != 5 {
			t.Fatalf("grant entry fields: %v", g)
		}
	}
}
