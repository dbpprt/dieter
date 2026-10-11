package daemonstate

import (
	"testing"

	"github.com/dbpprt/dieter/internal/store"
)

func TestMachinePrivacyBootRequestRoundTrip(t *testing.T) {
	t.Parallel()
	data := New(store.New(t.TempDir()))
	if value, err := data.MachinePrivacyRequest(); err != nil || value.Enabled {
		t.Fatalf("missing=%v %v", value, err)
	}
	if err := data.SetMachinePrivacyRequest(MachinePrivacyRequest{Enabled: true}); err == nil {
		t.Fatal("empty boot accepted")
	}
	for _, enabled := range []bool{true, false} {
		want := MachinePrivacyRequest{BootID: "boot-test", Enabled: enabled}
		if err := data.SetMachinePrivacyRequest(want); err != nil {
			t.Fatal(err)
		}
		value, err := New(store.New(data.store.Root)).MachinePrivacyRequest()
		if err != nil || value != want {
			t.Fatalf("got %v err %v", value, err)
		}
	}
}
