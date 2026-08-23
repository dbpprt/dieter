package store

import (
	"errors"
	"testing"

	"github.com/dbpprt/dieter/internal/model"
)

func TestRuntimeAdmissionEnforcesGlobalAgentAndBoardLimits(t *testing.T) {
	data := New(t.TempDir())
	settings, err := data.UpdateSettings(model.Settings{GlobalParallelLimit: 3, AgentParallelLimits: map[string]int{"codex": 1}, BoardParallelLimits: map[string]int{"b_one": 1}})
	if err != nil || settings.GlobalParallelLimit != 3 {
		t.Fatalf("settings=%#v err=%v", settings, err)
	}
	first, err := data.AcquireRuntimeLeaseFor("p_one", "b_one", "c_one", "codex")
	if err != nil {
		t.Fatal(err)
	}
	defer data.ReleaseRuntimeLease(first)
	if _, err := data.AcquireRuntimeLeaseFor("p_two", "b_two", "c_two", "codex"); !errors.Is(err, ErrCapacity) {
		t.Fatalf("expected agent capacity error, got %v", err)
	}
	if _, err := data.AcquireRuntimeLeaseFor("p_two", "b_one", "c_two", "omp"); !errors.Is(err, ErrCapacity) {
		t.Fatalf("expected board capacity error, got %v", err)
	}
	second, err := data.AcquireRuntimeLeaseFor("p_two", "b_two", "c_two", "omp")
	if err != nil {
		t.Fatal(err)
	}
	defer data.ReleaseRuntimeLease(second)
	third, err := data.AcquireRuntimeLeaseFor("p_three", "b_three", "c_three", "pi")
	if err != nil {
		t.Fatal(err)
	}
	defer data.ReleaseRuntimeLease(third)
	if _, err := data.AcquireRuntimeLeaseFor("p_four", "b_four", "c_four", "claude-code"); !errors.Is(err, ErrCapacity) {
		t.Fatalf("expected global capacity error, got %v", err)
	}
}

func TestSettingsRoundTripUsesIndependentEmptyMaps(t *testing.T) {
	data := New(t.TempDir())
	first, err := data.Settings()
	if err != nil {
		t.Fatal(err)
	}
	first.AgentParallelLimits["codex"] = 2
	second, err := data.Settings()
	if err != nil {
		t.Fatal(err)
	}
	if len(second.AgentParallelLimits) != 0 || len(second.BoardParallelLimits) != 0 {
		t.Fatalf("default settings leaked mutation: %#v", second)
	}
}
