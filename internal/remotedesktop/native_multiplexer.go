package remotedesktop

import (
	"context"
	"errors"
	"sync"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/pion/webrtc/v4/pkg/media"
)

// One signed native process hosts bounded encoders and shares ScreenCaptureKit
// surfaces between them. No raw desktop pixels cross the process boundary.
type nativeMultiplexer struct {
	mu       sync.Mutex
	next     uint64
	sources  map[uint64]*nativeRendition
	root     *nativeHelperSource
	cancel   context.CancelFunc
	finished chan struct{}
	retiring map[uint64]chan struct{}
}
type nativeRendition struct {
	mux        *nativeMultiplexer
	id         uint64
	template   *nativeHelperSource
	config     StreamConfiguration // mux.mu
	callback   func(SourceEvent)   // mux.mu
	frames     chan media.Sample
	done       chan struct{}
	started    bool // mux.mu
	createSent bool // mux.mu
	createDone chan struct{}
	removed    bool  // mux.mu
	closed     bool  // mux.mu
	failure    error // mux.mu
}

func newNativeMultiplexer() *nativeMultiplexer {
	return &nativeMultiplexer{sources: make(map[uint64]*nativeRendition), retiring: make(map[uint64]chan struct{})}
}
func (m *nativeMultiplexer) Source(template *nativeHelperSource) (FrameSource, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if len(m.sources) >= maxClients {
		return nil, errors.New("native encoder capacity reached")
	}
	m.next++
	s := &nativeRendition{mux: m, id: m.next, template: template, config: template.currentConfigurationLocked(), frames: make(chan media.Sample, 1), done: make(chan struct{}), createDone: make(chan struct{})}
	m.sources[s.id] = s
	return s, nil
}

func (m *nativeMultiplexer) process(ctx context.Context, template *nativeHelperSource) (*nativeHelperSource, error) {
	m.mu.Lock()
	if m.root != nil {
		root := m.root
		m.mu.Unlock()
		return waitNativeReady(ctx, root)
	}
	previous := m.finished
	m.mu.Unlock()
	if previous != nil {
		select {
		case <-previous:
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}
	m.mu.Lock()
	if m.root != nil {
		root := m.root
		m.mu.Unlock()
		return waitNativeReady(ctx, root)
	}
	root := &nativeHelperSource{path: template.path, display: template.display, profile: template.profile, codec: template.codec,
		fps: template.fps, bitrateKbps: template.bitrateKbps, maxWidth: template.maxWidth, maxHeight: template.maxHeight,
		synthetic: template.synthetic, inputAllowed: true, logger: template.logger, multiplex: true, ready: make(chan struct{})}
	processCtx, cancel := context.WithCancel(context.Background())
	m.root, m.cancel = root, cancel
	finished := make(chan struct{})
	m.finished = finished
	root.SetEventHandler(m.event)
	m.mu.Unlock()
	go func() {
		err := root.Stream(processCtx, m.frame)
		m.mu.Lock()
		if m.root == root {
			m.root = nil
			for _, source := range m.sources {
				source.failure = err
				if source.failure == nil {
					source.failure = errors.New("native capture helper stopped")
				}
				if !source.closed {
					source.closed = true
					close(source.done)
				}
			}
		}
		close(finished)
		m.mu.Unlock()
	}()
	return waitNativeReady(ctx, root)
}
func waitNativeReady(ctx context.Context, root *nativeHelperSource) (*nativeHelperSource, error) {
	select {
	case <-root.ready:
		return root, nil
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}
func (m *nativeMultiplexer) frame(sample media.Sample) error {
	metadata := sample.Metadata.(FrameMetadata)
	m.mu.Lock()
	source := m.sources[metadata.StreamID]
	if source != nil && !source.closed {
		select {
		case source.frames <- sample:
		default:
			m.mu.Unlock()
			return errors.New("native encoder exceeded its frame credit")
		}
	}
	m.mu.Unlock()
	return nil
}
func (m *nativeMultiplexer) event(event SourceEvent) {
	m.mu.Lock()
	s := m.sources[event.StreamID]
	var callback func(SourceEvent)
	if s != nil && !s.closed {
		callback = s.callback
		if event.Err != nil {
			s.failure = event.Err
			s.closed = true
			close(s.done)
		}
	}
	m.mu.Unlock()
	if callback != nil {
		callback(event)
	}
}
func (m *nativeMultiplexer) Close() {
	m.mu.Lock()
	cancel := m.cancel
	m.root = nil
	m.mu.Unlock()
	if cancel != nil {
		cancel()
	}
}

func (s *nativeRendition) Description() string     { return s.template.Description() }
func (s *nativeRendition) Codec() VideoCodec       { return s.template.Codec() }
func (s *nativeRendition) CodecParameters() string { return s.template.CodecParameters() }
func (s *nativeRendition) SetEventHandler(f func(SourceEvent)) {
	s.mux.mu.Lock()
	s.callback = f
	s.mux.mu.Unlock()
}
func (s *nativeRendition) command(ctx context.Context, command nativeCommand, wait bool) error {
	s.mux.mu.Lock()
	root, closed := s.mux.root, s.closed
	s.mux.mu.Unlock()
	if root == nil || closed {
		// Helper exit can race a frame-credit command. Preserve the same
		// recoverable classification as the stream's EOF, whichever wins.
		return errNativeHelperStopped
	}
	command.StreamID = s.id
	return root.send(ctx, command, wait)
}
func (s *nativeRendition) Stream(ctx context.Context, emit func(media.Sample) error) error {
	startup, cancel := context.WithTimeout(ctx, nativeStartupTimeout)
	defer cancel()
	if _, err := s.mux.process(startup, s.template); err != nil {
		return err
	}
	// Native removal acknowledges completed teardown, not just a queued stop.
	// Drain retired lanes before admitting a replacement hardware encoder.
	s.mux.mu.Lock()
	retired := make([]chan struct{}, 0, len(s.mux.retiring))
	for _, done := range s.mux.retiring {
		retired = append(retired, done)
	}
	s.mux.mu.Unlock()
	for _, done := range retired {
		select {
		case <-done:
		case <-startup.Done():
			return startup.Err()
		}
	}
	s.mux.mu.Lock()
	if s.closed {
		s.mux.mu.Unlock()
		return context.Canceled
	}
	config := s.config
	s.createSent = true
	s.mux.mu.Unlock()
	err := s.command(startup, nativeCommand{Kind: "create", Configuration: &config, Profile: s.template.profile, Codec: s.template.codec, ReferenceRecovery: s.template.referenceRecovery}, true)
	close(s.createDone)
	if err != nil {
		return err
	}
	s.mux.mu.Lock()
	latest := s.config
	s.started = true
	s.mux.mu.Unlock()
	if latest != config {
		if err := s.Configure(ctx, latest); err != nil {
			return err
		}
	}
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-s.done:
			s.mux.mu.Lock()
			err := s.failure
			s.mux.mu.Unlock()
			return err
		case sample := <-s.frames:
			if err := emit(sample); err != nil {
				return err
			}
			if err := s.command(ctx, nativeCommand{Kind: "frame_consumed", FrameID: sample.Metadata.(FrameMetadata).ID}, true); err != nil {
				return err
			}
		}
	}
}
func (s *nativeRendition) Configure(ctx context.Context, config StreamConfiguration) error {
	s.mux.mu.Lock()
	started := s.started
	if !started {
		s.config = config
	}
	s.mux.mu.Unlock()
	if !started {
		return nil
	}
	if err := s.command(ctx, nativeCommand{Kind: "configure", Configuration: &config}, true); err != nil {
		return err
	}
	s.mux.mu.Lock()
	s.config = config
	s.mux.mu.Unlock()
	return nil
}
func (s *nativeRendition) RequestKeyFrame() {
	_ = s.command(context.Background(), nativeCommand{Kind: "refresh"}, false)
}
func (s *nativeRendition) SetBitrateKbps(value int) {
	s.mux.mu.Lock()
	config := s.config
	s.mux.mu.Unlock()
	config.BitrateKbps = value
	_ = s.Configure(context.Background(), config)
}
func (s *nativeRendition) SendInput(ctx context.Context, input *dieterv1.RemoteDesktopInput) error {
	payload, err := translateNativeInput(input)
	if err != nil {
		return err
	}
	return s.command(ctx, nativeCommand{Kind: "input", Input: payload}, true)
}
func (s *nativeRendition) ReleaseInput(ctx context.Context) { _ = s.ReleaseInputChecked(ctx) }
func (s *nativeRendition) ReleaseInputChecked(ctx context.Context) error {
	return s.command(ctx, nativeCommand{Kind: "input", Input: &nativeInputPayload{Kind: "release_all"}}, true)
}
func (s *nativeRendition) Close() {
	m := s.mux
	m.mu.Lock()
	if s.removed {
		m.mu.Unlock()
		return
	}
	s.removed = true
	if !s.closed {
		s.closed = true
		close(s.done)
	}
	delete(m.sources, s.id)
	root, cancel := m.root, m.cancel
	last := len(m.sources) == 0
	if last {
		m.root = nil
	}
	var retired chan struct{}
	if !last && root != nil && s.createSent {
		retired = make(chan struct{})
		m.retiring[s.id] = retired
	}
	m.mu.Unlock()
	// Never block the capture registry on a native command/event callback.
	if last {
		if cancel != nil {
			cancel()
		}
		return
	}
	if retired != nil {
		go func() {
			<-s.createDone
			err := root.send(context.Background(), nativeCommand{Kind: "remove", StreamID: s.id}, true)
			// An unacknowledged teardown leaves hardware ownership unknown.
			// Retire this process instead of admitting unbounded native lanes.
			if err != nil && cancel != nil {
				cancel()
			}
			m.mu.Lock()
			delete(m.retiring, s.id)
			close(retired)
			m.mu.Unlock()
		}()
	}
}
