package store

import (
	"errors"
	"fmt"
	"testing"

	"github.com/dbpprt/dieter/internal/model"
)

func TestRuntimeAdmissionOnlySerializesSameConversation(t *testing.T) {
	data := New(t.TempDir())
	for i := 0; i < 12; i++ {
		lease, err := data.AcquireRuntimeLeaseFor("p_one", "b_one", fmt.Sprintf("c_%d", i), "codex")
		if err != nil {
			t.Fatal(err)
		}
		defer data.ReleaseRuntimeLease(lease)
		if _, err := data.AcquireRuntimeLeaseFor("p_one", "b_one", lease.CardID, "codex"); !errors.Is(err, ErrCardActive) {
			t.Fatalf("duplicate start: %v", err)
		}
	}
}

func TestRemoteDesktopSettingsUseDedicatedUpdatePath(t *testing.T) {
	data := New(t.TempDir())
	remote, err := data.UpdateRemoteDesktopSettings(true, true)
	if err != nil || !remote.RemoteDesktopEnabled || !remote.RemoteDesktopControlEnabled {
		t.Fatalf("remote settings=%#v err=%v", remote, err)
	}

	// The general settings RPC cannot erase settings it did not know about.
	updated, err := data.UpdateSettings(model.Settings{})
	if err != nil {
		t.Fatal(err)
	}
	if !updated.RemoteDesktopEnabled || !updated.RemoteDesktopControlEnabled {
		t.Fatalf("general settings write erased remote desktop: %#v", updated)
	}

	disabled, err := data.UpdateRemoteDesktopSettings(false, true)
	if err != nil {
		t.Fatal(err)
	}
	if disabled.RemoteDesktopEnabled || disabled.RemoteDesktopControlEnabled {
		t.Fatalf("disabled remote desktop retained control: %#v", disabled)
	}
}
