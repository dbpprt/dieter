package remotedesktop

import (
	"context"
	"errors"
	"fmt"
	"os"
	"testing"
	"time"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"google.golang.org/protobuf/proto"
)

func TestDisplayModeOwnershipRestorationAndStaleSelection(t *testing.T) {
	m, template, _ := testManagerAndRequest(t, "github:7")
	defer m.Shutdown(context.Background())
	ctx := context.Background()
	var sessions []*Session
	for i := 0; i < 2; i++ {
		request := proto.Clone(template).(*dieterv1.StartRemoteDesktopRequest)
		request.ClientNonce = fmt.Sprintf("display-viewer-%d", i)
		request.Control = true
		request.InputProtocolVersion = inputProtocolVersion
		peer := testViewer(t, request)
		defer peer.Close()
		sub, err := m.Start(request, true, true, "github:7")
		if err != nil {
			t.Fatal(err)
		}
		defer sub.Close()
		sessions = append(sessions, m.sessionFor(sub.SessionID))
	}
	owner, spectator := sessions[0], sessions[1]
	modes, err := m.ListDisplayModes(ctx, owner.id)
	if err != nil {
		t.Fatal(err)
	}
	request := &dieterv1.SetRemoteDesktopDisplayModeRequest{SessionId: spectator.id, DisplayId: modes.DisplayId, ModeId: "720", ExpectedCurrentModeId: modes.CurrentModeId}
	if _, err = m.SetDisplayMode(ctx, request); !errors.Is(err, ErrControlOwner) {
		t.Fatalf("spectator: %v", err)
	}
	request.SessionId = owner.id
	result, err := m.SetDisplayMode(ctx, request)
	if err != nil || !result.Temporary || result.OriginalModeId != "1080" {
		t.Fatalf("set: %v %v", result, err)
	}
	if _, err = m.SetDisplayMode(ctx, request); err == nil {
		t.Fatal("stale selection accepted")
	}
	if _, err = m.RestoreDisplayMode(ctx, spectator.id); !errors.Is(err, ErrControlOwner) {
		t.Fatalf("spectator restore: %v", err)
	}
	if _, err = m.SetControl(ctx, spectator.id, true); err != nil {
		t.Fatal(err)
	}
	result, err = m.ListDisplayModes(ctx, spectator.id)
	if err != nil || result.Temporary || result.CurrentModeId != "1080" {
		t.Fatalf("handoff restore: %v %v", result, err)
	}
	request.SessionId = spectator.id
	if _, err = m.SetDisplayMode(ctx, request); err != nil {
		t.Fatal(err)
	}
	if err = m.Close(owner.id, "spectator left"); err != nil {
		t.Fatal(err)
	}
	if m.displayOwner != spectator {
		t.Fatal("spectator closure removed display lease")
	}
	if err = m.Close(spectator.id, "controller left"); err != nil {
		t.Fatal(err)
	}
	if m.displayOwner != nil || m.displayBackend != nil {
		t.Fatal("last session retained display helper/lease")
	}
}

func TestDisplayFenceRejectsInputUntilNewNativeGeometry(t *testing.T) {
	source := &inputFrameSource{inputs: make(chan *dieterv1.RemoteDesktopInput, 8)}
	s := &Session{ctx: context.Background(), source: source, status: &dieterv1.RemoteDesktopSessionState{DisplayGeneration: 7}, displayModeFence: 7}
	input := &dieterv1.RemoteDesktopInput{DisplayGeneration: 7, Payload: &dieterv1.RemoteDesktopInput_Text{Text: &dieterv1.RemoteDesktopText{Text: "a"}}}
	s.deliverInput(source, input)
	if len(source.inputs) != 0 {
		t.Fatal("input crossed a physical mode change")
	}
	s.status.DisplayGeneration = 8
	s.deliverInput(source, input)
	if len(source.inputs) != 0 {
		t.Fatal("stale generation accepted")
	}
	input.DisplayGeneration = 8
	s.deliverInput(source, input)
	if len(source.inputs) != 1 {
		t.Fatal("new geometry did not resume input")
	}
}

func TestNativeDisplayServiceDryRun(t *testing.T) {
	path := os.Getenv("DIETER_TEST_CAPTURE_HELPER")
	if path == "" {
		t.Skip("native helper fixture not configured")
	}
	n := newNativeDisplay(SourceOptions{Kind: "native-synthetic", HelperPath: path})
	defer n.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	modes, err := n.Exchange(ctx, "list", "synthetic", "", "")
	if err != nil || modes.CurrentModeId != "1080" {
		t.Fatalf("native list: %v %v", modes, err)
	}
	modes, err = n.Exchange(ctx, "set", "synthetic", "720", "1080")
	if err != nil || !modes.Temporary || modes.OriginalModeId != "1080" {
		t.Fatalf("native set: %v %v", modes, err)
	}
	if _, err = n.Exchange(ctx, "set", "synthetic", "1080", "1080"); err == nil {
		t.Fatal("native stale mode accepted")
	}
	// Longer than the helper's watchdog: periodic daemon heartbeats retain the lease.
	time.Sleep(4 * time.Second)
	modes, err = n.Exchange(ctx, "restore", "synthetic", "", "")
	if err != nil || modes.Temporary || modes.CurrentModeId != "1080" {
		t.Fatalf("native restore: %v %v", modes, err)
	}
	done := n.done
	n.Close()
	select {
	case <-done:
	default:
		t.Fatal("display helper outlived close")
	}
}
