package remotedesktop

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/pion/webrtc/v4/pkg/media"
	"google.golang.org/protobuf/proto"
)

func TestMultipleClientsAdmissionReconnectAndControl(t *testing.T) {
	manager, template, _ := testManagerAndRequest(t, "github:7")
	defer manager.Shutdown(context.Background())
	source := &inputFrameSource{blockingFrameSource: blockingFrameSource{started: make(chan struct{}), stopped: make(chan struct{})}, inputs: make(chan *dieterv1.RemoteDesktopInput, 16), released: make(chan struct{}, 16)}
	manager.options.SourceFactory = func(SourceOptions) (FrameSource, error) { return source, nil }
	manager.options.CaptureProbe = func(context.Context, SourceOptions) error { return nil }
	manager.options.ControlProbe = func(context.Context, SourceOptions, bool) error { return nil }
	var sessions []*Session
	var subscriptions []*Subscription
	for i := 0; i < 5; i++ {
		req := proto.Clone(template).(*dieterv1.StartRemoteDesktopRequest)
		req.ClientNonce = fmt.Sprintf("viewer-%d", i)
		req.ClientName = fmt.Sprintf("Client %d", i)
		req.InputProtocolVersion = inputProtocolVersion
		req.Control = true
		req.Clipboard = true
		peer := testViewer(t, req)
		defer peer.Close()
		sub, err := manager.Start(req, "github:7")
		if i == 4 {
			if !errors.Is(err, ErrCapacity) {
				t.Fatalf("fifth admission = %v", err)
			}
			break
		}
		if err != nil {
			t.Fatal(err)
		}
		subscriptions = append(subscriptions, sub)
		session := manager.sessionFor(sub.SessionID)
		sessions = append(sessions, session)
		if i == 0 {
			replacement, err := manager.Start(req, "github:7")
			if err != nil || replacement.SessionID != sub.SessionID {
				t.Fatalf("reattach = %v", err)
			}
			defer replacement.Close()
		}
	}
	counts := manager.Sessions()
	if len(counts.Sessions) != 4 || counts.Encoders != 1 {
		t.Fatalf("resources: %v", counts)
	}
	first, second := sessions[0], sessions[1]
	initial := &dieterv1.RemoteDesktopClipboardRequest{SessionId: first.id, OperationId: randomID(), ControlGeneration: manager.controlGeneration, Action: dieterv1.RemoteDesktopClipboardRequest_WRITE, Text: "Only the controlling viewer"}
	if _, err := manager.ExchangeClipboard(context.Background(), initial); err != nil {
		t.Fatal(err)
	}
	for i, session := range sessions {
		_, err := manager.ExchangeClipboard(context.Background(), &dieterv1.RemoteDesktopClipboardRequest{SessionId: session.id, OperationId: randomID(), ControlGeneration: manager.controlGeneration})
		if (err == nil) != (i == 0) {
			t.Fatalf("clipboard access for viewer %d: %v", i, err)
		}
	}
	oldGrant := manager.controlGeneration
	packet := func(grant uint64) *dieterv1.RemoteDesktopInput {
		return &dieterv1.RemoteDesktopInput{ControlGeneration: grant, Payload: &dieterv1.RemoteDesktopInput_Text{Text: &dieterv1.RemoteDesktopText{Text: "test"}}}
	}
	first.deliverInput(first.source.(InputSink), packet(oldGrant))
	if len(source.inputs) != 1 {
		t.Fatal("initial owner could not inject")
	}
	state, err := manager.SetControl(context.Background(), second.id, true)
	if err != nil || !state.ControlActive || state.ControlGeneration <= oldGrant {
		t.Fatalf("handoff = %v %v", state, err)
	}
	if len(source.released) != 1 {
		t.Fatal("handoff did not release held input")
	}
	initial.OperationId = randomID()
	if _, err := manager.ExchangeClipboard(context.Background(), initial); err == nil {
		t.Fatal("retired controller wrote clipboard")
	}
	copied, err := manager.ExchangeClipboard(context.Background(), &dieterv1.RemoteDesktopClipboardRequest{SessionId: second.id, OperationId: randomID(), ControlGeneration: state.ControlGeneration})
	if err != nil || copied.Text != "Only the controlling viewer" {
		t.Fatalf("clipboard handoff: %v %v", copied, err)
	}
	first.deliverInput(first.source.(InputSink), packet(oldGrant))
	second.deliverInput(second.source.(InputSink), packet(oldGrant))
	if len(source.inputs) != 1 {
		t.Fatal("stale ownership injected input")
	}
	second.deliverInput(second.source.(InputSink), packet(state.ControlGeneration))
	if len(source.inputs) != 2 {
		t.Fatal("new owner cannot inject")
	}
	manager.Close(sessions[2].id, "spectator left")
	if len(source.released) != 1 {
		t.Fatal("spectator disconnect released the controller's keys")
	}
	if len(manager.Sessions().Sessions) != 3 || !manager.sessionFor(second.id).active() {
		t.Fatal("spectator closed another session")
	}
	released, err := manager.SetControl(context.Background(), second.id, false)
	if err != nil || released.ControlActive {
		t.Fatalf("release = %v %v", released, err)
	}
	if manager.controller != nil {
		t.Fatal("control transferred implicitly")
	}
	for _, sub := range subscriptions {
		sub.Close()
	}
}

type pooledTestSource struct {
	frames    chan media.Sample
	mu        sync.Mutex
	callback  func(SourceEvent)
	config    StreamConfiguration
	keyframes atomic.Int32
}

func (*pooledTestSource) Codec() VideoCodec   { return VideoCodecH264 }
func (*pooledTestSource) Description() string { return "pooled fixture" }
func (s *pooledTestSource) SetEventHandler(f func(SourceEvent)) {
	s.mu.Lock()
	s.callback = f
	s.mu.Unlock()
}
func (s *pooledTestSource) Configure(_ context.Context, c StreamConfiguration) error {
	s.mu.Lock()
	s.config = c
	s.mu.Unlock()
	return nil
}
func (s *pooledTestSource) SetBitrateKbps(int) {}
func (s *pooledTestSource) RequestKeyFrame()   { s.keyframes.Add(1) }
func (s *pooledTestSource) Stream(ctx context.Context, emit func(media.Sample) error) error {
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case frame := <-s.frames:
			if err := emit(frame); err != nil {
				return err
			}
		}
	}
}
func TestSharedEncoderIsolatesSlowViewerAndSplitsSettings(t *testing.T) {
	var sources []*pooledTestSource
	pool := newCapturePool(func(o SourceOptions) (FrameSource, error) {
		s := &pooledTestSource{frames: make(chan media.Sample, 100), config: sourceConfiguration(o)}
		sources = append(sources, s)
		return s, nil
	})
	defer pool.Close()
	options := SourceOptions{Display: "1", FPS: 60, MaxWidth: 1920, MaxHeight: 1080, Bitrate: 12000, Profile: "high"}
	a, err := pool.Subscribe(options)
	if err != nil {
		t.Fatal(err)
	}
	b, err := pool.Subscribe(options)
	if err != nil {
		t.Fatal(err)
	}
	if len(sources) != 1 {
		t.Fatal("identical viewers started duplicate encoders")
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	blocked := make(chan struct{})
	entered := make(chan struct{})
	fast := make(chan uint64, 100)
	defer close(blocked)
	go a.Stream(ctx, func(sample media.Sample) error { fast <- sample.Metadata.(FrameMetadata).ID; return nil })
	go b.Stream(ctx, func(sample media.Sample) error {
		select {
		case <-entered:
		default:
			close(entered)
		}
		select {
		case <-blocked:
		case <-ctx.Done():
		}
		return nil
	})
	waitMulti(t, func() bool {
		pool.mu.Lock()
		defer pool.mu.Unlock()
		return a.(*sharedSource).running && b.(*sharedSource).running
	})
	for i := 1; i <= 30; i++ {
		sources[0].frames <- media.Sample{Data: []byte{1, 2, 3}, Metadata: FrameMetadata{ID: uint64(i), Generation: 1}}
	}
	deadline := time.After(2 * time.Second)
	for i := 0; i < 30; i++ {
		select {
		case <-fast:
		case <-deadline:
			t.Fatal("slow viewer blocked fast viewer")
		}
	}
	if len(b.(*sharedSource).frames) > 1 {
		t.Fatal("unbounded spectator queue")
	}
	config := sourceConfiguration(options)
	config.MaxWidth = 1280
	config.MaxHeight = 720
	if err := b.(AdaptiveFrameSource).Configure(ctx, config); err != nil {
		t.Fatal(err)
	}
	captures, encoders := pool.Counts()
	if captures != 1 || encoders != 2 {
		t.Fatalf("split resources: %d %d", captures, encoders)
	}
	if a.(*sharedSource).variant.config.MaxWidth != 1920 {
		t.Fatal("spectator changed main viewer resolution")
	}
	if err := b.(AdaptiveFrameSource).Configure(ctx, sourceConfiguration(options)); err != nil {
		t.Fatal(err)
	}
	_, encoders = pool.Counts()
	if encoders != 1 {
		t.Fatal("identical renditions did not merge")
	}
	b.(*sharedSource).Close()
	if a.(*sharedSource).closed {
		t.Fatal("closing spectator closed shared capture")
	}
	a.(*sharedSource).Close()
	captures, encoders = pool.Counts()
	if captures != 0 || encoders != 0 {
		t.Fatal("capture resource leak")
	}
}
func waitMulti(t *testing.T, predicate func() bool) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if predicate() {
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatal("condition timed out")
}

type failingReleaseSource struct {
	inputFrameSource
	fail atomic.Bool
}

func (s *failingReleaseSource) ReleaseInputChecked(context.Context) error {
	if s.fail.Load() {
		return errors.New("release was not acknowledged")
	}
	return nil
}
func TestControlHandoffRequiresAcknowledgedRelease(t *testing.T) {
	manager, template, _ := testManagerAndRequest(t, "github:7")
	defer manager.Shutdown(context.Background())
	source := &failingReleaseSource{inputFrameSource: inputFrameSource{blockingFrameSource: blockingFrameSource{started: make(chan struct{}), stopped: make(chan struct{})}, inputs: make(chan *dieterv1.RemoteDesktopInput, 4), released: make(chan struct{}, 4)}}
	manager.options.SourceFactory = func(SourceOptions) (FrameSource, error) { return source, nil }
	manager.options.CaptureProbe = func(context.Context, SourceOptions) error { return nil }
	manager.options.ControlProbe = func(context.Context, SourceOptions, bool) error { return nil }
	start := func(nonce string, version uint32) *Session {
		t.Helper()
		r := proto.Clone(template).(*dieterv1.StartRemoteDesktopRequest)
		r.ClientNonce = nonce
		r.Control = true
		r.InputProtocolVersion = version
		peer := testViewer(t, r)
		t.Cleanup(func() { peer.Close() })
		sub, err := manager.Start(r, "github:7")
		if err != nil {
			t.Fatal(err)
		}
		return manager.sessionFor(sub.SessionID)
	}
	second := start("first", inputProtocolVersion)
	third := start("second", inputProtocolVersion)
	source.fail.Store(true)
	grant := manager.controlGeneration
	if _, err := manager.SetControl(context.Background(), third.id, true); err == nil {
		t.Fatal("unacknowledged release transferred control")
	}
	if manager.controller != second || manager.controlGeneration != grant {
		t.Fatal("failed handoff changed authority")
	}
	source.fail.Store(false)
	if _, err := manager.SetControl(context.Background(), third.id, true); err != nil {
		t.Fatal(err)
	}
}
