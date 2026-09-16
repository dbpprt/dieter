package remotedesktop

import (
	"context"
	"errors"
	"testing"
)

func TestPermissionProbeBoundsConcurrencyAndCancelsHelper(t *testing.T) {
	started := make(chan struct{})
	m := New(Options{Source: SourceOptions{Kind: "synthetic"}, CaptureProbe: func(ctx context.Context, _ SourceOptions) error { close(started); <-ctx.Done(); return ctx.Err() }})
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { _, err := m.ProbePermissions(ctx, false); done <- err }()
	<-started
	if _, err := m.ProbePermissions(context.Background(), false); !errors.Is(err, ErrBusy) {
		t.Fatalf("concurrent probe: %v", err)
	}
	cancel()
	if err := <-done; !errors.Is(err, context.Canceled) {
		t.Fatalf("canceled helper: %v", err)
	}
}

func TestPermissionProbeChecksBothPermissionsWithoutPrompt(t *testing.T) {
	m := New(Options{Source: SourceOptions{Kind: "synthetic"}, CaptureProbe: func(context.Context, SourceOptions) error { return errors.New("capture denied") }, ControlProbe: func(_ context.Context, _ SourceOptions, request bool) error {
		if request {
			t.Error("passive check requested permission")
		}
		return nil
	}})
	value, err := m.ProbePermissions(context.Background(), false)
	if err != nil || value.CaptureVerified || !value.ControlVerified || value.CaptureError != "capture denied" || value.DaemonExecutable == "" {
		t.Fatalf("probe: %v %v", value, err)
	}
}
