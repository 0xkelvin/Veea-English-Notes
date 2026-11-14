package learning

import (
	"bytes"
	"crypto/sha256"
	"encoding/json"
	"slices"
	"strconv"
	"time"
	"unicode/utf8"

	"github.com/google/uuid"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/httpx"
)

// Request-shape limits (TRD 05 §10.1).
const (
	MaxMutations    = 200
	MaxRequestBytes = 2 << 20
)

// ErrTooLarge is a push or import over the request limits: 413 payload_too_large.
var ErrTooLarge = httpx.ErrPayloadTooLarge

// Ops.
const (
	OpCreate  = "create"
	OpUpdate  = "update"
	OpDelete  = "delete"
	OpRestore = "restore"
)

// Mutation is one decoded queued change. Shape errors fail the whole request with
// httpx.ErrBadRequest; content errors become a per-item invalid_item (Invalid).
type Mutation struct {
	Seq      int64
	Op       string
	EntityID uuid.UUID
	Base     *int64
	Changed  []string       // update only, in request order
	Item     *Item          // create and restore: the full word
	Patch    map[string]any // update only: decoded values of the changed fields
	Invalid  *Invalid       // invalid_utf8 found while decoding; other checks run on the merged item
	BadDate  bool           // a date that does not parse (invalid_date, after the earlier checks)
	Hash     [32]byte       // SHA-256 of the exact mutation bytes as sent
}

// Editable fields of an update. client_created_at is fixed at creation.
var editable = []string{"word", "meaning", "pronunciation", "part_of_speech", "source", "examples", "tags", "capture_day"}

// DecodeMutations decodes the raw mutation objects of a push or import body.
func DecodeMutations(raw []json.RawMessage) ([]Mutation, error) {
	if len(raw) == 0 {
		return nil, httpx.ErrBadRequest
	}
	if len(raw) > MaxMutations {
		return nil, ErrTooLarge
	}
	out := make([]Mutation, 0, len(raw))
	for i, r := range raw {
		m, err := decodeMutation(r)
		if err != nil {
			return nil, err
		}
		if i > 0 && m.Seq != out[i-1].Seq+1 {
			return nil, httpx.ErrBadRequest // seq values must be strictly contiguous
		}
		out = append(out, m)
	}
	return out, nil
}

func decodeMutation(raw json.RawMessage) (Mutation, error) {
	var head struct {
		Op string `json:"op"`
	}
	if err := json.Unmarshal(raw, &head); err != nil {
		return Mutation{}, httpx.ErrBadRequest
	}
	m := Mutation{Op: head.Op, Hash: sha256.Sum256(raw)}
	switch head.Op {
	case OpCreate:
		var v struct {
			Seq      int64           `json:"seq"`
			Op       string          `json:"op"`
			EntityID uuid.UUID       `json:"entity_id"`
			Data     json.RawMessage `json:"data"`
		}
		if err := httpx.DecodeObject(raw, &v); err != nil {
			return Mutation{}, err
		}
		m.Seq, m.EntityID = v.Seq, v.EntityID
		it, bad, badDate, err := decodeItem(v.Data)
		if err != nil {
			return Mutation{}, err
		}
		m.Item, m.Invalid, m.BadDate = &it, bad, badDate
	case OpRestore:
		var v struct {
			Seq          int64           `json:"seq"`
			Op           string          `json:"op"`
			EntityID     uuid.UUID       `json:"entity_id"`
			BaseRevision int64           `json:"base_revision"`
			Data         json.RawMessage `json:"data"`
		}
		if err := httpx.DecodeObject(raw, &v); err != nil {
			return Mutation{}, err
		}
		m.Seq, m.EntityID, m.Base = v.Seq, v.EntityID, &v.BaseRevision
		it, bad, badDate, err := decodeItem(v.Data)
		if err != nil {
			return Mutation{}, err
		}
		m.Item, m.Invalid, m.BadDate = &it, bad, badDate
	case OpDelete:
		var v struct {
			Seq          int64     `json:"seq"`
			Op           string    `json:"op"`
			EntityID     uuid.UUID `json:"entity_id"`
			BaseRevision int64     `json:"base_revision"`
		}
		if err := httpx.DecodeObject(raw, &v); err != nil {
			return Mutation{}, err
		}
		m.Seq, m.EntityID, m.Base = v.Seq, v.EntityID, &v.BaseRevision
	case OpUpdate:
		var v struct {
			Seq           int64                      `json:"seq"`
			Op            string                     `json:"op"`
			EntityID      uuid.UUID                  `json:"entity_id"`
			BaseRevision  int64                      `json:"base_revision"`
			ChangedFields []string                   `json:"changed_fields"`
			Data          map[string]json.RawMessage `json:"data"`
		}
		if err := httpx.DecodeObject(raw, &v); err != nil {
			return Mutation{}, err
		}
		m.Seq, m.EntityID, m.Base, m.Changed = v.Seq, v.EntityID, &v.BaseRevision, v.ChangedFields
		if len(v.ChangedFields) == 0 || len(v.Data) != len(v.ChangedFields) {
			return Mutation{}, httpx.ErrBadRequest
		}
		m.Patch = map[string]any{}
		for _, f := range v.ChangedFields {
			value, ok := v.Data[f]
			_, dup := m.Patch[f]
			if !ok || dup || !slices.Contains(editable, f) {
				return Mutation{}, httpx.ErrBadRequest // unknown, duplicate, or not in data
			}
			got, bad, err := decodeField(f, value)
			if err != nil {
				return Mutation{}, err
			}
			if bad != nil && m.Invalid == nil {
				m.Invalid = bad
			}
			if f == "capture_day" && got == nil {
				m.BadDate = true
				got = time.Time{}
			}
			m.Patch[f] = got
		}
	default:
		return Mutation{}, httpx.ErrBadRequest
	}
	if m.Seq < 1 || m.EntityID == uuid.Nil || (m.Base != nil && *m.Base < 0) {
		return Mutation{}, httpx.ErrBadRequest
	}
	return m, nil
}

// decodeItem decodes a full word. A UTF-8 or date problem is a content failure, not a shape one.
func decodeItem(raw json.RawMessage) (Item, *Invalid, bool, error) {
	var v struct {
		Word            json.RawMessage `json:"word"`
		Meaning         json.RawMessage `json:"meaning"`
		Pronunciation   json.RawMessage `json:"pronunciation"`
		PartOfSpeech    json.RawMessage `json:"part_of_speech"`
		Source          json.RawMessage `json:"source"`
		Examples        json.RawMessage `json:"examples"`
		Tags            json.RawMessage `json:"tags"`
		CaptureDay      json.RawMessage `json:"capture_day"`
		ClientCreatedAt json.RawMessage `json:"client_created_at"`
	}
	if err := httpx.DecodeObject(raw, &v); err != nil {
		return Item{}, nil, false, err
	}
	var it Item
	var first *Invalid
	note := func(b *Invalid) {
		if b != nil && first == nil {
			first = b
		}
	}
	badDate := false
	for _, f := range []struct {
		name string
		raw  json.RawMessage
	}{{"word", v.Word}, {"meaning", v.Meaning}, {"pronunciation", v.Pronunciation}, {"part_of_speech", v.PartOfSpeech},
		{"source", v.Source}, {"examples", v.Examples}, {"tags", v.Tags}, {"capture_day", v.CaptureDay}} {
		got, bad, err := decodeField(f.name, f.raw)
		if err != nil {
			return Item{}, nil, false, err
		}
		note(bad)
		assign(&it, f.name, got)
		if f.name == "capture_day" && got == nil {
			badDate = true
		}
	}
	s, bad, err := jsonString(v.ClientCreatedAt)
	if err != nil {
		return Item{}, nil, false, err
	}
	note(bad)
	if t, err := time.Parse(time.RFC3339Nano, s); err == nil && bad == nil {
		it.ClientCreatedAt = t
	} else {
		badDate = true
	}
	return it, first, badDate, nil
}

// decodeField decodes one named field. For capture_day an unparsable date returns (nil, nil, nil).
func decodeField(name string, raw json.RawMessage) (any, *Invalid, error) {
	switch name {
	case "word", "meaning":
		return jsonString(raw)
	case "pronunciation", "part_of_speech", "source":
		if bytes.Equal(bytes.TrimSpace(raw), []byte("null")) {
			return (*string)(nil), nil, nil
		}
		s, bad, err := jsonString(raw)
		if err != nil {
			return nil, nil, err
		}
		return &s, bad, nil
	case "examples", "tags":
		var items []json.RawMessage
		if err := json.Unmarshal(raw, &items); err != nil || items == nil {
			return nil, nil, httpx.ErrBadRequest
		}
		out := make([]string, 0, len(items))
		var first *Invalid
		for _, r := range items {
			s, bad, err := jsonString(r)
			if err != nil {
				return nil, nil, err
			}
			if bad != nil && first == nil {
				first = bad
			}
			out = append(out, s)
		}
		return out, first, nil
	case "capture_day":
		s, bad, err := jsonString(raw)
		if err != nil {
			return nil, nil, err
		}
		if bad != nil {
			return nil, bad, nil
		}
		d, err := time.Parse("2006-01-02", s)
		if err != nil {
			return nil, nil, nil
		}
		return d, nil, nil
	}
	return nil, nil, httpx.ErrBadRequest
}

func assign(it *Item, name string, v any) {
	switch name {
	case "word":
		it.Word = v.(string)
	case "meaning":
		it.Meaning = v.(string)
	case "pronunciation":
		it.Pronunciation = v.(*string)
	case "part_of_speech":
		it.PartOfSpeech = v.(*string)
	case "source":
		it.Source = v.(*string)
	case "examples":
		it.Examples = v.([]string)
	case "tags":
		it.Tags = v.([]string)
	case "capture_day":
		if d, ok := v.(time.Time); ok {
			it.CaptureDay = d
		}
	}
}

// jsonString decodes a JSON string token. encoding/json silently replaces invalid UTF-8 and lone
// surrogate escapes with U+FFFD, so both are detected on the raw token first and reported as
// invalid_utf8. A token that is not a string is a shape error.
func jsonString(raw json.RawMessage) (string, *Invalid, error) {
	raw = bytes.TrimSpace(raw)
	if len(raw) < 2 || raw[0] != '"' || raw[len(raw)-1] != '"' {
		return "", nil, httpx.ErrBadRequest
	}
	body := raw[1 : len(raw)-1]
	bad := !utf8.Valid(body) || loneSurrogate(body)
	var s string
	if err := json.Unmarshal(raw, &s); err != nil {
		return "", nil, httpx.ErrBadRequest
	}
	if bad {
		return s, &Invalid{Detail: "invalid_utf8"}, nil
	}
	return s, nil, nil
}

// loneSurrogate reports a \uD800-\uDFFF escape that is not a valid high+low pair.
func loneSurrogate(b []byte) bool {
	for i := 0; i < len(b); i++ {
		if b[i] != '\\' {
			continue
		}
		if i+1 >= len(b) {
			return false
		}
		if b[i+1] != 'u' {
			i++ // skip the escaped character, including an escaped backslash
			continue
		}
		hi, ok := hex4(b, i+2)
		if !ok {
			return false // malformed; json.Unmarshal rejects it
		}
		switch {
		case hi >= 0xD800 && hi <= 0xDBFF:
			lo, ok := uint16(0), false
			if i+11 < len(b) && b[i+6] == '\\' && b[i+7] == 'u' {
				lo, ok = hex4(b, i+8)
			}
			if !ok || lo < 0xDC00 || lo > 0xDFFF {
				return true
			}
			i += 11
		case hi >= 0xDC00 && hi <= 0xDFFF:
			return true
		default:
			i += 5
		}
	}
	return false
}

func hex4(b []byte, at int) (uint16, bool) {
	if at+4 > len(b) {
		return 0, false
	}
	v, err := strconv.ParseUint(string(b[at:at+4]), 16, 16)
	return uint16(v), err == nil
}
