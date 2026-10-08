package remotedesktop

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
)

func TestPrivacyNativeProtocolBoundsAndRejection(t *testing.T) {
	for _, raw := range []string{`{"state":3}`, `{"state":1}`, `{"state":2}`, `{"display_count":33}`, `{"input_device_count":129}`, `invalid`} {
		if _, err := decodePrivacy([]byte(raw)); err == nil {
			t.Fatalf("accepted %s", raw)
		}
	}
	_, err := decodePrivacy([]byte(`{"error":"permission denied"}`))
	var rejected *privacyOperationError
	if !errors.As(err, &rejected) {
		t.Fatalf("error=%v", err)
	}
	output := &boundedPrivacyOutput{}
	if _, err := output.Write(make([]byte, 8193)); err == nil {
		t.Fatal("unbounded output")
	}
}
func TestNativePrivacyOwnerSurvivesReplacementController(t *testing.T) {
	helper := os.Getenv("DIETER_TEST_CAPTURE_HELPER")
	if helper == "" {
		t.Skip("native helper supplied by screens_native_test")
	}
	root, err := os.MkdirTemp("../../tmp", "privacy-")
	if err != nil {
		t.Fatal(err)
	}
	root, err = filepath.Abs(root)
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(root)
	ctx, cancel := context.WithTimeout(t.Context(), 15*time.Second)
	defer cancel()
	first := NewNativePrivacy(root, helper, true)
	defer func() {
		cleanup, cancel := context.WithTimeout(context.Background(), 6*time.Second)
		defer cancel()
		_, err := first.Set(cleanup, false)
		if err != nil {
			t.Errorf("privacy cleanup: %v", err)
		}
	}()
	on, err := first.Set(ctx, true)
	if err != nil || on.GetState() != dieterv1.MachinePrivacy_STATE_ON {
		t.Fatalf("on=%v error=%v", on, err)
	}
	info, err := os.Stat(filepath.Join(root, "runtime", "privacy", "control.sock"))
	if err != nil || info.Mode().Perm() != 0600 {
		t.Fatalf("socket=%v error=%v", info, err)
	}
	replacement := NewNativePrivacy(root, helper, true)
	value, err := replacement.Snapshot(ctx)
	if err != nil || !value.GetRequested() {
		t.Fatalf("adoption=%v error=%v", value, err)
	}
	off, err := replacement.Set(ctx, false)
	if err != nil || off.GetRequested() || off.GetState() != dieterv1.MachinePrivacy_STATE_OFF {
		t.Fatalf("off=%v error=%v", off, err)
	}
	// Confirm the owner exits rather than retaining an off process/socket.
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if _, err := os.Stat(filepath.Join(root, "runtime", "privacy", "control.sock")); os.IsNotExist(err) {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("unlocked helper did not exit")
}
