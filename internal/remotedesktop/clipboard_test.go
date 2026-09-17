package remotedesktop

import (
	"context"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
)

func clipboardFixture(t *testing.T) (*Session, *MemoryClipboard) {
	t.Helper()
	backend := &MemoryClipboard{}
	m := New(Options{Source: SourceOptions{Kind: "synthetic"}, ClipboardFactory: func() ClipboardBackend { return backend }})
	ctx, cancel := context.WithCancel(context.Background())
	s := &Session{manager: m, id: "clipboard-test", ctx: ctx, cancel: cancel, control: true, protocol: 3, inputEpoch: []byte("1234567890123456"), status: &dieterv1.RemoteDesktopSessionState{ClipboardEnabled: true}}
	m.sessions[s.id] = s
	m.controller = s
	m.controlGeneration = 1
	t.Cleanup(func() {
		cancel()
		s.clipboard.mu.Lock()
		defer s.clipboard.mu.Unlock()
		if s.clipboard.backend != nil {
			s.clipboard.backend.Close()
		}
	})
	return s, backend
}
func clipboardRequest(s *Session, action dieterv1.RemoteDesktopClipboardRequest_Action) *dieterv1.RemoteDesktopClipboardRequest {
	return &dieterv1.RemoteDesktopClipboardRequest{SessionId: s.id, OperationId: randomID(), ControlGeneration: 1, InputEpoch: s.inputEpoch, Action: action}
}
func TestClipboardRoundTripAndExactlyOnceRecentPaste(t *testing.T) {
	s, backend := clipboardFixture(t)
	for _, text := range []string{"", "Unicode é 🦊 日本語\n\tkeep whitespace\n", strings.Repeat("x", ClipboardMaxBytes)} {
		r := clipboardRequest(s, dieterv1.RemoteDesktopClipboardRequest_PASTE)
		r.Text = text
		for range 2 {
			v, err := s.manager.ExchangeClipboard(s.ctx, r)
			if err != nil || v.Error != "" {
				t.Fatalf("paste: %v %v", v, err)
			}
		}
		v, err := s.exchangeClipboard(s.ctx, clipboardRequest(s, dieterv1.RemoteDesktopClipboardRequest_READ))
		if err != nil || v.Text != text || !v.HasText {
			t.Fatalf("read roundtrip: %v", err)
		}
		for _, action := range []dieterv1.RemoteDesktopClipboardRequest_Action{dieterv1.RemoteDesktopClipboardRequest_COPY, dieterv1.RemoteDesktopClipboardRequest_CUT} {
			selection, err := s.exchangeClipboard(s.ctx, clipboardRequest(s, action))
			if err != nil || selection.Text != text || !selection.HasText {
				t.Fatalf("selection roundtrip: %v", err)
			}
		}
		read := clipboardRequest(s, dieterv1.RemoteDesktopClipboardRequest_READ)
		read.KnownRevision = v.Revision
		v, err = s.exchangeClipboard(s.ctx, read)
		if err != nil || v.Changed || v.Text != "" {
			t.Fatal("unchanged poll returned content")
		}
		r.Text = "different"
		if _, err = s.exchangeClipboard(s.ctx, r); err == nil {
			t.Fatal("accepted reused operation ID")
		}
	}
	if backend.Pastes != 3 {
		t.Fatalf("pasted %d times", backend.Pastes)
	}
}
func TestClipboardControlAndBounds(t *testing.T) {
	s, _ := clipboardFixture(t)
	r := clipboardRequest(s, dieterv1.RemoteDesktopClipboardRequest_WRITE)
	r.Text = strings.Repeat("a", ClipboardMaxBytes+1)
	if _, err := s.exchangeClipboard(s.ctx, r); err == nil {
		t.Fatal("oversized accepted")
	}
	r.Text = "a"
	r.ControlGeneration = 0
	if _, err := s.exchangeClipboard(s.ctx, r); err == nil {
		t.Fatal("old grant accepted")
	}
	r.ControlGeneration = 1
	r.InputEpoch = []byte("wrong")
	if _, err := s.exchangeClipboard(s.ctx, r); err == nil {
		t.Fatal("wrong epoch accepted")
	}
	r.InputEpoch = s.inputEpoch
	s.receiverInputExpired = true
	if _, err := s.exchangeClipboard(s.ctx, r); err == nil {
		t.Fatal("expired input accepted")
	}
	s.receiverInputExpired = false
	s.manager.controller = nil
	if _, err := s.exchangeClipboard(s.ctx, r); err == nil {
		t.Fatal("view only accepted")
	}
	s.manager.controller = s
	toggle := clipboardRequest(s, dieterv1.RemoteDesktopClipboardRequest_CONFIGURE)
	if _, err := s.exchangeClipboard(s.ctx, toggle); err != nil {
		t.Fatal(err)
	}
	if _, err := s.exchangeClipboard(s.ctx, r); err == nil {
		t.Fatal("disabled sharing accepted")
	}
	toggle.Enabled = true
	if _, err := s.exchangeClipboard(s.ctx, toggle); err != nil {
		t.Fatal(err)
	}
	if _, err := s.exchangeClipboard(s.ctx, r); err != nil {
		t.Fatal(err)
	}
}

type delayedClipboard struct {
	entered chan struct{}
	release chan struct{}
}

func (d *delayedClipboard) Close() {}
func (d *delayedClipboard) Exchange(ctx context.Context, _ *dieterv1.RemoteDesktopClipboardRequest) (*dieterv1.RemoteDesktopClipboardResponse, error) {
	close(d.entered)
	select {
	case <-d.release:
		return &dieterv1.RemoteDesktopClipboardResponse{Text: "old controller content"}, nil
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}
func TestClipboardSlowReadDoesNotBlockHandoffOrLeakAfterIt(t *testing.T) {
	s, _ := clipboardFixture(t)
	backend := &delayedClipboard{make(chan struct{}), make(chan struct{})}
	s.manager.options.ClipboardFactory = func() ClipboardBackend { return backend }
	done := make(chan error, 1)
	go func() {
		_, err := s.exchangeClipboard(s.ctx, clipboardRequest(s, dieterv1.RemoteDesktopClipboardRequest_READ))
		done <- err
	}()
	<-backend.entered
	if !s.manager.controlMu.TryLock() {
		t.Fatal("slow clipboard read blocks control")
	}
	s.manager.controlGeneration++
	s.manager.controlMu.Unlock()
	close(backend.release)
	if err := <-done; err == nil {
		t.Fatal("old controller received clipboard after handoff")
	}
}
func TestNativeClipboardService(t *testing.T) {
	helper := os.Getenv("DIETER_TEST_CAPTURE_HELPER")
	if helper == "" {
		t.Skip("native helper not configured")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	backend := newNativeClipboard(ctx, SourceOptions{Kind: "native-synthetic", HelperPath: helper}, "com.dbpprt.dieter.fixture."+randomID())
	defer backend.Close()
	for i, text := range []string{"", "Native clipboard 🌍\n日本語\n", strings.Repeat("é", ClipboardMaxBytes/2)} {
		v, err := backend.Exchange(ctx, &dieterv1.RemoteDesktopClipboardRequest{Action: dieterv1.RemoteDesktopClipboardRequest_PASTE, Text: text})
		if err != nil || v.Error != "" {
			t.Fatalf("native write %d: %v %v", i, err, v)
		}
		v, err = backend.Exchange(ctx, &dieterv1.RemoteDesktopClipboardRequest{Action: dieterv1.RemoteDesktopClipboardRequest_READ})
		if err != nil || v.Error != "" || v.Text != text {
			t.Fatalf("native read %d: %v len=%d", i, err, len(v.GetText()))
		}
		t.Log(fmt.Sprintf("native clipboard roundtrip %d bytes", len(text)))
	}
}

func TestClipboardWaitsForSelectionInput(t *testing.T) {
	s, backend := clipboardFixture(t)
	r := clipboardRequest(s, dieterv1.RemoteDesktopClipboardRequest_PASTE)
	r.Text = "selected target"
	r.InputBarrier = 7
	done := make(chan error, 1)
	go func() { _, err := s.exchangeClipboard(s.ctx, r); done <- err }()
	select {
	case <-done:
		t.Fatal("paste overtook reliable input")
	case <-time.After(30 * time.Millisecond):
	}
	backend.mu.Lock()
	pastes := backend.Pastes
	backend.mu.Unlock()
	if pastes != 0 {
		t.Fatal("paste ran before selection")
	}
	s.completedStateSequence.Store(7)
	if err := <-done; err != nil {
		t.Fatal(err)
	}
}
