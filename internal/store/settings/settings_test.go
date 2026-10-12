package settings_test

import (
	"errors"
	"fmt"
	"testing"

	"github.com/dbpprt/dieter/internal/store"
	"github.com/dbpprt/dieter/internal/store/leases"
)

func TestRuntimeAdmissionOnlySerializesSameConversation(t *testing.T) {
	t.Parallel()
	data := store.New(t.TempDir())
	for i := 0; i < 12; i++ {
		lease, err := data.Kanban.AcquireRuntimeLeaseFor("p_one", "b_one", fmt.Sprintf("c_%d", i), "codex")
		if err != nil {
			t.Fatal(err)
		}
		defer func() { _ = data.Leases.Release(lease) }()
		if _, err := data.Kanban.AcquireRuntimeLeaseFor("p_one", "b_one", lease.CardID, "codex"); !errors.Is(err, leases.ErrCardActive) {
			t.Fatalf("duplicate start: %v", err)
		}
	}
}
