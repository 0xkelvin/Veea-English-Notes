package lifecycle

import (
	"bytes"
	"compress/flate"
	"crypto/rand"
	"testing"

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
