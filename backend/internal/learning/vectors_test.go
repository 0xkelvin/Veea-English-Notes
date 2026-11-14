package learning

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"os"
	"strings"
	"testing"
	"time"
)

// The canonical-encoder vectors shared with the Flutter client (TRD 05 §15.2 check 11). The Go
// encoder and validator generate the expected values; the Dart test reads the same file. Run with
// VEEA_UPDATE_VECTORS=1 to rewrite it after an intentional change.
const vectorsFile = "testdata/canonical_vectors.json"

type vectorItem struct {
	Word            string   `json:"word"`
	Meaning         string   `json:"meaning"`
	Pronunciation   *string  `json:"pronunciation"`
	PartOfSpeech    *string  `json:"part_of_speech"`
	Source          *string  `json:"source"`
	Examples        []string `json:"examples"`
	Tags            []string `json:"tags"`
	CaptureDay      string   `json:"capture_day"`
	ClientCreatedAt string   `json:"client_created_at"`
}

type vector struct {
	Name         string     `json:"name"`
	Item         vectorItem `json:"item"`
	CanonicalB64 string     `json:"canonical_b64"`
	Size         int        `json:"size"`
	CodePoints   int        `json:"word_code_points"`
	Detail       string     `json:"invalid_detail"`
	Field        string     `json:"invalid_field"`
}

type vectorFile struct {
	Comment string   `json:"comment"`
	Limits  any      `json:"limits"`
	Vectors []vector `json:"vectors"`
}

func boundaryItem(quotes int) vectorItem {
	it := vectorItem{Word: "w", Meaning: strings.Repeat("x", MaxMeaningLen), Examples: []string{}, Tags: []string{},
		CaptureDay: "2026-11-14", ClientCreatedAt: "2026-11-14T08:00:00Z"}
	for size(it)+MaxExampleLen+3 <= MaxItemBytes-1000 {
		it.Examples = append(it.Examples, strings.Repeat("y", MaxExampleLen))
	}
	if quotes < 0 {
		quotes = MaxItemBytes - size(it) + (-quotes - 1)
	}
	it.Meaning = strings.Repeat(`"`, quotes) + strings.Repeat("x", MaxMeaningLen-quotes)
	return it
}

func toContent(v vectorItem) Content {
	return Content{Word: v.Word, Meaning: v.Meaning, Pronunciation: v.Pronunciation, PartOfSpeech: v.PartOfSpeech,
		Source: v.Source, Examples: v.Examples, Tags: v.Tags}
}

func size(v vectorItem) int { return CanonicalSize(toContent(v)) }

func vectorInputs() []vector {
	s := func(v string) *string { return &v }
	base := func(word string) vectorItem {
		return vectorItem{Word: word, Meaning: "m", Examples: []string{}, Tags: []string{}, CaptureDay: "2026-11-14", ClientCreatedAt: "2026-11-14T08:00:00Z"}
	}
	with := func(v vectorItem, f func(*vectorItem)) vectorItem { f(&v); return v }
	many := func(n int, v string) []string {
		out := make([]string, n)
		for i := range out {
			out[i] = v
		}
		return out
	}
	return []vector{
		{Name: "plain", Item: base("serendipity")},
		{Name: "every field", Item: with(base("run"), func(v *vectorItem) {
			v.Meaning, v.Pronunciation, v.PartOfSpeech, v.Source = "chạy", s("/rʌn/"), s("v"), s("book")
			v.Examples, v.Tags = []string{"I run.", "She runs daily."}, []string{"verb", "daily"}
		})},
		{Name: "escapes quote backslash LF TAB", Item: base("a\"b\\c\nd\te")},
		{Name: "no HTML escaping", Item: base("<b>&amp;</b>")},
		{Name: "U+2028 and U+2029 are raw", Item: base("a b c")},
		{Name: "emoji and modifiers", Item: base("👋🏽 🙂 👨‍👩‍👧")},
		{Name: "combining marks", Item: base("é à")},
		{Name: "precomposed vietnamese", Item: base("tiếng Việt ệ")},
		{Name: "empty source and lists", Item: with(base("w"), func(v *vectorItem) { v.Source = s("") })},
		{Name: "word 200 code points of emoji", Item: base(strings.Repeat("🙂", 200))},
		{Name: "word 201 code points", Item: base(strings.Repeat("a", 201))},
		{Name: "100 combining pairs plus a letter is 201 code points", Item: base(strings.Repeat("é", 100) + "x")},
		{Name: "meaning 2000 vietnamese", Item: with(base("w"), func(v *vectorItem) { v.Meaning = strings.Repeat("ệ", 2000) })},
		{Name: "meaning 2001", Item: with(base("w"), func(v *vectorItem) { v.Meaning = strings.Repeat("ệ", 2001) })},
		{Name: "pronunciation 201", Item: with(base("w"), func(v *vectorItem) { v.Pronunciation = s(strings.Repeat("ə", 201)) })},
		{Name: "source 501", Item: with(base("w"), func(v *vectorItem) { v.Source = s(strings.Repeat("s", 501)) })},
		{Name: "20 examples of 500", Item: with(base("w"), func(v *vectorItem) { v.Examples = many(20, strings.Repeat("e", 300)) })},
		{Name: "21 examples", Item: with(base("w"), func(v *vectorItem) { v.Examples = many(21, "e") })},
		{Name: "example 501", Item: with(base("w"), func(v *vectorItem) { v.Examples = []string{strings.Repeat("e", 501)} })},
		{Name: "30 tags", Item: with(base("w"), func(v *vectorItem) { v.Tags = many(30, "t") })},
		{Name: "31 tags", Item: with(base("w"), func(v *vectorItem) { v.Tags = many(31, "t") })},
		{Name: "tag 51", Item: with(base("w"), func(v *vectorItem) { v.Tags = []string{strings.Repeat("t", 51)} })},
		{Name: "empty word", Item: base("")},
		{Name: "CR refused", Item: base("a\rb")},
		{Name: "NUL refused", Item: base("a\x00b")},
		{Name: "unit separator refused", Item: base("a\x1fb")},
		{Name: "invalid part of speech", Item: with(base("w"), func(v *vectorItem) { v.PartOfSpeech = s("noun") })},
		{Name: "invalid capture day", Item: with(base("w"), func(v *vectorItem) { v.CaptureDay = "2026-02-30" })},
		{Name: "invalid created calendar day", Item: with(base("w"), func(v *vectorItem) { v.ClientCreatedAt = "2026-02-30T08:00:00Z" })},
		{Name: "invalid created hour", Item: with(base("w"), func(v *vectorItem) { v.ClientCreatedAt = "2026-11-14T24:00:00Z" })},
		{Name: "created UTC year out of range", Item: with(base("w"), func(v *vectorItem) { v.ClientCreatedAt = "0001-01-01T00:00:00+07:00" })},
		{Name: "control before date", Item: with(base("a\x01"), func(v *vectorItem) { v.CaptureDay = "nope" })},
		{Name: "date before limits", Item: with(base(strings.Repeat("a", 201)), func(v *vectorItem) { v.CaptureDay = "nope" })},
		{Name: "exactly 8192 bytes by escaping", Item: boundaryItem(-1)},
		{Name: "8193 bytes only by escaping", Item: boundaryItem(-2)},
		{Name: "within every field limit but over 8 KiB", Item: with(base("w"), func(v *vectorItem) {
			v.Meaning = strings.Repeat("ệ", 2000)
			v.Examples = many(5, strings.Repeat("x", 500))
		})},
	}
}

func expected(v vector) vector {
	c := toContent(v.Item)
	v.CanonicalB64 = base64.StdEncoding.EncodeToString(AppendCanonical(nil, c))
	v.Size = CanonicalSize(c)
	v.CodePoints = len([]rune(v.Item.Word))
	day, derr := time.Parse("2006-01-02", v.Item.CaptureDay)
	created, cerr := time.Parse(time.RFC3339Nano, v.Item.ClientCreatedAt)
	inv := Item{Content: c, CaptureDay: day, ClientCreatedAt: created}.Validate(derr != nil || cerr != nil)
	v.Detail, v.Field = "", ""
	if inv != nil {
		v.Detail, v.Field = inv.Detail, inv.Field
	}
	return v
}

func TestCanonicalVectorsFile(t *testing.T) {
	file := vectorFile{
		Comment: "Generated by backend/internal/learning TestCanonicalVectorsFile (VEEA_UPDATE_VECTORS=1). The Flutter client runs the same vectors.",
		Limits: map[string]int{"max_item_bytes": MaxItemBytes, "max_word": MaxWordLen, "max_meaning": MaxMeaningLen, "max_pronunciation": MaxPronLen,
			"max_source": MaxSourceLen, "max_examples": MaxExamples, "max_example": MaxExampleLen, "max_tags": MaxTags, "max_tag": MaxTagLen,
			"max_live_words": MaxLiveWords, "max_content_bytes": MaxContentBytes},
	}
	for _, v := range vectorInputs() {
		file.Vectors = append(file.Vectors, expected(v))
	}
	var want bytes.Buffer
	enc := json.NewEncoder(&want)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", "  ")
	if err := enc.Encode(file); err != nil {
		t.Fatal(err)
	}
	if os.Getenv("VEEA_UPDATE_VECTORS") == "1" {
		if err := os.WriteFile(vectorsFile, want.Bytes(), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	got, err := os.ReadFile(vectorsFile)
	if err != nil {
		t.Fatalf("%v (generate with VEEA_UPDATE_VECTORS=1)", err)
	}
	if !bytes.Equal(got, want.Bytes()) {
		t.Fatal("canonical_vectors.json is stale; regenerate with VEEA_UPDATE_VECTORS=1 and rerun the Flutter vector test")
	}
	// Sanity: the boundary pair really straddles 8 KiB, and some vectors are invalid.
	vs := file.Vectors
	at, over := vs[len(vs)-3], vs[len(vs)-2]
	if at.Size != MaxItemBytes || at.Detail != "" || over.Size != MaxItemBytes+1 || over.Detail != "item_too_large" {
		t.Fatalf("boundary vectors: %d %q / %d %q", at.Size, at.Detail, over.Size, over.Detail)
	}
}
