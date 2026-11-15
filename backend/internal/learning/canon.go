package learning

import (
	"errors"
	"fmt"
	"strconv"
	"time"
	"unicode/utf8"

	"github.com/google/uuid"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/db/sqlc"
)

// Limits (TRD 05 §10.1, D7, D8). Field limits count Unicode code points.
const (
	MaxLiveWords    = 50_000
	MaxItemBytes    = 8 << 10  // canonical content JSON, after escaping
	MaxContentBytes = 64 << 20 // sum over live words
	MaxWordLen      = 200
	MaxMeaningLen   = 2_000
	MaxPronLen      = 200
	MaxSourceLen    = 500
	MaxExamples     = 20
	MaxExampleLen   = 500
	MaxTags         = 30
	MaxTagLen       = 50
)

// Export bound (TRD 05 §11.1). EnvelopeBytes is the fixed per-word export overhead outside the
// content, including the separating comma; MaxHeaderBytes bounds header plus trailer.
const (
	EnvelopeBytes       = 242
	MaxHeaderBytes      = 16 << 10
	MaxExportPlainBytes = MaxContentBytes + MaxLiveWords*EnvelopeBytes + MaxHeaderBytes // 79,225,248
	ExportChunkBytes    = 1 << 20
	MaxExportChunks     = (MaxExportPlainBytes + ExportChunkBytes - 1) / ExportChunkBytes // 76
	// MaxSealedChunkBytes is one encoding byte, the chunk, and the AES-GCM nonce and tag.
	MaxSealedChunkBytes = 1 + ExportChunkBytes + 12 + 16 // 1,048,605
	// MaxSealedExportBytes bounds the sealed payloads of one export. PostgreSQL row, TOAST and
	// metadata overhead is not included.
	MaxSealedExportBytes = MaxExportPlainBytes + MaxExportChunks*(1+12+16) // 79,227,452
)

// PartsOfSpeech are the Flutter PartOfSpeech ids.
var PartsOfSpeech = map[string]bool{"n": true, "v": true, "adj": true, "adv": true, "phr": true, "idm": true, "etc": true}

// Content is the synced part of a word. Its canonical JSON is what the 8 KiB and 64 MiB limits
// measure and what the export writes, byte for byte.
type Content struct {
	Word          string
	Meaning       string
	Pronunciation *string
	PartOfSpeech  *string
	Source        *string
	Examples      []string
	Tags          []string
}

// AppendCanonical appends the canonical encoding: fixed key order, no whitespace, null for an
// absent optional field, and strings escaping only `"`, `\`, LF and TAB. Every other character
// is written as its UTF-8 bytes; other control characters never pass Validate.
func AppendCanonical(dst []byte, c Content) []byte {
	dst = append(dst, `{"word":`...)
	dst = appendString(dst, c.Word)
	dst = append(dst, `,"meaning":`...)
	dst = appendString(dst, c.Meaning)
	dst = append(dst, `,"pronunciation":`...)
	dst = appendNullable(dst, c.Pronunciation)
	dst = append(dst, `,"part_of_speech":`...)
	dst = appendNullable(dst, c.PartOfSpeech)
	dst = append(dst, `,"source":`...)
	dst = appendNullable(dst, c.Source)
	dst = append(dst, `,"examples":`...)
	dst = appendList(dst, c.Examples)
	dst = append(dst, `,"tags":`...)
	dst = appendList(dst, c.Tags)
	return append(dst, '}')
}

// CanonicalSize is len(AppendCanonical(nil, c)) without allocating the encoding.
func CanonicalSize(c Content) int {
	n := len(`{"word":,"meaning":,"pronunciation":,"part_of_speech":,"source":,"examples":,"tags":}`)
	n += stringSize(c.Word) + stringSize(c.Meaning) + nullableSize(c.Pronunciation) + nullableSize(c.PartOfSpeech) + nullableSize(c.Source)
	n += listSize(c.Examples) + listSize(c.Tags)
	return n
}

func appendString(dst []byte, s string) []byte {
	dst = append(dst, '"')
	for i := 0; i < len(s); i++ {
		switch b := s[i]; b {
		case '"':
			dst = append(dst, '\\', '"')
		case '\\':
			dst = append(dst, '\\', '\\')
		case '\n':
			dst = append(dst, '\\', 'n')
		case '\t':
			dst = append(dst, '\\', 't')
		default:
			dst = append(dst, b)
		}
	}
	return append(dst, '"')
}

func stringSize(s string) int {
	n := 2 + len(s)
	for i := 0; i < len(s); i++ {
		switch s[i] {
		case '"', '\\', '\n', '\t':
			n++
		}
	}
	return n
}

func appendNullable(dst []byte, s *string) []byte {
	if s == nil {
		return append(dst, "null"...)
	}
	return appendString(dst, *s)
}

func nullableSize(s *string) int {
	if s == nil {
		return 4
	}
	return stringSize(*s)
}

func appendList(dst []byte, l []string) []byte {
	dst = append(dst, '[')
	for i, s := range l {
		if i > 0 {
			dst = append(dst, ',')
		}
		dst = appendString(dst, s)
	}
	return append(dst, ']')
}

func listSize(l []string) int {
	n := 2
	for i, s := range l {
		if i > 0 {
			n++
		}
		n += stringSize(s)
	}
	return n
}

// Invalid is a per-item validation failure (invalid_item with detail and, for field limits, field).
type Invalid struct {
	Detail string
	Field  string
}

// Item is one word as a mutation carries it.
type Item struct {
	Content
	CaptureDay      time.Time
	ClientCreatedAt time.Time
}

// field is one named string of an item, in the fixed validation order.
type field struct {
	name  string
	value string
	max   int
}

func (c Content) fields() []field {
	f := []field{{"word", c.Word, MaxWordLen}, {"meaning", c.Meaning, MaxMeaningLen}}
	if c.Pronunciation != nil {
		f = append(f, field{"pronunciation", *c.Pronunciation, MaxPronLen})
	}
	if c.PartOfSpeech != nil {
		f = append(f, field{"part_of_speech", *c.PartOfSpeech, 0})
	}
	if c.Source != nil {
		f = append(f, field{"source", *c.Source, MaxSourceLen})
	}
	for _, e := range c.Examples {
		f = append(f, field{"examples", e, MaxExampleLen})
	}
	for _, t := range c.Tags {
		f = append(f, field{"tags", t, MaxTagLen})
	}
	return f
}

// Validate checks an item in the TRD 05 §10.1 order: UTF-8, control characters, part of speech
// and dates, field limits, then the serialized size. badDate reports a date the decoder could
// not parse. The first failure is returned, or nil.
func (it Item) Validate(badDate bool) *Invalid {
	fs := it.fields()
	for _, f := range fs {
		if !utf8.ValidString(f.value) {
			return &Invalid{Detail: "invalid_utf8"}
		}
	}
	for _, f := range fs {
		for _, r := range f.value {
			if r < 0x20 && r != '\t' && r != '\n' {
				return &Invalid{Detail: "control_character"}
			}
		}
	}
	if it.PartOfSpeech != nil && !PartsOfSpeech[*it.PartOfSpeech] {
		return &Invalid{Detail: "invalid_part_of_speech"}
	}
	if badDate || !validYear(it.CaptureDay) || !validYear(it.ClientCreatedAt.UTC()) {
		return &Invalid{Detail: "invalid_date"}
	}
	if utf8.RuneCountInString(it.Word) == 0 {
		return &Invalid{Detail: "field_empty", Field: "word"}
	}
	if len(it.Examples) > MaxExamples {
		return &Invalid{Detail: "too_many_entries", Field: "examples"}
	}
	if len(it.Tags) > MaxTags {
		return &Invalid{Detail: "too_many_entries", Field: "tags"}
	}
	for _, f := range fs {
		if f.max > 0 && utf8.RuneCountInString(f.value) > f.max {
			return &Invalid{Detail: "field_too_long", Field: f.name}
		}
	}
	if CanonicalSize(it.Content) > MaxItemBytes {
		return &Invalid{Detail: "item_too_large"}
	}
	return nil
}

func validYear(t time.Time) bool { return t.Year() >= 1 && t.Year() <= 9999 }

// ExportTime is the fixed 24-character export timestamp format.
const ExportTime = "2006-01-02T15:04:05.000Z"

// AppendExportItem appends one export element (TRD 05 §11.1): the fixed envelope around the
// canonical content. Without the separating comma it is EnvelopeBytes-1 bytes plus the content
// at most; years are 0001-9999 and the revision is a positive bigint.
func AppendExportItem(dst []byte, id uuid.UUID, revision int64, captureDay, clientCreated, created, updated time.Time, content []byte) []byte {
	dst = append(dst, `{"id":"`...)
	dst = append(dst, id.String()...)
	dst = append(dst, `","revision":`...)
	dst = strconv.AppendInt(dst, revision, 10)
	dst = append(dst, `,"capture_day":"`...)
	dst = captureDay.AppendFormat(dst, "2006-01-02")
	dst = append(dst, `","client_created_at":"`...)
	dst = clientCreated.UTC().AppendFormat(dst, ExportTime)
	dst = append(dst, `","created_at":"`...)
	dst = created.UTC().AppendFormat(dst, ExportTime)
	dst = append(dst, `","updated_at":"`...)
	dst = updated.UTC().AppendFormat(dst, ExportTime)
	dst = append(dst, `","content":`...)
	dst = append(dst, content...)
	return append(dst, '}')
}

// AppendExportRow appends one live word's export element, re-encoding its content with the
// canonical encoder and failing closed when the encoding differs from the stored content_bytes
// (the quantity the quota and the export bound were computed from).
func AppendExportRow(dst []byte, r sqlc.VocabularyItem) ([]byte, error) {
	if r.DeletedAt != nil || r.CaptureDay == nil || r.ClientCreatedAt == nil {
		return dst, errors.New("learning: export row is not a live word")
	}
	it := itemOf(r)
	start := len(dst)
	dst = AppendExportItem(dst, r.ID, r.Revision, *r.CaptureDay, *r.ClientCreatedAt, r.CreatedAt, r.UpdatedAt, nil)
	dst = dst[:len(dst)-1] // reopen before the closing brace to place the content
	before := len(dst)
	dst = AppendCanonical(dst, it.Content)
	if n := len(dst) - before; n != int(r.ContentBytes) || n > MaxItemBytes {
		return dst[:start], fmt.Errorf("learning: export content size %d differs from stored %d", n, r.ContentBytes)
	}
	return append(dst, '}'), nil
}
