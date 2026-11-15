package learning

import (
	"encoding/json"
	"math"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
)

func ptr(s string) *string { return &s }

func TestCanonicalEncodingIsExactAndCountsEscapes(t *testing.T) {
	c := Content{Word: `a"b\c`, Meaning: "line\nnext\tcol <&>   ✓ 🙂", Pronunciation: nil, PartOfSpeech: ptr("n"),
		Source: ptr(""), Examples: []string{}, Tags: []string{"x", `"q"`}}
	got := string(AppendCanonical(nil, c))
	want := `{"word":"a\"b\\c","meaning":"line\nnext\tcol <&> ` + " " + ` ✓ 🙂","pronunciation":null,"part_of_speech":"n","source":"","examples":[],"tags":["x","\"q\""]}`
	if got != want {
		t.Fatalf("canonical encoding\n got %s\nwant %s", got, want)
	}
	if CanonicalSize(c) != len(got) {
		t.Fatalf("CanonicalSize %d != len %d", CanonicalSize(c), len(got))
	}
	// The canonical form is valid JSON that decodes back to the same strings.
	var back struct {
		Word, Meaning string
		Tags          []string
	}
	if err := json.Unmarshal([]byte(got), &back); err != nil || back.Word != c.Word || back.Meaning != c.Meaning || back.Tags[1] != `"q"` {
		t.Fatalf("round trip: %v %+v", err, back)
	}
}

func TestEnvelopeIsFixedAt242BytesWithItsSeparator(t *testing.T) {
	max := time.Date(9999, 12, 31, 23, 59, 59, 999_000_000, time.UTC)
	content := []byte(`{"word":"w"}`)
	b := AppendExportItem(nil, uuid.New(), math.MaxInt64, max, max, max, max, content)
	if len(b)-len(content) != EnvelopeBytes-1 {
		t.Fatalf("envelope is %d bytes, want %d plus the separator", len(b)-len(content), EnvelopeBytes-1)
	}
	if !json.Valid(b) {
		t.Fatalf("export element is not JSON: %s", b)
	}
}

func TestExportBoundConstants(t *testing.T) {
	if MaxExportPlainBytes != 79_225_248 || MaxExportChunks != 76 || MaxSealedChunkBytes != 1_048_605 || MaxSealedExportBytes != 79_227_452 {
		t.Fatalf("bounds: plain %d chunks %d chunk %d sealed %d", MaxExportPlainBytes, MaxExportChunks, MaxSealedChunkBytes, MaxSealedExportBytes)
	}
}

func item(word string) Item {
	return Item{Content: Content{Word: word, Meaning: "m", Examples: []string{}, Tags: []string{}},
		CaptureDay: time.Date(2026, 11, 14, 0, 0, 0, 0, time.UTC), ClientCreatedAt: time.Date(2026, 11, 14, 1, 2, 3, 0, time.UTC)}
}

func TestValidateCountsCodePointsAndKeepsTheOrder(t *testing.T) {
	cases := map[string]struct {
		it      func() Item
		badDate bool
		want    *Invalid
	}{
		"200 code points of 4-byte emoji":  {func() Item { return item(strings.Repeat("🙂", 200)) }, false, nil},
		"201 code points":                  {func() Item { return item(strings.Repeat("a", 201)) }, false, &Invalid{"field_too_long", "word"}},
		"combining marks count separately": {func() Item { return item(strings.Repeat("é", 100) + "x") }, false, &Invalid{"field_too_long", "word"}},
		"precomposed vietnamese counts 1":  {func() Item { return item(strings.Repeat("ệ", 200)) }, false, nil},
		"empty word":                       {func() Item { return item("") }, false, &Invalid{"field_empty", "word"}},
		"CR refused":                       {func() Item { return item("a\rb") }, false, &Invalid{"control_character", ""}},
		"TAB and LF allowed":               {func() Item { return item("a\tb\nc") }, false, nil},
		"control before date":              {func() Item { return item("a\x01") }, true, &Invalid{"control_character", ""}},
		"date before limits":               {func() Item { return item(strings.Repeat("a", 201)) }, true, &Invalid{"invalid_date", ""}},
		"part of speech":                   {func() Item { it := item("a"); it.PartOfSpeech = ptr("noun"); return it }, false, &Invalid{"invalid_part_of_speech", ""}},
		"21 examples":                      {func() Item { it := item("a"); it.Examples = make([]string, 21); return it }, false, &Invalid{"too_many_entries", "examples"}},
		"31 tags":                          {func() Item { it := item("a"); it.Tags = make([]string, 31); return it }, false, &Invalid{"too_many_entries", "tags"}},
		"within every field limit but over 8 KiB": {func() Item {
			it := item("a")
			it.Meaning = strings.Repeat("ệ", 2000) // 6,000 bytes
			it.Examples = []string{strings.Repeat("x", 500), strings.Repeat("x", 500), strings.Repeat("x", 500), strings.Repeat("x", 500), strings.Repeat("x", 500)}
			return it
		}, false, &Invalid{"item_too_large", ""}},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			got := tc.it().Validate(tc.badDate)
			if (got == nil) != (tc.want == nil) || (got != nil && *got != *tc.want) {
				t.Fatalf("Validate = %+v, want %+v", got, tc.want)
			}
		})
	}
}

func TestItemSizeBoundaryIncludesEscaping(t *testing.T) {
	// Examples bring the word close to 8 KiB with a 2,000-code-point ASCII meaning; then each '"'
	// replacing an 'x' adds exactly one byte (it encodes as two), so escaping alone decides.
	it := item("w")
	it.Meaning = strings.Repeat("x", MaxMeaningLen)
	for CanonicalSize(it.Content)+MaxExampleLen+3 <= MaxItemBytes-1000 {
		it.Examples = append(it.Examples, strings.Repeat("y", MaxExampleLen))
	}
	q := MaxItemBytes - CanonicalSize(it.Content)
	if q < 1 || q >= MaxMeaningLen {
		t.Fatalf("fixture layout: %d quotes", q)
	}
	with := func(quotes int) Item {
		c := it
		c.Meaning = strings.Repeat(`"`, quotes) + strings.Repeat("x", MaxMeaningLen-quotes)
		return c
	}
	at, over := with(q), with(q+1)
	if CanonicalSize(at.Content) != MaxItemBytes || len(AppendCanonical(nil, at.Content)) != MaxItemBytes || at.Validate(false) != nil {
		t.Fatalf("exactly 8,192 canonical bytes must pass: %d %+v", CanonicalSize(at.Content), at.Validate(false))
	}
	if CanonicalSize(over.Content) != MaxItemBytes+1 || over.Validate(false) == nil || over.Validate(false).Detail != "item_too_large" {
		t.Fatalf("8,193 bytes reached only by escaping must fail: %d", CanonicalSize(over.Content))
	}
}

func TestDecodeDetectsInvalidUTF8AndLoneSurrogates(t *testing.T) {
	data := func(word string) []byte {
		return []byte(`{"seq":1,"op":"create","entity_id":"` + uuid.NewString() + `","data":{"word":` + word +
			`,"meaning":"m","pronunciation":null,"part_of_speech":null,"source":null,"examples":[],"tags":[],"capture_day":"2026-11-14","client_created_at":"2026-11-14T00:00:00Z"}}`)
	}
	for name, word := range map[string]string{"raw invalid byte": "\"a\xffb\"", "lone high surrogate": `"\ud83d"`, "lone low surrogate": `"\ude00x"`} {
		m, err := decodeMutation(data(word))
		if err != nil || m.Invalid == nil || m.Invalid.Detail != "invalid_utf8" {
			t.Errorf("%s: %v %+v", name, err, m.Invalid)
		}
	}
	for name, word := range map[string]string{"pair": `"😀"`, "escaped backslash then u": `"\\ud800"`, "plain": `"ok"`} {
		m, err := decodeMutation(data(word))
		if err != nil || m.Invalid != nil {
			t.Errorf("%s: %v %+v", name, err, m.Invalid)
		}
	}
	if _, err := decodeMutation([]byte(`{"seq":1,"op":"create","entity_id":"` + uuid.NewString() + `","data":{"word":"w"}}`)); err == nil {
		t.Error("a create without every data field must be a shape error")
	}
	if _, err := decodeMutation([]byte(`{"seq":1,"op":"delete","entity_id":"` + uuid.NewString() + `","base_revision":1,"extra":1}`)); err == nil {
		t.Error("unknown keys must be refused")
	}
}
