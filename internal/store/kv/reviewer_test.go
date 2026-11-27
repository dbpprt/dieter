package kv_test

import (
	"errors"
	"testing"

	"github.com/dbpprt/dieter/internal/platform/fault"
	"github.com/dbpprt/dieter/internal/replication/schema"
	"github.com/dbpprt/dieter/internal/store"
	"github.com/dbpprt/dieter/internal/store/kv"
)

func TestReviewerSettingsDefaultsAndCompareAndSet(t *testing.T) {
	t.Parallel()
	s, _ := providerStore(t, "d_mini_1")
	entry, err := s.KV.ReviewerSettings()
	if err != nil || entry.Configured || entry.Record.Harness != schema.ReviewerDefaultHarness || entry.Record.Depth != "quick" || entry.Record.MaxFindings != 6 || entry.Record.MaxRounds != 3 {
		t.Fatalf("defaults=%#v err=%v", entry, err)
	}
	record := schema.DefaultReviewerSettings()
	record.Harness, record.Model, record.Depth, record.IgnoreGlobs = "codex", "gpt-5.5", "thorough", []string{"gen/**"}
	saved, err := s.KV.PutReviewerSettings(record, entry.Revision)
	if err != nil || !saved.Configured || saved.Record.Harness != "codex" || saved.Record.UpdatedAt == "" || saved.Revision == "" || saved.Revision == entry.Revision {
		t.Fatalf("saved=%#v err=%v", saved, err)
	}
	reread, err := store.New(s.Root).KV.ReviewerSettings()
	if err != nil || reread.Record.Model != "gpt-5.5" || reread.Revision != saved.Revision || len(reread.Record.IgnoreGlobs) != 1 {
		t.Fatalf("reread=%#v err=%v", reread, err)
	}
	record.MinConfidence = 3
	current, err := s.KV.PutReviewerSettings(record, saved.Revision)
	if err != nil || current.Record.MinConfidence != 3 {
		t.Fatalf("compare-and-set on the current revision=%#v err=%v", current, err)
	}
	record.Depth = "quick"
	if _, err := s.KV.PutReviewerSettings(record, saved.Revision); !errors.Is(err, kv.ErrReviewerSettingsChanged) {
		t.Fatalf("a stale revision wrote: %v", err)
	}
	if kind, _ := fault.KindOf(kv.ErrReviewerSettingsChanged); kind != fault.Conflict {
		t.Fatalf("conflict kind = %v", kind)
	}
	overwritten, err := s.KV.PutReviewerSettings(record, "")
	if err != nil || overwritten.Record.Depth != "quick" {
		t.Fatalf("overwrite=%#v err=%v", overwritten, err)
	}
	record.MaxFindings = 99
	if _, err := s.KV.PutReviewerSettings(record, ""); err == nil {
		t.Fatal("an invalid setting was saved")
	}
}

func TestReviewerSettingsNeedAReplicaIdentity(t *testing.T) {
	t.Parallel()
	s := store.New(t.TempDir())
	if entry, err := s.KV.ReviewerSettings(); err != nil || entry.Configured {
		t.Fatalf("defaults without identity=%#v err=%v", entry, err)
	}
	if _, err := s.KV.PutReviewerSettings(schema.DefaultReviewerSettings(), ""); err == nil {
		t.Fatal("a machine without a replica identity saved the reviewer setting")
	}
}
