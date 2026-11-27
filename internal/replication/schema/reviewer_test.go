package schema

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/dbpprt/dieter/internal/replication/crdt"
)

func reviewerKV(t *testing.T, key string, value any) crdt.Record {
	t.Helper()
	raw, ok := value.([]byte)
	if !ok {
		var err error
		if raw, err = json.Marshal(value); err != nil {
			t.Fatal(err)
		}
	}
	return crdt.Record{Kind: KVKindPrefix + ReviewerSettingsNamespace, ID: key, Versions: []crdt.Version{{Clock: crdt.Clock{"a": 1}, Value: raw}}}
}

func TestReviewerSettingsAreValidatedOnIngest(t *testing.T) {
	t.Parallel()
	valid := DefaultReviewerSettings()
	valid.Instructions, valid.IgnoreGlobs, valid.MinConfidence = "Mind lock ordering.", []string{"gen/**", "*.pb.go"}, 4
	if err := Validate(reviewerKV(t, ReviewerSettingsKey, valid)); err != nil {
		t.Fatalf("valid setting refused: %v", err)
	}
	if !ReviewerNamespaceKind(ReviewerSettingsNamespace) || ReviewerNamespaceKind("navigation") {
		t.Fatal("namespace kind")
	}
	invalid := map[string]func(*ReviewerSettingsRecord){
		"no harness":       func(r *ReviewerSettingsRecord) { r.Harness = "" },
		"depth":            func(r *ReviewerSettingsRecord) { r.Depth = "deep" },
		"zero findings":    func(r *ReviewerSettingsRecord) { r.MaxFindings = 0 },
		"many findings":    func(r *ReviewerSettingsRecord) { r.MaxFindings = 21 },
		"confidence":       func(r *ReviewerSettingsRecord) { r.MinConfidence = 11 },
		"rounds":           func(r *ReviewerSettingsRecord) { r.MaxRounds = 11 },
		"long instruction": func(r *ReviewerSettingsRecord) { r.Instructions = strings.Repeat("x", ReviewerInstructionsBytes+1) },
		"NUL instruction":  func(r *ReviewerSettingsRecord) { r.Instructions = "a\x00b" },
		"absolute glob":    func(r *ReviewerSettingsRecord) { r.IgnoreGlobs = []string{"/etc/*"} },
		"bad glob":         func(r *ReviewerSettingsRecord) { r.IgnoreGlobs = []string{"[unclosed"} },
		"empty glob":       func(r *ReviewerSettingsRecord) { r.IgnoreGlobs = []string{" "} },
		"control harness":  func(r *ReviewerSettingsRecord) { r.Harness = "claude\ncode" },
		"too many globs": func(r *ReviewerSettingsRecord) {
			r.IgnoreGlobs = make([]string, ReviewerMaxGlobs+1)
			for i := range r.IgnoreGlobs {
				r.IgnoreGlobs[i] = "*.x"
			}
		},
	}
	for name, mutate := range invalid {
		record := DefaultReviewerSettings()
		mutate(&record)
		if err := Validate(reviewerKV(t, ReviewerSettingsKey, record)); err == nil {
			t.Errorf("%s: invalid setting accepted", name)
		}
	}
	if err := Validate(reviewerKV(t, "other", valid)); err == nil {
		t.Fatal("a reviewer setting under another key was accepted")
	}
	if err := Validate(reviewerKV(t, ReviewerSettingsKey, []byte(`{"harness":"mock","depth":"quick","maxFindings":6,"maxRounds":3,"surprise":true}`))); err == nil {
		t.Fatal("unknown fields were accepted")
	}
	if err := Validate(reviewerKV(t, ReviewerSettingsKey, []byte(`{"harness":"mock","depth":"quick","maxFindings":6,"maxRounds":3,"instructions":"`+strings.Repeat("y", ReviewerValueBytes)+`"}`))); err == nil {
		t.Fatal("an oversized record was accepted")
	}
	decoded, err := DecodeReviewerSettings(ReviewerSettingsKey, []byte(`{"harness":"codex","model":"gpt-5.5","depth":"thorough","maxFindings":10,"maxRounds":2}`))
	if err != nil || decoded.Harness != "codex" || decoded.Depth != "thorough" || decoded.MaxFindings != 10 {
		t.Fatalf("decoded=%#v err=%v", decoded, err)
	}
}
