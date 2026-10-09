package remotedesktop

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"google.golang.org/protobuf/proto"
)

type failingVirtualDisplay struct {
	MemoryVirtualDisplay
	failed atomic.Bool
}

func (f *failingVirtualDisplay) Exchange(ctx context.Context, action string, r *dieterv1.SetRemoteDesktopVirtualDisplayRequest) (*dieterv1.RemoteDesktopVirtualDisplay, error) {
	if action == "status" && f.failed.Load() {
		return nil, errors.New("fixture helper unavailable")
	}
	return f.MemoryVirtualDisplay.Exchange(ctx, action, r)
}

func TestVirtualDisplayRestoresAfterHelperFailureOrViewerSilence(t *testing.T) {
	for _, helperFailure := range []bool{true, false} {
		m, owner, _ := virtualFixture(t)
		backend := &failingVirtualDisplay{}
		m.options.VirtualDisplayFactory = func() VirtualDisplayBackend { return backend }
		if _, err := m.SetVirtualDisplay(context.Background(), virtualRequest(owner.id)); err != nil {
			t.Fatal(err)
		}
		if helperFailure {
			backend.failed.Store(true)
		} else {
			m.controlMu.Lock()
			m.virtualPresented = true
			owner.mu.Lock()
			owner.lastFeedback = time.Now().Add(-4 * time.Second)
			owner.mu.Unlock()
			m.controlMu.Unlock()
		}
		restored := false
		for deadline := time.Now().Add(4 * time.Second); time.Now().Before(deadline); {
			m.controlMu.Lock()
			restored = m.virtualOwner == nil
			m.controlMu.Unlock()
			if restored {
				break
			}
			time.Sleep(10 * time.Millisecond)
		}
		if !restored {
			t.Fatalf("virtual lease survived helper failure=%v", helperFailure)
		}
		owner.mu.Lock()
		if owner.status.Configuration.DisplayId == "virtual-synthetic" {
			t.Error("capture still targets removed display")
		}
		owner.mu.Unlock()
	}
}

func virtualFixture(t *testing.T) (*Manager, *Session, *Session) {
	t.Helper()
	m, r, _ := testManagerAndRequest(t, "github:7")
	t.Cleanup(func() { m.Shutdown(context.Background()) })
	var sessions []*Session
	for _, name := range []string{"owner", "spectator"} {
		request := proto.Clone(r).(*dieterv1.StartRemoteDesktopRequest)
		request.Control = true
		request.InputProtocolVersion = inputProtocolVersion
		request.ClientNonce = "virtual-" + name
		peer := testViewer(t, request)
		t.Cleanup(func() { _ = peer.Close() })
		sub, err := m.Start(request, "github:7")
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(sub.Close)
		sessions = append(sessions, m.sessionFor(sub.SessionID))
	}
	return m, sessions[0], sessions[1]
}
func virtualRequest(id string) *dieterv1.SetRemoteDesktopVirtualDisplayRequest {
	return &dieterv1.SetRemoteDesktopVirtualDisplayRequest{SessionId: id, PixelWidth: 1280, PixelHeight: 720, Scale: 2, DisablePhysical: true}
}
func TestVirtualDisplayOwnershipPresentationAndRestore(t *testing.T) {
	m, owner, spectator := virtualFixture(t)
	ctx := context.Background()
	if _, err := m.SetVirtualDisplay(ctx, virtualRequest(spectator.id)); !errors.Is(err, ErrControlOwner) {
		t.Fatalf("spectator: %v", err)
	}
	state, err := m.SetVirtualDisplay(ctx, virtualRequest(owner.id))
	if err != nil {
		t.Fatal(err)
	}
	if !state.Active || !state.AwaitingPresentation || state.PhysicalDisabled {
		t.Fatalf("disabled without presentation: %v", state)
	}
	same, err := m.SetVirtualDisplay(ctx, virtualRequest(owner.id))
	if err != nil || !proto.Equal(state, same) {
		t.Fatalf("idempotent set: %v %v", same, err)
	}
	ack := &dieterv1.ConfirmRemoteDesktopVirtualDisplayRequest{SessionId: owner.id, DisplayId: state.DisplayId, DisplayGeneration: 7}
	owner.mu.Lock()
	owner.status.DisplayId = state.DisplayId
	owner.status.DisplayGeneration = 7
	owner.status.MediaGeneration = 6
	owner.mu.Unlock()
	if _, err = m.ConfirmVirtualDisplay(ctx, ack); err == nil {
		t.Fatal("accepted old media generation")
	}
	owner.mu.Lock()
	owner.status.MediaGeneration = 7
	owner.mu.Unlock()
	ack.DisplayId = "old-display"
	if _, err = m.ConfirmVirtualDisplay(ctx, ack); err == nil {
		t.Fatal("accepted wrong display")
	}
	ack.DisplayId = state.DisplayId
	ack.SessionId = spectator.id
	if _, err = m.ConfirmVirtualDisplay(ctx, ack); !errors.Is(err, ErrControlOwner) {
		t.Fatalf("spectator ack: %v", err)
	}
	ack.SessionId = owner.id
	state, err = m.ConfirmVirtualDisplay(ctx, ack)
	if err != nil || !state.PhysicalDisabled || state.AwaitingPresentation {
		t.Fatalf("confirm: %v %v", state, err)
	}
	if _, err = m.RestoreVirtualDisplay(ctx, spectator.id); !errors.Is(err, ErrControlOwner) {
		t.Fatalf("spectator restore: %v", err)
	}
	if _, err = m.SetControl(ctx, spectator.id, true); err != nil {
		t.Fatal(err)
	}
	state, err = m.GetVirtualDisplay(ctx, owner.id)
	if err != nil || state.Active {
		t.Fatalf("handoff restore: %v %v", state, err)
	}
	if m.virtualOwner != nil || m.virtualBackend != nil {
		t.Fatal("handoff leaked helper")
	}
	if _, err = m.SetVirtualDisplay(ctx, virtualRequest(spectator.id)); err != nil {
		t.Fatal(err)
	}
	if err = m.Close(spectator.id, "controller disconnected"); err != nil {
		t.Fatal(err)
	}
	if m.virtualOwner != nil || m.virtualBackend != nil {
		t.Fatal("disconnect leaked helper")
	}
}
func TestVirtualDisplayInvalidGeometryAndRollback(t *testing.T) {
	m, owner, _ := virtualFixture(t)
	ctx := context.Background()
	for _, size := range [][3]int32{{319, 720, 1}, {1280, 2170, 1}, {1281, 720, 1}, {1282, 720, 2}, {1280, 720, 3}} {
		r := virtualRequest(owner.id)
		r.PixelWidth, r.PixelHeight, r.Scale = size[0], size[1], size[2]
		if _, err := m.SetVirtualDisplay(ctx, r); err == nil {
			t.Fatalf("invalid size %v", size)
		}
	}
	if m.virtualBackend != nil {
		t.Fatal("invalid request started helper")
	}
	if _, err := m.SetVirtualDisplay(ctx, virtualRequest(owner.id)); err != nil {
		t.Fatal(err)
	}
	configuration := &dieterv1.RemoteDesktopStreamConfiguration{DisplayId: "primary", MaxWidth: 1920, MaxHeight: 1080, MaxFps: 60, MaxBitrateKbps: 12000}
	if _, err := m.UpdateSession(ctx, &dieterv1.UpdateRemoteDesktopSessionRequest{SessionId: owner.id, Configuration: configuration}); err != nil {
		t.Fatal(err)
	}
	if m.virtualOwner != nil {
		t.Fatal("display selection retained virtual lease")
	}
}
func TestNativeVirtualDisplayServiceDryRun(t *testing.T) {
	helper := os.Getenv("DIETER_TEST_CAPTURE_HELPER")
	if helper == "" {
		t.Skip("native helper fixture not configured")
	}
	n := newNativeVirtualDisplay(SourceOptions{Kind: "native-synthetic", HelperPath: helper, StateRoot: t.TempDir()})
	defer n.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	state, err := n.Exchange(ctx, "create", virtualRequest("fixture"))
	if err != nil || !state.Active || state.PhysicalDisabled {
		t.Fatalf("create: %v %v", state, err)
	}
	time.Sleep(4 * time.Second) // Native heartbeat watchdog must retain a healthy owner.
	// A slow mutation may hold the pipe across heartbeat ticks. Waiting for the
	// mutex must not spend a heartbeat's deadline and then kill a healthy helper.
	n.pipe.mu.Lock()
	time.Sleep(2200 * time.Millisecond)
	n.pipe.mu.Unlock()
	state, err = n.Exchange(ctx, "confirm", nil)
	if err != nil || !state.PhysicalDisabled {
		t.Fatalf("confirm: %v %v", state, err)
	}
	state, err = n.Exchange(ctx, "restore", nil)
	if err != nil || state.Active {
		t.Fatalf("restore: %v %v", state, err)
	}
	done := n.pipe.done
	n.Close()
	select {
	case <-done:
	default:
		t.Fatal("native display process leaked")
	}
}

// Hardware qualification uses an isolated state root and owns only its helper.
// The pipeline holds the desktop lease and refuses an existing operator app.
func TestNativeVirtualDisplayHardware(t *testing.T) {
	if os.Getenv("DIETER_TEST_VIRTUAL_HARDWARE") != "1" {
		t.Skip("explicit desktop hardware qualification required")
	}
	helper := os.Getenv("DIETER_TEST_CAPTURE_HELPER")
	if helper == "" {
		t.Fatal("capture helper required")
	}
	root := os.Getenv("DIETER_TEST_VIRTUAL_STATE_ROOT")
	if root == "" {
		t.Fatal("retained virtual display state root required")
	}
	if err := os.MkdirAll(root, 0700); err != nil {
		t.Fatal(err)
	}
	options := SourceOptions{HelperPath: helper, StateRoot: root}
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	before, err := ProbeCapabilities(ctx, options)
	if err != nil {
		t.Fatal(err)
	}
	original := ""
	for _, d := range before.Displays {
		if d.Primary {
			original = d.Id
		}
	}
	if original == "" {
		t.Fatal("no original display")
	}
	for _, crash := range []bool{false, true} {
		n := newNativeVirtualDisplay(options)
		r := virtualRequest("hardware")
		r.Scale = 1
		if crash {
			r.Scale = 2
			r.PixelWidth, r.PixelHeight = 2560, 1440
		}
		t.Logf("native desktop %dx%d scale=%d crash=%v", r.PixelWidth, r.PixelHeight, r.Scale, crash)
		r.DisablePhysical = os.Getenv("DIETER_TEST_VIRTUAL_DISABLE") == "1"
		state, err := n.Exchange(ctx, "create", r)
		if err != nil {
			n.Close()
			t.Fatal(err)
		}
		if state.OriginalDisplayId != original {
			n.Close()
			t.Fatalf("original display mismatch: %v", state)
		}
		current, err := ProbeCapabilities(ctx, options)
		if err != nil {
			n.Close()
			t.Fatal(err)
		}
		matched := false
		for _, d := range current.Displays {
			if d.Id == state.DisplayId && d.Primary && d.PhysicalWidth == r.PixelWidth && d.PhysicalHeight == r.PixelHeight && d.Scale == float64(r.Scale) {
				matched = true
			}
		}
		if !matched {
			n.Close()
			t.Fatalf("native virtual geometry absent: %v", current.Displays)
		}
		if _, err := n.Exchange(ctx, "status", nil); err != nil {
			n.Close()
			t.Fatalf("virtual display audit: %v; displays: %v", err, current.Displays)
		}
		capture := options
		capture.Kind, capture.Display = "screen", state.DisplayId
		capture.Codec, capture.MaxWidth, capture.MaxHeight, capture.FPS, capture.Bitrate = VideoCodecH264, int(r.PixelWidth), int(r.PixelHeight), 30, 4000
		if err := ProbeCapture(ctx, capture); err != nil {
			n.Close()
			t.Fatalf("virtual display capture: %v", err)
		}
		if r.DisablePhysical {
			if _, err = n.Exchange(ctx, "confirm", nil); err != nil {
				n.Close()
				t.Fatal(err)
			}
			// Disabled outputs may lose their public UUID. They must remain
			// leased across heartbeat audits until explicit restore or failure.
			time.Sleep(4 * time.Second)
			confirmed, confirmErr := n.Exchange(ctx, "status", nil)
			if confirmErr != nil || !confirmed.GetActive() || !confirmed.GetPhysicalDisabled() {
				n.Close()
				t.Fatalf("disabled display heartbeat: %v %v", confirmed, confirmErr)
			}
		}
		if crash {
			n.pipe.cancel()
			<-n.pipe.done
		} else {
			if _, err = n.Exchange(ctx, "restore", nil); err != nil {
				n.Close()
				t.Fatal(err)
			}
		}
		n.Close()
		restored := false
		for deadline := time.Now().Add(8 * time.Second); time.Now().Before(deadline); {
			after, probeErr := ProbeCapabilities(ctx, options)
			if probeErr == nil {
				for _, d := range after.Displays {
					if d.Id == original && d.Primary {
						restored = true
					}
				}
			}
			_, journalErr := os.Stat(filepath.Join(root, "virtual-display", "recovery.json"))
			if restored && errors.Is(journalErr, os.ErrNotExist) {
				break
			}
			restored = false
			time.Sleep(100 * time.Millisecond)
		}
		if !restored {
			t.Fatal("physical main/journal failed to restore after helper exit")
		}
	}
}
