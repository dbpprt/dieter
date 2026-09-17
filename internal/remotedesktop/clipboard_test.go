package remotedesktop

import (
	"bytes"
	"context"
	"fmt"
	"github.com/pion/webrtc/v4"
	"google.golang.org/protobuf/proto"
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
	backend := newNativeClipboard(ctx, SourceOptions{Kind: "native-synthetic", HelperPath: helper, ClipboardDirectory: t.TempDir()}, "com.dbpprt.dieter.fixture."+randomID())
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

func TestClipboardBinaryRoundTripAndValidation(t *testing.T) {
	s, backend := clipboardFixture(t)
	r := clipboardRequest(s, dieterv1.RemoteDesktopClipboardRequest_PASTE)
	r.AcceptBinary = true
	r.Items = []*dieterv1.RemoteDesktopClipboardItem{{Name: "payload.bin", MimeType: "application/octet-stream", Data: bytes.Repeat([]byte{0, 1, 255, 10}, ClipboardBinaryMaxBytes/4)}, {Name: "empty.txt", MimeType: "text/plain"}}
	if _, err := s.exchangeClipboard(s.ctx, r); err != nil {
		t.Fatal(err)
	}
	if _, err := s.exchangeClipboard(s.ctx, r); err != nil {
		t.Fatal(err)
	}
	if backend.Pastes != 1 {
		t.Fatal("paste replayed")
	}
	read := clipboardRequest(s, dieterv1.RemoteDesktopClipboardRequest_READ)
	read.AcceptBinary = true
	value, err := s.exchangeClipboard(s.ctx, read)
	if err != nil || len(value.Items) != 2 || !proto.Equal(value.Items[0], r.Items[0]) || value.HasText {
		t.Fatalf("binary round trip: %v", err)
	}
	read.AcceptBinary = false
	legacy, err := s.exchangeClipboard(s.ctx, read)
	if err != nil || len(legacy.Items) != 0 || legacy.HasText {
		t.Fatal("legacy viewer received binary content")
	}
	for _, name := range []string{"../escape", "/absolute", "..", "a\\b", "nul\x00name"} {
		bad := proto.Clone(r).(*dieterv1.RemoteDesktopClipboardRequest)
		bad.Items[0].Name = name
		if _, err := s.exchangeClipboard(s.ctx, bad); err == nil {
			t.Errorf("accepted name %q", name)
		}
	}
	duplicate := proto.Clone(r).(*dieterv1.RemoteDesktopClipboardRequest)
	duplicate.Items[1].Name = "PAYLOAD.BIN"
	if _, err := s.exchangeClipboard(s.ctx, duplicate); err == nil {
		t.Fatal("accepted filenames that collide on macOS")
	}
	r.Items[1].Data = []byte{1}
	if _, err := s.exchangeClipboard(s.ctx, r); err == nil {
		t.Fatal("accepted oversized clipboard")
	}
	r.Items = []*dieterv1.RemoteDesktopClipboardItem{{Name: "image.png", Kind: dieterv1.RemoteDesktopClipboardItem_IMAGE, MimeType: "application/x-executable"}}
	if _, err := s.exchangeClipboard(s.ctx, r); err == nil {
		t.Fatal("accepted unsupported image")
	}
}

func TestNativeClipboardBinaryFiles(t *testing.T) {
	helper := os.Getenv("DIETER_TEST_CAPTURE_HELPER")
	if helper == "" {
		t.Skip("native helper not configured")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	root := t.TempDir()
	backend := newNativeClipboard(ctx, SourceOptions{Kind: "native-synthetic", HelperPath: helper, ClipboardDirectory: root}, "com.dbpprt.dieter.fixture."+randomID())
	defer backend.Close()
	items := []*dieterv1.RemoteDesktopClipboardItem{{Name: "data.bin", MimeType: "application/octet-stream", Data: bytes.Repeat([]byte{0, 255, 12}, 700000)}, {Name: "empty.txt", MimeType: "text/plain"}}
	value, err := backend.Exchange(ctx, &dieterv1.RemoteDesktopClipboardRequest{Action: dieterv1.RemoteDesktopClipboardRequest_PASTE, Items: items, AcceptBinary: true})
	if err != nil || value.Error != "" {
		t.Fatalf("native write: %v %v", err, value)
	}
	value, err = backend.Exchange(ctx, &dieterv1.RemoteDesktopClipboardRequest{Action: dieterv1.RemoteDesktopClipboardRequest_READ, AcceptBinary: true})
	if err != nil || value.Error != "" || len(value.Items) != 2 || !bytes.Equal(value.Items[0].Data, items[0].Data) || len(value.Items[1].Data) != 0 {
		t.Fatalf("native file round trip: %v, %s", err, value.GetError())
	}
}

func TestClipboardChannelDisconnectBeforeFinalChunkDoesNotPaste(t *testing.T) {
	s, backend := clipboardFixture(t)
	client, err := webrtc.NewPeerConnection(webrtc.Configuration{})
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	host, err := webrtc.NewPeerConnection(webrtc.Configuration{})
	if err != nil {
		t.Fatal(err)
	}
	defer host.Close()
	host.OnDataChannel(s.installClipboardChannel)
	channel, err := client.CreateDataChannel(clipboardChannelLabel, nil)
	if err != nil {
		t.Fatal(err)
	}
	ready := make(chan struct{})
	channel.OnOpen(func() { close(ready) })
	replies := make(chan *dieterv1.RemoteDesktopClipboardResponse, 1)
	channel.OnMessage(func(m webrtc.DataChannelMessage) {
		var frame dieterv1.RemoteDesktopClipboardFrame
		if proto.Unmarshal(m.Data, &frame) != nil || !frame.End {
			return
		}
		var reply dieterv1.RemoteDesktopClipboardResponse
		if proto.Unmarshal(frame.Data, &reply) == nil {
			replies <- &reply
		}
	})
	offer, err := client.CreateOffer(nil)
	if err != nil {
		t.Fatal(err)
	}
	gathered := webrtc.GatheringCompletePromise(client)
	if err = client.SetLocalDescription(offer); err != nil {
		t.Fatal(err)
	}
	<-gathered
	if err = host.SetRemoteDescription(*client.LocalDescription()); err != nil {
		t.Fatal(err)
	}
	answer, err := host.CreateAnswer(nil)
	if err != nil {
		t.Fatal(err)
	}
	gathered = webrtc.GatheringCompletePromise(host)
	if err = host.SetLocalDescription(answer); err != nil {
		t.Fatal(err)
	}
	<-gathered
	if err = client.SetRemoteDescription(*host.LocalDescription()); err != nil {
		t.Fatal(err)
	}
	select {
	case <-ready:
	case <-time.After(5 * time.Second):
		t.Fatal("clipboard channel did not open")
	}
	send := func(r *dieterv1.RemoteDesktopClipboardRequest, complete bool) {
		t.Helper()
		raw, err := proto.Marshal(r)
		if err != nil {
			t.Fatal(err)
		}
		if !complete {
			raw = raw[:min(len(raw), 2*clipboardChunkBytes)]
		}
		for offset := 0; offset < len(raw); offset += clipboardChunkBytes {
			end := min(offset+clipboardChunkBytes, len(raw))
			frame, _ := proto.Marshal(&dieterv1.RemoteDesktopClipboardFrame{OperationId: r.OperationId, Data: raw[offset:end], End: complete && end == len(raw)})
			if err := channel.Send(frame); err != nil {
				t.Fatal(err)
			}
		}
	}
	baseline := clipboardRequest(s, dieterv1.RemoteDesktopClipboardRequest_WRITE)
	baseline.Text = "Preserve this clipboard"
	send(baseline, true)
	select {
	case reply := <-replies:
		if reply.Error != "" {
			t.Fatal(reply.Error)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("clipboard baseline did not cross WebRTC")
	}
	partial := clipboardRequest(s, dieterv1.RemoteDesktopClipboardRequest_PASTE)
	partial.OperationId = "partial"
	partial.AcceptBinary = true
	partial.Items = []*dieterv1.RemoteDesktopClipboardItem{{Name: "partial.bin", Data: bytes.Repeat([]byte{0xa5}, ClipboardBinaryMaxBytes)}}
	send(partial, false)
	if err := channel.Close(); err != nil {
		t.Fatal(err)
	}
	s.cancel()
	backend.mu.Lock()
	defer backend.mu.Unlock()
	if backend.Pastes != 0 || backend.text != baseline.Text {
		t.Fatal("partial transfer mutated the native clipboard or pasted")
	}
}
