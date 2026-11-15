package learning

import (
	"bytes"
	"encoding/json"
	"github.com/google/uuid"
	"strings"
	"testing"
)

func TestCartridgePublishingValidation(t *testing.T) {
	id := uuid.New()
	entry := CartridgeEntry{EntryID: id, Content: json.RawMessage(`{"word":"fixture","meaning":"m","pronunciation":null,"part_of_speech":"n","source":null,"examples":[],"tags":[]}`)}
	base := CartridgeDocument{ID: "synthetic", Title: "Fixture", Version: 1, RequiredPlan: "free", Entries: []CartridgeEntry{entry}}
	valid, _ := json.Marshal(base)
	if _, _, err := decodeCartridge(valid); err != nil {
		t.Fatal(err)
	}
	cases := map[string][]byte{
		"size":                bytes.Repeat([]byte{'x'}, MaxCartridgeBytes+1),
		"unknown":             bytes.Replace(valid, []byte(`"word":"fixture"`), []byte(`"unknown":"fixture"`), 1),
		"duplicate_entry_key": bytes.Replace(valid, []byte(`"entry_id":`), []byte(`"entry_id":"`+id.String()+`","entry_id":`), 1),
		"lone_surrogate":      bytes.Replace(valid, []byte(`"fixture"`), []byte(`"\ud800"`), 1),
		"title_control":       bytes.Replace(valid, []byte(`"Fixture"`), []byte(`"\u0001"`), 1),
		"oversize_word":       bytes.Replace(valid, []byte(`"fixture"`), []byte(`"`+strings.Repeat("a", 201)+`"`), 1),
		"bad_part_of_speech":  bytes.Replace(valid, []byte(`"part_of_speech":"n"`), []byte(`"part_of_speech":"noun"`), 1),
	}
	for name, raw := range cases {
		t.Run(name, func(t *testing.T) {
			if _, _, err := decodeCartridge(raw); err == nil {
				t.Fatal("invalid document accepted")
			}
		})
	}
	base.Entries = make([]CartridgeEntry, MaxMutations+1)
	raw, _ := json.Marshal(base)
	if _, _, err := decodeCartridge(raw); err == nil {
		t.Fatal("entry bound not enforced")
	}
}
