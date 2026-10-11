package store

import (
	"errors"
	"fmt"
	"testing"
)

func TestRuntimeAdmissionOnlySerializesSameConversation(t *testing.T) {
	t.Parallel()
	data := New(t.TempDir())
	for i := 0; i < 12; i++ {
		lease, err := data.AcquireRuntimeLeaseFor("p_one", "b_one", fmt.Sprintf("c_%d", i), "codex")
		if err != nil {
			t.Fatal(err)
		}
		defer func() { _ = data.ReleaseRuntimeLease(lease) }()
		if _, err := data.AcquireRuntimeLeaseFor("p_one", "b_one", lease.CardID, "codex"); !errors.Is(err, ErrCardActive) {
			t.Fatalf("duplicate start: %v", err)
		}
	}
}
